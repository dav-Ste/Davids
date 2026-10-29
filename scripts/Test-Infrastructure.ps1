# Run after Aspire (or Kubernetes/Istio port-forward) is healthy.
# Verifies Self-Hosted .NET OIDC discovery/JWKS, Customer Authorization Code + PKCE (S256),
# RabbitMQ outbox provisioning into customersdb, and Gateway Admin OIDC BFF SSO + CSRF enforcement.
param(
    [Parameter(Mandatory)][uri]$GatewayUrl,
    [string]$AdminEmail,
    [string]$AdminPassword
)

$ErrorActionPreference = 'Stop'
$gwRoot = $GatewayUrl.AbsoluteUri.TrimEnd('/')
$identity = "$gwRoot/identity"
$adminIdentity = "$gwRoot/admin-identity"
$customers = "$gwRoot/customers"

function New-CryptoBytes([int]$Length) {
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ,$bytes
}

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=') -replace '\+', '-' -replace '/', '_'
}

function New-PkcePair {
    $verifier = ConvertTo-Base64Url (New-CryptoBytes 32)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    } finally {
        $sha.Dispose()
    }
    return @{
        Verifier  = $verifier
        Challenge = (ConvertTo-Base64Url $hash)
    }
}

function Get-HiddenInputValue([string]$Html, [string]$FieldName) {
    $escaped = [regex]::Escape($FieldName)
    $m = [regex]::Match($Html, "name=`"$escaped`"\s+value=`"([^`"]*)`"", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) {
        throw "Hidden input '$FieldName' not found in OIDC authorization form."
    }
    return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}

function Invoke-HttpRaw {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$ContentType,
        [string]$Body,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [switch]$NoRedirect
    )
    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $Headers
        TimeoutSec      = 15
        UseBasicParsing = $true
    }
    if ($ContentType) { $params.ContentType = $ContentType }
    if ($null -ne $Body) { $params.Body = $Body }
    if ($WebSession) { $params.WebSession = $WebSession }
    if ($NoRedirect) { $params.MaximumRedirection = 0 }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck')) {
        $params.SkipHttpErrorCheck = $true
    }
    try {
        $resp = Invoke-WebRequest @params
        $loc = $resp.Headers['Location']
        if ($loc -is [array]) { $loc = $loc[0] }
        return @{ StatusCode = [int]$resp.StatusCode; Content = [string]$resp.Content; Location = [string]$loc }
    } catch {
        $httpResp = $_.Exception.Response
        if ($null -eq $httpResp) { throw }
        $loc = $httpResp.Headers['Location']
        return @{ StatusCode = [int]$httpResp.StatusCode; Content = ''; Location = [string]$loc }
    }
}

function ConvertTo-FormBody([hashtable]$Fields) {
    return (($Fields.GetEnumerator() | ForEach-Object {
        "$([uri]::EscapeDataString([string]$_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
    }) -join '&')
}

function Parse-QueryDictionary([uri]$TargetUri) {
    $result = @{}
    $q = $TargetUri.Query.TrimStart('?')
    foreach ($pair in ($q -split '&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        $k = [uri]::UnescapeDataString($parts[0])
        $v = if ($parts.Length -gt 1) { [uri]::UnescapeDataString($parts[1]) } else { '' }
        $result[$k] = $v
    }
    return $result
}

# 1. Gateway health and OIDC discovery / JWKS isolation checks
$gwHealth = Invoke-HttpRaw -Uri "$gwRoot/health"
if ($gwHealth.StatusCode -ne 200) { throw 'API Gateway /health check failed.' }
$gwInfo = Invoke-RestMethod "$gwRoot/gateway-info" -TimeoutSec 10
if (-not $gwInfo.service) { throw 'API Gateway /gateway-info returned unexpected payload.' }

$custDiscovery = Invoke-RestMethod "$identity/.well-known/openid-configuration" -TimeoutSec 10
$adminDiscovery = Invoke-RestMethod "$adminIdentity/.well-known/openid-configuration" -TimeoutSec 10
if ($custDiscovery.issuer -eq $adminDiscovery.issuer) { throw 'Customer and Admin OIDC authorities must not share an issuer.' }
if ($custDiscovery.code_challenge_methods_supported -notcontains 'S256') { throw 'Customer OIDC discovery missing PKCE S256.' }
if ($adminDiscovery.code_challenge_methods_supported -notcontains 'S256') { throw 'Admin OIDC discovery missing PKCE S256.' }

$custJwks = Invoke-RestMethod "$identity/.well-known/jwks" -TimeoutSec 10
$adminJwks = Invoke-RestMethod "$adminIdentity/.well-known/jwks" -TimeoutSec 10
if ($custJwks.keys[0].kid -eq $adminJwks.keys[0].kid) { throw 'Customer and Admin JWKS signing keys must be cryptographically distinct.' }

# 2. Customer registration + OAuth 2.1 Authorization Code + PKCE (S256)
$userId = [Guid]::NewGuid()
$email = 'smoke-' + [Guid]::NewGuid().ToString('N') + '@example.com'
$password = 'Cust-' + [Convert]::ToBase64String((New-CryptoBytes 24)) + '!'
$signUpBody = @{ userId = $userId; email = $email; password = $password } | ConvertTo-Json
$created = Invoke-HttpRaw -Uri "$identity/sign-up" -Method 'POST' -ContentType 'application/json' -Body $signUpBody
if ($created.StatusCode -ne 201) { throw "Customer registration failed with HTTP $($created.StatusCode)." }

$pkce = New-PkcePair
$state = ConvertTo-Base64Url (New-CryptoBytes 16)
$redirectUri = 'http://localhost/callback'
$scope = 'openid email profile roles offline_access davids-services'
$authorizeQuery = ConvertTo-FormBody @{
    client_id             = 'davids-web'
    redirect_uri          = $redirectUri
    response_type         = 'code'
    scope                 = $scope
    code_challenge        = $pkce.Challenge
    code_challenge_method = 'S256'
    state                 = $state
}
$authPage = Invoke-HttpRaw -Uri "$identity/connect/authorize?$authorizeQuery"
if ($authPage.StatusCode -ne 200) { throw 'Customer OIDC /connect/authorize GET failed.' }
$requestToken = Get-HiddenInputValue -Html $authPage.Content -FieldName 'request_token'

$authPost = Invoke-HttpRaw -Uri "$identity/connect/authorize" -Method 'POST' -NoRedirect `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body (ConvertTo-FormBody @{
        client_id             = 'davids-web'
        redirect_uri          = $redirectUri
        response_type         = 'code'
        scope                 = $scope
        code_challenge        = $pkce.Challenge
        code_challenge_method = 'S256'
        state                 = $state
        request_token         = $requestToken
        email                 = $email
        password              = $password
    })
