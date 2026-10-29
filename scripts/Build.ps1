$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$dotnet = 'dotnet'
if ($env:OS -eq 'Windows_NT') {
    $progFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { 'C:\Program Files' }
    $candidate64 = Join-Path $progFiles64 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $candidate64) { $dotnet = $candidate64 }
}
$env:MSBUILDDISABLENODEREUSE = '1'
Push-Location $repoRoot
try {
    $solution = 'Davids.sln'
    if (-not (Test-Path $solution)) { throw "Missing $solution. Run ./scripts/Get-Projects.ps1 first." }
    & $dotnet build $solution --no-restore -c Release -m:2 -nr:false --tl:off
    if ($LASTEXITCODE) { throw 'Build failed.' }
} finally { Pop-Location }
