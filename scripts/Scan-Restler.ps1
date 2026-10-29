[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [ValidateSet('Test', 'FuzzLean', 'Fuzz')]
    [string]$Mode = 'FuzzLean',
    [double]$TimeBudgetHours = 0.25,
    [string]$RestlerImage = 'mcr.microsoft.com/restlerfuzzer/restler:latest@sha256:0f3275119352be05011b7004a7bc644b190baf7522674ab970955917ee111a12',
    [string]$RestlerDllPath = $env:DAVIDS_RESTLER_DLL,
    [string]$PythonExecutable = $env:DAVIDS_RESTLER_PYTHON,
    [string]$CustomerBearerToken = $env:DAVIDS_STAGE4_CUSTOMER_TOKEN,
    [string]$ShadowCustomerBearerToken = $env:DAVIDS_STAGE4_SHADOW_CUSTOMER_TOKEN,
    [string]$AdminBearerToken = $env:DAVIDS_STAGE4_ADMIN_TOKEN,
    [string]$CustomerEmail = $env:DAVIDS_STAGE4_CUSTOMER_EMAIL,
    [string]$CustomerPassword = $env:DAVIDS_STAGE4_CUSTOMER_PASSWORD,
    [string]$AdminEmail = $env:DAVIDS_STAGE4_ADMIN_EMAIL,
    [string]$AdminPassword = $env:DAVIDS_STAGE4_ADMIN_PASSWORD,
    [string]$AdminBffClientId = 'davids-admin-bff',
    [string]$AdminBffClientSecret = $env:DAVIDS_STAGE4_ADMIN_BFF_SECRET,
    [string]$AdminRedirectUri = 'https://localhost/signin-oidc',
    [string]$CustomerRedirectUri = 'https://localhost/callback',
    [string]$OutputDirectory = '',
    [switch]$CompileOnly,
    [switch]$ValidateConfigOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$restlerConfigDir = Join-Path $repoRoot 'security/restler'

if ($ValidateConfigOnly) {
    foreach ($cfgFile in @(
        'annotations-customer.json',
        'annotations-admin.json',
        'dict.template.json',
        'compile-customer.json',
        'compile-admin.json',
        'engine-settings.json',
        'specs/identity.restler.openapi.json',
        'specs/admin-identity.restler.openapi.json',
        'specs/customers.restler.openapi.json'
    )) {
        $fullPath = Join-Path $restlerConfigDir $cfgFile
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "Missing required RESTler configuration or OpenAPI 3.0.3 spec: $fullPath"
        }
        $parsed = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json -Depth 64
        if ($cfgFile.StartsWith('compile-')) {
            if (-not $parsed.UseRefreshableToken) {
                throw "$cfgFile must enable UseRefreshableToken=true."
            }
        }
        if ($cfgFile.StartsWith('specs/')) {
            if ([string]$parsed.openapi -ne '3.0.3') {
                throw "$cfgFile must target OpenAPI 3.0.3 for RESTler compatibility (found '$($parsed.openapi)')."
            }
        }
    }
    Write-Host 'Verified Microsoft RESTler stateful fuzzing configurations and OpenAPI 3.0.3 specs.'
    return
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/stage4/restler'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function New-PkcePair {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ Verifier = $verifier; Challenge = $challenge }
}

