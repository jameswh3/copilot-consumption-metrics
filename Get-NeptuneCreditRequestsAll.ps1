[CmdletBinding()]
param(
    [string]$BaseUri = 'https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests',

    [string]$Service = 'Cowork',

    [string[]]$States = @('Pending'),

    [bool]$IncludeCount = $true,

    [int]$PageSize = 50,

    [int]$MaxPages = 200,

    [string]$TenantId,

    [string]$AccessToken,

    [string]$RootAuthToken,

    [string]$CookieHeader,

    [switch]$UseGraphAuth,

    [switch]$AllowMsal,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$importDotEnvPath = Join-Path $repoRoot 'Shared\Import-DotEnv.ps1'
$dotEnvPath = Join-Path $repoRoot '.env'

if ((Test-Path -Path $importDotEnvPath) -and (Test-Path -Path $dotEnvPath)) {
    . $importDotEnvPath
    Import-DotEnv -Path $dotEnvPath
}

function ConvertTo-Boolean {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    switch -Regex ($Value.Trim()) {
        '^(1|true|yes|y|on)$' { return $true }
        '^(0|false|no|n|off)$' { return $false }
        default { throw "Unable to convert '$Value' to boolean." }
    }
}

function Split-EnvironmentList {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

if (-not $PSBoundParameters.ContainsKey('BaseUri') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_CREDITREQUESTS_BASE_URI)) {
    $script:BaseUri = $env:NEPTUNE_CREDITREQUESTS_BASE_URI
}

if (-not $PSBoundParameters.ContainsKey('Service') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_CREDITREQUESTS_SERVICE)) {
    $script:Service = $env:NEPTUNE_CREDITREQUESTS_SERVICE
}

if (-not $PSBoundParameters.ContainsKey('States')) {
    $resolvedStates = Split-EnvironmentList -Value $env:NEPTUNE_CREDITREQUESTS_STATES
    if (@($resolvedStates).Count -gt 0) {
        $script:States = $resolvedStates
    }
}

if (-not $PSBoundParameters.ContainsKey('IncludeCount') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_INCLUDE_COUNT)) {
    $script:IncludeCount = [bool](ConvertTo-Boolean -Value $env:NEPTUNE_INCLUDE_COUNT)
}

if (-not $PSBoundParameters.ContainsKey('PageSize')) {
    if (-not [string]::IsNullOrWhiteSpace($env:NEPTUNE_PAGE_SIZE)) {
        $script:PageSize = [int]$env:NEPTUNE_PAGE_SIZE
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:NEPTUNE_SKIP_PAGE_SIZE)) {
        $script:PageSize = [int]$env:NEPTUNE_SKIP_PAGE_SIZE
    }
}

if (-not $PSBoundParameters.ContainsKey('TenantId') -and -not [string]::IsNullOrWhiteSpace($env:TENANT_ID)) {
    $script:TenantId = $env:TENANT_ID
}

if (-not $PSBoundParameters.ContainsKey('AccessToken') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_ACCESS_TOKEN)) {
    $script:AccessToken = $env:NEPTUNE_ACCESS_TOKEN
}

if (-not $PSBoundParameters.ContainsKey('RootAuthToken') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_ROOT_AUTH_TOKEN)) {
    $script:RootAuthToken = $env:NEPTUNE_ROOT_AUTH_TOKEN
}

if (-not $PSBoundParameters.ContainsKey('CookieHeader') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_COOKIE_HEADER)) {
    $script:CookieHeader = $env:NEPTUNE_COOKIE_HEADER
}

if (-not $PSBoundParameters.ContainsKey('UseGraphAuth') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_USE_GRAPH_AUTH)) {
    $script:UseGraphAuth = [bool](ConvertTo-Boolean -Value $env:NEPTUNE_USE_GRAPH_AUTH)
}

if (-not $PSBoundParameters.ContainsKey('AllowMsal') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_ALLOW_MSAL)) {
    $script:AllowMsal = [bool](ConvertTo-Boolean -Value $env:NEPTUNE_ALLOW_MSAL)
}

