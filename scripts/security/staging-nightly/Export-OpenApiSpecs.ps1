[CmdletBinding()]
param(
    [string]$GatewayUrl = 'http://localhost:17320',
    [string]$IdentityDirectUrl = 'http://localhost:5004',
    [string]$AdminIdentityDirectUrl = 'http://localhost:17325',
    [string]$CustomersDirectUrl = 'http://localhost:5002',
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$openApiDir = Join-Path $repoRoot 'security/staging-nightly/openapi'
$restlerSpecDir = Join-Path $repoRoot 'security/quarterly-release/restler/specs'
foreach ($dir in @($openApiDir, $restlerSpecDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function ConvertTo-OpenApi30Node {
    param([Parameter(ValueFromPipeline)]$Node)

    if ($null -eq $Node) {
        return $null
    }

    if ($Node -is [System.Collections.IDictionary]) {
        $mapped = [ordered]@{}
        $nullableAdded = $false
        foreach ($key in $Node.Keys) {
            if ($key -eq 'jsonSchemaDialect') {
                continue
            }

            $val = $Node[$key]
            if ($key -eq 'type' -and $val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
                $types = @($val | ForEach-Object { [string]$_ })
                $nonNull = @($types | Where-Object { $_ -ne 'null' })
                if ($types -contains 'null') {
                    $nullableAdded = $true
                }
                $mapped['type'] = if ($nonNull.Count -gt 0) { $nonNull[0] } else { 'string' }
                continue
            }

            $mapped[$key] = ConvertTo-OpenApi30Node -Node $val
        }

        if ($nullableAdded) {
            $mapped['nullable'] = $true
        }
        return $mapped
    }

    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        $items = @()
        foreach ($item in $Node) {
            $items += ,(ConvertTo-OpenApi30Node -Node $item)
        }
        return ,$items
    }

    return $Node
}

function Assert-NoArrayTypeNodes {
    param(
        [AllowNull()]$Node,
        [Parameter(Mandatory)][string]$FilePath
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $val = $Node[$key]
            if ($key -eq 'type' -and $val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
                throw "RESTler OpenAPI 3.0.3 contract '$FilePath' still contains an OpenAPI 3.1 array 'type' declaration."
            }
            Assert-NoArrayTypeNodes -Node $val -FilePath $FilePath
        }
        return
    }

    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        foreach ($item in $Node) {
            Assert-NoArrayTypeNodes -Node $item -FilePath $FilePath
        }
    }
}

$targets = @(
    @{
        Name            = 'identity'
        DirectUrl       = $IdentityDirectUrl.TrimEnd('/')
        Prefix          = '/identity'
        OutputFile      = Join-Path $openApiDir 'identity.gateway.openapi.json'
        RestlerSpecFile = Join-Path $restlerSpecDir 'identity.restler.openapi.json'
        StripPaths      = @()
    },
    @{
        Name            = 'admin-identity'
        DirectUrl       = $AdminIdentityDirectUrl.TrimEnd('/')
        Prefix          = '/admin-identity'
        OutputFile      = Join-Path $openApiDir 'admin-identity.gateway.openapi.json'
        RestlerSpecFile = Join-Path $restlerSpecDir 'admin-identity.restler.openapi.json'
        StripPaths      = @('/sign-up')
    },
    @{
        Name            = 'customers'
        DirectUrl       = $CustomersDirectUrl.TrimEnd('/')
        Prefix          = '/customers'
        OutputFile      = Join-Path $openApiDir 'customers.gateway.openapi.json'
        RestlerSpecFile = Join-Path $restlerSpecDir 'customers.restler.openapi.json'
        StripPaths      = @()
    }
)