function Get-OidcAccessTokenPkce {
    param(
        [Parameter(Mandatory)][string]$BaseGatewayUrl,
        [Parameter(Mandatory)][string]$RoutePrefix,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$ClientSecret = '',
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password
    )

    $pkce = New-PkcePair
    $state = 'restler-' + [Guid]::NewGuid().ToString('N')
    $queryPairs = @(
        "client_id=$([Uri]::EscapeDataString($ClientId))",
        "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))",
        "response_type=code",
        "scope=$([Uri]::EscapeDataString($Scope))",
        "code_challenge=$($pkce.Challenge)",
        "code_challenge_method=S256",
        "state=$state"
    ) -join '&'

    $authorizeGetUri = "$($BaseGatewayUrl.TrimEnd('/'))/$RoutePrefix/connect/authorize?$queryPairs"
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $getResp = Invoke-WebRequest -Uri $authorizeGetUri -Method Get -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $getResp -or [int]$getResp.StatusCode -ne 200) {
        throw "GET $authorizeGetUri did not return HTTP 200."
    }

    $match = [regex]::Match($getResp.Content, 'name="request_token"\s+value="([^"]*)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Missing hidden 'request_token' field in /$RoutePrefix/connect/authorize login form."
    }
    $requestToken = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)

    $formBody = @{
        client_id             = $ClientId
        redirect_uri          = $RedirectUri
        response_type         = 'code'
        scope                 = $Scope
        code_challenge        = $pkce.Challenge
        code_challenge_method = 'S256'
        state                 = $state
        request_token         = $requestToken
        email                 = $Email
        password              = $Password
    }

    $authorizePostUri = "$($BaseGatewayUrl.TrimEnd('/'))/$RoutePrefix/connect/authorize"
    $postResp = Invoke-WebRequest -Uri $authorizePostUri -Method Post -Body $formBody -ContentType 'application/x-www-form-urlencoded' -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $postResp -or [int]$postResp.StatusCode -notin @(302, 303)) {
        throw "POST $authorizePostUri failed to redirect."
    }

    $locationHeader = [string]$postResp.Headers['Location']
    $locationUri = if ($locationHeader.StartsWith('http', [StringComparison]::OrdinalIgnoreCase)) {
        [Uri]$locationHeader
    } else {
        [Uri]::new([Uri]$BaseGatewayUrl, $locationHeader)
    }

    $parsedQuery = [System.Web.HttpUtility]::ParseQueryString($locationUri.Query)
    $code = $parsedQuery['code']
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "Authorization redirect from /$RoutePrefix/connect/authorize did not contain an authorization code."
    }

    $tokenBody = @{
        grant_type    = 'authorization_code'
        client_id     = $ClientId
        code          = $code
        redirect_uri  = $RedirectUri
        code_verifier = $pkce.Verifier
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientSecret)) {
        $tokenBody['client_secret'] = $ClientSecret
    }

    $tokenUri = "$($BaseGatewayUrl.TrimEnd('/'))/$RoutePrefix/connect/token"
    $tokenResp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
    if ([string]::IsNullOrWhiteSpace($tokenResp.access_token)) {
        throw "POST $tokenUri did not return an access_token."
    }
    return [string]$tokenResp.access_token
}

# Verify OpenAPI 3.1 + RESTler 3.0.3 specs are synchronized before compiling grammars
& (Join-Path $PSScriptRoot 'Export-OpenApiSpecs.ps1') -VerifyOnly

$useLocalRestler = -not [string]::IsNullOrWhiteSpace($RestlerDllPath)
if ($useLocalRestler) {
    if (-not (Test-Path -LiteralPath $RestlerDllPath)) {
        throw "Specified -RestlerDllPath does not exist: $RestlerDllPath"
    }
    $RestlerDllPath = (Resolve-Path -LiteralPath $RestlerDllPath).Path
    if ([string]::IsNullOrWhiteSpace($PythonExecutable)) {
        $PythonExecutable = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
    }
} else {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker CLI is not installed and -RestlerDllPath was not provided. Install Docker Desktop/Engine or set DAVIDS_RESTLER_DLL."
    }
}

$targetUri = [Uri]$GatewayUrl
$effectiveHost = $targetUri.Host
$effectivePort = $targetUri.Port
$useSsl = $targetUri.Scheme -eq 'https'

if (-not $useLocalRestler -and $targetUri.Host -in @('localhost', '127.0.0.1', '::1')) {
    $effectiveHost = 'host.docker.internal'
}

$restlerTaskMode = switch ($Mode) {
    'Test'     { 'test' }
    'FuzzLean' { 'fuzz-lean' }
    'Fuzz'     { 'fuzz' }
}

# Prepare runtime fuzzing workspace with ephemeral fuzz password (zero static secrets in git)
$workRoot = Join-Path $OutputDirectory 'workspace'
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

$ephemeralFuzzSecret = "Restler!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Aa9"
$dictRaw = Get-Content -LiteralPath (Join-Path $restlerConfigDir 'dict.template.json') -Raw
$dictHydrated = $dictRaw.Replace('__RESTLER_RUNTIME_FUZZ_PASSWORD__', $ephemeralFuzzSecret)

