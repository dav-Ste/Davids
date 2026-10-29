[CmdletBinding()]
param(
    [string]$SeqUrl = $env:DAVIDS_SEQ_URL,
    [string]$SeqApiKey = $env:DAVIDS_SEQ_API_KEY,
    [string]$ConfigPath = '',
    [switch]$ValidateConfigOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $repoRoot 'security/stage5/seq/seq-security-signals-and-alerts.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Seq security signals & alerts specification not found: $ConfigPath"
}

$spec = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 16
if (-not $spec.signals -or @($spec.signals).Count -lt 6) {
    throw "Expected at least 6 Seq security signals in $ConfigPath."
}

$seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($sig in $spec.signals) {
    if ([string]::IsNullOrWhiteSpace([string]$sig.id) -or
        [string]::IsNullOrWhiteSpace([string]$sig.title) -or
        [string]::IsNullOrWhiteSpace([string]$sig.filter) -or
        $null -eq $sig.alert) {
        throw "Invalid Seq signal entry in ${ConfigPath}: $($sig | ConvertTo-Json -Compress)"
    }
    if (-not $seenIds.Add([string]$sig.id)) {
        throw "Duplicate Seq signal id '$($sig.id)' in $ConfigPath."
    }
    if ([int]$sig.alert.windowMinutes -le 0 -or [int]$sig.alert.thresholdCount -le 0) {
        throw "Seq signal '$($sig.id)' must specify positive alert windowMinutes and thresholdCount."
    }
}

if ($ValidateConfigOnly) {
    Write-Host "Verified Stage 5 Seq login-audit & runtime signals specification ($($seenIds.Count) signals): $ConfigPath"
    return
}

if ([string]::IsNullOrWhiteSpace($SeqUrl)) {
    $SeqUrl = 'http://localhost:5341'
}
$baseSeq = $SeqUrl.TrimEnd('/')
$headers = @{ Accept = 'application/json' }
if (-not [string]::IsNullOrWhiteSpace($SeqApiKey)) {
    $headers['X-Seq-ApiKey'] = $SeqApiKey
}

$existingSignals = @(Invoke-RestMethod -Uri "$baseSeq/api/signals?shared=true" -Method Get -Headers $headers)

foreach ($sig in $spec.signals) {
    $match = $existingSignals | Where-Object { $_.Title -eq $sig.title } | Select-Object -First 1
    $payload = @{
        Title       = [string]$sig.title
        Description = [string]$sig.description
        Filters     = @(
            @{
                FilterNonStrict = [string]$sig.filter
            }
        )
        IsProtected = $false
        OwnerId     = $null
    }

    if ($null -ne $match) {
        $payload['Id'] = $match.Id
        $payload['Links'] = $match.Links
        $updated = Invoke-RestMethod `
            -Uri "$baseSeq/api/signals/$($match.Id)" `
            -Method Put `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body ($payload | ConvertTo-Json -Depth 10)
        Write-Host "Updated Seq security signal: $($updated.Title) ($($updated.Id))"
    } else {
        $created = Invoke-RestMethod `
            -Uri "$baseSeq/api/signals" `
            -Method Post `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body ($payload | ConvertTo-Json -Depth 10)
        Write-Host "Created Seq security signal: $($created.Title) ($($created.Id))"
    }
}

Write-Host "Stage 5 Seq security audit signals synchronized cleanly against $baseSeq."
