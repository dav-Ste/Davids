[CmdletBinding()]
param(
    [switch]$InstallGitleaks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '=== [1/3] Git Pre-Commit Hooks ==='
if ($InstallGitleaks) {
    & (Join-Path $PSScriptRoot 'Install-GitHooks.ps1') -InstallGitleaks
} else {
    & (Join-Path $PSScriptRoot 'Install-GitHooks.ps1')
}

Write-Host '=== [2/3] Gitleaks Secret & Private-Key Scan ==='
& (Join-Path $PSScriptRoot 'Scan-Secrets.ps1')

Write-Host '=== [3/3] NuGet Direct & Transitive Vulnerability Audit ==='
& (Join-Path $PSScriptRoot 'Verify-Dependencies.ps1')

Write-Host 'All Local Dev / Commit security gates passed across all 7 Davids repositories.'