foreach ($domain in @(
    @{ Subdir = 'CustomerDomain'; CompileCfg = 'compile-customer.json'; Annotations = 'annotations-customer.json' },
    @{ Subdir = 'AdminDomain';    CompileCfg = 'compile-admin.json';    Annotations = 'annotations-admin.json' }
)) {
    $domainDir = Join-Path $workRoot $domain.Subdir
    New-Item -ItemType Directory -Path (Join-Path $domainDir 'specs') -Force | Out-Null
    foreach ($specName in @('identity.restler.openapi.json', 'admin-identity.restler.openapi.json', 'customers.restler.openapi.json')) {
        Copy-Item -LiteralPath (Join-Path $restlerConfigDir "specs/$specName") -Destination (Join-Path $domainDir "specs/$specName") -Force
    }
    Copy-Item -LiteralPath (Join-Path $restlerConfigDir $domain.Annotations) -Destination (Join-Path $domainDir $domain.Annotations) -Force
    [System.IO.File]::WriteAllText((Join-Path $domainDir 'dict.runtime.json'), $dictHydrated, $utf8NoBom)
    $cfgRaw = Get-Content -LiteralPath (Join-Path $restlerConfigDir $domain.CompileCfg) -Raw
    $cfgHydrated = $cfgRaw.Replace('dict.template.json', 'dict.runtime.json')
    [System.IO.File]::WriteAllText((Join-Path $domainDir $domain.CompileCfg), $cfgHydrated, $utf8NoBom)
}

$engineSettings = Get-Content -LiteralPath (Join-Path $restlerConfigDir 'engine-settings.json') -Raw | ConvertFrom-Json -AsHashtable
$engineSettings['time_budget'] = $TimeBudgetHours
[System.IO.File]::WriteAllText(
    (Join-Path $workRoot 'engine-settings.runtime.json'),
    (($engineSettings | ConvertTo-Json -Depth 20) + "`n"),
    $utf8NoBom)

function Invoke-RestlerCommand {
    param(
        [Parameter(Mandatory)][string[]]$RestlerArgs,
        [Parameter(Mandatory)][string]$WorkingSubdir
    )

    $hostRunDir = Join-Path $workRoot $WorkingSubdir
    New-Item -ItemType Directory -Path $hostRunDir -Force | Out-Null

    if ($useLocalRestler) {
        $prevRollForward = $env:DOTNET_ROLL_FORWARD
        try {
            $env:DOTNET_ROLL_FORWARD = 'Major'
            Push-Location $hostRunDir
            try {
                $globalArgs = @('--disable_log_upload', '--python_path', $PythonExecutable)
                & dotnet $RestlerDllPath @globalArgs @RestlerArgs
                if ($LASTEXITCODE -ne 0) {
                    throw "Microsoft RESTler exited with code $LASTEXITCODE ($($RestlerArgs -join ' '))."
                }
            } finally {
                Pop-Location
            }
        } finally {
            $env:DOTNET_ROLL_FORWARD = $prevRollForward
        }
    } else {
        $dockerArgs = @('run', '--rm')
        if ($IsLinux) {
            $dockerArgs += '--add-host=host.docker.internal:host-gateway'
        }
        $dockerArgs += @(
            '-v', "${workRoot}:/restler-work",
            '-w', "/restler-work/$WorkingSubdir",
            $RestlerImage,
            '/RESTler/restler/Restler',
            '--disable_log_upload'
        )
        $dockerArgs += $RestlerArgs
        & docker @dockerArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Microsoft RESTler container exited with code $LASTEXITCODE."
        }
    }
}

Write-Host '=== Stage 4A: Compiling Microsoft RESTler Stateful Grammars (Customer & Admin) ==='
Invoke-RestlerCommand -WorkingSubdir 'CustomerDomain' -RestlerArgs @('compile', 'compile-customer.json')
Invoke-RestlerCommand -WorkingSubdir 'AdminDomain' -RestlerArgs @('compile', 'compile-admin.json')

