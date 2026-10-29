[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GitHubOwner
)

$ErrorActionPreference = 'Stop'
$owner = $GitHubOwner.Trim().Trim('/')
if ($owner -match '^https?://github\.com/') {
    $owner = ($owner -replace '^https?://github\.com/', '').Trim('/')
}
if ($owner -match '/' -or [string]::IsNullOrWhiteSpace($owner)) {
    throw 'Pass a GitHub user or organization name, not a full repository URL.'
}

$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent
$repositories = @(
    @{ Name = 'Davids.Shared'; Solution = 'Davids.Shared.sln' },
    @{ Name = 'Davids.Services.Identity'; Solution = 'Davids.Services.Identity.sln' },
    @{ Name = 'Davids.Services.AdminIdentity'; Solution = 'Davids.Services.AdminIdentity.sln' },
    @{ Name = 'Davids.Services.Customers'; Solution = 'Davids.Services.Customers.sln' },
    @{ Name = 'Davids.APIGateway'; Solution = 'Davids.APIGateway.sln' },
    @{ Name = 'Davids.Frontend.Admin'; Solution = 'Davids.Frontend.Admin.sln' }
)

foreach ($repository in $repositories) {
    $destination = Join-Path $workspaceRoot $repository.Name
    $solutionPath = Join-Path $destination $repository.Solution

    if (Test-Path $destination) {
        if ((Test-Path (Join-Path $destination '.git')) -or (Test-Path $solutionPath)) {
            Write-Host "Already present; leaving $($repository.Name) unchanged. Use Update-Projects.ps1 for a safe fast-forward."
            continue
        }
        throw "The destination '$destination' already exists but is not a recognized checkout. Move it aside before cloning."
    }

    $url = "https://github.com/$owner/$($repository.Name).git"
    Write-Host "Cloning $url into $destination"
    & git clone -- $url $destination
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $destination) { Remove-Item -Recurse -Force $destination }
        throw "Git clone failed for $($repository.Name). Check the repository owner, access and Git credentials."
    }
}

Write-Host "Component checkouts are ready beside '$infraRoot'. Open Davids.sln for the aggregate Aspire solution."
