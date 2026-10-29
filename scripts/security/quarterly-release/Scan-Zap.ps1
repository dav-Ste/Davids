[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$ZapImage = 'ghcr.io/zaproxy/zaproxy:2.17.0@sha256:030d3df57735dacbb83464854758e674dd9ad01d79d12a129a8e58b1fd384238',
    [string]$AutomationPlanPath = '',
    [string]$CustomerBearerToken = $env:DAVIDS_RELEASE_CUSTOMER_TOKEN,
    [string]$AdminBearerToken = $env:DAVIDS_RELEASE_ADMIN_TOKEN,
    [string]$CustomerEmail = $env:DAVIDS_RELEASE_CUSTOMER_EMAIL,
    [string]$CustomerPassword = $env:DAVIDS_RELEASE_CUSTOMER_PASSWORD,
    [string]$AdminEmail = $env:DAVIDS_RELEASE_ADMIN_EMAIL,
    [string]$AdminPassword = $env:DAVIDS_RELEASE_ADMIN_PASSWORD,
    [string]$AdminBffClientId = 'davids-admin-bff',
    [string]$AdminBffClientSecret = $env:DAVIDS_RELEASE_ADMIN_BFF_SECRET,
    [string]$AdminRedirectUri = 'https://localhost/signin-oidc',
    [string]$CustomerRedirectUri = 'https://localhost/callback',
    [string]$OutputDirectory = '',
    [switch]$ValidateConfigOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
if ([string]::IsNullOrWhiteSpace($AutomationPlanPath)) {
    $AutomationPlanPath = Join-Path $repoRoot 'security/quarterly-release/zap/zap-automation.yaml'
}
if (-not (Test-Path -LiteralPath $AutomationPlanPath)) {
    throw "OWASP ZAP Automation Framework plan not found: $AutomationPlanPath"
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/quarterly-release/zap'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$planRaw = Get-Content -LiteralPath $AutomationPlanPath -Raw
$requiredMarkers = @(
    'contexts:',
    'name: "Davids-Gateway"',
    '- type: passiveScan-config',
    '- type: replacer',
    '- type: openapi',
    '- type: spider',
    '- type: activeScan',
    '- type: report',
    'template: "sarif-json"',
    '- type: exitStatus',
    'errorLevel: "Medium"'
)
foreach ($marker in $requiredMarkers) {
    if (-not $planRaw.Contains($marker)) {
        throw "OWASP ZAP Automation plan '$AutomationPlanPath' is missing required section/property: $marker"
    }
}

& (Join-Path $repoRoot 'scripts/security/staging-nightly/Export-OpenApiSpecs.ps1') -VerifyOnly

if ($ValidateConfigOnly) {
    Write-Host "Verified OWASP ZAP Quarterly / Release Automation Framework plan: $AutomationPlanPath"
    return
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker CLI is required to run OWASP ZAP container scans. Install Docker Desktop/Engine or pass -ValidateConfigOnly.'
}

function New-PkcePair {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ Verifier = $verifier; Challenge = $challenge }
}

function Get-OidcAccessTokenPkce {
    param(
        [Parameter(Mandatory)][string]$BaseGatewayUrl,
        [Parameter(Mandatory)][string]$RoutePrefix,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$ClientSecret = '',
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password
    )

    $pkce = New-PkcePair
    $state = 'zap-' + [Guid]::NewGuid().ToString('N')
    $queryPairs = @(
        "client_id=$([Uri]::EscapeDataString($ClientId))",
        "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))",
        "response_type=code",
        "scope=$([Uri]::EscapeDataString($Scope))",
        "code_challenge=$($pkce.Challenge)",
        "code_challenge_method=S256",
        "state=$state"
    ) -join '&'

    $authorizeGetUri = "$($BaseGatewayUrl.TrimEnd('/'))/$RoutePrefix/connect/authorize?$queryPairs"
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $getResp = Invoke-WebRequest -Uri $authorizeGetUri -Method Get -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $getResp -or [int]$getResp.StatusCode -ne 200) {
        throw "GET $authorizeGetUri did not return HTTP 200."
    }

    $match = [regex]::Match($getResp.Content, 'name="request_token"\s+value="([^"]*)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Missing hidden 'request_token' field in /$RoutePrefix/connect/authorize login form."
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

    $authorizePostUri = "$($BaseGatewayUrl.TrimEnd('/'))/$RoutePrefix/connect/authorize"
    $postResp = Invoke-WebRequest -Uri $authorizePostUri -Method Post -Body $formBody -ContentType 'application/x-www-form-urlencoded' -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $postResp -or [int]$postResp.StatusCode -notin @(302, 303)) {
        throw "POST $authorizePostUri failed to redirect."
    }

    $locationHeader = [string]$postResp.Headers['Location']
    $locationUri = if ($locationHeader.StartsWith('http', [StringComparison]::OrdinalIgnoreCase)) {
        [Uri]$locationHeader
    } else {
        [Uri]::new([Uri]$BaseGatewayUrl, $locationHeader)
    }

    $parsedQuery = [System.Web.HttpUtility]::ParseQueryString($locationUri.Query)
    $code = $parsedQuery['code']
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "Authorization redirect from /$RoutePrefix/connect/authorize did not contain an authorization code."
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

    $tokenUri = "$($BaseGatewayUrl.TrimEnd('/'))/$RoutePrefix/connect/token"
    $tokenResp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
    return [string]$tokenResp.access_token
}