foreach ($compiledDir in @('CustomerDomain/Compile', 'AdminDomain/Compile')) {
    foreach ($artifact in @('grammar.py', 'grammar.json', 'dict.json', 'engine_settings.json')) {
        $artifactPath = Join-Path $workRoot "$compiledDir/$artifact"
        if (-not (Test-Path -LiteralPath $artifactPath)) {
            throw "RESTler compilation failed to emit expected artifact: $artifactPath"
        }
    }
}
Write-Host 'RESTler Customer and Admin stateful grammars compiled cleanly (0 errors).'

if ($CompileOnly) {
    Write-Host 'CompileOnly specified; skipping live stateful fuzzing execution.'
    return
}

# Acquire Customer & Admin RS256 Bearer tokens if not pre-supplied
if ([string]::IsNullOrWhiteSpace($CustomerBearerToken)) {
    if ([string]::IsNullOrWhiteSpace($CustomerEmail)) {
        $CustomerEmail = "restler.seed.$([Guid]::NewGuid().ToString('N').Substring(0, 8))@davids.example"
        $CustomerPassword = "RestlerSeed!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Zz9"
        $signUpUri = "$($GatewayUrl.TrimEnd('/'))/identity/sign-up"
        Invoke-RestMethod -Uri $signUpUri -Method Post -ContentType 'application/json' -Body (@{
            email    = $CustomerEmail
            password = $CustomerPassword
            role     = 'user'
        } | ConvertTo-Json) | Out-Null
    }
    $CustomerBearerToken = Get-OidcAccessTokenPkce `
        -BaseGatewayUrl $GatewayUrl `
        -RoutePrefix 'identity' `
        -ClientId 'davids-web' `
        -RedirectUri $CustomerRedirectUri `
        -Scope 'openid email profile roles offline_access davids-services' `
        -Email $CustomerEmail `
        -Password $CustomerPassword
}

if ([string]::IsNullOrWhiteSpace($ShadowCustomerBearerToken)) {
    $shadowEmail = "restler.shadow.$([Guid]::NewGuid().ToString('N').Substring(0, 8))@davids.example"
    $shadowPassword = "RestlerShad!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Zz9"
    $signUpUri = "$($GatewayUrl.TrimEnd('/'))/identity/sign-up"
    Invoke-RestMethod -Uri $signUpUri -Method Post -ContentType 'application/json' -Body (@{
        email    = $shadowEmail
        password = $shadowPassword
        role     = 'user'
    } | ConvertTo-Json) | Out-Null
    $ShadowCustomerBearerToken = Get-OidcAccessTokenPkce `
        -BaseGatewayUrl $GatewayUrl `
        -RoutePrefix 'identity' `
        -ClientId 'davids-web' `
        -RedirectUri $CustomerRedirectUri `
        -Scope 'openid email profile roles offline_access davids-services' `
        -Email $shadowEmail `
        -Password $shadowPassword
}

if ([string]::IsNullOrWhiteSpace($AdminBearerToken)) {
    if ([string]::IsNullOrWhiteSpace($AdminEmail) -or [string]::IsNullOrWhiteSpace($AdminPassword) -or [string]::IsNullOrWhiteSpace($AdminBffClientSecret)) {
        throw "Provide -AdminBearerToken (or DAVIDS_STAGE4_ADMIN_TOKEN), or supply -AdminEmail, -AdminPassword, and -AdminBffClientSecret for PKCE token exchange."
    }
    $AdminBearerToken = Get-OidcAccessTokenPkce `
        -BaseGatewayUrl $GatewayUrl `
        -RoutePrefix 'admin-identity' `
        -ClientId $AdminBffClientId `
        -ClientSecret $AdminBffClientSecret `
        -RedirectUri $AdminRedirectUri `
        -Scope 'openid email profile roles offline_access davids-admin' `
        -Email $AdminEmail `
        -Password $AdminPassword
}

# Write per-role RESTler token refresh helpers (tokens stored in ephemeral runtime files, never logged)
$customerTokenFile = Join-Path $workRoot '.customer-bearer.token'
$shadowCustomerTokenFile = Join-Path $workRoot '.customer-shadow-bearer.token'
$adminTokenFile = Join-Path $workRoot '.admin-bearer.token'
[System.IO.File]::WriteAllText($customerTokenFile, $CustomerBearerToken.Trim(), $utf8NoBom)
[System.IO.File]::WriteAllText($shadowCustomerTokenFile, $ShadowCustomerBearerToken.Trim(), $utf8NoBom)
[System.IO.File]::WriteAllText($adminTokenFile, $AdminBearerToken.Trim(), $utf8NoBom)

