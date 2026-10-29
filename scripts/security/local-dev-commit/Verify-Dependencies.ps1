$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$workspaceRoot = Split-Path $repoRoot -Parent
$dotnet = 'dotnet'
if ($env:OS -eq 'Windows_NT') {
    $progFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { 'C:\Program Files' }
    $candidate64 = Join-Path $progFiles64 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $candidate64) { $dotnet = $candidate64 }
}
$env:MSBUILDDISABLENODEREUSE = '1'

$repos = @(
    $repoRoot,
    (Join-Path $workspaceRoot 'Davids.Shared'),
    (Join-Path $workspaceRoot 'Davids.Services.Identity'),
    (Join-Path $workspaceRoot 'Davids.Services.AdminIdentity'),
    (Join-Path $workspaceRoot 'Davids.Services.Customers'),
    (Join-Path $workspaceRoot 'Davids.APIGateway'),
    (Join-Path $workspaceRoot 'Davids.Frontend.Admin')
)

Push-Location $repoRoot
try {
    foreach ($dir in $repos) {
        if (-not (Test-Path -LiteralPath $dir)) {
            throw "Missing repository path $dir. Run ./scripts/Get-Projects.ps1 first."
        }
        $centralProps = Join-Path $dir 'Directory.Packages.props'
        if (-not (Test-Path -LiteralPath $centralProps)) {
            throw "Missing Central Package Management file: $centralProps"
        }
    }

    $null = (& $dotnet list Davids.sln package --include-transitive --format json) -join [Environment]::NewLine
    if ($LASTEXITCODE) { throw 'Dependency inspection failed.' }

    # dotnet list package --vulnerable exits 0 even when advisories exist; parse the JSON report explicitly.
    $vulnRaw = (& $dotnet list Davids.sln package --vulnerable --include-transitive --format json) -join [Environment]::NewLine
    if ($LASTEXITCODE) { throw 'NuGet vulnerability audit command failed.' }
    $vulnReport = $vulnRaw | ConvertFrom-Json
    $advisoryFindings = New-Object System.Collections.Generic.List[string]
    foreach ($proj in @($vulnReport.projects)) {
        if ($null -eq $proj.PSObject.Properties['frameworks']) { continue }
        foreach ($fw in @($proj.frameworks)) {
            foreach ($groupName in @('topLevelPackages', 'transitivePackages')) {
                if ($null -eq $fw.PSObject.Properties[$groupName]) { continue }
                foreach ($pkg in @($fw.$groupName)) {
                    if ($null -ne $pkg.PSObject.Properties['vulnerabilities'] -and @($pkg.vulnerabilities).Count -gt 0) {
                        foreach ($v in @($pkg.vulnerabilities)) {
                            $advisoryFindings.Add("$($proj.path): $($pkg.id) $($pkg.resolvedVersion) [$($v.severity)] $($v.advisoryurl)")
                        }
                    }
                }
            }
        }
    }
    if ($advisoryFindings.Count -gt 0) {
        $advisoryFindings | ForEach-Object { Write-Error $_ }
        throw "Found $($advisoryFindings.Count) vulnerable NuGet package advisory(ies)."
    }

    Write-Output 'All resolved direct and transitive NuGet dependencies passed audit with zero vulnerability advisories.'
} finally { Pop-Location }