if ([string]::IsNullOrWhiteSpace($CustomerBearerToken)) {
    if ([string]::IsNullOrWhiteSpace($CustomerEmail)) {
        $CustomerEmail = "zap.seed.$([Guid]::NewGuid().ToString('N').Substring(0, 8))@davids.example"
        $CustomerPassword = "ZapSeed!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Zz9"
        Invoke-RestMethod -Uri "$($GatewayUrl.TrimEnd('/'))/identity/sign-up" -Method Post -ContentType 'application/json' -Body (@{
            email    = $CustomerEmail
            password = $CustomerPassword
            role     = 'user'
        } | ConvertTo-Json) | Out-Null
    }
    $CustomerBearerToken = Get-OidcAccessTokenPkce `
        -BaseGatewayUrl $GatewayUrl `
        -RoutePrefix 'identity' `
        -ClientId 'davids-web' `
        -RedirectUri $CustomerRedirectUri `
        -Scope 'openid email profile roles offline_access davids-services' `
        -Email $CustomerEmail `
        -Password $CustomerPassword
}

if ([string]::IsNullOrWhiteSpace($AdminBearerToken)) {
    if ([string]::IsNullOrWhiteSpace($AdminEmail) -or [string]::IsNullOrWhiteSpace($AdminPassword) -or [string]::IsNullOrWhiteSpace($AdminBffClientSecret)) {
        throw 'Provide -AdminBearerToken (or DAVIDS_RELEASE_ADMIN_TOKEN), or supply -AdminEmail, -AdminPassword, and -AdminBffClientSecret.'
    }
    $AdminBearerToken = Get-OidcAccessTokenPkce `
        -BaseGatewayUrl $GatewayUrl `
        -RoutePrefix 'admin-identity' `
        -ClientId $AdminBffClientId `
        -ClientSecret $AdminBffClientSecret `
        -RedirectUri $AdminRedirectUri `
        -Scope 'openid email profile roles offline_access davids-admin' `
        -Email $AdminEmail `
        -Password $AdminPassword
}

$parsedGateway = [Uri]$GatewayUrl
$containerTargetUrl = if ($parsedGateway.Host -in @('localhost', '127.0.0.1', '::1')) {
    "$($parsedGateway.Scheme)://host.docker.internal:$($parsedGateway.Port)"
} else {
    $GatewayUrl.TrimEnd('/')
}

$wrkSpecsDir = Join-Path $OutputDirectory 'specs'
$wrkReportsDir = Join-Path $OutputDirectory 'reports'
New-Item -ItemType Directory -Path $wrkSpecsDir -Force | Out-Null
New-Item -ItemType Directory -Path $wrkReportsDir -Force | Out-Null

foreach ($specName in @('identity.restler.openapi.json', 'admin-identity.restler.openapi.json', 'customers.restler.openapi.json')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "security/quarterly-release/restler/specs/$specName") -Destination (Join-Path $wrkSpecsDir $specName) -Force
}

$runtimePlanFile = Join-Path $OutputDirectory 'zap-quarterly-release.runtime.yaml'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$hydratedPlan = $planRaw.
    Replace('${ZAP_TARGET_URL}', $containerTargetUrl).
    Replace('${ZAP_CUSTOMER_BEARER_HEADER}', "Bearer $($CustomerBearerToken.Trim())").
    Replace('${ZAP_ADMIN_BEARER_HEADER}', "Bearer $($AdminBearerToken.Trim())")

[System.IO.File]::WriteAllText($runtimePlanFile, $hydratedPlan, $utf8NoBom)

try {
    $dockerArgs = @('run', '--rm')
    if ($IsLinux) {
        $dockerArgs += '--add-host=host.docker.internal:host-gateway'
    }
    $dockerArgs += @(
        '-v', "${OutputDirectory}:/zap/wrk:rw",
        $ZapImage,
        'zap.sh', '-cmd', '-autorun', '/zap/wrk/zap-quarterly-release.runtime.yaml'
    )

    Write-Host "=== Quarterly / Release: Running OWASP ZAP 2.17.0 Automation Framework against $containerTargetUrl ==="
    & docker @dockerArgs
    $zapExit = $LASTEXITCODE
    if ($zapExit -ne 0) {
        throw "OWASP ZAP Quarterly / Release active/passive scan FAILED with exit code $zapExit (Medium/High alert threshold exceeded). Inspect $wrkReportsDir."
    }
    Write-Host "Quarterly / Release OWASP ZAP gate PASSED (0 Medium/High alerts). Reports written to $wrkReportsDir"
} finally {
    if (Test-Path -LiteralPath $runtimePlanFile) {
        Remove-Item -LiteralPath $runtimePlanFile -Force
    }
}
