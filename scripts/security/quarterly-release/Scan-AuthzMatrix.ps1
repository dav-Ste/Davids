[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$MatrixPath = '',
    [string]$CustomerABearerToken = $env:DAVIDS_RELEASE_CUSTOMER_TOKEN,
    [string]$CustomerAId = $env:DAVIDS_RELEASE_CUSTOMER_ID,
    [string]$CustomerBBearerToken = $env:DAVIDS_RELEASE_SHADOW_CUSTOMER_TOKEN,
    [string]$CustomerBId = $env:DAVIDS_RELEASE_SHADOW_CUSTOMER_ID,
    [string]$AdminBearerToken = $env:DAVIDS_RELEASE_ADMIN_TOKEN,
    [string]$AdminEmail = $env:DAVIDS_RELEASE_ADMIN_EMAIL,
    [string]$AdminPassword = $env:DAVIDS_RELEASE_ADMIN_PASSWORD,
    [string]$AdminBffClientId = 'davids-admin-bff',
    [string]$AdminBffClientSecret = $env:DAVIDS_RELEASE_ADMIN_BFF_SECRET,
    [string]$AdminRedirectUri = 'https://localhost/signin-oidc',
    [string]$CustomerRedirectUri = 'https://localhost/callback',
    [string]$OutputDirectory = '',
    [switch]$ValidateConfigOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
if ([string]::IsNullOrWhiteSpace($MatrixPath)) {
    $MatrixPath = Join-Path $repoRoot 'security/quarterly-release/authz/authz-matrix.json'
}
if (-not (Test-Path -LiteralPath $MatrixPath)) {
    throw "Quarterly / Release authorization matrix not found: $MatrixPath"
}

$burpConfigPath = Join-Path $repoRoot 'security/quarterly-release/authz/burp-community-project-options.json'
if (-not (Test-Path -LiteralPath $burpConfigPath)) {
    throw "Burp Suite Community project configuration not found: $burpConfigPath"
}
$null = Get-Content -LiteralPath $burpConfigPath -Raw | ConvertFrom-Json

$matrix = Get-Content -LiteralPath $MatrixPath -Raw | ConvertFrom-Json
if ($null -eq $matrix.cases -or $matrix.cases.Count -lt 25) {
    throw "Quarterly / Release authorization matrix '$MatrixPath' must define at least 25 cross-role security test cases."
}

$seenIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($case in $matrix.cases) {
    if (-not $seenIds.Add([string]$case.id)) {
        throw "Duplicate case id '$($case.id)' in $MatrixPath."
    }
    if ($case.actor -notin @('unauthenticated', 'customerA', 'customerB', 'admin')) {
        throw "Unsupported actor '$($case.actor)' in case '$($case.id)'."
    }
}

if ($ValidateConfigOnly) {
    Write-Host "Verified Quarterly / Release authorization matrix ($($matrix.cases.Count) cross-role cases) and Burp Community config."
    return
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'TestResults/quarterly-release/authz'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$baseGateway = $GatewayUrl.TrimEnd('/')

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([Parameter(Mandatory)][string]$Value)
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '=' }
    }
    return [Convert]::FromBase64String($padded)
}

function New-PkcePair {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $verifier = ConvertTo-Base64Url -Bytes $bytes
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = ConvertTo-Base64Url -Bytes $hash
    return @{ Verifier = $verifier; Challenge = $challenge }
}

