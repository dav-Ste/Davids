[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$CustomerBearerToken = $env:DAVIDS_CUSTOMER_BEARER_TOKEN,
    [string]$AdminBearerToken = $env:DAVIDS_ADMIN_BEARER_TOKEN,
    [string]$AdminEmail = $env:DAVIDS_ADMIN_EMAIL,
    [string]$AdminPassword = $env:DAVIDS_ADMIN_PASSWORD,
    [string]$AdminBffClientSecret = $env:DAVIDS_ADMIN_BFF_CLIENT_SECRET,
    [switch]$AutoProvisionCustomerToken,
    [switch]$ValidateConfigOnly,
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$configFile = Join-Path $repoRoot 'security/staging-nightly/schemathesis/schemathesis.toml'
$openApiDir = Join-Path $repoRoot 'security/staging-nightly/openapi'

if (-not (Test-Path -LiteralPath $configFile)) {
    throw "Missing Schemathesis configuration file: $configFile"
}

& (Join-Path $PSScriptRoot 'Export-OpenApiSpecs.ps1') -VerifyOnly

if ($ValidateConfigOnly) {
    Write-Host 'Schemathesis TOML configuration and all 7 OpenAPI 3.1 gateway contracts verified.'
    return
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/staging-nightly'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDirectory).Path
$resolvedRepoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
$realmOutDir = Join-Path $resolvedOutputDir 'realm-openapi'
& (Join-Path $PSScriptRoot 'Export-OpenApiSpecs.ps1') -VerifyOnly -RealmOutputDirectory $realmOutDir

# Digest-pinned Schemathesis v4.32.6 container image for Docker Desktop fallback.
$schemathesisImage = 'schemathesis/schemathesis:v4.32.6@sha256:8718231f162f7db12f7aa27f9524b8544d98b0292567e304c446f249fcf03cc7'
$schemathesisCmd = Get-Command 'schemathesis' -ErrorAction SilentlyContinue
$dockerCmd = Get-Command 'docker' -ErrorAction SilentlyContinue

if ($null -eq $schemathesisCmd -and $null -eq $dockerCmd) {
    throw "Neither 'schemathesis' nor 'docker' was found on PATH. Install Schemathesis ('pip install schemathesis==4.32.6') or start Docker Desktop."
}

$normalizedGateway = $GatewayUrl.TrimEnd('/')

function New-PkcePair {
    $verifierBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($verifierBytes)
    $verifier = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $challengeBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{
        Verifier  = $verifier
        Challenge = $challenge
    }
}

function Invoke-PkceTokenMint {
    param(
        [Parameter(Mandatory)][string]$RoutePrefix,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$ClientSecret = '',
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password
    )

    $pkce = New-PkcePair
    $state = 'schemathesis-' + [Guid]::NewGuid().ToString('N')
    $queryPairs = @(
        "client_id=$([Uri]::EscapeDataString($ClientId))",
        "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))",
        "response_type=code",
        "scope=$([Uri]::EscapeDataString($Scope))",
        "code_challenge=$($pkce.Challenge)",
        "code_challenge_method=S256",
        "state=$state"
    ) -join '&'

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $getResp = Invoke-WebRequest -Uri "$normalizedGateway/$RoutePrefix/connect/authorize?$queryPairs" -Method Get -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $getResp -or [int]$getResp.StatusCode -ne 200) {
        $actualCode = if ($null -eq $getResp) { 0 } else { [int]$getResp.StatusCode }
        throw "GET /$RoutePrefix/connect/authorize failed with HTTP $actualCode."
    }

    $match = [regex]::Match($getResp.Content, 'name="request_token"\s+value="([^"]*)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Missing hidden 'request_token' CSRF field in /$RoutePrefix/connect/authorize."
    }
    $requestToken = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)

    $formBody = @{
        client_id             = $ClientId
        redirect_uri          = $RedirectUri
        response_type         = 'code'
        scope                 = $Scope
        code_challenge        = $pkce.Challenge
        code_challenge_method = 'S256'
        state                 = $state
        request_token         = $requestToken
        email                 = $Email
        password              = $Password
    }
    $postResp = Invoke-WebRequest -Uri "$normalizedGateway/$RoutePrefix/connect/authorize" -Method Post -Body $formBody -ContentType 'application/x-www-form-urlencoded' -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $postResp -or [int]$postResp.StatusCode -notin @(302, 303)) {
        $actualCode = if ($null -eq $postResp) { 0 } else { [int]$postResp.StatusCode }
        throw "POST /$RoutePrefix/connect/authorize failed with HTTP $actualCode."
    }

    $locationHeader = [string]$postResp.Headers['Location']
    $locationUri = if ($locationHeader.StartsWith('http', [StringComparison]::OrdinalIgnoreCase)) {
        [Uri]$locationHeader
    } else {
        [Uri]::new([Uri]$normalizedGateway, $locationHeader)
    }
    $parsedQuery = [System.Web.HttpUtility]::ParseQueryString($locationUri.Query)
    $code = [string]$parsedQuery['code']
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "Authorization code missing from /$RoutePrefix/connect/authorize redirect."
    }

    $tokenBody = @{
        grant_type    = 'authorization_code'
        client_id     = $ClientId
        code          = $code
        redirect_uri  = $RedirectUri
        code_verifier = $pkce.Verifier
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientSecret)) {
        $tokenBody['client_secret'] = $ClientSecret
    }

    $tokenPayload = Invoke-RestMethod -Uri "$normalizedGateway/$RoutePrefix/connect/token" -Method Post -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
    $accessToken = [string]$tokenPayload.access_token
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Failed to obtain RS256 access_token from /$RoutePrefix/connect/token."
    }
    return $accessToken
}