$tokenScriptTemplate = @'
import pathlib, sys
primary = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if len(sys.argv) > 2 and pathlib.Path(sys.argv[2]).exists():
    shadow = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").strip()
    print("{'app1': {}, 'app2': {}}")
    print(f"Authorization: Bearer {primary}")
    print(f"Authorization: Bearer {shadow}")
else:
    print("{'app1': {}}")
    print(f"Authorization: Bearer {primary}")
'@
[System.IO.File]::WriteAllText((Join-Path $workRoot 'emit-token.py'), $tokenScriptTemplate, $utf8NoBom)

$suites = @(
    @{
        Name            = 'customer'
        CompileDir      = 'CustomerDomain/Compile'
        RunSubdir       = 'RunCustomer'
        TokenFile       = '.customer-bearer.token'
        ShadowTokenFile = '.customer-shadow-bearer.token'
        Checkers        = 'leakagerule,resourcehierarchy,useafterfree,namespacerule,invaliddynamicobject,payloadbody,invalidvalue'
    },
    @{
        Name            = 'admin'
        CompileDir      = 'AdminDomain/Compile'
        RunSubdir       = 'RunAdmin'
        TokenFile       = '.admin-bearer.token'
        ShadowTokenFile = ''
        Checkers        = 'leakagerule,resourcehierarchy,useafterfree,invaliddynamicobject,payloadbody,invalidvalue'
    }
)

$suiteSummaries = @()
$sarifResults = @()
$totalBugCount = 0

