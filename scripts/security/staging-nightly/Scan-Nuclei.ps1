[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [switch]$InstallNuclei,
    [switch]$ValidateOnly,
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$nucleiConfig = Join-Path $repoRoot 'security/staging-nightly/nuclei/nuclei-config.yaml'
$assertionsDir = Join-Path $repoRoot 'security/staging-nightly/nuclei/assertions'
$vulnerabilitiesDir = Join-Path $repoRoot 'security/staging-nightly/nuclei/vulnerabilities'

foreach ($requiredPath in @($nucleiConfig, $assertionsDir, $vulnerabilitiesDir)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing required Nuclei asset: $requiredPath"
    }
}

$nucleiVersion = '3.11.1'
$nucleiChecksums = @{
    'linux_amd64'   = 'ea63d4ae232808cd7c6bc00d0142428e231fab59dae01042246097d195835ab6'
    'linux_arm64'   = '8044e3d9768ba0a744b2872c1a87e813006f013da97ca9f50f7661a4203bec07'
    'windows_amd64' = 'bb6cb9ff8939b753f6fcab06fd30a15f5bc61d8382a597871334c007a85ff9d2'
    'windows_386'   = 'f7571ca47f8501a654860b4df20d12137b8f4de7799d439b621a5b8035747990'
    'macOS_amd64'   = '75c47ce11e9dbd4288a1c895ed85e3c4df9f4acb8237d6d178da6dccd1628f2a'
    'macOS_arm64'   = '7d7e291addd1fc29a9bf8d089afe878a9799b20229cbea2fb1693fc40fd4c5f0'
}

function Resolve-NucleiBinary {
    $cmd = Get-Command 'nuclei' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }

    $exeName = if ($IsWindows) { 'nuclei.exe' } else { 'nuclei' }
    $localToolPath = Join-Path $repoRoot ".tools/nuclei/$nucleiVersion/$exeName"
    if (Test-Path -LiteralPath $localToolPath) {
        return $localToolPath
    }

    if (-not $InstallNuclei) {
        throw "ProjectDiscovery 'nuclei' was not found on PATH. Re-run with -InstallNuclei to download SHA-256 verified Nuclei v$nucleiVersion."
    }

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $platformKey = if ($IsWindows) {
        if ($arch -eq 'x86') { 'windows_386' } else { 'windows_amd64' }
    } elseif ($IsMacOS) {
        if ($arch -eq 'arm64') { 'macOS_arm64' } else { 'macOS_amd64' }
    } else {
        if ($arch -eq 'arm64') { 'linux_arm64' } else { 'linux_amd64' }
    }

    $expectedSha = $nucleiChecksums[$platformKey]
    $archiveName = "nuclei_${nucleiVersion}_${platformKey}.zip"
    $downloadUrl = "https://github.com/projectdiscovery/nuclei/releases/download/v$nucleiVersion/$archiveName"

    $installDir = Split-Path $localToolPath -Parent
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $zipPath = Join-Path $installDir $archiveName

    Write-Host "Downloading Nuclei v$nucleiVersion ($platformKey) from $downloadUrl ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath

    $actualSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $expectedSha) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed for $archiveName! Expected $expectedSha, got $actualSha."
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $installDir -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    if (-not $IsWindows) {
        chmod +x $localToolPath
    }
    return $localToolPath
}

$nucleiBin = Resolve-NucleiBinary

Write-Host 'Validating custom Davids Nuclei YAML templates...'
& $nucleiBin -validate -t $assertionsDir -t $vulnerabilitiesDir -duc
if ($LASTEXITCODE) {
    throw 'Nuclei template validation failed.'
}

if ($ValidateOnly) {
    Write-Host 'All 10 custom Davids Nuclei templates validated cleanly.'
    return
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/staging-nightly'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$assertionsJsonl = Join-Path $OutputDirectory 'nuclei-assertions.jsonl'
$vulnsJsonl = Join-Path $OutputDirectory 'nuclei-vulns.jsonl'
$vulnsSarif = Join-Path $OutputDirectory 'nuclei-vulns.sarif'
Remove-Item -LiteralPath $assertionsJsonl, $vulnsJsonl, $vulnsSarif -Force -ErrorAction SilentlyContinue

$normalizedGateway = $GatewayUrl.TrimEnd('/')

Write-Host "=== Nuclei Suite A: Security Posture Assertions against $normalizedGateway ==="
& $nucleiBin -config $nucleiConfig -u $normalizedGateway -t $assertionsDir -jsonl-export $assertionsJsonl -nc -duc
if ($LASTEXITCODE) {
    throw "Nuclei posture assertion scan exited with code $LASTEXITCODE."
}

$expectedAssertionIds = @(
    'davids-posture-admin-signup-disabled',
    'davids-posture-auth-and-bff-boundaries',
    'davids-posture-gateway-security-headers',
    'davids-posture-oidc-discovery-hardening'
)

$matchedIds = @()
if (Test-Path -LiteralPath $assertionsJsonl) {
    foreach ($line in (Get-Content -LiteralPath $assertionsJsonl)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $obj = $line | ConvertFrom-Json
            $matchedIds += [string]$obj.'template-id'
        }
    }
}
$uniqueMatchedIds = @($matchedIds | Select-Object -Unique)
$missingIds = @($expectedAssertionIds | Where-Object { $_ -notin $uniqueMatchedIds })
if ($missingIds.Count -gt 0) {
    throw "Missing required Davids security posture assertions: $($missingIds -join ', '). Matched: $($uniqueMatchedIds -join ', ')."
}
Write-Host "Verified all $($expectedAssertionIds.Count) Davids posture assertions matched ($($matchedIds.Count) total checks)."

Write-Host "=== Nuclei Suite B: Vulnerability Regression Templates against $normalizedGateway ==="
& $nucleiBin -config $nucleiConfig -u $normalizedGateway -t $vulnerabilitiesDir -sarif-export $vulnsSarif -jsonl-export $vulnsJsonl -nc -duc
if ($LASTEXITCODE) {
    throw "Nuclei vulnerability regression scan exited with code $LASTEXITCODE."
}

$vulnMatches = @()
if (Test-Path -LiteralPath $vulnsJsonl) {
    foreach ($line in (Get-Content -LiteralPath $vulnsJsonl)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $vulnMatches += ($line | ConvertFrom-Json)
        }
    }
}

if (-not (Test-Path -LiteralPath $vulnsSarif)) {
    # Nuclei v3.11.1 omits writing -sarif-export when zero findings match; emit an empty SARIF 2.1.0 log for GitHub Code Scanning.
    $emptySarif = @{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            @{
                tool    = @{
                    driver = @{
                        name           = 'Nuclei (Davids Custom Templates)'
                        semanticVersion = $nucleiVersion
                        informationUri = 'https://github.com/projectdiscovery/nuclei'
                        rules          = @()
                    }
                }
                results = @()
            }
        )
    } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($vulnsSarif, "$emptySarif`n", [System.Text.UTF8Encoding]::new($false))
}

if ($vulnMatches.Count -gt 0) {
    $ids = ($vulnMatches | ForEach-Object { $_.'template-id' } | Select-Object -Unique) -join ', '
    throw "Nuclei detected $($vulnMatches.Count) security regression finding(s): $ids"
}

Write-Host "Nuclei Staging / Nightly regression gate passed with 0 vulnerabilities. SARIF saved to $vulnsSarif."