function Get-AuthorizationCodePkce {
    param(
        [Parameter(Mandatory)][string]$RoutePrefix,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$CodeChallenge,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password
    )

    $state = 'authz-' + [Guid]::NewGuid().ToString('N')
    $queryPairs = @(
        "client_id=$([Uri]::EscapeDataString($ClientId))",
        "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))",
        "response_type=code",
        "scope=$([Uri]::EscapeDataString($Scope))",
        "code_challenge=$CodeChallenge",
        "code_challenge_method=S256",
        "state=$state"
    ) -join '&'

    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $getResp = Invoke-WebRequest -Uri "$baseGateway/$RoutePrefix/connect/authorize?$queryPairs" -Method Get -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $getResp -or [int]$getResp.StatusCode -ne 200) {
        throw "GET /$RoutePrefix/connect/authorize failed."
    }

    $match = [regex]::Match($getResp.Content, 'name="request_token"\s+value="([^"]*)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Missing hidden 'request_token' field in /$RoutePrefix/connect/authorize."
    }
    $requestToken = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)

    $formBody = @{
        client_id             = $ClientId
        redirect_uri          = $RedirectUri
        response_type         = 'code'
        scope                 = $Scope
        code_challenge        = $CodeChallenge
        code_challenge_method = 'S256'
        state                 = $state
        request_token         = $requestToken
        email                 = $Email
        password              = $Password
    }
    $postResp = Invoke-WebRequest -Uri "$baseGateway/$RoutePrefix/connect/authorize" -Method Post -Body $formBody -ContentType 'application/x-www-form-urlencoded' -WebSession $session -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    if ($null -eq $postResp -or [int]$postResp.StatusCode -notin @(302, 303)) {
        throw "POST /$RoutePrefix/connect/authorize failed."
    }

    $locationHeader = [string]$postResp.Headers['Location']
    $locationUri = if ($locationHeader.StartsWith('http', [StringComparison]::OrdinalIgnoreCase)) {
        [Uri]$locationHeader
    } else {
        [Uri]::new([Uri]$baseGateway, $locationHeader)
    }
    $parsedQuery = [System.Web.HttpUtility]::ParseQueryString($locationUri.Query)
    return [string]$parsedQuery['code']
}

function Invoke-PkceTokenExchange {
    param(
        [Parameter(Mandatory)][string]$RoutePrefix,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$ClientSecret = '',
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password
    )

    $pkce = New-PkcePair
    $code = Get-AuthorizationCodePkce -RoutePrefix $RoutePrefix -ClientId $ClientId -RedirectUri $RedirectUri -Scope $Scope -CodeChallenge $pkce.Challenge -Email $Email -Password $Password
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
    $resp = Invoke-RestMethod -Uri "$baseGateway/$RoutePrefix/connect/token" -Method Post -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
    return [string]$resp.access_token
}

function Get-JwtPayloadHashtable {
    param([Parameter(Mandatory)][string]$Jwt)
    $parts = $Jwt.Split('.')
    $json = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url -Value $parts[1]))
    return $json | ConvertFrom-Json -AsHashtable
}

# Provision / resolve Customer A, Customer B, and Admin tokens if not pre-supplied
if ([string]::IsNullOrWhiteSpace($CustomerABearerToken)) {
    $emailA = "release.custa.$([Guid]::NewGuid().ToString('N').Substring(0, 8))@davids.example"
    $passA = "ReleaseCustA!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Zz9"
    Invoke-RestMethod -Uri "$baseGateway/identity/sign-up" -Method Post -ContentType 'application/json' -Body (@{
        email = $emailA; password = $passA; role = 'user'
    } | ConvertTo-Json) | Out-Null
    $CustomerABearerToken = Invoke-PkceTokenExchange -RoutePrefix 'identity' -ClientId 'davids-web' -RedirectUri $CustomerRedirectUri -Scope 'openid email profile roles offline_access davids-services' -Email $emailA -Password $passA
}
if ([string]::IsNullOrWhiteSpace($CustomerAId)) {
    $CustomerAId = [string](Get-JwtPayloadHashtable -Jwt $CustomerABearerToken)['sub']
}

if ([string]::IsNullOrWhiteSpace($CustomerBBearerToken)) {
    $emailB = "release.custb.$([Guid]::NewGuid().ToString('N').Substring(0, 8))@davids.example"
    $passB = "ReleaseCustB!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Zz9"
    Invoke-RestMethod -Uri "$baseGateway/identity/sign-up" -Method Post -ContentType 'application/json' -Body (@{
        email = $emailB; password = $passB; role = 'user'
    } | ConvertTo-Json) | Out-Null
    $CustomerBBearerToken = Invoke-PkceTokenExchange -RoutePrefix 'identity' -ClientId 'davids-web' -RedirectUri $CustomerRedirectUri -Scope 'openid email profile roles offline_access davids-services' -Email $emailB -Password $passB
}
if ([string]::IsNullOrWhiteSpace($CustomerBId)) {
    $CustomerBId = [string](Get-JwtPayloadHashtable -Jwt $CustomerBBearerToken)['sub']
}