if ($authPost.StatusCode -ne 302) { throw "Customer OIDC /connect/authorize POST failed with HTTP $($authPost.StatusCode)." }
$cbParams = Parse-QueryDictionary ([uri]$authPost.Location)
if ($cbParams['state'] -ne $state -or [string]::IsNullOrWhiteSpace($cbParams['code'])) {
    throw 'Customer OIDC callback missing valid state or authorization code.'
}

$tokens = Invoke-RestMethod "$identity/connect/token" -Method Post `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body (ConvertTo-FormBody @{
        grant_type    = 'authorization_code'
        client_id     = 'davids-web'
        code          = $cbParams['code']
        redirect_uri  = $redirectUri
        code_verifier = $pkce.Verifier
    }) -TimeoutSec 15

$auth = @{ Authorization = 'Bearer ' + $tokens.access_token }
$me = Invoke-RestMethod "$identity/me" -Headers $auth -TimeoutSec 15
if ($me.email -ne $email) { throw 'Authenticated customer /me mismatch.' }
$userInfo = Invoke-RestMethod "$identity/connect/userinfo" -Headers $auth -TimeoutSec 15
if ($userInfo.email -ne $email) { throw 'Authenticated customer /connect/userinfo mismatch.' }

# 3. Zero-trust boundary checks through YARP Gateway
$anonFrontend = Invoke-HttpRaw -Uri "$gwRoot/" -Headers @{ Accept = 'text/html' } -NoRedirect
if ($anonFrontend.StatusCode -ne 302) { throw 'Gateway did not redirect unauthenticated browser request from / to /login.' }
$customerFrontend = Invoke-HttpRaw -Uri "$gwRoot/" -Headers @{ Authorization = 'Bearer ' + $tokens.access_token; Accept = 'text/html' } -NoRedirect
if ($customerFrontend.StatusCode -ne 403) { throw 'Gateway allowed a non-admin customer token to access Davids.Frontend.Admin.' }

$anonCustomers = Invoke-HttpRaw -Uri "$customers/$userId"
if ($anonCustomers.StatusCode -ne 401) { throw 'Gateway accepted an anonymous protected Customers request.' }
$nonAdminList = Invoke-HttpRaw -Uri $customers -Headers $auth
if ($nonAdminList.StatusCode -ne 403) { throw 'Gateway accepted a non-admin Customers directory request.' }
$nonAdminEdit = Invoke-HttpRaw -Uri "$customers/$userId" -Method 'PUT' -Headers $auth -ContentType 'application/json' `
    -Body (@{ customerId = $userId; fullName = 'Blocked'; address = 'Blocked' } | ConvertTo-Json)
