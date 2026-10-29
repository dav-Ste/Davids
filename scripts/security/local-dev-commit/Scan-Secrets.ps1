[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$workspaceRoot = Split-Path $repoRoot -Parent

$repos = @(
    'Davids',
    'Davids.Shared',
    'Davids.Services.Identity',
    'Davids.Services.AdminIdentity',
    'Davids.Services.Customers',
    'Davids.APIGateway',
    'Davids.Frontend.Admin'
)

$gitleaks = $null
$cmd = Get-Command 'gitleaks' -ErrorAction SilentlyContinue
if ($null -ne $cmd) {
    $gitleaks = $cmd.Source
} elseif ($env:OS -eq 'Windows_NT' -and $env:LOCALAPPDATA) {
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\gitleaks\gitleaks.exe'
    if (Test-Path -LiteralPath $candidate) { $gitleaks = $candidate }
} else {
    $homeDir = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
    $candidate = Join-Path $homeDir '.local/bin/gitleaks'
    if (Test-Path -LiteralPath $candidate) { $gitleaks = $candidate }
}

if (-not $gitleaks) {
    throw "Gitleaks binary not found. Install it with './scripts/security/local-dev-commit/Install-GitHooks.ps1 -InstallGitleaks' or 'winget install Gitleaks.Gitleaks'."
}

foreach ($repoName in $repos) {
    $dir = if ($repoName -eq 'Davids') { $repoRoot } else { Join-Path $workspaceRoot $repoName }
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Missing sibling repository: $dir"
    }

    $configPath = Join-Path $dir '.gitleaks.toml'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Missing .gitleaks.toml in $dir"
    }

    Write-Host "Scanning $repoName with Gitleaks..."
    & $gitleaks dir $dir --config $configPath --verbose --redact --no-banner
    if ($LASTEXITCODE) {
        throw "Gitleaks detected a potential secret leak in $repoName (review redacted finding details above)."
    }
}

Write-Host 'All 7 Davids repositories passed Gitleaks secret scanning with zero findings.'
