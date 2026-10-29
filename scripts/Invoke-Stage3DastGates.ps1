[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$CustomerBearerToken = $env:DAVIDS_CUSTOMER_BEARER_TOKEN,
    [string]$AdminBearerToken = $env:DAVIDS_ADMIN_BEARER_TOKEN,
    [switch]$AutoProvisionCustomerToken,
    [switch]$InstallTools,
    [switch]$SkipDastardlyContainer,
    [switch]$ValidateOnly,
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '=== [1/4] Verify Gateway OpenAPI 3.1 Contracts ==='
& (Join-Path $PSScriptRoot 'Export-OpenApiSpecs.ps1') -VerifyOnly

if ($ValidateOnly) {
    Write-Host '=== [2/4] Validate Schemathesis Configuration ==='
    & (Join-Path $PSScriptRoot 'Scan-Schemathesis.ps1') -ValidateConfigOnly

    Write-Host '=== [3/4] Validate Custom Davids Nuclei Templates ==='
    if ($InstallTools) {
        & (Join-Path $PSScriptRoot 'Scan-Nuclei.ps1') -InstallNuclei -ValidateOnly
    } else {
        & (Join-Path $PSScriptRoot 'Scan-Nuclei.ps1') -ValidateOnly
    }

    Write-Host '=== [4/4] Validate PortSwigger Dastardly & Burp Suite DAST Configs ==='
    & (Join-Path $PSScriptRoot 'Scan-Dastardly.ps1') -ValidateConfigOnly

    Write-Host 'All Stage 3 DAST configurations, OpenAPI 3.1 contracts, and Nuclei templates validated cleanly.'
    return
}

Write-Host '=== [2/4] Schemathesis Property-Based & Stateful OpenAPI Fuzzing ==='
$stParams = @{
    GatewayUrl          = $GatewayUrl
    CustomerBearerToken = $CustomerBearerToken
    AdminBearerToken    = $AdminBearerToken
    OutputDirectory     = $OutputDirectory
}
if ($AutoProvisionCustomerToken) {
    $stParams['AutoProvisionCustomerToken'] = $true
}
& (Join-Path $PSScriptRoot 'Scan-Schemathesis.ps1') @stParams

Write-Host '=== [3/4] ProjectDiscovery Nuclei Posture Assertions & Vulnerability Regression ==='
$nucleiParams = @{
    GatewayUrl      = $GatewayUrl
    OutputDirectory = $OutputDirectory
}
if ($InstallTools) {
    $nucleiParams['InstallNuclei'] = $true
}
& (Join-Path $PSScriptRoot 'Scan-Nuclei.ps1') @nucleiParams

Write-Host '=== [4/4] PortSwigger Dastardly / Burp Suite DAST Web & BFF Scan ==='
if ($SkipDastardlyContainer) {
    & (Join-Path $PSScriptRoot 'Scan-Dastardly.ps1') -ValidateConfigOnly
} else {
    & (Join-Path $PSScriptRoot 'Scan-Dastardly.ps1') -GatewayUrl $GatewayUrl -OutputDirectory $OutputDirectory
}

Write-Host 'All Stage 3 Staging / Nightly DAST security gates passed.'