function New-NeptuneUri {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $pairs = foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($null -eq $value) {
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            foreach ($entry in $value) {
                '{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$entry)
            }
            continue
        }

        '{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$value)
    }

    '{0}?{1}' -f $BaseUri, ($pairs -join '&')
}

function Resolve-AuthHeaders {
    if ($AccessToken) {
        return @{ Authorization = "Bearer $AccessToken" }
    }

    if ($UseGraphAuth) {
        $graphToken = & (Join-Path $PSScriptRoot 'Get-AdminApiAccessToken.ps1') -Resource 'https://graph.microsoft.com' -TenantId $TenantId -AllowMsal:$true -Quiet
        if ($graphToken -and $graphToken.AccessToken) {
            return @{ Authorization = "Bearer $($graphToken.AccessToken)" }
        }

        throw 'Graph auth mode did not yield a token. Run Connect-MgGraph/az login first, or disable UseGraphAuth and use cookie/HAR auth.'
    }

    if ($CookieHeader) {
        return @{ Cookie = $CookieHeader }
    }

    if ($RootAuthToken) {
        return @{ Cookie = "RootAuthToken=$RootAuthToken" }
    }

    throw 'No usable auth material was found. Provide AccessToken, CookieHeader, RootAuthToken, or set UseGraphAuth.'
}

function Invoke-NeptuneRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -MaximumRedirection 0
    $contentType = $response.Headers['Content-Type']
    if ($contentType -notmatch 'json') {
        throw "Expected JSON response but got '$contentType'."
    }

    $json = $response.Content | ConvertFrom-Json -Depth 30
    return [pscustomobject]@{
        Uri        = $Uri
        StatusCode = [int]$response.StatusCode
        Json       = $json
    }
}

if ($PageSize -le 0) {
    throw 'PageSize must be greater than 0.'
}

if ($MaxPages -le 0) {
    throw 'MaxPages must be greater than 0.'
}

$headers = Resolve-AuthHeaders
$allItems = [System.Collections.Generic.List[object]]::new()
$page = 0
$continuationToken = $null
$seenContinuationTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$seenRequestIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

while ($page -lt $MaxPages) {
    $page += 1

    $queryParams = @{
        service      = $Service
        states       = $States
        includeCount = $IncludeCount.ToString().ToLowerInvariant()
        top          = $PageSize
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$continuationToken)) {
        if (-not $seenContinuationTokens.Add([string]$continuationToken)) {
            Write-Warning 'Continuation token repeated; stopping to avoid a loop.'
            break
        }

        $queryParams.continuationToken = [string]$continuationToken
    }

    $uri = New-NeptuneUri -Parameters $queryParams
    $result = Invoke-NeptuneRequest -Uri $uri -Headers $headers

    $items = @()
    if ($result.Json -and ($result.Json.PSObject.Properties.Name -contains 'value')) {
        $items = @($result.Json.value)
    }

    $hasContinuationField = $result.Json -and ($result.Json.PSObject.Properties.Name -contains 'continuationToken')
    $nextContinuationToken = if ($hasContinuationField) { [string]$result.Json.continuationToken } else { $null }

    $itemCount = @($items).Count
    Write-Host ("Page {0} | mode=continuationToken | items={1} | hasNextToken={2}" -f $page, $itemCount, (-not [string]::IsNullOrWhiteSpace($nextContinuationToken)))

    if ($itemCount -eq 0) {
        break
    }

    foreach ($item in $items) {
        $requestId = if ($item.PSObject.Properties.Name -contains 'requestId') { [string]$item.requestId } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($requestId)) {
            if (-not $seenRequestIds.Add($requestId)) {
                continue
            }
        }

        $allItems.Add($item)
    }

    if ([string]::IsNullOrWhiteSpace($nextContinuationToken)) {
        break
    }

    $continuationToken = $nextContinuationToken
}

Write-Host ("Total items collected: {0}" -f $allItems.Count)

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $allItems | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath
    Write-Host ("Saved results to: {0}" -f $OutputPath)
}

$allItems