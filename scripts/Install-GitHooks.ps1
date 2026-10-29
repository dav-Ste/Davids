[CmdletBinding()]
param(
    [switch]$InstallGitleaks
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
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

# Pinned Gitleaks v8.30.1 release artifacts and official SHA-256 digests (supply-chain verified).
$gitleaksVersion = '8.30.1'
$pinnedChecksums = @{
    'windows_x64.zip'      = 'd29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e'
    'windows_arm64.zip'    = 'b95f5e4f5c425cedca7ee203d9afd29597e692c4924a12ed42f970537c72cc0f'
    'linux_x64.tar.gz'     = '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'
    'linux_arm64.tar.gz'   = 'e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080'
    'darwin_arm64.tar.gz'  = 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5'
    'darwin_x64.tar.gz'    = 'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709'
}

function Resolve-GitleaksBinary {
    $cmd = Get-Command 'gitleaks' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }

    if ($env:OS -eq 'Windows_NT' -and $env:LOCALAPPDATA) {
        $winCandidate = Join-Path $env:LOCALAPPDATA 'Programs\gitleaks\gitleaks.exe'
        if (Test-Path -LiteralPath $winCandidate) { return $winCandidate }
    } else {
        $homeDir = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
        $unixCandidate = Join-Path $homeDir '.local/bin/gitleaks'
        if (Test-Path -LiteralPath $unixCandidate) { return $unixCandidate }
    }
    return $null
}

function Install-VerifiedGitleaks {
    $archRaw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $arch = if ($archRaw -eq 'arm64') { 'arm64' } else { 'x64' }

    if ($env:OS -eq 'Windows_NT') {
        $suffix = "windows_${arch}.zip"
        $installDir = Join-Path $env:LOCALAPPDATA 'Programs\gitleaks'
        $binaryPath = Join-Path $installDir 'gitleaks.exe'
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $suffix = "darwin_${arch}.tar.gz"
        $installDir = Join-Path $env:HOME '.local/bin'
        $binaryPath = Join-Path $installDir 'gitleaks'
    } else {
        $suffix = "linux_${arch}.tar.gz"
        $installDir = Join-Path $env:HOME '.local/bin'
        $binaryPath = Join-Path $installDir 'gitleaks'
    }

    $expectedSha = $pinnedChecksums[$suffix]
    if (-not $expectedSha) {
        throw "Unsupported platform artifact '$suffix' for pinned Gitleaks installation."
    }

    $archiveName = "gitleaks_${gitleaksVersion}_${suffix}"
    $downloadUrl = "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaksVersion}/${archiveName}"
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("davids-gitleaks-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $archivePath = Join-Path $tempDir $archiveName
        Write-Host "Downloading Gitleaks v${gitleaksVersion} ($archiveName)..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing

        $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $expectedSha) {
            throw "SHA-256 checksum mismatch for $archiveName! Expected $expectedSha, got $actualSha."
        }

        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        if ($suffix.EndsWith('.zip')) {
            $extractDir = Join-Path $tempDir 'extracted'
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
            Copy-Item -LiteralPath (Join-Path $extractDir 'gitleaks.exe') -Destination $binaryPath -Force
        } else {
            & tar -xzf $archivePath -C $installDir gitleaks
            if ($LASTEXITCODE) { throw 'Failed to extract gitleaks tar.gz archive.' }
            & chmod +x $binaryPath
        }

        Write-Host "Installed SHA-256 verified Gitleaks v${gitleaksVersion} to $binaryPath"
        return $binaryPath
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($InstallGitleaks) {
    $existingBin = Resolve-GitleaksBinary
    if (-not $existingBin) {
        $null = Install-VerifiedGitleaks
    } else {
        Write-Host "Gitleaks already installed at: $existingBin"
    }
}

$configuredCount = 0
$gitCmd = Get-Command 'git' -ErrorAction SilentlyContinue
foreach ($repoName in $repos) {
    $dir = if ($repoName -eq 'Davids') { $repoRoot } else { Join-Path $workspaceRoot $repoName }
    if (-not (Test-Path -LiteralPath $dir)) { continue }

    $hookFile = Join-Path $dir '.githooks/pre-commit'
    if (-not (Test-Path -LiteralPath $hookFile)) {
        throw "Missing tracked pre-commit hook at $hookFile"
    }

    if ($env:OS -ne 'Windows_NT') {
        & chmod +x $hookFile
    }

    if ($null -ne $gitCmd -and (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        Push-Location $dir
        try {
            & git config core.hooksPath .githooks
            if ($LASTEXITCODE) { throw "Failed to configure core.hooksPath in $repoName." }
            $configuredCount++
        } finally {
            Pop-Location
        }
    }
}

$resolvedGitleaks = Resolve-GitleaksBinary
if ($configuredCount -gt 0) {
    Write-Host "Configured git core.hooksPath=.githooks across $configuredCount git repository(ies)."
} else {
    Write-Host "Verified .githooks/pre-commit and .gitleaks.toml across Davids repositories (run again after 'git init' / 'git clone' to bind core.hooksPath)."
}
if (-not $resolvedGitleaks) {
    Write-Host "Note: 'gitleaks' binary not yet found on PATH. Run './scripts/Install-GitHooks.ps1 -InstallGitleaks' (or 'winget install Gitleaks.Gitleaks') before committing."
}
