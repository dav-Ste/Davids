[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [switch]$ValidateConfigOnly,
    [switch]$SkipReachabilityCheck,
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$seedsPath = Join-Path $repoRoot 'security/staging-nightly/burp/dastardly-seeds.json'
$burpConfigPath = Join-Path $repoRoot 'security/staging-nightly/burp/burp-dast-scan-config.json'
$recordedLoginPath = Join-Path $repoRoot 'security/staging-nightly/burp/burp-recorded-admin-bff-login.template.json'

foreach ($requiredPath in @($seedsPath, $burpConfigPath, $recordedLoginPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing required PortSwigger Burp / Dastardly configuration file: $requiredPath"
    }
}

$seedsDoc = Get-Content -LiteralPath $seedsPath -Raw | ConvertFrom-Json
$burpDoc = Get-Content -LiteralPath $burpConfigPath -Raw | ConvertFrom-Json
$loginDoc = Get-Content -LiteralPath $recordedLoginPath -Raw | ConvertFrom-Json

if ($null -eq $seedsDoc.targets -or $seedsDoc.targets.Count -eq 0) {
    throw 'dastardly-seeds.json must define at least one scan seed target.'
}
if ($burpDoc.davidsProfile.sessionPreservationExclusions -notcontains '/auth/logout') {
    throw "burp-dast-scan-config.json must exclude '/auth/logout' so active authenticated crawls preserve the BFF session cookie."
}
if ($null -eq $loginDoc.events -or $loginDoc.events.Count -lt 4) {
    throw 'burp-recorded-admin-bff-login.template.json must define the PKCE BFF recorded login sequence.'
}

if ($ValidateConfigOnly) {
    Write-Host "Validated PortSwigger Dastardly seeds ($($seedsDoc.targets.Count) target(s)), Burp Suite DAST scan configuration, and BFF recorded login template."
    return
}

$dockerCmd = Get-Command 'docker' -ErrorAction SilentlyContinue
if ($null -eq $dockerCmd) {
    throw "'docker' was not found on PATH. Start Docker Desktop or run with -ValidateConfigOnly."
}

$normalizedGateway = $GatewayUrl.TrimEnd('/')

# 1. Pre-flight check: verify the live Davids API Gateway is reachable before pulling/starting Chromium.
if (-not $SkipReachabilityCheck) {
    $probeUrl = "$normalizedGateway/gateway-info"
    try {
        $probeResp = Invoke-WebRequest -Uri $probeUrl -Method Get -TimeoutSec 10 -SkipHttpErrorCheck
        if ([int]$probeResp.StatusCode -ge 500 -or [int]$probeResp.StatusCode -eq 0) {
            throw "Unexpected status $([int]$probeResp.StatusCode) from $probeUrl."
        }
    } catch {
        throw "Target Davids API Gateway is not reachable at '$probeUrl' ($($_.Exception.Message)). Start the stack first ('./scripts/Start.ps1' or Visual Studio F5), pass -GatewayUrl <url>, or run './scripts/security/staging-nightly/Scan-Dastardly.ps1 -ValidateConfigOnly' for offline config validation."
    }
}

# 2. Ensure the digest-pinned PortSwigger Dastardly image is pulled and unpacked cleanly before running.
$dastardlyImage = [string]$seedsDoc.image
& $dockerCmd.Source image inspect $dastardlyImage *> $null
if ($LASTEXITCODE -ne 0) {
    $retryDelays = @(5, 10, 20, 30)
    $pullSucceeded = $false
    $pullText = ''
    for ($attempt = 1; $attempt -le ($retryDelays.Count + 1); $attempt++) {
        Write-Host "Pulling PortSwigger Dastardly container image ($dastardlyImage) [attempt $attempt/$($retryDelays.Count + 1)]..."
        $pullOutput = & $dockerCmd.Source pull --platform linux/amd64 $dastardlyImage 2>&1
        if ($LASTEXITCODE -eq 0) {
            $pullSucceeded = $true
            break
        }
        $pullText = ($pullOutput | Out-String).Trim()
        if ($pullText -match 'failed to register layer|input/output error|fchmodat2|no space left on device') {
            break
        }
        if ($attempt -le $retryDelays.Count) {
            $delaySec = $retryDelays[$attempt - 1]
            Write-Warning "Transient registry error pulling '$dastardlyImage' (attempt $attempt); retrying in ${delaySec}s: $pullText"
            Start-Sleep -Seconds $delaySec
        }
    }
    if (-not $pullSucceeded) {
        if ($pullText -match 'failed to register layer|input/output error|fchmodat2|no space left on device') {
            throw @"
Docker failed to unpack the PortSwigger Dastardly image into its Linux storage backend (Docker Engine / WSL2 layer I/O error, NOT a scan failure):
$pullText

Fix on Windows Docker Desktop (WSL2):
  1. Check free disk space on C: and Docker Desktop -> Settings -> Resources -> Advanced -> Virtual disk limit (Dastardly unpacks ~1.8 GB of Chromium + Ubuntu layers).
  2. Update WSL2 and restart Docker Desktop's VM from an elevated PowerShell prompt:
       wsl --update
       wsl --shutdown
  3. Enable Docker Desktop -> Settings -> General -> 'Use containerd for pulling and storing images' (avoids legacy overlay2 go-archive fchmodat2 unpack errors), then run:
       docker builder prune -f
       docker image prune -f
       docker pull --platform linux/amd64 $dastardlyImage
  4. If docker_data.vhdx ext4 metadata is corrupted after an unclean shutdown, repair it with:
       wsl --shutdown
       wsl -d docker-desktop -u root -- sh -c "df -h; dmesg | tail -n 20"
     or use Docker Desktop -> Troubleshoot (bug icon) -> Clean / Purge data (WSL 2).
"@
        }
        throw "Failed to pull PortSwigger Dastardly image '$dastardlyImage':`n$pullText"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/staging-nightly'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $OutputDirectory).Path
if ($IsLinux) {
    chmod 0777 $resolvedOutputDir
}

# On Linux Docker Engine, --network=host connects directly to localhost and preserves the exact Host/Origin header;
# on Windows/macOS Docker Desktop VM, host.docker.internal routes to host localhost.
$containerGateway = if ($IsLinux) {
    $normalizedGateway
} else {
    $normalizedGateway -replace '^(https?://)(localhost|127\.0\.0\.1)(:\d+)?', '$1host.docker.internal$3'
}

$totalFailures = 0
$totalJunitFailures = 0
$nonzeroExitRuns = 0
foreach ($seed in $seedsDoc.targets) {
    $seedId = [string]$seed.id
    $relativeUrl = [string]$seed.relativeUrl
    $targetUrl = "$containerGateway$relativeUrl"
    $reportFile = "dastardly-$seedId.junit.xml"
    $hostReportPath = Join-Path $resolvedOutputDir $reportFile
    Remove-Item -LiteralPath $hostReportPath -Force -ErrorAction SilentlyContinue

    Write-Host "=== PortSwigger Dastardly: $seedId ($targetUrl) ==="
    $dockerArgs = @('run', '--rm', '--platform', 'linux/amd64')
    if ($IsLinux) {
        $dockerArgs += '--network=host'
    }
    $dockerArgs += @(
        '--mount', "type=bind,source=$resolvedOutputDir,target=/dastardly",
        '-e', "BURP_START_URL=$targetUrl",
        '-e', "BURP_REPORT_FILE_PATH=/dastardly/$reportFile",
        '-e', "DASTARDLY_TARGET_URL=$targetUrl",
        '-e', "DASTARDLY_OUTPUT_FILE=/dastardly/$reportFile",
        $dastardlyImage
    )

    & $dockerCmd.Source @dockerArgs
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 125 -or $exitCode -eq 126 -or $exitCode -eq 127) {
        throw "Docker Engine failed to start the Dastardly container (docker exit code $exitCode). Verify Docker Desktop is running Linux containers and has sufficient memory/disk."
    }

    if (-not (Test-Path -LiteralPath $hostReportPath)) {
        throw "Dastardly exited with code $exitCode before writing JUnit XML report '$hostReportPath'. Verify '$normalizedGateway$relativeUrl' responds with HTTP 200 HTML from the host."
    }

    [xml]$junit = Get-Content -LiteralPath $hostReportPath -Raw
    $failures = @($junit.SelectNodes('//failure'))
    $totalJunitFailures += $failures.Count
    if ($exitCode -ne 0) { $nonzeroExitRuns++ }
    if ($failures.Count -gt 0 -or $exitCode -ne 0) {
        $totalFailures += [Math]::Max($failures.Count, 1)
        foreach ($failure in $failures) {
            Write-Warning "Dastardly finding [$seedId]: $($failure.GetAttribute('message'))"
        }
        Write-Warning "Dastardly seed '$seedId': $($failures.Count) JUnit failure(s), scanner exit code $exitCode. Severity is not evaluated by this gate."
    } else {
        Write-Host "Dastardly seed '$seedId' passed with 0 findings."
    }
}

if ($totalFailures -gt 0) {
    throw "PortSwigger Dastardly gate failed: $totalJunitFailures JUnit failure(s) and $nonzeroExitRuns scan(s) with nonzero exit codes ($totalFailures blocking result(s)). Severity is not evaluated; inspect the reports and scanner logs."
}

Write-Host "All $($seedsDoc.targets.Count) PortSwigger Dastardly web/BFF DAST scan(s) passed with zero findings."