if ($nonAdminEdit.StatusCode -ne 403) { throw 'Gateway accepted a non-admin Customer edit request.' }
$otherCustomer = Invoke-HttpRaw -Uri "$customers/$([Guid]::NewGuid())" -Headers $auth
if ($otherCustomer.StatusCode -ne 403) { throw 'Gateway accepted a cross-user Customers lookup.' }

# 4. Async RabbitMQ signed_up customer provisioning & profile completion
$customerReady = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $customerResponse = Invoke-HttpRaw -Uri "$customers/$userId" -Headers $auth
    if ($customerResponse.StatusCode -eq 200) { $customerReady = $true; break }
    if ($customerResponse.StatusCode -ne 404) {
        throw "Customers returned HTTP $($customerResponse.StatusCode) while waiting for sign-up provisioning."
    }
    Start-Sleep -Seconds 2
}
if (-not $customerReady) { throw 'Customer was not provisioned from identity signed_up event within 60 seconds.' }

$profileBody = @{ customerId = $userId; fullName = 'Infrastructure Smoke Test'; address = 'Local Development' } | ConvertTo-Json
$profileCreated = Invoke-HttpRaw -Uri $customers -Method 'POST' -Headers $auth -ContentType 'application/json' -Body $profileBody
if ($profileCreated.StatusCode -ne 201) { throw 'Customer profile completion failed.' }
$profile = Invoke-RestMethod "$customers/$userId" -Headers $auth -TimeoutSec 15
if ($profile.state -ne 'valid' -or $profile.fullName -ne 'Infrastructure Smoke Test') { throw 'Customer profile response mismatch.' }

