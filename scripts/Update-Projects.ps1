$ErrorActionPreference = 'Stop'
$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent
$repositories = @(
    'Davids.Shared',
    'Davids.Services.Identity',
    'Davids.Services.AdminIdentity',
    'Davids.Services.Customers',
    'Davids.APIGateway',
    'Davids.Frontend.Admin'
)

foreach ($name in $repositories) {
    $path = Join-Path $workspaceRoot $name
    if (-not (Test-Path $path)) { throw "Missing '$path'. Run Get-Projects.ps1 -GitHubOwner <owner> first." }
    if (-not (Test-Path (Join-Path $path '.git'))) {
        Write-Warning "$name is present as a source folder but has no Git metadata; skipping pull."
        continue
    }

    $status = & git -C $path status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect Git status for $name." }
    if ($status) { throw "$name has uncommitted changes. Commit or stash them before updating repositories." }

    $branch = (& git -C $path branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
        throw "$name is not on a local branch; switch to a tracking branch before updating."
    }

    Write-Host "Fast-forwarding $name ($branch)"
    & git -C $path pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "Git pull failed for $name." }
}

Write-Host 'Component repositories are up to date.'
