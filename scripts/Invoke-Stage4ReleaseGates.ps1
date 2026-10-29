[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$CustomerABearerToken = $env:DAVIDS_STAGE4_CUSTOMER_TOKEN,
    [string]$CustomerAId = $env:DAVIDS_STAGE4_CUSTOMER_ID,
    [string]$CustomerBBearerToken = $env:DAVIDS_STAGE4_SHADOW_CUSTOMER_TOKEN,
    [string]$CustomerBId = $env:DAVIDS_STAGE4_SHADOW_CUSTOMER_ID,
    [string]$AdminBearerToken = $env:DAVIDS_STAGE4_ADMIN_TOKEN,
    [string]$AdminEmail = $env:DAVIDS_STAGE4_ADMIN_EMAIL,
    [string]$AdminPassword = $env:DAVIDS_STAGE4_ADMIN_PASSWORD,
    [string]$AdminBffClientId = 'davids-admin-bff',
    [string]$AdminBffClientSecret = $env:DAVIDS_STAGE4_ADMIN_BFF_SECRET,
    [ValidateSet('Test', 'FuzzLean', 'Fuzz')]
    [string]$RestlerMode = 'FuzzLean',
    [double]$RestlerTimeBudgetHours = 0.25,
    [switch]$SkipAuthzMatrix,
    [switch]$SkipRestler,
    [switch]$SkipZap,
    [switch]$ValidateOnly,
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$davidsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $davidsRoot 'TestResults/stage4'
}

Write-Host '=== [1/4] Verify Gateway OpenAPI 3.1.1 & RESTler OpenAPI 3.0.3 Contracts ==='
& (Join-Path $PSScriptRoot 'Export-OpenApiSpecs.ps1') -VerifyOnly

if ($ValidateOnly) {
    Write-Host '=== [2/4] Validate Cross-Role Authorization Matrix & Burp Community Configs ==='
    & (Join-Path $PSScriptRoot 'Scan-AuthzMatrix.ps1') -ValidateConfigOnly

    Write-Host '=== [3/4] Validate Microsoft RESTler Stateful Fuzzing Configurations ==='
    & (Join-Path $PSScriptRoot 'Scan-Restler.ps1') -ValidateConfigOnly

    Write-Host '=== [4/4] Validate OWASP ZAP Automation Framework Plan ==='
    & (Join-Path $PSScriptRoot 'Scan-Zap.ps1') -ValidateConfigOnly

    Write-Host 'All Stage 4 release security gate configurations ($0 free OSS/Community toolchain) validated cleanly.'
    return
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

if (-not $SkipAuthzMatrix) {
    Write-Host '=== [2/4] Cross-Role Authorization Matrix (Automated Autorize) & JWT/OIDC Cryptographic Boundary Gate ==='
    $authzParams = @{
        GatewayUrl           = $GatewayUrl
        CustomerABearerToken = $CustomerABearerToken
        CustomerAId          = $CustomerAId
        CustomerBBearerToken = $CustomerBBearerToken
        CustomerBId          = $CustomerBId
        AdminBearerToken     = $AdminBearerToken
        AdminEmail           = $AdminEmail
        AdminPassword        = $AdminPassword
        AdminBffClientId     = $AdminBffClientId
        AdminBffClientSecret = $AdminBffClientSecret
        OutputDirectory      = (Join-Path $OutputDirectory 'authz')
    }
    & (Join-Path $PSScriptRoot 'Scan-AuthzMatrix.ps1') @authzParams
} else {
    Write-Host '=== [2/4] Skipping Cross-Role Authorization Matrix (-SkipAuthzMatrix) ==='
}

if (-not $SkipRestler) {
    Write-Host '=== [3/4] Microsoft RESTler Stateful Producer/Consumer API Fuzzing ==='
    $restlerParams = @{
        GatewayUrl                = $GatewayUrl
        Mode                      = $RestlerMode
        TimeBudgetHours           = $RestlerTimeBudgetHours
        CustomerBearerToken       = $CustomerABearerToken
        ShadowCustomerBearerToken = $CustomerBBearerToken
        AdminBearerToken          = $AdminBearerToken
        AdminEmail                = $AdminEmail
        AdminPassword             = $AdminPassword
        AdminBffClientId          = $AdminBffClientId
        AdminBffClientSecret      = $AdminBffClientSecret
        OutputDirectory           = (Join-Path $OutputDirectory 'restler')
    }
    & (Join-Path $PSScriptRoot 'Scan-Restler.ps1') @restlerParams
} else {
    Write-Host '=== [3/4] Skipping Microsoft RESTler (-SkipRestler) ==='
}

if (-not $SkipZap) {
    Write-Host '=== [4/4] OWASP ZAP Automation Framework Active/Passive & OpenAPI DAST ==='
    $zapParams = @{
        GatewayUrl           = $GatewayUrl
        CustomerBearerToken  = $CustomerABearerToken
        AdminBearerToken     = $AdminBearerToken
        AdminEmail           = $AdminEmail
        AdminPassword        = $AdminPassword
        AdminBffClientId     = $AdminBffClientId
        AdminBffClientSecret = $AdminBffClientSecret
        OutputDirectory      = (Join-Path $OutputDirectory 'zap')
    }
    & (Join-Path $PSScriptRoot 'Scan-Zap.ps1') @zapParams
} else {
    Write-Host '=== [4/4] Skipping OWASP ZAP (-SkipZap) ==='
}

Write-Host "All Stage 4 Quarterly / Release Security Verification Gates PASSED ($OutputDirectory)."