if ([string]::IsNullOrWhiteSpace($AdminBearerToken)) {
    if ([string]::IsNullOrWhiteSpace($AdminEmail) -or [string]::IsNullOrWhiteSpace($AdminPassword) -or [string]::IsNullOrWhiteSpace($AdminBffClientSecret)) {
        throw 'Provide -AdminBearerToken (or DAVIDS_RELEASE_ADMIN_TOKEN), or supply -AdminEmail, -AdminPassword, and -AdminBffClientSecret.'
    }
    $AdminBearerToken = Invoke-PkceTokenExchange -RoutePrefix 'admin-identity' -ClientId $AdminBffClientId -ClientSecret $AdminBffClientSecret -RedirectUri $AdminRedirectUri -Scope 'openid email profile roles offline_access davids-admin' -Email $AdminEmail -Password $AdminPassword
}

# Create disposable customer account for PKCE downgrade, code-replay, and RFC 7009 token revocation probes
$disposableEmail = "release.probe.$([Guid]::NewGuid().ToString('N').Substring(0, 8))@davids.example"
$disposablePassword = "ReleaseProbe!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Zz9"
Invoke-RestMethod -Uri "$baseGateway/identity/sign-up" -Method Post -ContentType 'application/json' -Body (@{
    email = $disposableEmail; password = $disposablePassword; role = 'user'
} | ConvertTo-Json) | Out-Null

$runtimeTestPassword = "ReleaseRuntime!" + [Guid]::NewGuid().ToString('N').Substring(0, 10) + "#Aa9"
$results = [System.Collections.Generic.List[object]]::new()
$sarifResults = @()

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][int]$ActualStatus,
        [Parameter(Mandatory)][int[]]$ExpectedStatuses,
        [string]$Detail = ''
    )

    $entry = [ordered]@{
        id               = $Id
        category         = $Category
        description      = $Description
        passed           = $Passed
        actualStatus     = $ActualStatus
        expectedStatuses = $ExpectedStatuses
        detail           = $Detail
    }
    $results.Add($entry) | Out-Null

    if (-not $Passed) {
        $script:sarifResults += [ordered]@{
            ruleId  = $Id
            level   = 'error'
            message = @{
                text = "[$Category] $Description — expected HTTP [$($ExpectedStatuses -join ', ')], got HTTP $ActualStatus. $Detail"
            }
        }
    }
}

