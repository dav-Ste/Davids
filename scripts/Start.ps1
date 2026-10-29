param([switch]$AllOptional)
$ErrorActionPreference = 'Stop'
$dotnet = 'dotnet'
if ($env:OS -eq 'Windows_NT') {
    $progFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { 'C:\Program Files' }
    $candidate64 = Join-Path $progFiles64 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $candidate64) { $dotnet = $candidate64 }
}
$env:MSBUILDDISABLENODEREUSE = '1'
$names = @('Integrations__InfluxDB', 'Integrations__Elasticsearch')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    if ($AllOptional) {
        $env:Integrations__InfluxDB = 'true'
        $env:Integrations__Elasticsearch = 'true'
    }
    & $dotnet run --project src/Davids.AppHost
    if ($LASTEXITCODE) { throw 'Start failed.' }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    Pop-Location
}