try {
    foreach ($suite in $suites) {
        Write-Host "=== Stage 4A: Running Microsoft RESTler ($restlerTaskMode) for '$($suite.Name)' security domain ==="
        $absBase = if ($useLocalRestler) { $workRoot } else { '/restler-work' }
        $pyCmd = if ($useLocalRestler) { $PythonExecutable } else { '/usr/bin/python3' }
        $refreshCmd = if (-not [string]::IsNullOrWhiteSpace($suite.ShadowTokenFile)) {
            "$pyCmd $absBase/emit-token.py $absBase/$($suite.TokenFile) $absBase/$($suite.ShadowTokenFile)"
        } else {
            "$pyCmd $absBase/emit-token.py $absBase/$($suite.TokenFile)"
        }

        $fuzzArgs = @(
            $restlerTaskMode,
            '--grammar_file', "$absBase/$($suite.CompileDir)/grammar.py",
            '--dictionary_file', "$absBase/$($suite.CompileDir)/dict.json",
            '--settings', "$absBase/engine-settings.runtime.json",
            '--target_ip', $effectiveHost,
            '--target_port', "$effectivePort",
            '--host', "$($targetUri.Authority)",
            '--token_refresh_command', $refreshCmd,
            '--token_refresh_interval', '600',
            '--enable_checkers', $suite.Checkers
        )
        if (-not $useSsl) {
            $fuzzArgs += '--no_ssl'
        }
        if ($restlerTaskMode -eq 'fuzz') {
            $fuzzArgs += @('--time_budget', "$TimeBudgetHours")
        }

        Invoke-RestlerCommand -WorkingSubdir $suite.RunSubdir -RestlerArgs $fuzzArgs

        $suiteOutRoot = Join-Path $workRoot $suite.RunSubdir
        $runSummaryFile = Get-ChildItem -Path $suiteOutRoot -Recurse -Filter 'runSummary.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        $bugBucketsFile = Get-ChildItem -Path $suiteOutRoot -Recurse -Filter 'bug_buckets.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
        $testingSummaryFile = Get-ChildItem -Path $suiteOutRoot -Recurse -Filter 'testing_summary.json' -ErrorAction SilentlyContinue | Select-Object -First 1

        $bugCount = 0
        $totalRequestsSent = 0
        $specCoverage = ''
        if ($null -ne $testingSummaryFile) {
            $ts = Get-Content -LiteralPath $testingSummaryFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($ts.ContainsKey('total_bug_buckets')) {
                $bugCount = [int]$ts['total_bug_buckets']
            } elseif ($ts.ContainsKey('bug_buckets') -and $null -ne $ts['bug_buckets']) {
                $bb = $ts['bug_buckets']
                if ($bb -is [System.Collections.IDictionary]) {
                    foreach ($v in $bb.Values) {
                        $bugCount += [int]$v
                    }
                }
            }
            if ($ts.ContainsKey('final_spec_coverage')) {
                $specCoverage = [string]$ts['final_spec_coverage']
            }
            if ($ts.ContainsKey('total_requests_sent') -and $ts['total_requests_sent'] -is [System.Collections.IDictionary]) {
                foreach ($reqVal in $ts['total_requests_sent'].Values) {
                    $totalRequestsSent += [int]$reqVal
                }
            }
        } elseif ($null -ne $bugBucketsFile) {
            $bbLines = @(Get-Content -LiteralPath $bugBucketsFile.FullName | Where-Object { $_ -match '^Total Buckets:\s*(\d+)' })
            if ($bbLines.Count -gt 0 -and $bbLines[0] -match '(\d+)') {
                $bugCount = [int]$Matches[1]
            }
        }

        $totalBugCount += $bugCount
        $suiteSummaries += [ordered]@{
            suite             = $suite.Name
            mode              = $restlerTaskMode
            bugBuckets        = $bugCount
            finalSpecCoverage = $specCoverage
            totalRequestsSent = $totalRequestsSent
            runSummaryPath    = if ($runSummaryFile) { $runSummaryFile.FullName } else { $null }
            testingSummary    = if ($testingSummaryFile) { $testingSummaryFile.FullName } else { $null }
        }

        if ($bugCount -gt 0) {
            $details = if ($bugBucketsFile) { Get-Content -LiteralPath $bugBucketsFile.FullName -Raw } else { "RESTler reported $bugCount bug bucket(s)." }
            $sarifResults += [ordered]@{
                ruleId  = "RESTLER-$($suite.Name.ToUpperInvariant())-BUG"
                level   = 'error'
                message = @{ text = "Microsoft RESTler ($restlerTaskMode) reported $bugCount bug bucket(s) in suite '$($suite.Name)': $details" }
            }
        }

        Write-Host "RESTler suite '$($suite.Name)' completed: bugBuckets=$bugCount, specCoverage=$specCoverage, mainDriverRequests=$totalRequestsSent"
    }
} finally {
    # Scrub runtime bearer token files immediately after execution
    foreach ($secretFile in @(
        $customerTokenFile,
        $shadowCustomerTokenFile,
        $adminTokenFile,
        (Join-Path $workRoot 'CustomerDomain/dict.runtime.json'),
        (Join-Path $workRoot 'AdminDomain/dict.runtime.json')
    )) {
        if (Test-Path -LiteralPath $secretFile) {
            Remove-Item -LiteralPath $secretFile -Force
        }
    }
}

$summaryDoc = [ordered]@{
    tool          = 'Microsoft RESTler'
    gatewayUrl    = $GatewayUrl
    mode          = $restlerTaskMode
    executedAtUtc = [DateTime]::UtcNow.ToString('o')
    totalBugs     = $totalBugCount
    passed        = ($totalBugCount -eq 0)
    suites        = $suiteSummaries
}
$summaryJsonPath = Join-Path $OutputDirectory 'restler-summary.json'
[System.IO.File]::WriteAllText($summaryJsonPath, (($summaryDoc | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

$sarifDoc = [ordered]@{
    '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
    version   = '2.1.0'
    runs      = @(
        [ordered]@{
            tool    = @{
                driver = @{
                    name           = 'Microsoft RESTler'
                    informationUri = 'https://github.com/microsoft/restler-fuzzer'
                    rules          = @()
                }
            }
            results = $sarifResults
        }
    )
}
$sarifPath = Join-Path $OutputDirectory 'restler.sarif'
[System.IO.File]::WriteAllText($sarifPath, (($sarifDoc | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

if ($totalBugCount -gt 0) {
    throw "Stage 4 Microsoft RESTler gate FAILED: $totalBugCount bug bucket(s) detected. Inspect $OutputDirectory."
}

Write-Host "Stage 4 Microsoft RESTler gate PASSED (0 bug buckets across Customer & Admin suites). Summary: $summaryJsonPath"
