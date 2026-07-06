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

    [string]$ExtraHeadersJson,

    [string]$HarPath,

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

if (-not $PSBoundParameters.ContainsKey('ExtraHeadersJson') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_EXTRA_HEADERS_JSON)) {
    $script:ExtraHeadersJson = $env:NEPTUNE_EXTRA_HEADERS_JSON
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

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText,

        [int]$Depth = 20
    )

    $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertFromJson.Parameters.ContainsKey('Depth')) {
        return $JsonText | ConvertFrom-Json -Depth $Depth
    }

    return $JsonText | ConvertFrom-Json
}

function Get-HarAuthMaterial {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "HAR file not found: $Path"
    }

    $harJsonRaw = Get-Content -Path $Path -Raw
    $har = ConvertFrom-JsonCompat -JsonText $harJsonRaw -Depth 100
    $entries = @($har.log.entries)
    if ($entries.Count -eq 0) {
        throw 'The HAR has no entries.'
    }

    $matchingEntries = $entries | Where-Object {
        $_.request.url -match 'admin\.cloud\.microsoft/admin/api/neptunelicensing/creditrequests'
    }

    if (@($matchingEntries).Count -eq 0) {
        throw 'No neptunelicensing/creditrequests request was found in the HAR.'
    }

    $entry = $matchingEntries | Select-Object -Last 1
    $headers = @($entry.request.headers)

    $cookieHeader = $null
    $authToken = $null
    $extraHeaders = @{}

    foreach ($header in $headers) {
        $name = if ($header -and ($header.PSObject.Properties.Name -contains 'name')) { [string]$header.name } else { $null }
        $value = if ($header -and ($header.PSObject.Properties.Name -contains 'value')) { [string]$header.value } else { $null }

        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($name -ieq 'Cookie') {
            $cookieHeader = $value
            continue
        }

        if ($name -ieq 'Authorization') {
            $authMatch = [regex]::Match($value, '^Bearer\s+(.+)$')
            if ($authMatch.Success) {
                $authToken = $authMatch.Groups[1].Value
            }
            continue
        }

        if ($name.StartsWith(':')) {
            continue
        }

        $extraHeaders[$name] = $value
    }

    return [pscustomobject]@{
        CookieHeader      = $cookieHeader
        AccessToken       = $authToken
        ExtraHeadersJson  = if ($extraHeaders.Count -gt 0) { $extraHeaders | ConvertTo-Json -Compress -Depth 20 } else { '{}' }
        RequestUrl        = [string]$entry.request.url
        ExtraHeaderCount  = $extraHeaders.Count
    }
}

if (-not [string]::IsNullOrWhiteSpace($HarPath)) {
    $harAuth = Get-HarAuthMaterial -Path $HarPath

    if (-not $PSBoundParameters.ContainsKey('AccessToken') -and [string]::IsNullOrWhiteSpace($script:AccessToken) -and -not [string]::IsNullOrWhiteSpace($harAuth.AccessToken)) {
        $script:AccessToken = $harAuth.AccessToken
    }

    if (-not $PSBoundParameters.ContainsKey('CookieHeader') -and [string]::IsNullOrWhiteSpace($script:CookieHeader) -and -not [string]::IsNullOrWhiteSpace($harAuth.CookieHeader)) {
        $script:CookieHeader = $harAuth.CookieHeader
    }

    if (-not $PSBoundParameters.ContainsKey('ExtraHeadersJson') -and [string]::IsNullOrWhiteSpace($script:ExtraHeadersJson) -and -not [string]::IsNullOrWhiteSpace($harAuth.ExtraHeadersJson)) {
        $script:ExtraHeadersJson = $harAuth.ExtraHeadersJson
    }

    Write-Host ("Loaded auth/header material from HAR in-memory only | requestUrl={0} | extraHeaders={1}" -f $harAuth.RequestUrl, $harAuth.ExtraHeaderCount)
}

