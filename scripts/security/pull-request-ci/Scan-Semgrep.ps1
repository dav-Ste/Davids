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

# Digest-pinned Semgrep v1.182.0 container image for Windows / Docker Desktop fallback.
$semgrepImage = 'semgrep/semgrep:1.182.0@sha256:4a34048c04fef049f71665047f074cffb00cc3d89482f965a5cd151d589237af'
$semgrepCmd = Get-Command 'semgrep' -ErrorAction SilentlyContinue
$dockerCmd = Get-Command 'docker' -ErrorAction SilentlyContinue

if ($null -eq $semgrepCmd -and $null -eq $dockerCmd) {
    throw "Neither 'semgrep' nor 'docker' was found on PATH. Install Semgrep ('pip install semgrep==1.182.0') or start Docker Desktop."
}

foreach ($repoName in $repos) {
    $dir = if ($repoName -eq 'Davids') { $repoRoot } else { Join-Path $workspaceRoot $repoName }
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Missing sibling repository: $dir"
    }

    $relativeRules = if ($repoName -eq 'Davids') { 'security/pull-request-ci/semgrep/davids-security.yml' } else { '.semgrep/davids-security.yml' }
    $rulesPath = Join-Path $dir $relativeRules
    if (-not (Test-Path -LiteralPath $rulesPath)) {
        throw "Missing custom Semgrep ruleset: $rulesPath"
    }

    Write-Host "Scanning $repoName with custom Davids Semgrep rules..."
    if ($null -ne $semgrepCmd) {
        Push-Location $dir
        try {
            & $semgrepCmd.Source scan `
                --no-git-ignore `
                --exclude=artifacts `
                --exclude=bin `
                --exclude=obj `
                --exclude=.git `
                --exclude=.vs `
                --exclude=TestResults `
                --config $relativeRules `
                . `
                --error `
                --metrics=off
            if ($LASTEXITCODE) {
                throw "Semgrep reported blocking security findings in $repoName."
            }
        } finally {
            Pop-Location
        }
    } else {
        $resolvedDir = (Resolve-Path -LiteralPath $dir).Path
        & $dockerCmd.Source run --rm `
            --mount "type=bind,source=$resolvedDir,target=/src,readonly" `
            -w /src `
            $semgrepImage `
            semgrep scan `
            --no-git-ignore `
            --exclude=artifacts `
            --exclude=bin `
            --exclude=obj `
            --exclude=.git `
            --exclude=.vs `
            --exclude=TestResults `
            --config $relativeRules `
            . `
            --error `
            --metrics=off
        if ($LASTEXITCODE) {
            throw "Semgrep reported blocking security findings in $repoName."
        }
    }
}

Write-Host 'All 7 Davids repositories passed custom Semgrep SAST checks with zero findings.'
