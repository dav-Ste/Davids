[CmdletBinding()]
param(
    [switch]$Unblock,
    [switch]$InstallGitleaks
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$workspaceRoot = Split-Path $repoRoot -Parent
$requiredRepos = @(
    'Davids.Shared',
    'Davids.Services.Identity',
    'Davids.Services.AdminIdentity',
    'Davids.Services.Customers',
    'Davids.APIGateway',
    'Davids.Frontend.Admin'
)
$missing = @($requiredRepos | Where-Object { -not (Test-Path (Join-Path $workspaceRoot $_)) })
if ($missing.Count -gt 0) {
    throw "Missing sibling repositories: $($missing -join ', '). Run ./scripts/Get-Projects.ps1 -GitHubOwner <owner> first."
}

# Always prefer the 64-bit .NET CLI on Windows and disable MSBuild node reuse so child MSBuild
# worker nodes cannot exhaust virtual memory / commit charge alongside Docker & Aspire containers.
$dotnet = 'dotnet'
if ($env:OS -eq 'Windows_NT') {
    $progFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { 'C:\Program Files' }
    $candidate64 = Join-Path $progFiles64 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $candidate64) {
        $dotnet = $candidate64
    }
}
$env:MSBUILDDISABLENODEREUSE = '1'

function New-CryptoBytes([int]$Length) {
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ,$bytes
}

function ConvertTo-DerLength([int]$Length) {
    if ($Length -lt 0x80) { return ,[byte[]]@([byte]$Length) }
    $octets = New-Object System.Collections.Generic.List[byte]
    $remaining = $Length
    while ($remaining -gt 0) {
        $octets.Insert(0, [byte]($remaining -band 0xFF))
        $remaining = $remaining -shr 8
    }
    $octets.Insert(0, [byte](0x80 -bor $octets.Count))
    return ,$octets.ToArray()
}

function ConvertTo-DerTlv([byte]$Tag, [byte[]]$Content) {
    $lenBytes = ConvertTo-DerLength $Content.Length
    $buffer = New-Object byte[] (1 + $lenBytes.Length + $Content.Length)
    $buffer[0] = $Tag
    [System.Buffer]::BlockCopy($lenBytes, 0, $buffer, 1, $lenBytes.Length)
    [System.Buffer]::BlockCopy($Content, 0, $buffer, 1 + $lenBytes.Length, $Content.Length)
    return ,$buffer
}

function ConvertTo-DerInteger([byte[]]$UnsignedBigEndian) {
    $start = 0
    while (($start -lt ($UnsignedBigEndian.Length - 1)) -and ($UnsignedBigEndian[$start] -eq 0)) {
        $start++
    }
    $padZero = ($UnsignedBigEndian[$start] -band 0x80) -ne 0
    $sliceLen = $UnsignedBigEndian.Length - $start
    $body = New-Object byte[] ($sliceLen + $(if ($padZero) { 1 } else { 0 }))
    [System.Buffer]::BlockCopy($UnsignedBigEndian, $start, $body, $(if ($padZero) { 1 } else { 0 }), $sliceLen)
    return ,(ConvertTo-DerTlv 0x02 $body)
}

function Join-ByteArrays([byte[][]]$Parts) {
    $total = 0
    foreach ($part in $Parts) { $total += $part.Length }
    $merged = New-Object byte[] $total
    $offset = 0
    foreach ($part in $Parts) {
        [System.Buffer]::BlockCopy($part, 0, $merged, $offset, $part.Length)
        $offset += $part.Length
    }
    return ,$merged
}

