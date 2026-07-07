[CmdletBinding()]
param(
    [string]$BaseUri = 'https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests',

    [string]$Service = 'Cowork',

    [string[]]$States = @('Pending'),

    [bool]$IncludeCount = $true,

    [int]$PageSize = 50,

    [string]$AccessToken,

    [string]$CookieHeader,

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

if (-not $PSBoundParameters.ContainsKey('AccessToken') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_ACCESS_TOKEN)) {
    $script:AccessToken = $env:NEPTUNE_ACCESS_TOKEN
}

if (-not $PSBoundParameters.ContainsKey('CookieHeader') -and -not [string]::IsNullOrWhiteSpace($env:NEPTUNE_COOKIE_HEADER)) {
    $script:CookieHeader = $env:NEPTUNE_COOKIE_HEADER
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText,

        [int]$Depth = 30
    )

    $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertFromJson.Parameters.ContainsKey('Depth')) {
        return $JsonText | ConvertFrom-Json -Depth $Depth
    }

    return $JsonText | ConvertFrom-Json
}

function ConvertFrom-JwtPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) {
        throw 'The supplied access token is not a JWT.'
    }

    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }

    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    return ConvertFrom-JsonCompat -JsonText $json -Depth 20
}

function Resolve-AccessToken {
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        return $null
    }

    return $AccessToken
}

function Resolve-CookieHeader {
    if ([string]::IsNullOrWhiteSpace($CookieHeader)) {
        return $null
    }

    return $CookieHeader
}

function Get-CookieValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CookieHeaderValue,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    foreach ($pair in ($CookieHeaderValue -split ';')) {
        $parts = $pair.Split('=', 2)
        if ($parts.Length -ne 2) {
            continue
        }

        if ($parts[0].Trim() -ieq $Name) {
            return $parts[1].Trim()
        }
    }

    return $null
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

        try {
            if ($response.PSObject.Properties.Name -contains 'StatusCode') {
                $statusCode = [int]$response.StatusCode
            }
        }
        catch {
            $statusCode = $null
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
        }
    }

    [pscustomobject]@{
        StatusCode = $statusCode
        Body       = $body
    }
}

function Get-NonJsonResponseDiagnostics {
    param(
        [string]$ResponseBody
    )

    $loginUrl = ''
    $aadsts = ''

    if (-not [string]::IsNullOrWhiteSpace($ResponseBody)) {
        $loginUrlMatch = [regex]::Match($ResponseBody, "var\s+loginURL\s*=\s*'(?<u>[^']+)';", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($loginUrlMatch.Success) {
            $loginUrl = $loginUrlMatch.Groups['u'].Value
            try {
                $loginUrl = [System.Net.WebUtility]::HtmlDecode($loginUrl)
            }
            catch {
            }
        }

        $aadstsMatch = [regex]::Match($ResponseBody, '(AADSTS\d{5,})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($aadstsMatch.Success) {
            $aadsts = $aadstsMatch.Groups[1].Value
        }
    }

    return [pscustomobject]@{
        LoginUrl = $loginUrl
        AADSTS   = $aadsts
    }
}

function Invoke-NeptuneRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -MaximumRedirection 0
    }
    catch {
        throw 'Auth failed.'
    }

    $contentType = $response.Headers['Content-Type']
    if ($contentType -notmatch 'json') {
        throw 'Auth failed.'
    }

    return ConvertFrom-JsonCompat -JsonText $response.Content -Depth 30
}

if ($PageSize -le 0) {
    throw 'PageSize must be greater than 0.'
}

$requestHeaders = @{}
$bearerToken = Resolve-AccessToken
$cookieHeaderValue = Resolve-CookieHeader

if (-not [string]::IsNullOrWhiteSpace($bearerToken)) {
    $requestHeaders.Authorization = "Bearer $bearerToken"
    $claims = ConvertFrom-JwtPayload -Token $bearerToken
    Write-Host ("Using bearer token | aud={0} | tid={1}" -f $claims.aud, $claims.tid)
}
elseif (-not [string]::IsNullOrWhiteSpace($cookieHeaderValue)) {
    $requestHeaders.Cookie = $cookieHeaderValue
    $resolvedAjaxSessionKey = $null
    $cookieAjaxSessionKey = Get-CookieValue -CookieHeaderValue $cookieHeaderValue -Name 's.AjaxSessionKey'
    if (-not [string]::IsNullOrWhiteSpace($cookieAjaxSessionKey)) {
        $resolvedAjaxSessionKey = [Uri]::UnescapeDataString($cookieAjaxSessionKey)
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedAjaxSessionKey)) {
        $requestHeaders.ajaxsessionkey = $resolvedAjaxSessionKey
        Write-Host 'Using cookie header auth with ajaxsessionkey.'
    }
    else {
        Write-Host 'Using cookie header auth.'
    }
}
else {
    throw 'No auth was provided. Set NEPTUNE_ACCESS_TOKEN or NEPTUNE_COOKIE_HEADER in .env, or pass -AccessToken / -CookieHeader directly.'
}

$allItems = [System.Collections.Generic.List[object]]::new()
$page = 0
$continuationToken = $null
$seenContinuationTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$seenRequestIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

while ($true) {
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
    $json = Invoke-NeptuneRequest -Uri $uri -Headers $requestHeaders

    $items = @()
    if ($json -and ($json.PSObject.Properties.Name -contains 'value')) {
        $items = @($json.value)
    }

    $hasContinuationField = $json -and ($json.PSObject.Properties.Name -contains 'continuationToken')
    $nextContinuationToken = if ($hasContinuationField) { [string]$json.continuationToken } else { $null }

    $itemCount = @($items).Count
    Write-Host ("Page {0} | items={1} | hasNextToken={2}" -f $page, $itemCount, (-not [string]::IsNullOrWhiteSpace($nextContinuationToken)))

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