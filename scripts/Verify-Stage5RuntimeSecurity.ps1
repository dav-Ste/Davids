[CmdletBinding()]
param(
    [switch]$InstallTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

$kyvernoVersion = 'v1.19.2'
$kyvernoChecksums = @{
    'kyverno-cli_v1.19.2_windows_x86_64.zip' = 'c787cd56d2c2571e5470b1d070fff851c05d104513fcf5cb1652021bb187a1f6'
    'kyverno-cli_v1.19.2_linux_x86_64.tar.gz' = '357eaf1df8bc24ddd5a73979fadeaae6a032e8710f11af264229756e4956bf4a'
    'kyverno-cli_v1.19.2_linux_arm64.tar.gz'  = '250f2a02f143d5c6425e686b13c130d3a3ba7372dba6a7210d599d1b0dd12e92'
    'kyverno-cli_v1.19.2_darwin_x86_64.tar.gz' = 'b645654ab8e65bd4aa64de9228e274b388bab19b3404a4e9af70174b3d5ad230'
    'kyverno-cli_v1.19.2_darwin_arm64.tar.gz'  = '7915c03c613c22363a100adb3da8d06f2e2626d9d21a98b97f921795ffdc536f'
}

$istioVersion = '1.31.3'
$istioctlChecksums = @{
    'istioctl-1.31.3-win.zip'            = '00076785cad0f7cc45984f04c692c3a59a763f9d4f34033975411a0d3d7eb9b2'
    'istioctl-1.31.3-linux-amd64.tar.gz' = '382c3004ce2e9c5ed3064b092ae0da7f6bbe3064b092ae0da7f6bbe30c766a1be282f45725add004860'
    'istioctl-1.31.3-linux-arm64.tar.gz' = '7476801623dbb900073cb1dba6a23b6a15c564b7e92b208aed36829315fefff1'
    'istioctl-1.31.3-osx-arm64.tar.gz'   = '881c3b443d9e458e8f19feed6ffa187dcfcb03dc032cb56068f19feed6ffa18'
}
# Exact upstream SHA-256 digests matching Scan-IaC.ps1:
$istioctlChecksums['istioctl-1.31.3-linux-amd64.tar.gz'] = '382c3004ce2e9c5ed3064b092ae0da7f6bbe30c766a1be282f45725add004860'
$istioctlChecksums['istioctl-1.31.3-osx-arm64.tar.gz'] = '881c3b443d9e458e8f19feed6ffa187dcfcb03dc032cb56068f7d1d0cd976c82'
$istioctlChecksums['istioctl-1.31.3-osx.tar.gz'] = '1e690b3038aad5535a5c810f5e88d881c691e85d6907394487bcf68b43653979'

$promVersion = '3.15.1'
$promChecksums = @{
    'prometheus-3.15.1.windows-amd64.zip'  = 'ba25b5e590520cb9fb028edef99bdc8523244d2d489b8c629e0d453d94fb030b'
    'prometheus-3.15.1.linux-amd64.tar.gz' = '6a726885328ad9efebbf36e876ce2fb6225468a71fd1e7ce3ba666d5f4d97a84'
    'prometheus-3.15.1.linux-arm64.tar.gz' = 'ceb6d21493c37ca0b4513b147642797c68cf39a0f50a444d50e1e80c74f21b26'
    'prometheus-3.15.1.darwin-amd64.tar.gz' = 'c89fcb30045d8c394c9d93e96cbbee3aaf2448a48326b417e811eb4e528edf88'
    'prometheus-3.15.1.darwin-arm64.tar.gz' = '0d4d3d9837d27e4fcd0bd16d115b1b8d6732a4bf3e69107f1190d9ef653ae471'
}

function Get-LocalToolDirectory {
    if ($env:OS -eq 'Windows_NT' -and $env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA 'Programs\davids-security')
    }
    $homeDir = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path $homeDir '.local/bin')
}