function New-RsaPrivateKeyPkcs8Base64 {
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $exportMethod = $rsa.GetType().GetMethod('ExportPkcs8PrivateKey', [Type]::EmptyTypes)
        if ($null -ne $exportMethod) {
            return [Convert]::ToBase64String([byte[]]$exportMethod.Invoke($rsa, $null))
        }

        # Windows PowerShell 5.1 (.NET Framework 4.8) fallback: RFC 5208 PKCS#8 DER encoding
        $p = $rsa.ExportParameters($true)
        $rsaPrivateKeySeq = ConvertTo-DerTlv 0x30 (Join-ByteArrays @(
            (ConvertTo-DerInteger ([byte[]]@(0))),
            (ConvertTo-DerInteger $p.Modulus),
            (ConvertTo-DerInteger $p.Exponent),
            (ConvertTo-DerInteger $p.D),
            (ConvertTo-DerInteger $p.P),
            (ConvertTo-DerInteger $p.Q),
            (ConvertTo-DerInteger $p.DP),
            (ConvertTo-DerInteger $p.DQ),
            (ConvertTo-DerInteger $p.InverseQ)
        ))
        [byte[]]$rsaAlgId = 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00
        $pkcs8 = ConvertTo-DerTlv 0x30 (Join-ByteArrays @(
            (ConvertTo-DerInteger ([byte[]]@(0))),
            $rsaAlgId,
            (ConvertTo-DerTlv 0x04 $rsaPrivateKeySeq)
        ))
        return [Convert]::ToBase64String($pkcs8)
    } finally {
        $rsa.Dispose()
    }
}