if ($VerifyOnly) {
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target.OutputFile)) {
            throw "Missing gateway OpenAPI contract: $($target.OutputFile)"
        }

        $doc = Get-Content -LiteralPath $target.OutputFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not ($doc.ContainsKey('openapi')) -or -not ($doc['openapi'].ToString().StartsWith('3.1.'))) {
            throw "Expected OpenAPI 3.1.x specification in $($target.OutputFile), found '$($doc['openapi'])'."
        }

        if (-not $doc.ContainsKey('components') -or
            -not $doc['components'].ContainsKey('securitySchemes') -or
            -not $doc['components']['securitySchemes'].ContainsKey('BearerAuth')) {
            throw "Expected RS256 'BearerAuth' securityScheme in $($target.OutputFile)."
        }

        $paths = $doc['paths']
        if ($null -eq $paths -or $paths.Count -eq 0) {
            throw "OpenAPI contract $($target.OutputFile) contains zero operations."
        }

        foreach ($pathKey in $paths.Keys) {
            if (-not ($pathKey -eq $target.Prefix -or $pathKey.StartsWith("$($target.Prefix)/"))) {
                throw "Path '$pathKey' in $($target.OutputFile) does not match expected gateway prefix '$($target.Prefix)'."
            }
            if ($target.Name -eq 'admin-identity' -and $pathKey -eq '/admin-identity/sign-up') {
                throw "Forbidden public admin sign-up path '/admin-identity/sign-up' present in $($target.OutputFile)."
            }
        }

        Write-Host "Verified gateway OpenAPI 3.1 contract: $($target.OutputFile) ($($paths.Count) paths)"

        if (-not (Test-Path -LiteralPath $target.RestlerSpecFile)) {
            throw "Missing RESTler OpenAPI 3.0.3 contract: $($target.RestlerSpecFile)"
        }

        $restlerDoc = Get-Content -LiteralPath $target.RestlerSpecFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not ($restlerDoc.ContainsKey('openapi')) -or $restlerDoc['openapi'].ToString() -ne '3.0.3') {
            throw "Expected OpenAPI 3.0.3 specification in $($target.RestlerSpecFile), found '$($restlerDoc['openapi'])'."
        }

        Assert-NoArrayTypeNodes -Node $restlerDoc -FilePath $target.RestlerSpecFile

        $restlerPaths = $restlerDoc['paths']
        if ($null -eq $restlerPaths -or $restlerPaths.Count -ne $paths.Count) {
            throw "RESTler OpenAPI 3.0.3 path count ($($restlerPaths.Count)) does not match OpenAPI 3.1 path count ($($paths.Count)) for '$($target.Name)'."
        }

        Write-Host "Verified RESTler OpenAPI 3.0.3 contract: $($target.RestlerSpecFile) ($($restlerPaths.Count) paths)"
    }
    return
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$normalizedGateway = $GatewayUrl.TrimEnd('/')

foreach ($target in $targets) {
    $sourceUri = "$($target.DirectUrl)/openapi/v1.json"
    Write-Host "Fetching live OpenAPI document from $sourceUri ..."
    $rawJson = Invoke-RestMethod -Uri $sourceUri -Method Get -Headers @{ Accept = 'application/json' } | ConvertTo-Json -Depth 100
    $doc = $rawJson | ConvertFrom-Json -AsHashtable

    $rewrittenPaths = [ordered]@{}
    foreach ($entry in $doc['paths'].GetEnumerator()) {
        $rawPath = [string]$entry.Key
        if ($target.StripPaths -contains $rawPath) {
            continue
        }

        $mappedPath = if ($rawPath -eq '/') {
            $target.Prefix
        } else {
            "$($target.Prefix)$rawPath"
        }
        $rewrittenPaths[$mappedPath] = $entry.Value
    }

    $doc['paths'] = $rewrittenPaths
    $doc['servers'] = @(
        @{
            url         = $normalizedGateway
            description = 'Davids YARP API Gateway'
        }
    )

    $serialized = $doc | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($target.OutputFile, "$serialized`n", $utf8NoBom)
    Write-Host "Exported $($target.OutputFile) ($($rewrittenPaths.Count) gateway paths)"

    $restlerDoc = ConvertTo-OpenApi30Node -Node $doc
    $restlerDoc['openapi'] = '3.0.3'
    $serializedRestler = $restlerDoc | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($target.RestlerSpecFile, "$serializedRestler`n", $utf8NoBom)
    Write-Host "Exported $($target.RestlerSpecFile) (OpenAPI 3.0.3 for Microsoft RESTler)"
}
