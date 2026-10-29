[CmdletBinding()]
param(
    [switch]$InstallIstioctl
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

# Pinned Istio 1.31.3 istioctl artifacts and official SHA-256 digests.
$istioVersion = '1.31.3'
$istioctlChecksums = @{
    'istioctl-1.31.3-win.zip'            = '00076785cad0f7cc45984f04c692c3a59a763f9d4f34033975411a0d3d7eb9b2'
    'istioctl-1.31.3-linux-amd64.tar.gz' = '382c3004ce2e9c5ed3064b092ae0da7f6bbe30c766a1be282f45725add004860'
    'istioctl-1.31.3-linux-arm64.tar.gz' = '7476801623dbb900073cb1dba6a23b6a15c564b7e92b208aed36829315fefff1'
    'istioctl-1.31.3-osx-arm64.tar.gz'   = '881c3b443d9e458e8f19feed6ffa187dcfcb03dc032cb56068f7d1d0cd976c82'
    'istioctl-1.31.3-osx.tar.gz'         = '1e690b3038aad5535a5c810f5e88d881c691e85d6907394487bcf68b43653979'
}

# Digest-pinned Checkov v3.3.30 container image for Windows / Docker Desktop fallback.
$checkovImage = 'bridgecrew/checkov:3.3.30@sha256:4b65e89f1fde292249fc0aa0d0db43302c036dfe39f7370b2d3517571082b894'

function Resolve-IstioctlBinary {
    $cmd = Get-Command 'istioctl' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }

    if ($env:OS -eq 'Windows_NT' -and $env:LOCALAPPDATA) {
        $winCandidate = Join-Path $env:LOCALAPPDATA 'Programs\davids-security\istioctl.exe'
        if (Test-Path -LiteralPath $winCandidate) { return $winCandidate }
    } else {
        $homeDir = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
        $unixCandidate = Join-Path $homeDir '.local/bin/istioctl'
        if (Test-Path -LiteralPath $unixCandidate) { return $unixCandidate }
    }
    return $null
}

function Install-VerifiedIstioctl {
    $archRaw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $isArm64 = ($archRaw -eq 'arm64')

    if ($env:OS -eq 'Windows_NT') {
        $archiveName = "istioctl-${istioVersion}-win.zip"
        $installDir = Join-Path $env:LOCALAPPDATA 'Programs\davids-security'
        $binaryPath = Join-Path $installDir 'istioctl.exe'
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $archiveName = if ($isArm64) { "istioctl-${istioVersion}-osx-arm64.tar.gz" } else { "istioctl-${istioVersion}-osx.tar.gz" }
        $installDir = Join-Path $env:HOME '.local/bin'
        $binaryPath = Join-Path $installDir 'istioctl'
    } else {
        $archiveName = if ($isArm64) { "istioctl-${istioVersion}-linux-arm64.tar.gz" } else { "istioctl-${istioVersion}-linux-amd64.tar.gz" }
        $installDir = Join-Path $env:HOME '.local/bin'
        $binaryPath = Join-Path $installDir 'istioctl'
    }

    $expectedSha = $istioctlChecksums[$archiveName]
    if (-not $expectedSha) {
        throw "Unsupported platform artifact '$archiveName' for pinned istioctl installation."
    }

    $downloadUrl = "https://github.com/istio/istio/releases/download/${istioVersion}/${archiveName}"
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("davids-istioctl-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $archivePath = Join-Path $tempDir $archiveName
        Write-Host "Downloading istioctl ${istioVersion} ($archiveName)..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing

        $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $expectedSha) {
            throw "SHA-256 checksum mismatch for $archiveName! Expected $expectedSha, got $actualSha."
        }

        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        if ($archiveName.EndsWith('.zip')) {
            $extractDir = Join-Path $tempDir 'extracted'
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
            Copy-Item -LiteralPath (Join-Path $extractDir 'istioctl.exe') -Destination $binaryPath -Force
        } else {
            & tar -xzf $archivePath -C $installDir istioctl
            if ($LASTEXITCODE) { throw 'Failed to extract istioctl archive.' }
            & chmod +x $binaryPath
        }

        Write-Host "Installed SHA-256 verified istioctl ${istioVersion} to $binaryPath"
        return $binaryPath
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$istioctl = Resolve-IstioctlBinary
if (-not $istioctl -and $InstallIstioctl) {
    $istioctl = Install-VerifiedIstioctl
}
if (-not $istioctl) {
    throw "istioctl binary not found. Run './scripts/security/pull-request-ci/Scan-IaC.ps1 -InstallIstioctl' to install SHA-256 verified istioctl ${istioVersion}."
}

$k8sManifests = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deploy/k8s') -Filter '*.yaml' -File | ForEach-Object { $_.FullName })
if ($k8sManifests.Count -eq 0) {
    throw 'No Kubernetes/Istio YAML manifests found under deploy/k8s.'
}

Write-Host 'Analyzing Kubernetes and Istio mesh manifests with istioctl...'
& $istioctl analyze --use-kube=false --failure-threshold Warning @k8sManifests
if ($LASTEXITCODE) {
    throw 'istioctl analyze reported Kubernetes/Istio validation issues.'
}

$checkovCmd = Get-Command 'checkov' -ErrorAction SilentlyContinue
$dockerCmd = Get-Command 'docker' -ErrorAction SilentlyContinue
if ($null -eq $checkovCmd -and $null -eq $dockerCmd) {
    throw "Neither 'checkov' nor 'docker' was found on PATH. Install Checkov ('pip install checkov') or start Docker Desktop."
}

foreach ($repoName in $repos) {
    $dir = if ($repoName -eq 'Davids') { $repoRoot } else { Join-Path $workspaceRoot $repoName }
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Missing sibling repository: $dir"
    }

    Write-Host "Running Checkov IaC & workflow scan on $repoName..."
    if ($null -ne $checkovCmd) {
        & $checkovCmd.Source -d $dir --framework kubernetes,dockerfile,github_actions --skip-path bin --skip-path obj --skip-path .vs --skip-path .git --skip-path kyverno-tests --compact --quiet
    } else {
        $resolvedDir = (Resolve-Path -LiteralPath $dir).Path
        & $dockerCmd.Source run --rm `
            --mount "type=bind,source=$resolvedDir,target=/tf,readonly" `
            $checkovImage `
            -d /tf --framework kubernetes,dockerfile,github_actions --skip-path bin --skip-path obj --skip-path .vs --skip-path .git --skip-path kyverno-tests --compact --quiet
    }
    if ($LASTEXITCODE) {
        throw "Checkov reported IaC, Dockerfile, or GitHub Actions security findings in $repoName."
    }
}

Write-Host 'All Kubernetes/Istio manifests, Dockerfiles, and GitHub Actions workflows passed istioctl analyze and Checkov.'