function Resolve-Binary([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }

    $exeName = if ($env:OS -eq 'Windows_NT') { "$Name.exe" } else { $Name }
    $localCandidate = Join-Path (Get-LocalToolDirectory) $exeName
    if (Test-Path -LiteralPath $localCandidate) { return $localCandidate }

    $tmpCandidate = Join-Path '/var/tmp/tools' $Name
    if (Test-Path -LiteralPath $tmpCandidate) { return $tmpCandidate }

    return $null
}

function Install-VerifiedArchiveBinary {
    param(
        [string]$BinaryName,
        [string]$DownloadUrl,
        [string]$ArchiveName,
        [string]$ExpectedSha256,
        [string]$RelativeExtractedBinary
    )

    $installDir = Get-LocalToolDirectory
    $exeName = if ($env:OS -eq 'Windows_NT') { "$BinaryName.exe" } else { $BinaryName }
    $targetPath = Join-Path $installDir $exeName
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("davids-$BinaryName-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $archivePath = Join-Path $tempDir $ArchiveName
        Write-Host "Downloading $BinaryName from $DownloadUrl ..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $archivePath -UseBasicParsing

        $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $ExpectedSha256.ToLowerInvariant()) {
            throw "SHA-256 checksum mismatch for $ArchiveName! Expected $ExpectedSha256, got $actualSha."
        }

        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        $extractDir = Join-Path $tempDir 'extract'
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        if ($ArchiveName.EndsWith('.zip')) {
            Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
        } else {
            & tar -xzf $archivePath -C $extractDir
            if ($LASTEXITCODE) { throw "Failed to extract $ArchiveName." }
        }

        $extractedBin = Join-Path $extractDir $RelativeExtractedBinary
        Copy-Item -LiteralPath $extractedBin -Destination $targetPath -Force
        if ($env:OS -ne 'Windows_NT') {
            & chmod +x $targetPath
        }
        Write-Host "Installed SHA-256 verified $BinaryName to $targetPath"
        return $targetPath
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$isArm64 = ($arch -eq 'arm64')

$kyvernoBin = Resolve-Binary 'kyverno'
if (-not $kyvernoBin -and $InstallTools) {
    if ($env:OS -eq 'Windows_NT') {
        $kArchive = "kyverno-cli_${kyvernoVersion}_windows_x86_64.zip"
        $kRel = 'kyverno.exe'
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $kArchive = if ($isArm64) { "kyverno-cli_${kyvernoVersion}_darwin_arm64.tar.gz" } else { "kyverno-cli_${kyvernoVersion}_darwin_x86_64.tar.gz" }
        $kRel = 'kyverno'
    } else {
        $kArchive = if ($isArm64) { "kyverno-cli_${kyvernoVersion}_linux_arm64.tar.gz" } else { "kyverno-cli_${kyvernoVersion}_linux_x86_64.tar.gz" }
        $kRel = 'kyverno'
    }
    $kyvernoBin = Install-VerifiedArchiveBinary `
        -BinaryName 'kyverno' `
        -DownloadUrl "https://github.com/kyverno/kyverno/releases/download/$kyvernoVersion/$kArchive" `
        -ArchiveName $kArchive `
        -ExpectedSha256 $kyvernoChecksums[$kArchive] `
        -RelativeExtractedBinary $kRel
}
if (-not $kyvernoBin) {
    throw "kyverno CLI not found. Run './scripts/Verify-Stage5RuntimeSecurity.ps1 -InstallTools' to install SHA-256 verified Kyverno $kyvernoVersion."
}

$istioctlBin = Resolve-Binary 'istioctl'
if (-not $istioctlBin -and $InstallTools) {
    if ($env:OS -eq 'Windows_NT') {
        $iArchive = "istioctl-${istioVersion}-win.zip"
        $iRel = 'istioctl.exe'
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $iArchive = if ($isArm64) { "istioctl-${istioVersion}-osx-arm64.tar.gz" } else { "istioctl-${istioVersion}-osx.tar.gz" }
        $iRel = 'istioctl'
    } else {
        $iArchive = if ($isArm64) { "istioctl-${istioVersion}-linux-arm64.tar.gz" } else { "istioctl-${istioVersion}-linux-amd64.tar.gz" }
        $iRel = 'istioctl'
    }
    $istioctlBin = Install-VerifiedArchiveBinary `
        -BinaryName 'istioctl' `
        -DownloadUrl "https://github.com/istio/istio/releases/download/$istioVersion/$iArchive" `
        -ArchiveName $iArchive `
        -ExpectedSha256 $istioctlChecksums[$iArchive] `
        -RelativeExtractedBinary $iRel
}
if (-not $istioctlBin) {
    throw "istioctl CLI not found. Run './scripts/Verify-Stage5RuntimeSecurity.ps1 -InstallTools' to install SHA-256 verified Istio $istioVersion."
}

$promtoolBin = Resolve-Binary 'promtool'
if (-not $promtoolBin -and $InstallTools) {
    if ($env:OS -eq 'Windows_NT') {
        $pStem = "prometheus-${promVersion}.windows-amd64"
        $pArchive = "$pStem.zip"
        $pRel = "$pStem\promtool.exe"
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        $pStem = if ($isArm64) { "prometheus-${promVersion}.darwin-arm64" } else { "prometheus-${promVersion}.darwin-amd64" }
        $pArchive = "$pStem.tar.gz"
        $pRel = "$pStem/promtool"
    } else {
        $pStem = if ($isArm64) { "prometheus-${promVersion}.linux-arm64" } else { "prometheus-${promVersion}.linux-amd64" }
        $pArchive = "$pStem.tar.gz"
        $pRel = "$pStem/promtool"
    }
    $promtoolBin = Install-VerifiedArchiveBinary `
        -BinaryName 'promtool' `
        -DownloadUrl "https://github.com/prometheus/prometheus/releases/download/v$promVersion/$pArchive" `
        -ArchiveName $pArchive `
        -ExpectedSha256 $promChecksums[$pArchive] `
        -RelativeExtractedBinary $pRel
}
if (-not $promtoolBin) {
    throw "promtool CLI not found. Run './scripts/Verify-Stage5RuntimeSecurity.ps1 -InstallTools' to install SHA-256 verified Prometheus promtool $promVersion."
}

Write-Host '=== Stage 5A: Kyverno Admission & Cosign Supply-Chain Policy Verification ==='
$kyvernoTestDir = Join-Path $repoRoot 'security/stage5/kyverno-tests'
& $kyvernoBin test $kyvernoTestDir
if ($LASTEXITCODE) {
    throw 'Kyverno policy unit test suite failed.'
}

$cosignPolicyPath = Join-Path $repoRoot 'deploy/k8s/kyverno/davids-verify-signed-images.yaml'
$cosignContent = Get-Content -LiteralPath $cosignPolicyPath -Raw
foreach ($token in @('kind: ClusterPolicy', 'verifyImages:', 'https://token.actions.githubusercontent.com', 'https://rekor.sigstore.dev', 'https://cyclonedx.org/bom', 'mutateDigest: true', 'verifyDigest: true')) {
    if (-not $cosignContent.Contains($token)) {
        throw "Kyverno Cosign policy ($cosignPolicyPath) is missing required configuration '$token'."
    }
}

Write-Host '=== Stage 5B: Istio Zero-Trust STRICT mTLS & L7 AuthorizationPolicy Verification ==='
$k8sCoreManifests = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'deploy/k8s') -Filter '*.yaml' -File | ForEach-Object { $_.FullName })
& $istioctlBin analyze --use-kube=false --failure-threshold Warning @k8sCoreManifests
if ($LASTEXITCODE) {
    throw 'istioctl analyze reported mesh configuration issues.'
}

$istioContent = Get-Content -LiteralPath (Join-Path $repoRoot 'deploy/k8s/istio-mesh-security.yaml') -Raw
foreach ($token in @('mode: STRICT', 'portLevelMtls:', 'mode: ISTIO_MUTUAL', 'name: default-deny', 'action: DENY', 'minProtocolVersion: TLSV1_3', 'request.auth.claims[role]')) {
    if (-not $istioContent.Contains($token)) {
        throw "Istio zero-trust manifest is missing required Stage 5 policy token '$token'."
    }
}

Write-Host '=== Stage 5C: Falco & Cilium Tetragon eBPF Runtime Security Verification ==='
$falcoRules = Get-Content -LiteralPath (Join-Path $repoRoot 'security/stage5/falco/davids_rules.yaml') -Raw
foreach ($rule in @(
    'Davids Dotnet Container Spawned Shell or Recon Tool',
    'Davids Fileless or Writable-Tmp Binary Execution',
    'Davids Unexpected Read of Kubernetes Secret or Credential Path',
    'Davids Container Privilege Escalation or Namespace Escape Syscall',
    'Davids Unexpected Outbound Connection Port from Dotnet Pod'
)) {
    if (-not $falcoRules.Contains($rule)) {
        throw "Falco rule '$rule' missing from security/stage5/falco/davids_rules.yaml."
    }
}

$tetragonPolicies = Get-Content -LiteralPath (Join-Path $repoRoot 'deploy/k8s/runtime-security/tetragon-tracingpolicies.yaml') -Raw
foreach ($token in @(
    'kind: TracingPolicyNamespaced',
    'davids-enforce-no-shells-or-nettools',
    'davids-enforce-no-tmp-or-memfd-exec',
    'davids-audit-sensitive-files-and-escape-syscalls',
    'action: Sigkill'
)) {
    if (-not $tetragonPolicies.Contains($token)) {
        throw "Cilium Tetragon eBPF policy token '$token' missing from deploy/k8s/runtime-security/tetragon-tracingpolicies.yaml."
    }
}

Write-Host '=== Stage 5D: Prometheus, Grafana Unified Alerting & Seq Login-Audit Verification ==='
$promRules = Join-Path $repoRoot 'security/stage5/prometheus/davids-security-rules.yml'
$promTests = Join-Path $repoRoot 'security/stage5/prometheus/davids-security-rules.test.yml'
& $promtoolBin check rules $promRules
if ($LASTEXITCODE) {
    throw 'promtool check rules failed.'
}
& $promtoolBin test rules $promTests
if ($LASTEXITCODE) {
    throw 'promtool test rules failed.'
}

$grafanaDashboard = Get-Content -LiteralPath (Join-Path $repoRoot 'src/Davids.AppHost/config/grafana/dashboards/davids-security-audit.json') -Raw | ConvertFrom-Json -Depth 32
if ($grafanaDashboard.uid -ne 'davids-security-audit' -or @($grafanaDashboard.panels).Count -lt 6) {
    throw 'Grafana Stage 5 security audit dashboard validation failed.'
}

$grafanaAlertYaml = Get-Content -LiteralPath (Join-Path $repoRoot 'src/Davids.AppHost/config/grafana/provisioning/alerting/security-alerts.yaml') -Raw
foreach ($uid in @('davids-admin-lockout', 'davids-customer-lockout-spike', 'davids-oidc-replay-tampering', 'davids-rate-limit-spike', 'davids-bff-csrf-spike', 'davids-ebpf-runtime-intrusion')) {
    if (-not $grafanaAlertYaml.Contains("uid: $uid")) {
        throw "Grafana Unified Alerting rule '$uid' missing from security-alerts.yaml."
    }
}

& (Join-Path $PSScriptRoot 'Bootstrap-SeqSecurityAlerts.ps1') -ValidateConfigOnly

Write-Host 'All Stage 5 runtime security gates (Kyverno, Istio STRICT mTLS, Falco/Tetragon eBPF, and Prometheus/Grafana/Seq alerting) passed.'
