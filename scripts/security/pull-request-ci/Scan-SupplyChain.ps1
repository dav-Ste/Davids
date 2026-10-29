[CmdletBinding()]
param(
    [switch]$InstallScanners
)

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

# Pinned Grype v0.121.0 and Trivy v0.76.1 release artifacts and official SHA-256 digests.
$grypeVersion = '0.121.0'
$grypeChecksums = @{
    'grype_0.121.0_windows_amd64.zip'  = 'f867bbdc14bd8b0d99b3fc47d839af07480a540072b16896373a8ba32b76f588'
    'grype_0.121.0_linux_amd64.tar.gz' = '64e07133d3486115de647a66581461dccf5c732748a0a3119077395565f15519'
    'grype_0.121.0_linux_arm64.tar.gz' = '86f570f75ca947ea3dd6486309232bcff6d78e44ba081ae75ab14eab72be3dae'
    'grype_0.121.0_darwin_arm64.tar.gz'= '7be39d3a0428c664ce0183e4aba31ed9accffce9eda7e7f6fa84e9c512285f27'
    'grype_0.121.0_darwin_amd64.tar.gz'= '27eef17e42f0340af6582cdbc33ad18faf9f601c613ab81d2e1658a94cbc357f'
}

$trivyVersion = '0.76.1'
$trivyChecksums = @{
    'trivy_0.76.1_windows-64bit.zip'   = '1051f49cb22d5284f43425f72aad9cda63ca12ceb92e7caa06903490c82dc9bf'
    'trivy_0.76.1_Linux-64bit.tar.gz'  = 'c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0'
    'trivy_0.76.1_Linux-ARM64.tar.gz'  = 'e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f'
    'trivy_0.76.1_macOS-ARM64.tar.gz'  = '11a9b6cd2752011b54f01ea4bd0dbfa9f0c41dc6538d5a3f9d23955f471bf4e5'
    'trivy_0.76.1_macOS-64bit.tar.gz'  = '7aa762eacd582052d053b62dcf972a1ab058abe39a57ccae234ed8894945b6b7'
}

function Resolve-LocalBinary([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }

    if ($env:OS -eq 'Windows_NT' -and $env:LOCALAPPDATA) {
        $winCandidate = Join-Path $env:LOCALAPPDATA "Programs\davids-security\${Name}.exe"
        if (Test-Path -LiteralPath $winCandidate) { return $winCandidate }
    } else {
        $homeDir = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
        $unixCandidate = Join-Path $homeDir ".local/bin/${Name}"
        if (Test-Path -LiteralPath $unixCandidate) { return $unixCandidate }
    }
    return $null
}

function Install-VerifiedArchiveBinary([string]$ToolName, [string]$DownloadUrl, [string]$ArchiveName, [string]$ExpectedSha) {
    if ($env:OS -eq 'Windows_NT') {
        $installDir = Join-Path $env:LOCALAPPDATA 'Programs\davids-security'
        $binaryPath = Join-Path $installDir "${ToolName}.exe"
    } else {
        $installDir = Join-Path $env:HOME '.local/bin'
        $binaryPath = Join-Path $installDir $ToolName
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("davids-${ToolName}-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $archivePath = Join-Path $tempDir $ArchiveName
        Write-Host "Downloading SHA-256 pinned $ToolName ($ArchiveName)..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $archivePath -UseBasicParsing

        $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $ExpectedSha) {
            throw "SHA-256 checksum mismatch for $ArchiveName! Expected $ExpectedSha, got $actualSha."
        }

        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        if ($ArchiveName.EndsWith('.zip')) {
            $extractDir = Join-Path $tempDir 'extracted'
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
            Copy-Item -LiteralPath (Join-Path $extractDir "${ToolName}.exe") -Destination $binaryPath -Force
        } else {
            & tar -xzf $archivePath -C $installDir $ToolName
            if ($LASTEXITCODE) { throw "Failed to extract $ArchiveName." }
            & chmod +x $binaryPath
        }

        Write-Host "Installed SHA-256 verified $ToolName to $binaryPath"
        return $binaryPath
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$archRaw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$isArm64 = ($archRaw -eq 'arm64')

$grype = Resolve-LocalBinary 'grype'
if (-not $grype -and $InstallScanners) {
    if ($env:OS -eq 'Windows_NT') {
        $gArchive = "grype_${grypeVersion}_windows_amd64.zip"
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $gArchive = if ($isArm64) { "grype_${grypeVersion}_darwin_arm64.tar.gz" } else { "grype_${grypeVersion}_darwin_amd64.tar.gz" }
    } else {
        $gArchive = if ($isArm64) { "grype_${grypeVersion}_linux_arm64.tar.gz" } else { "grype_${grypeVersion}_linux_amd64.tar.gz" }
    }
    $grype = Install-VerifiedArchiveBinary 'grype' "https://github.com/anchore/grype/releases/download/v${grypeVersion}/${gArchive}" $gArchive $grypeChecksums[$gArchive]
}

$trivy = Resolve-LocalBinary 'trivy'
if (-not $trivy -and $InstallScanners) {
    if ($env:OS -eq 'Windows_NT') {
        $tArchive = "trivy_${trivyVersion}_windows-64bit.zip"
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $tArchive = if ($isArm64) { "trivy_${trivyVersion}_macOS-ARM64.tar.gz" } else { "trivy_${trivyVersion}_macOS-64bit.tar.gz" }
    } else {
        $tArchive = if ($isArm64) { "trivy_${trivyVersion}_Linux-ARM64.tar.gz" } else { "trivy_${trivyVersion}_Linux-64bit.tar.gz" }
    }
    $trivy = Install-VerifiedArchiveBinary 'trivy' "https://github.com/aquasecurity/trivy/releases/download/v${trivyVersion}/${tArchive}" $tArchive $trivyChecksums[$tArchive]
}

if (-not $grype -or -not $trivy) {
    throw "Grype and/or Trivy binary not found. Run './scripts/security/pull-request-ci/Scan-SupplyChain.ps1 -InstallScanners' to install SHA-256 verified Grype v${grypeVersion} and Trivy v${trivyVersion}."
}

& (Join-Path $repoRoot 'scripts/security/local-dev-commit/Verify-Dependencies.ps1')

foreach ($repoName in $repos) {
    $dir = if ($repoName -eq 'Davids') { $repoRoot } else { Join-Path $workspaceRoot $repoName }
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Missing sibling repository: $dir"
    }

    Push-Location $dir
    try {
        Write-Host "Scanning $repoName lockfiles with Grype..."
        & $grype 'dir:.' --exclude './**/artifacts/**' --exclude './**/bin/**' --exclude './**/obj/**' --exclude './**/TestResults/**' --fail-on high -q
        if ($LASTEXITCODE) {
            throw "Grype reported HIGH/CRITICAL vulnerability findings in $repoName."
        }

        Write-Host "Scanning $repoName lockfiles & configs with Trivy..."
        & $trivy fs . --skip-dirs '**/artifacts,**/bin,**/obj,**/TestResults,**/kyverno-tests' --scanners vuln,misconfig --severity HIGH,CRITICAL --exit-code 1 --quiet
        if ($LASTEXITCODE) {
            throw "Trivy reported HIGH/CRITICAL vulnerability or misconfiguration findings in $repoName."
        }
    } finally {
        Pop-Location
    }
}

Write-Host 'All 7 Davids repositories passed NuGet JSON audit, SHA-verified Grype, and SHA-verified Trivy supply-chain scans.'
