[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$CustomerBearerToken = $env:DAVIDS_CUSTOMER_BEARER_TOKEN,
    [string]$AdminBearerToken = $env:DAVIDS_ADMIN_BEARER_TOKEN,
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
    Write-Host 'Schemathesis TOML configuration and all 3 OpenAPI 3.1 gateway contracts verified.'
    return
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/staging-nightly'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDirectory).Path
$resolvedRepoRoot = (Resolve-Path -LiteralPath $repoRoot).Path

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

    $pkce = New-PkcePair
    $redirectUri = 'http://localhost:17320/identity/callback'
    $authorizeUrl = "$normalizedGateway/identity/connect/authorize?client_id=davids-customer-pkce&response_type=code&redirect_uri=$([Uri]::EscapeDataString($redirectUri))&scope=$([Uri]::EscapeDataString('openid profile email roles offline_access davids_api'))&code_challenge=$($pkce.Challenge)&code_challenge_method=S256&state=staging-nightly"

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $form = [System.Net.Http.FormUrlEncodedContent]::new(@{
            email    = $email
            password = $password
        })
        $authorizeResp = $client.PostAsync($authorizeUrl, $form).GetAwaiter().GetResult()
        if ([int]$authorizeResp.StatusCode -ne 302 -or $null -eq $authorizeResp.Headers.Location) {
            throw "Expected 302 authorization code redirect from /identity/connect/authorize, got $([int]$authorizeResp.StatusCode)."
        }

        $locationQuery = $authorizeResp.Headers.Location.Query.TrimStart('?') -split '&'
        $code = ''
        foreach ($pair in $locationQuery) {
            $kv = $pair -split '=', 2
            if ($kv.Length -eq 2 -and $kv[0] -eq 'code') {
                $code = [Uri]::UnescapeDataString($kv[1])
            }
        }
        if ([string]::IsNullOrWhiteSpace($code)) {
            throw 'Authorization code missing from /identity/connect/authorize redirect.'
        }

        $tokenForm = [System.Net.Http.FormUrlEncodedContent]::new(@{
            grant_type    = 'authorization_code'
            client_id     = 'davids-customer-pkce'
            code          = $code
            redirect_uri  = $redirectUri
            code_verifier = $pkce.Verifier
        })
        $tokenResp = $client.PostAsync("$normalizedGateway/identity/connect/token", $tokenForm).GetAwaiter().GetResult()
        $tokenPayload = $tokenResp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $CustomerBearerToken = [string]$tokenPayload.access_token
        if ([string]::IsNullOrWhiteSpace($CustomerBearerToken)) {
            throw 'Failed to obtain customer RS256 access_token from /identity/connect/token.'
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
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
        $containerUrl = $normalizedGateway -replace '^(https?://)(localhost|127\.0\.0\.1)(:\d+)?', '$1host.docker.internal$3'
        $dockerArgs = @('run', '--rm')
        if ($IsLinux) {
            $dockerArgs += '--add-host=host.docker.internal:host-gateway'
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

# 1. Unauthenticated boundary fuzzing across all 3 OpenAPI 3.1 contracts
Invoke-SchemathesisSuite `
    -Label 'Identity OpenAPI (Unauthenticated Boundary Fuzzing)' `
    -SpecRelativePath 'security/staging-nightly/openapi/identity.gateway.openapi.json' `
    -ReportFileName 'schemathesis-unauth-identity.junit.xml' `
    -ExtraArgs @('--exclude-checks', 'positive_data_acceptance')

Invoke-SchemathesisSuite `
    -Label 'AdminIdentity OpenAPI (Unauthenticated Boundary Fuzzing)' `
    -SpecRelativePath 'security/staging-nightly/openapi/admin-identity.gateway.openapi.json' `
    -ReportFileName 'schemathesis-unauth-admin-identity.junit.xml' `
    -ExtraArgs @('--exclude-checks', 'positive_data_acceptance')

Invoke-SchemathesisSuite `
    -Label 'Customers OpenAPI (Unauthenticated Boundary Fuzzing)' `
    -SpecRelativePath 'security/staging-nightly/openapi/customers.gateway.openapi.json' `
    -ReportFileName 'schemathesis-unauth-customers.junit.xml' `
    -ExtraArgs @('--exclude-checks', 'positive_data_acceptance')

# 2. Authenticated Customer RS256 Bearer fuzzing + stateful API state-machine testing
if (-not [string]::IsNullOrWhiteSpace($CustomerBearerToken)) {
    Invoke-SchemathesisSuite `
        -Label 'Identity OpenAPI (Authenticated Customer RS256 + Stateful)' `
        -SpecRelativePath 'security/staging-nightly/openapi/identity.gateway.openapi.json' `
        -ReportFileName 'schemathesis-auth-identity.junit.xml' `
        -BearerToken $CustomerBearerToken

    Invoke-SchemathesisSuite `
        -Label 'Customers POST /customers (Authenticated Customer RS256 + Stateful)' `
        -SpecRelativePath 'security/staging-nightly/openapi/customers.gateway.openapi.json' `
        -ReportFileName 'schemathesis-auth-customers-user.junit.xml' `
        -BearerToken $CustomerBearerToken `
        -ExtraArgs @('--include-method', 'POST')
} else {
    Write-Warning 'Skipping authenticated Customer Schemathesis suites (supply -CustomerBearerToken, DAVIDS_CUSTOMER_BEARER_TOKEN, or -AutoProvisionCustomerToken).'
}

# 3. Authenticated Admin RS256 Bearer fuzzing + stateful API state-machine testing
if (-not [string]::IsNullOrWhiteSpace($AdminBearerToken)) {
    Invoke-SchemathesisSuite `
        -Label 'AdminIdentity OpenAPI (Authenticated Admin RS256)' `
        -SpecRelativePath 'security/staging-nightly/openapi/admin-identity.gateway.openapi.json' `
        -ReportFileName 'schemathesis-auth-admin-identity.junit.xml' `
        -BearerToken $AdminBearerToken

    Invoke-SchemathesisSuite `
        -Label 'Customers Admin Operations (Authenticated Admin RS256 + Stateful)' `
        -SpecRelativePath 'security/staging-nightly/openapi/customers.gateway.openapi.json' `
        -ReportFileName 'schemathesis-auth-customers-admin.junit.xml' `
        -BearerToken $AdminBearerToken `
        -ExtraArgs @('--exclude-method', 'POST')
} else {
    Write-Warning 'Skipping authenticated Admin Schemathesis suites (supply -AdminBearerToken or DAVIDS_ADMIN_BEARER_TOKEN).'
}

Write-Host "Schemathesis OpenAPI fuzzing completed cleanly. Reports saved to $resolvedOutputDir."