Write-Host "=== Quarterly / Release (Part 1/2): Executing $($matrix.cases.Count) Cross-Role Authorization Matrix Cases (Automated Autorize) ==="
foreach ($case in $matrix.cases) {
    $resolvedPath = ([string]$case.path).
        Replace('{{custAId}}', $CustomerAId).
        Replace('{{custBId}}', $CustomerBId)

    $headers = @{}
    switch ([string]$case.actor) {
        'customerA' { $headers['Authorization'] = "Bearer $($CustomerABearerToken.Trim())" }
        'customerB' { $headers['Authorization'] = "Bearer $($CustomerBBearerToken.Trim())" }
        'admin'     { $headers['Authorization'] = "Bearer $($AdminBearerToken.Trim())" }
    }

    $invokeParams = @{
        Uri                = "$baseGateway$resolvedPath"
        Method             = [string]$case.method
        Headers            = $headers
        MaximumRedirection = 0
        SkipHttpErrorCheck = $true
        ErrorAction        = 'SilentlyContinue'
    }

    if ($case.PSObject.Properties['jsonBody'] -and $null -ne $case.jsonBody) {
        $rawBody = ($case.jsonBody | ConvertTo-Json -Depth 10).
            Replace('{{custAId}}', $CustomerAId).
            Replace('{{custBId}}', $CustomerBId).
            Replace('__RUNTIME_TEST_PASSWORD__', $runtimeTestPassword)
        $invokeParams['Body'] = $rawBody
        $invokeParams['ContentType'] = 'application/json'
    } elseif ($case.method -in @('POST', 'PUT')) {
        $invokeParams['Body'] = ''
    }

    $resp = Invoke-WebRequest @invokeParams
    $status = [int]$resp.StatusCode
    $expected = @($case.expectedStatuses | ForEach-Object { [int]$_ })
    $ok = $expected -contains $status

    Add-CheckResult `
        -Id ([string]$case.id) `
        -Category ([string]$case.category) `
        -Description ([string]$case.description) `
        -Passed $ok `
        -ActualStatus $status `
        -ExpectedStatuses $expected `
        -Detail "$($case.method) $resolvedPath as $($case.actor)"
}

Write-Host '=== Quarterly / Release (Part 2/2): Executing 11 Cryptographic JWT Editor & OIDC/PKCE/BFF Boundary Attacks ==='

$adminClaims = Get-JwtPayloadHashtable -Jwt $AdminBearerToken
$custAClaims = Get-JwtPayloadHashtable -Jwt $CustomerABearerToken
$adminDiscovery = Invoke-RestMethod -Uri "$baseGateway/admin-identity/.well-known/openid-configuration" -Method Get
$adminJwksRaw = (Invoke-WebRequest -Uri "$baseGateway/admin-identity/.well-known/jwks" -Method Get -SkipHttpErrorCheck).Content
$adminJwks = $adminJwksRaw | ConvertFrom-Json
$liveAdminKid = [string]$adminJwks.keys[0].kid
$custJwksRaw = (Invoke-WebRequest -Uri "$baseGateway/identity/.well-known/jwks" -Method Get -SkipHttpErrorCheck).Content

$forgedAdminPayloadJson = (@{
    iss   = [string]$adminClaims['iss']
    aud   = $adminClaims['aud']
    sub   = [Guid]::NewGuid().ToString()
    role  = 'admin'
    jti   = [Guid]::NewGuid().ToString('N')
    iat   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    exp   = [DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds()
} | ConvertTo-Json -Compress)
$forgedAdminPayloadB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($forgedAdminPayloadJson))

# CRYPTO-001 & CRYPTO-002: alg="none" signature-stripping attack
$noneHeaderB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes('{"alg":"none","typ":"JWT"}'))
$algNoneJwt = "$noneHeaderB64.$forgedAdminPayloadB64."

$r1 = Invoke-WebRequest -Uri "$baseGateway/customers" -Method Get -Headers @{ Authorization = "Bearer $algNoneJwt" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-001' -Category 'JWT-Alg-None' -Description 'Reject alg="none" unsigned JWT with role=admin on GET /customers' -Passed ([int]$r1.StatusCode -eq 401) -ActualStatus ([int]$r1.StatusCode) -ExpectedStatuses @(401)

$r2 = Invoke-WebRequest -Uri "$baseGateway/admin-identity/users" -Method Get -Headers @{ Authorization = "Bearer $algNoneJwt" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-002' -Category 'JWT-Alg-None' -Description 'Reject alg="none" unsigned JWT with role=admin on GET /admin-identity/users' -Passed ([int]$r2.StatusCode -eq 401) -ActualStatus ([int]$r2.StatusCode) -ExpectedStatuses @(401)

# CRYPTO-003 & CRYPTO-004: RS256 -> HS256 JWKS public-key confusion attack
$hsHeaderJson = (@{ alg = 'HS256'; typ = 'JWT'; kid = $liveAdminKid } | ConvertTo-Json -Compress)
$hsHeaderB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($hsHeaderJson))
$hsSigningInput = [System.Text.Encoding]::ASCII.GetBytes("$hsHeaderB64.$forgedAdminPayloadB64")
$hmacAdmin = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($adminJwksRaw))
$hsSigAdmin = ConvertTo-Base64Url -Bytes ($hmacAdmin.ComputeHash($hsSigningInput))
$hsConfusedAdminJwt = "$hsHeaderB64.$forgedAdminPayloadB64.$hsSigAdmin"

$r3 = Invoke-WebRequest -Uri "$baseGateway/admin-identity/users" -Method Get -Headers @{ Authorization = "Bearer $hsConfusedAdminJwt" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-003' -Category 'JWT-HS256-Key-Confusion' -Description 'Reject RS256->HS256 JWKS key-confusion JWT on GET /admin-identity/users' -Passed ([int]$r3.StatusCode -eq 401) -ActualStatus ([int]$r3.StatusCode) -ExpectedStatuses @(401)

$hmacCust = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($custJwksRaw))
$hsSigCust = ConvertTo-Base64Url -Bytes ($hmacCust.ComputeHash($hsSigningInput))
$hsConfusedCustJwt = "$hsHeaderB64.$forgedAdminPayloadB64.$hsSigCust"
$r4 = Invoke-WebRequest -Uri "$baseGateway/customers" -Method Get -Headers @{ Authorization = "Bearer $hsConfusedCustJwt" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-004' -Category 'JWT-HS256-Key-Confusion' -Description 'Reject RS256->HS256 JWKS key-confusion JWT on GET /customers' -Passed ([int]$r4.StatusCode -eq 401) -ActualStatus ([int]$r4.StatusCode) -ExpectedStatuses @(401)

# CRYPTO-005: Rogue 2048-bit RSA keypair + live kid + injected jku & embedded jwk header
$rogueRsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $rogueParams = $rogueRsa.ExportParameters($false)
    $rogueHeaderJson = (@{
        alg = 'RS256'
        typ = 'JWT'
        kid = $liveAdminKid
        jku = 'https://attacker.davids.invalid/.well-known/jwks.json'
        jwk = @{
            kty = 'RSA'
            use = 'sig'
            alg = 'RS256'
            kid = $liveAdminKid
            n   = ConvertTo-Base64Url -Bytes $rogueParams.Modulus
            e   = ConvertTo-Base64Url -Bytes $rogueParams.Exponent
        }
    } | ConvertTo-Json -Depth 6 -Compress)
    $rogueHeaderB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($rogueHeaderJson))
    $rogueSigningBytes = [System.Text.Encoding]::ASCII.GetBytes("$rogueHeaderB64.$forgedAdminPayloadB64")
    $rogueSig = ConvertTo-Base64Url -Bytes ($rogueRsa.SignData($rogueSigningBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1))
    $rogueRsaJwt = "$rogueHeaderB64.$forgedAdminPayloadB64.$rogueSig"
} finally {
    $rogueRsa.Dispose()
}

$r5 = Invoke-WebRequest -Uri "$baseGateway/admin-identity/users" -Method Get -Headers @{ Authorization = "Bearer $rogueRsaJwt" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-005' -Category 'JWT-Rogue-RSA-JKU-JWK' -Description 'Reject rogue RS256 keypair with matching kid + injected jku/jwk headers' -Passed ([int]$r5.StatusCode -eq 401) -ActualStatus ([int]$r5.StatusCode) -ExpectedStatuses @(401)

# CRYPTO-006: Payload claim mutation (sub=custBId, role=admin) keeping original Customer A RS256 signature
$custAParts = $CustomerABearerToken.Trim().Split('.')
$tamperedClaims = Get-JwtPayloadHashtable -Jwt $CustomerABearerToken
$tamperedClaims['sub'] = $CustomerBId
$tamperedClaims['role'] = 'admin'
$tamperedPayloadB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes(($tamperedClaims | ConvertTo-Json -Compress)))
$tamperedJwt = "$($custAParts[0]).$tamperedPayloadB64.$($custAParts[2])"
$r6 = Invoke-WebRequest -Uri "$baseGateway/customers/$CustomerBId" -Method Get -Headers @{ Authorization = "Bearer $tamperedJwt" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-006' -Category 'JWT-Payload-Tampering' -Description 'Reject Customer A JWT with mutated sub/role claims and original RS256 signature' -Passed ([int]$r6.StatusCode -eq 401) -ActualStatus ([int]$r6.StatusCode) -ExpectedStatuses @(401)

# CRYPTO-007: PKCE missing code_verifier rejected at /identity/connect/token
$pkce7 = New-PkcePair
$code7 = Get-AuthorizationCodePkce -RoutePrefix 'identity' -ClientId 'davids-web' -RedirectUri $CustomerRedirectUri -Scope 'openid email profile roles davids-services' -CodeChallenge $pkce7.Challenge -Email $disposableEmail -Password $disposablePassword
$r7 = Invoke-WebRequest -Uri "$baseGateway/identity/connect/token" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type   = 'authorization_code'
    client_id    = 'davids-web'
    code         = $code7
    redirect_uri = $CustomerRedirectUri
} -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-007' -Category 'OIDC-PKCE-Enforcement' -Description 'Reject authorization_code token exchange missing PKCE code_verifier' -Passed ([int]$r7.StatusCode -eq 400) -ActualStatus ([int]$r7.StatusCode) -ExpectedStatuses @(400)

# CRYPTO-008: PKCE forged/wrong code_verifier rejected at /identity/connect/token
$pkce8 = New-PkcePair
$forgedPkce8 = New-PkcePair
$code8 = Get-AuthorizationCodePkce -RoutePrefix 'identity' -ClientId 'davids-web' -RedirectUri $CustomerRedirectUri -Scope 'openid email profile roles davids-services' -CodeChallenge $pkce8.Challenge -Email $disposableEmail -Password $disposablePassword
$r8 = Invoke-WebRequest -Uri "$baseGateway/identity/connect/token" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type    = 'authorization_code'
    client_id     = 'davids-web'
    code          = $code8
    redirect_uri  = $CustomerRedirectUri
    code_verifier = $forgedPkce8.Verifier
} -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-008' -Category 'OIDC-PKCE-Enforcement' -Description 'Reject authorization_code token exchange with mismatched PKCE code_verifier' -Passed ([int]$r8.StatusCode -eq 400) -ActualStatus ([int]$r8.StatusCode) -ExpectedStatuses @(400)

# CRYPTO-009: OAuth 2.1 single-use authorization_code replay rejected + RFC 6749 s10.5 cascade revocation
$pkce9 = New-PkcePair
$code9 = Get-AuthorizationCodePkce -RoutePrefix 'identity' -ClientId 'davids-web' -RedirectUri $CustomerRedirectUri -Scope 'openid email profile roles davids-services' -CodeChallenge $pkce9.Challenge -Email $disposableEmail -Password $disposablePassword
$firstExchange = Invoke-RestMethod -Uri "$baseGateway/identity/connect/token" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type    = 'authorization_code'
    client_id     = 'davids-web'
    code          = $code9
    redirect_uri  = $CustomerRedirectUri
    code_verifier = $pkce9.Verifier
}
$replayVictimToken = [string]$firstExchange.access_token
$preReplayMe = Invoke-WebRequest -Uri "$baseGateway/identity/me" -Method Get -Headers @{ Authorization = "Bearer $replayVictimToken" } -SkipHttpErrorCheck
if ([int]$preReplayMe.StatusCode -ne 200) {
    throw "Auth-code pre-replay sanity check failed with HTTP $([int]$preReplayMe.StatusCode)."
}
$r9 = Invoke-WebRequest -Uri "$baseGateway/identity/connect/token" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type    = 'authorization_code'
    client_id     = 'davids-web'
    code          = $code9
    redirect_uri  = $CustomerRedirectUri
    code_verifier = $pkce9.Verifier
} -SkipHttpErrorCheck
$postReplayMe = Invoke-WebRequest -Uri "$baseGateway/identity/me" -Method Get -Headers @{ Authorization = "Bearer $replayVictimToken" } -SkipHttpErrorCheck
$replayPassed = (([int]$r9.StatusCode -eq 400) -and ([int]$postReplayMe.StatusCode -eq 401))
Add-CheckResult -Id 'CRYPTO-009' -Category 'OIDC-AuthCode-Replay' -Description 'Reject second redemption of authorization code (400) and cascade-revoke previously issued access_token (401)' -Passed $replayPassed -ActualStatus ([int]$r9.StatusCode) -ExpectedStatuses @(400) -Detail "postReplayAccessTokenStatus=$([int]$postReplayMe.StatusCode)"

# CRYPTO-010: RFC 7009 access_token revocation enforced immediately across Gateway/Identity
$pkce10 = New-PkcePair
$code10 = Get-AuthorizationCodePkce -RoutePrefix 'identity' -ClientId 'davids-web' -RedirectUri $CustomerRedirectUri -Scope 'openid email profile roles davids-services' -CodeChallenge $pkce10.Challenge -Email $disposableEmail -Password $disposablePassword
$exchange10 = Invoke-RestMethod -Uri "$baseGateway/identity/connect/token" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
    grant_type    = 'authorization_code'
    client_id     = 'davids-web'
    code          = $code10
    redirect_uri  = $CustomerRedirectUri
    code_verifier = $pkce10.Verifier
}
$disposableAccessToken = [string]$exchange10.access_token
$preRevoke = Invoke-WebRequest -Uri "$baseGateway/identity/me" -Method Get -Headers @{ Authorization = "Bearer $disposableAccessToken" } -SkipHttpErrorCheck
if ([int]$preRevoke.StatusCode -ne 200) {
    throw "Disposable token pre-revocation sanity check failed with HTTP $([int]$preRevoke.StatusCode)."
}
$revokeResp = Invoke-WebRequest -Uri "$baseGateway/identity/connect/revocation" -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
    client_id       = 'davids-web'
    token           = $disposableAccessToken
    token_type_hint = 'access_token'
} -SkipHttpErrorCheck
if ([int]$revokeResp.StatusCode -ne 200) {
    throw "RFC 7009 revocation endpoint returned HTTP $([int]$revokeResp.StatusCode)."
}
$r10 = Invoke-WebRequest -Uri "$baseGateway/identity/me" -Method Get -Headers @{ Authorization = "Bearer $disposableAccessToken" } -SkipHttpErrorCheck
Add-CheckResult -Id 'CRYPTO-010' -Category 'OIDC-Token-Revocation' -Description 'Reject revoked RS256 access_token immediately after RFC 7009 /connect/revocation' -Passed ([int]$r10.StatusCode -eq 401) -ActualStatus ([int]$r10.StatusCode) -ExpectedStatuses @(401)

# CRYPTO-011: Admin BFF /logout CSRF/auth boundary & open-redirect sanitization on /login
$getLogout = Invoke-WebRequest -Uri "$baseGateway/logout" -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
$postLogoutNoCsrf = Invoke-WebRequest -Uri "$baseGateway/logout" -Method Post -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
$openRedirectLogin = Invoke-WebRequest -Uri "$baseGateway/login?returnUrl=https%3A%2F%2Fevil.davids.invalid%2Fphish" -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
$loginLoc = [string]$openRedirectLogin.Headers['Location']
$openRedirectSafe = (-not $loginLoc.Contains('evil.davids.invalid'))
$bffPassed = ((@(401, 405) -contains [int]$getLogout.StatusCode) -and (@(400, 401) -contains [int]$postLogoutNoCsrf.StatusCode) -and $openRedirectSafe)
Add-CheckResult -Id 'CRYPTO-011' -Category 'Admin-BFF-CSRF-OpenRedirect' -Description 'Block unauthenticated GET/POST /logout (401/405/400) and sanitize external returnUrl open-redirect on /login' -Passed $bffPassed -ActualStatus ([int]$getLogout.StatusCode) -ExpectedStatuses @(401, 405) -Detail "postLogoutStatus=$([int]$postLogoutNoCsrf.StatusCode); loginRedirectLocation=$loginLoc"

$passedCount = @($results | Where-Object { $_.passed }).Count
$failedCount = @($results | Where-Object { -not $_.passed }).Count

$reportDoc = [ordered]@{
    tool          = 'Davids Quarterly / Release AuthzMatrix & JWT/OIDC Cryptographic Verifier'
    gatewayUrl    = $GatewayUrl
    executedAtUtc = [DateTime]::UtcNow.ToString('o')
    totalChecks   = $results.Count
    passedChecks  = $passedCount
    failedChecks  = $failedCount
    passed        = ($failedCount -eq 0)
    oidcMetadata  = @{
        adminIssuer = [string]$adminDiscovery.issuer
        adminKid    = $liveAdminKid
    }
    results       = $results
}
$reportPath = Join-Path $OutputDirectory 'authz-matrix-report.json'
[System.IO.File]::WriteAllText($reportPath, (($reportDoc | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

$sarifDoc = [ordered]@{
    '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
    version   = '2.1.0'
    runs      = @(
        [ordered]@{
            tool    = @{
                driver = @{
                    name           = 'Davids Quarterly / Release AuthzMatrix & JWT Boundary Verifier'
                    informationUri = 'https://owasp.org/www-project-web-security-testing-guide/'
                    rules          = @()
                }
            }
            results = $sarifResults
        }
    )
}
$sarifPath = Join-Path $OutputDirectory 'authz-matrix.sarif'
[System.IO.File]::WriteAllText($sarifPath, (($sarifDoc | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)

Write-Host "Quarterly / Release AuthzMatrix & Cryptographic Boundary Summary: $passedCount / $($results.Count) passed ($failedCount failed)."
if ($failedCount -gt 0) {
    foreach ($f in ($results | Where-Object { -not $_.passed })) {
        Write-Warning "FAILED [$($f.id)] $($f.description): expected [$($f.expectedStatuses -join ', ')], got $($f.actualStatus)"
    }
    throw "Quarterly / Release Cross-Role Authorization & Cryptographic Boundary Gate FAILED ($failedCount failure(s)). Inspect $reportPath."
}

Write-Host "Quarterly / Release Cross-Role Authorization & Cryptographic Boundary Gate PASSED ($passedCount / $($results.Count) checks). Report: $reportPath"
