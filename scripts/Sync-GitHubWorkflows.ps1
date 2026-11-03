[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$infraRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $infraRoot -Parent

$expectedWorkflows = [ordered]@{
    'Davids'                        = @('codeql.yml', 'pull-request-ci.yml', 'staging-nightly.yml', 'quarterly-release.yml', 'production-cluster.yml')
    'Davids.Shared'                 = @('codeql.yml', 'pull-request-ci.yml')
    'Davids.Services.Identity'      = @('codeql.yml', 'pull-request-ci.yml')
    'Davids.Services.AdminIdentity' = @('codeql.yml', 'pull-request-ci.yml')
    'Davids.Services.Customers'     = @('codeql.yml', 'pull-request-ci.yml')
    'Davids.APIGateway'             = @('codeql.yml', 'pull-request-ci.yml')
    'Davids.Frontend.Admin'         = @('codeql.yml', 'pull-request-ci.yml')
    'Davids.Frontend.Web'           = @('codeql.yml', 'pull-request-ci.yml')
}

$allowedDavidsRootScripts = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'Build.ps1',
        'Get-Projects.ps1',
        'Setup.ps1',
        'Start.ps1',
        'Sync-GitHubWorkflows.ps1',
        'Test-Infrastructure.ps1',
        'Test.ps1',
        'Update-Database.ps1',
        'Update-Projects.ps1',
        'security'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

$allowedDavidsSecurityEntries = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'README.md',
        'local-dev-commit',
        'pull-request-ci',
        'staging-nightly',
        'quarterly-release',
        'production-cluster'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

function Remove-RepositoryEntry {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][bool]$HasGit,
        [Parameter(Mandatory)][string]$Reason
    )

    $fullPath = Join-Path $RepoPath $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return $false
    }

    if ($PSCmdlet.ShouldProcess($fullPath, $Reason)) {
        if ($HasGit) {
            & git -C $RepoPath rm -rf --ignore-unmatch $RelativePath *> $null
        }
        if (Test-Path -LiteralPath $fullPath) {
            Remove-Item -LiteralPath $fullPath -Recurse -Force
        }
        Write-Host "Removed superseded entry: $RepoName/$RelativePath"
        return $true
    }
    return $false
}

$removedCount = 0

foreach ($entry in $expectedWorkflows.GetEnumerator()) {
    $repoName = [string]$entry.Key
    $allowed = [System.Collections.Generic.HashSet[string]]::new([string[]]$entry.Value, [StringComparer]::OrdinalIgnoreCase)
    $repoPath = Join-Path $workspaceRoot $repoName
    if (-not (Test-Path -LiteralPath $repoPath)) {
        continue
    }

    $hasGit = Test-Path -LiteralPath (Join-Path $repoPath '.git')
    $workflowsDir = Join-Path $repoPath '.github/workflows'
    if (Test-Path -LiteralPath $workflowsDir) {
        foreach ($file in (Get-ChildItem -LiteralPath $workflowsDir -File)) {
            if ($allowed.Contains($file.Name)) {
                continue
            }

            if (Remove-RepositoryEntry -RepoPath $repoPath -RepoName $repoName -RelativePath ".github/workflows/$($file.Name)" -HasGit $hasGit -Reason 'Remove superseded GitHub Actions workflow') {
                $removedCount++
            }
        }
    }

    foreach ($legacySln in (Get-ChildItem -LiteralPath $repoPath -Filter '*.sln' -File -ErrorAction SilentlyContinue)) {
        if (Remove-RepositoryEntry -RepoPath $repoPath -RepoName $repoName -RelativePath $legacySln.Name -HasGit $hasGit -Reason 'Remove superseded legacy .sln file') {
            $removedCount++
        }
    }

    if ($repoName -eq 'Davids') {
        foreach ($legacyRootDir in @('.github/codeql', '.semgrep')) {
            if (Remove-RepositoryEntry -RepoPath $repoPath -RepoName $repoName -RelativePath $legacyRootDir -HasGit $hasGit -Reason 'Remove relocated security configuration directory') {
                $removedCount++
            }
        }

        $scriptsDir = Join-Path $repoPath 'scripts'
        if (Test-Path -LiteralPath $scriptsDir) {
            foreach ($item in (Get-ChildItem -LiteralPath $scriptsDir -Force)) {
                if ($allowedDavidsRootScripts.Contains($item.Name)) {
                    continue
                }
                if (Remove-RepositoryEntry -RepoPath $repoPath -RepoName $repoName -RelativePath "scripts/$($item.Name)" -HasGit $hasGit -Reason 'Remove relocated root security script') {
                    $removedCount++
                }
            }
        }

        $securityDir = Join-Path $repoPath 'security'
        if (Test-Path -LiteralPath $securityDir) {
            foreach ($item in (Get-ChildItem -LiteralPath $securityDir -Force)) {
                if ($allowedDavidsSecurityEntries.Contains($item.Name)) {
                    continue
                }
                if (Remove-RepositoryEntry -RepoPath $repoPath -RepoName $repoName -RelativePath "security/$($item.Name)" -HasGit $hasGit -Reason 'Remove superseded pre-lifecycle security directory') {
                    $removedCount++
                }
            }
        }
    }
}

$identityRepoPath = Join-Path $workspaceRoot 'Davids.Services.Identity'
if (Test-Path -LiteralPath $identityRepoPath) {
    $identityGit = Join-Path $identityRepoPath '.git'
    if (-not (Test-Path -LiteralPath $identityGit)) {
        Write-Warning "Davids.Services.Identity is not yet a git repository locally. Initialize git and push 'main' to GitHub so cross-repo workflows can check out refs/heads/main."
    } else {
        & git -C $identityRepoPath rev-parse --verify HEAD *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Davids.Services.Identity has 0 commits on HEAD. Commit and run 'git push -u origin main' so cross-repo workflows find refs/heads/main."
        }
    }
}

if ($removedCount -eq 0) {
    Write-Host 'All 7 repositories contain only canonical lifecycle GitHub Actions workflows, .slnx solutions, and lifecycle security directories.'
} else {
    Write-Host "Removed $removedCount superseded entry/entries. Commit and push all 7 repositories so GitHub stops running superseded workflows."
}