# 5. Admin OIDC BFF SSO flow (Authorization Code + PKCE + HttpOnly session cookie + CSRF protection)
if ($AdminEmail -and $AdminPassword) {
    $bffSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $loginChallenge = Invoke-HttpRaw -Uri "$gwRoot/auth/login?returnUrl=%2F" -WebSession $bffSession -NoRedirect
    if ($loginChallenge.StatusCode -ne 302) { throw 'Gateway /auth/login did not initiate OIDC challenge.' }

    $authorizeTarget = if ($loginChallenge.Location.StartsWith('http')) { $loginChallenge.Location } else { "$gwRoot$($loginChallenge.Location)" }
    $adminFormPage = Invoke-HttpRaw -Uri $authorizeTarget -WebSession $bffSession
    if ($adminFormPage.StatusCode -ne 200) { throw 'Admin OIDC /connect/authorize form failed to render.' }

    $oidcParams = Parse-QueryDictionary ([uri]$authorizeTarget)
    $oidcParams['request_token'] = Get-HiddenInputValue -Html $adminFormPage.Content -FieldName 'request_token'
    $oidcParams['email'] = $AdminEmail
    $oidcParams['password'] = $AdminPassword

    $adminAuthorizeSubmit = Invoke-HttpRaw -Uri "$adminIdentity/connect/authorize" -Method 'POST' -WebSession $bffSession -NoRedirect `
        -ContentType 'application/x-www-form-urlencoded' -Body (ConvertTo-FormBody $oidcParams)
    if ($adminAuthorizeSubmit.StatusCode -ne 302) { throw 'Admin OIDC credential submission failed.' }

    $signinOidcUrl = if ($adminAuthorizeSubmit.Location.StartsWith('http')) { $adminAuthorizeSubmit.Location } else { "$gwRoot$($adminAuthorizeSubmit.Location)" }
    $signinCallback = Invoke-HttpRaw -Uri $signinOidcUrl -WebSession $bffSession -NoRedirect
    if ($signinCallback.StatusCode -ne 302) { throw "Gateway /signin-oidc callback failed with HTTP $($signinCallback.StatusCode)." }

    $adminWorkspace = Invoke-HttpRaw -Uri "$gwRoot/" -WebSession $bffSession
    if ($adminWorkspace.StatusCode -ne 200) { throw 'Gateway did not serve Davids.Frontend.Admin for authenticated Admin OIDC BFF session.' }

    $sessionDto = Invoke-RestMethod "$gwRoot/auth/session" -WebSession $bffSession -TimeoutSec 10
    if (-not $sessionDto.authenticated -or $sessionDto.role -ne 'admin') { throw 'Gateway /auth/session did not report authenticated admin.' }

    $searchHits = @(Invoke-RestMethod "$customers?search=$([uri]::EscapeDataString($email))&state=valid" -WebSession $bffSession -TimeoutSec 15)
    if (-not ($searchHits | Where-Object { $_.id -eq $userId })) { throw 'Admin BFF customer search did not return smoke-test customer.' }

    $editBody = @{ customerId = $userId; fullName = 'Infrastructure Smoke Test Edited'; email = $email; address = 'Edited Development Address'; state = 'valid' } | ConvertTo-Json
    $csrfBlocked = Invoke-HttpRaw -Uri "$customers/$userId" -Method 'PUT' -WebSession $bffSession -ContentType 'application/json' -Body $editBody
    if ($csrfBlocked.StatusCode -ne 403) { throw 'Gateway BFF accepted state-changing PUT without X-Requested-With CSRF header.' }

    $edited = Invoke-RestMethod "$customers/$userId" -Method Put -WebSession $bffSession `
        -Headers @{ 'X-Requested-With' = 'DavidsAdmin' } -ContentType 'application/json' -Body $editBody -TimeoutSec 15
    if ($edited.fullName -ne 'Infrastructure Smoke Test Edited' -or $edited.address -ne 'Edited Development Address') {
        throw 'Admin BFF customer edit response mismatch.'
    }

    $logout = Invoke-HttpRaw -Uri "$gwRoot/auth/logout" -Method 'POST' -WebSession $bffSession -Headers @{ 'X-Requested-With' = 'DavidsAdmin' }
    if ($logout.StatusCode -ne 200) { throw 'Gateway BFF /auth/logout failed.' }
}

Write-Host 'Self-Hosted .NET OIDC + Gateway BFF infrastructure smoke test succeeded.'