function Get-ExtraHeadersHashtable {
    param(
        [string]$JsonText
    )

    $headers = @{}
    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return $headers
    }

    $trimmed = $JsonText.Trim()

    # Values loaded from .env may be wrapped in quotes and contain escaped JSON.
    if ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"') -and $trimmed.Length -ge 2) {
        try {
            $trimmed = ConvertFrom-JsonCompat -JsonText $trimmed -Depth 5
        }
        catch {
            try {
                # Fallback for .env-style escaping where quotes were unwrapped but backslashes remain.
                $unescaped = $trimmed -replace '\\"', '"'
                $trimmed = ConvertFrom-JsonCompat -JsonText $unescaped -Depth 5
            }
            catch {
                # Keep original text and let the main parse path produce a warning.
            }
        }
    }
    elseif ($trimmed -match '^\{\\"') {
        try {
            $trimmed = $trimmed -replace '\\"', '"'
        }
        catch {
            # Continue with original value if unescape fails.
        }
    }

    if ($trimmed -eq '{}' -or $trimmed -eq '') {
        return $headers
    }

    try {
        $obj = ConvertFrom-JsonCompat -JsonText $trimmed -Depth 20
        if ($obj) {
            foreach ($prop in $obj.PSObject.Properties) {
                if (-not [string]::IsNullOrWhiteSpace($prop.Name) -and $null -ne $prop.Value) {
                    $headers[$prop.Name] = [string]$prop.Value
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to parse ExtraHeadersJson. Continuing without extra headers. Error: $($_.Exception.Message)"
    }

    return $headers
}

function Merge-Headers {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Primary,

        [Parameter(Mandatory = $true)]
        [hashtable]$Secondary
    )

    $merged = @{}
    foreach ($key in $Primary.Keys) {
        $merged[$key] = $Primary[$key]
    }

    foreach ($key in $Secondary.Keys) {
        $alreadyExists = $false
        foreach ($existing in $merged.Keys) {
            if ($existing -ieq $key) {
                $alreadyExists = $true
                break
            }
        }

        if (-not $alreadyExists) {
            $merged[$key] = $Secondary[$key]
        }
    }

    return $merged
}

function Resolve-AuthHeaders {
    $baseHeaders = @{}

    if ($AccessToken) {
        $baseHeaders = @{ Authorization = "Bearer $AccessToken" }
    }

    elseif ($UseGraphAuth) {
        $graphToken = & (Join-Path $PSScriptRoot 'Get-AdminApiAccessToken.ps1') -Resource 'https://graph.microsoft.com' -TenantId $TenantId -AllowMsal:$true -Quiet
        if ($graphToken -and $graphToken.AccessToken) {
            $baseHeaders = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
        }
        else {
            throw 'Graph auth mode did not yield a token. Run Connect-MgGraph/az login first, or disable UseGraphAuth and use cookie/HAR auth.'
        }
    }

    elseif ($CookieHeader) {
        $baseHeaders = @{ Cookie = $CookieHeader }
    }

    elseif ($RootAuthToken) {
        $baseHeaders = @{ Cookie = "RootAuthToken=$RootAuthToken" }
    }

    $extraHeaders = Get-ExtraHeadersHashtable -JsonText $ExtraHeadersJson

    if ($baseHeaders.Count -eq 0) {
        throw 'No usable auth material was found. Provide AccessToken, CookieHeader, RootAuthToken, or set UseGraphAuth. Extra headers alone are not sufficient auth.'
    }

    return Merge-Headers -Primary $baseHeaders -Secondary $extraHeaders
}

function Get-HttpErrorDetails {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = $null
    $body = $null

    $exception = $ErrorRecord.Exception
    if ($exception -and ($exception.PSObject.Properties.Name -contains 'Response') -and $exception.Response) {
        $response = $exception.Response

        if ($response.PSObject.Properties.Name -contains 'StatusCode') {
            try {
                $statusCode = [int]$response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        try {
            if (($response.PSObject.Properties.Name -contains 'Content') -and $response.Content) {
                if ($response.Content.PSObject.Methods.Name -contains 'ReadAsStringAsync') {
                    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                else {
                    $body = [string]$response.Content
                }
            }
            elseif ($response.PSObject.Methods.Name -contains 'GetResponseStream') {
                $stream = $response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                    $stream.Dispose()
                }
            }
        }
        catch {
            # Best-effort diagnostics only.
        }
    }

    if (-not $statusCode -and $exception -and $exception.Message -match '\b(\d{3})\b') {
        $statusCode = [int]$matches[1]
    }

    [pscustomobject]@{
        StatusCode = $statusCode
        Body       = $body
    }
}

function Get-AuthOnlyHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $authHeaders = @{}
    foreach ($key in $Headers.Keys) {
        if ($key -ieq 'Authorization' -or $key -ieq 'Cookie') {
            $authHeaders[$key] = $Headers[$key]
        }
    }

    return $authHeaders
}

function Invoke-NeptuneRequestWithFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    try {
        return Invoke-NeptuneRequest -Uri $Uri -Headers $Headers
    }
    catch {
        $details = Get-HttpErrorDetails -ErrorRecord $_

        $authOnlyHeaders = Get-AuthOnlyHeaders -Headers $Headers
        $hasReplayHeaders = $Headers.Count -gt $authOnlyHeaders.Count

        if ($details.StatusCode -eq 400 -and $hasReplayHeaders -and $authOnlyHeaders.Count -gt 0) {
            Write-Warning 'Received HTTP 400 with replay headers; retrying once with auth-only headers.'
            return Invoke-NeptuneRequest -Uri $Uri -Headers $authOnlyHeaders
        }

        $bodyPreview = if ([string]::IsNullOrWhiteSpace($details.Body)) { '' } else { $details.Body.Substring(0, [Math]::Min(800, $details.Body.Length)) }
        if ($details.StatusCode) {
            throw "Neptune request failed with HTTP $($details.StatusCode). Uri: $Uri. Body: $bodyPreview"
        }

        throw
    }
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
    $result = Invoke-NeptuneRequestWithFallback -Uri $uri -Headers $headers

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