if ($AutoProvisionCustomerToken -and [string]::IsNullOrWhiteSpace($CustomerBearerToken)) {
    Write-Host "Auto-provisioning ephemeral PKCE S256 customer RS256 access token against $normalizedGateway ..."
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 10)
    $email = "st.$suffix@davids.example"
    $password = "StFuzz!$suffix#Aa9"

    $signUpBody = @{
        email    = $email
        password = $password
        role     = 'user'
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "$normalizedGateway/identity/sign-up" -Method Post -ContentType 'application/json' -Body $signUpBody | Out-Null

    $CustomerBearerToken = Invoke-PkceTokenMint `
        -RoutePrefix 'identity' `
        -ClientId 'davids-web' `
        -RedirectUri 'https://localhost/callback' `
        -Scope 'openid email profile roles offline_access davids-services' `
        -Email $email `
        -Password $password
}

if ([string]::IsNullOrWhiteSpace($AdminBearerToken) -and
    -not [string]::IsNullOrWhiteSpace($AdminEmail) -and
    -not [string]::IsNullOrWhiteSpace($AdminPassword) -and
    -not [string]::IsNullOrWhiteSpace($AdminBffClientSecret)) {
    Write-Host "Minting PKCE S256 admin RS256 access token against $normalizedGateway ..."
    $AdminBearerToken = Invoke-PkceTokenMint `
        -RoutePrefix 'admin-identity' `
        -ClientId 'davids-admin-bff' `
        -ClientSecret $AdminBffClientSecret `
        -RedirectUri 'https://localhost/signin-oidc' `
        -Scope 'openid email profile roles offline_access davids-admin' `
        -Email $AdminEmail `
        -Password $AdminPassword
}

function Invoke-SchemathesisSuite {
    param(
        [string]$Label,
        [string]$SpecRelativePath,
        [string]$ReportFileName,
        [string]$BearerToken = '',
        [string[]]$ExtraArgs = @()
    )

    Write-Host "=== Schemathesis: $Label ==="
    if ($null -ne $schemathesisCmd) {
        $cliArgs = @(
            '--config-file', $configFile,
            'run', (Join-Path $repoRoot $SpecRelativePath),
            '--url', $normalizedGateway,
            '--report', 'junit',
            '--report-junit-path', (Join-Path $resolvedOutputDir $ReportFileName),
            '--warnings', 'off'
        )
        if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
            $cliArgs += @('-H', "Authorization: Bearer $BearerToken")
        }
        $cliArgs += $ExtraArgs

        & $schemathesisCmd.Source @cliArgs
        if ($LASTEXITCODE) {
            throw "Schemathesis suite '$Label' failed with exit code $LASTEXITCODE."
        }
    } else {
        $dockerArgs = @('run', '--rm')
        if ($IsLinux) {
            $dockerArgs += '--network=host'
            $containerUrl = $normalizedGateway
        } else {
            $containerUrl = $normalizedGateway -replace '^(https?://)(localhost|127\.0\.0\.1)(:\d+)?', '$1host.docker.internal$3'
        }
        $dockerArgs += @(
            '--mount', "type=bind,source=$resolvedRepoRoot,target=/work,readonly",
            '--mount', "type=bind,source=$resolvedOutputDir,target=/reports",
            '-w', '/work',
            $schemathesisImage,
            '--config-file', 'security/staging-nightly/schemathesis/schemathesis.toml',
            'run', $SpecRelativePath,
            '--url', $containerUrl,
            '--report', 'junit',
            '--report-junit-path', "/reports/$ReportFileName",
            '--warnings', 'off'
        )
        if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
            $dockerArgs += @('-H', "Authorization: Bearer $BearerToken")
        }
        $dockerArgs += $ExtraArgs

        & $dockerCmd.Source @dockerArgs
        if ($LASTEXITCODE) {
            throw "Schemathesis container suite '$Label' failed with exit code $LASTEXITCODE."
        }
    }
}

# 1. Unauthenticated boundary fuzzing across all 7 OpenAPI 3.1 contracts (57 operations)
foreach ($unauthSpec in @(
    @{ Name = 'Identity';      Spec = 'security/staging-nightly/openapi/identity.gateway.openapi.json';       Report = 'schemathesis-unauth-identity.junit.xml' },
    @{ Name = 'AdminIdentity'; Spec = 'security/staging-nightly/openapi/admin-identity.gateway.openapi.json'; Report = 'schemathesis-unauth-admin-identity.junit.xml' },
    @{ Name = 'Customers';     Spec = 'security/staging-nightly/openapi/customers.gateway.openapi.json';      Report = 'schemathesis-unauth-customers.junit.xml' },
    @{ Name = 'Products';      Spec = 'security/staging-nightly/openapi/products.gateway.openapi.json';       Report = 'schemathesis-unauth-products.junit.xml' },
    @{ Name = 'Baskets';       Spec = 'security/staging-nightly/openapi/baskets.gateway.openapi.json';        Report = 'schemathesis-unauth-baskets.junit.xml' },
    @{ Name = 'Orders';        Spec = 'security/staging-nightly/openapi/orders.gateway.openapi.json';         Report = 'schemathesis-unauth-orders.junit.xml' },
    @{ Name = 'Payments';      Spec = 'security/staging-nightly/openapi/payments.gateway.openapi.json';       Report = 'schemathesis-unauth-payments.junit.xml' }
)) {
    Invoke-SchemathesisSuite `
        -Label "$($unauthSpec.Name) OpenAPI (Unauthenticated Boundary Fuzzing)" `
        -SpecRelativePath $unauthSpec.Spec `
        -ReportFileName $unauthSpec.Report `
        -ExtraArgs @('--exclude-checks', 'positive_data_acceptance')
}

$realmRelBase = [System.IO.Path]::GetRelativePath($resolvedRepoRoot, $realmOutDir).Replace('\', '/')

# 2. Authenticated Customer RS256 Bearer fuzzing + stateful API state-machine testing (5 realm contracts, 23 operations)
if (-not [string]::IsNullOrWhiteSpace($CustomerBearerToken)) {
    foreach ($custSuite in @(
        @{ Label = 'Identity OpenAPI (Authenticated Customer RS256 + Stateful)';  File = 'identity-customer.openapi.json';  Report = 'schemathesis-auth-identity.junit.xml' },
        @{ Label = 'Customers Self-Service (Authenticated Customer RS256)';       File = 'customers-customer.openapi.json'; Report = 'schemathesis-auth-customers-customer.junit.xml' },
        @{ Label = 'Baskets OpenAPI (Authenticated Customer RS256 + Stateful)';   File = 'baskets-customer.openapi.json';   Report = 'schemathesis-auth-baskets-customer.junit.xml' },
        @{ Label = 'Orders Customer OpenAPI (Authenticated Customer RS256)';      File = 'orders-customer.openapi.json';    Report = 'schemathesis-auth-orders-customer.junit.xml' },
        @{ Label = 'Payments Customer OpenAPI (Authenticated Customer RS256)';    File = 'payments-customer.openapi.json';  Report = 'schemathesis-auth-payments-customer.junit.xml' }
    )) {
        Invoke-SchemathesisSuite `
            -Label $custSuite.Label `
            -SpecRelativePath "$realmRelBase/$($custSuite.File)" `
            -ReportFileName $custSuite.Report `
            -BearerToken $CustomerBearerToken
    }
} else {
    Write-Warning 'Skipping authenticated Customer Schemathesis suites (supply -CustomerBearerToken, DAVIDS_CUSTOMER_BEARER_TOKEN, or -AutoProvisionCustomerToken).'
}

# 3. Authenticated Admin RS256 Bearer fuzzing + stateful API state-machine testing (6 realm contracts, 34 operations)
if (-not [string]::IsNullOrWhiteSpace($AdminBearerToken)) {
    foreach ($admSuite in @(
        @{ Label = 'Customer-Accounts Workforce Operations (Authenticated Admin RS256)'; File = 'customer-accounts-admin.openapi.json'; Report = 'schemathesis-auth-customer-accounts-admin.junit.xml' },
        @{ Label = 'AdminIdentity OpenAPI (Authenticated Admin RS256)';                  File = 'admin-identity-admin.openapi.json';    Report = 'schemathesis-auth-admin-identity.junit.xml' },
        @{ Label = 'Customers Admin Operations (Authenticated Admin RS256 + Stateful)';  File = 'customers-admin.openapi.json';         Report = 'schemathesis-auth-customers-admin.junit.xml' },
        @{ Label = 'Products Public + Workforce Catalog (Authenticated Admin RS256)';    File = 'products-admin.openapi.json';          Report = 'schemathesis-auth-products-admin.junit.xml' },
        @{ Label = 'Orders Workforce Operations (Authenticated Admin RS256)';            File = 'orders-admin.openapi.json';            Report = 'schemathesis-auth-orders-admin.junit.xml' },
        @{ Label = 'Payments Workforce Operations (Authenticated Admin RS256)';          File = 'payments-admin.openapi.json';          Report = 'schemathesis-auth-payments-admin.junit.xml' }
    )) {
        Invoke-SchemathesisSuite `
            -Label $admSuite.Label `
            -SpecRelativePath "$realmRelBase/$($admSuite.File)" `
            -ReportFileName $admSuite.Report `
            -BearerToken $AdminBearerToken
    }
} else {
    Write-Warning 'Skipping authenticated Admin Schemathesis suites (supply -AdminBearerToken or DAVIDS_ADMIN_BEARER_TOKEN).'
}

Write-Host "Schemathesis OpenAPI fuzzing completed cleanly. Reports saved to $resolvedOutputDir."
