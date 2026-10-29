[CmdletBinding()]
param(
    [switch]$InstallTools
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$localDevDir = Join-Path $repoRoot 'scripts/security/local-dev-commit'

Write-Host '=== [1/4] Gitleaks Secret Scan ==='
if ($InstallTools) {
    & (Join-Path $localDevDir 'Install-GitHooks.ps1') -InstallGitleaks
}
& (Join-Path $localDevDir 'Scan-Secrets.ps1')

Write-Host '=== [2/4] Custom Davids Semgrep SAST ==='
& (Join-Path $PSScriptRoot 'Scan-Semgrep.ps1')

Write-Host '=== [3/4] Checkov IaC + istioctl analyze ==='
if ($InstallTools) {
    & (Join-Path $PSScriptRoot 'Scan-IaC.ps1') -InstallIstioctl
} else {
    & (Join-Path $PSScriptRoot 'Scan-IaC.ps1')
}

Write-Host '=== [4/4] NuGet JSON Audit + SHA-Pinned Grype & Trivy ==='
if ($InstallTools) {
    & (Join-Path $PSScriptRoot 'Scan-SupplyChain.ps1') -InstallScanners
} else {
    & (Join-Path $PSScriptRoot 'Scan-SupplyChain.ps1')
}

Write-Host 'All Pull Request CI security gates passed across all 7 Davids repositories.'