$repoDirs = @($repoRoot) + @($requiredRepos | ForEach-Object { Join-Path $workspaceRoot $_ })
if ($env:OS -eq 'Windows_NT') {
    $toolsManifest = Join-Path $repoRoot '.config\dotnet-tools.json'
    $hasMotw = $null -ne (Get-Item -LiteralPath $toolsManifest -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
    if ($Unblock -or ($hasMotw -and $PSCmdlet.ShouldContinue(
        "Workspace files carry Windows Mark-of-the-Web (Zone.Identifier) from extracting a downloaded .zip archive, which blocks 'dotnet tool restore'. Unblock files in the Davids repositories now?",
        'Windows Mark-of-the-Web Detected'))) {
        foreach ($dir in $repoDirs) {
            Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Unblock-File
        }
        Write-Host 'Unblocked workspace files across Davids repositories.'
    } elseif ($hasMotw) {
        throw "Blocked '.config\dotnet-tools.json' (Mark of the Web). Re-run './scripts/Setup.ps1 -Unblock' or run: Get-ChildItem '$workspaceRoot' -Recurse -File -Force | Unblock-File"
    }
}

Push-Location $repoRoot
try {
    & $dotnet dev-certs https --trust
    if ($LASTEXITCODE) { throw 'HTTPS certificate setup failed.' }

    # Provision Aspire development parameters in user-secrets upfront (in-process, zero MSBuild overhead).
    $project = 'src/Davids.AppHost'
    $existing = & $dotnet user-secrets list --project $project
    if ($LASTEXITCODE) { throw 'Cannot inspect development secrets.' }

    foreach ($obsoleteParam in @('jwt-signing-key', 'admin-jwt-signing-key')) {
        if ($existing -match ("^Parameters:" + [regex]::Escape($obsoleteParam) + " =")) {
            & $dotnet user-secrets remove "Parameters:$obsoleteParam" --project $project | Out-Null
        }
    }

    foreach ($rsaParam in @(
        'oidc-signing-key',
        'oidc-encryption-key',
        'admin-oidc-signing-key',
        'admin-oidc-encryption-key'
    )) {
        if (-not ($existing -match ("^Parameters:" + [regex]::Escape($rsaParam) + " ="))) {
            $rsaKey = New-RsaPrivateKeyPkcs8Base64
            & $dotnet user-secrets set "Parameters:$rsaParam" $rsaKey --project $project | Out-Null
            if ($LASTEXITCODE) { throw "Failed to store $rsaParam in user-secrets." }
        }
    }

    if (-not ($existing -match '^Parameters:admin-oidc-bff-client-secret =')) {
        $bffSecret = [Convert]::ToBase64String((New-CryptoBytes 48))
        & $dotnet user-secrets set 'Parameters:admin-oidc-bff-client-secret' $bffSecret --project $project | Out-Null
        if ($LASTEXITCODE) { throw 'Admin OIDC BFF client secret setup failed.' }
    }
    if (-not ($existing -match '^Parameters:vault-dev-root-token =')) {
        $token = ([System.BitConverter]::ToString((New-CryptoBytes 32)) -replace '-', '')
        & $dotnet user-secrets set 'Parameters:vault-dev-root-token' $token --project $project | Out-Null
        if ($LASTEXITCODE) { throw 'Vault development token setup failed.' }
    }
    if (-not ($existing -match '^Parameters:dev-admin-password =')) {
        $adminSecret = 'Admin-' + [Convert]::ToBase64String((New-CryptoBytes 18)) + '!'
        & $dotnet user-secrets set 'Parameters:dev-admin-password' $adminSecret --project $project | Out-Null
        if ($LASTEXITCODE) { throw 'Development admin password setup failed.' }
        Write-Host "Provisioned development admin secret in user-secrets (seeded in adminidentitydb for email: admin@davids.local; inspect via 'dotnet user-secrets list --project src/Davids.AppHost')."
    }

    & $dotnet tool restore
    if ($LASTEXITCODE) { throw 'Tool restore failed.' }

    # Restore each standalone repository solution sequentially in locked mode (-m:1 -nr:false --tl:off)
    # to avoid multi-node MSBuild memory spikes on Windows when Docker Desktop & Aspire are running.
    $lockedSolutions = @(
        '../Davids.Shared/Davids.Shared.slnx',
        '../Davids.Services.Identity/Davids.Services.Identity.slnx',
        '../Davids.Services.AdminIdentity/Davids.Services.AdminIdentity.slnx',
        '../Davids.Services.Customers/Davids.Services.Customers.slnx',
        '../Davids.APIGateway/Davids.APIGateway.slnx',
        '../Davids.Frontend.Admin/Davids.Frontend.Admin.slnx',
        'src/Davids.Bootstrap/Davids.Bootstrap.csproj'
    )
    foreach ($sln in $lockedSolutions) {
        & $dotnet restore $sln --locked-mode -m:1 -nr:false --tl:off
        if ($LASTEXITCODE) { throw "Locked solution restore failed for $sln." }
    }

    # Clear any stale AppHost build outputs so Visual Studio / dotnet run always re-stamps
    # host-OS DCP (dcpclipath) and Dashboard (aspiredashboardpath) assembly metadata.
    foreach ($staleDir in @(
        'artifacts/bin/Davids.AppHost',
        'artifacts/obj/Davids.AppHost',
        'artifacts/bin/Davids.AppHost.Tests',
        'artifacts/obj/Davids.AppHost.Tests',
        'src/Davids.AppHost/bin',
        'src/Davids.AppHost/obj',
        'tests/Davids.AppHost.Tests/bin',
        'tests/Davids.AppHost.Tests/obj'
    )) {
        if (Test-Path -LiteralPath $staleDir) {
            Remove-Item -LiteralPath $staleDir -Recurse -Force
        }
    }

    # Restore Davids.slnx (Davids.AppHost resolves host-OS RID packages Aspire.Hosting.Orchestration.<rid>
    # and Aspire.Dashboard.Sdk.<rid> pinned to 13.6.1 in Directory.Packages.props).
    & $dotnet restore 'Davids.slnx' -m:1 -nr:false --tl:off
    if ($LASTEXITCODE) { throw 'Solution restore failed for Davids.slnx.' }

    $installHooksScript = Join-Path $PSScriptRoot 'security/local-dev-commit/Install-GitHooks.ps1'
    if (Test-Path -LiteralPath $installHooksScript) {
        if ($InstallGitleaks) {
            & $installHooksScript -InstallGitleaks
        } else {
            & $installHooksScript
        }
    }

    Write-Host 'Setup completed: all Aspire OIDC parameters provisioned in user-secrets, git pre-commit hooks verified, and all solutions restored.'
} finally { Pop-Location }
