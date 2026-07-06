[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HarPath,

    [string]$DotEnvPath = (Join-Path $PSScriptRoot '.env'),

    [switch]$PersistToDotEnv,

    [switch]$SetProcessEnvironment = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $HarPath)) {
    throw "HAR file not found: $HarPath"
}

if ($PersistToDotEnv -and -not (Test-Path -Path $DotEnvPath)) {
    throw ".env file not found: $DotEnvPath"
}

function Set-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value,

        [switch]$RawValue
    )

    $newLine = $null
    if ($RawValue) {
        $newLine = $Name + '=' + $Value
    }
    else {
        $safeValue = $Value.Replace('"', '\"')
        $newLine = $Name + '="' + $safeValue + '"'
    }

    $content = Get-Content -Path $Path

    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "^\s*$([Regex]::Escape($Name))\s*=") {
            $content[$i] = $newLine
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        $content += $newLine
    }

    Set-Content -Path $Path -Value $content
}

function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText,

        [int]$Depth = 100
    )

    $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertFromJson.Parameters.ContainsKey('Depth')) {
        return $JsonText | ConvertFrom-Json -Depth $Depth
    }

    return $JsonText | ConvertFrom-Json
}

$harJsonRaw = Get-Content -Path $HarPath -Raw
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

$cookieHeaderEntry = $headers | Where-Object { $_.name -ieq 'Cookie' } | Select-Object -First 1
$authHeaderEntry = $headers | Where-Object { $_.name -ieq 'Authorization' } | Select-Object -First 1

$cookieHeader = $null
if ($cookieHeaderEntry -and ($cookieHeaderEntry.PSObject.Properties.Name -contains 'value')) {
    $cookieHeader = [string]$cookieHeaderEntry.value
}

$authHeader = $null
if ($authHeaderEntry -and ($authHeaderEntry.PSObject.Properties.Name -contains 'value')) {
    $authHeader = [string]$authHeaderEntry.value
}

$token = $null
if ($authHeader) {
    $authMatch = [regex]::Match($authHeader, '^Bearer\s+(.+)$')
    if ($authMatch.Success) {
        $token = $authMatch.Groups[1].Value
    }
}

if ($token) {
    if ($PersistToDotEnv) {
        Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_ACCESS_TOKEN' -Value $token
    }
}

$rootAuth = $null
if ($cookieHeader) {
    $rootMatch = [regex]::Match($cookieHeader, '(?:^|;\s*)RootAuthToken=([^;]+)')
    if ($rootMatch.Success) {
        $rootAuth = $rootMatch.Groups[1].Value
    }
}

if ($rootAuth) {
    if ($PersistToDotEnv) {
        Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_ROOT_AUTH_TOKEN' -Value $rootAuth
    }
}

$extraHeaders = @{}
foreach ($header in $headers) {
    $name = if ($header -and ($header.PSObject.Properties.Name -contains 'name')) { [string]$header.name } else { $null }
    $value = if ($header -and ($header.PSObject.Properties.Name -contains 'value')) { [string]$header.value } else { $null }

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($value)) {
        continue
    }

    if ($name.StartsWith(':')) {
        continue
    }

    if ($name -ieq 'Cookie' -or $name -ieq 'Authorization') {
        continue
    }

    $extraHeaders[$name] = $value
}

$extraHeadersJson = if ($extraHeaders.Count -gt 0) { $extraHeaders | ConvertTo-Json -Compress -Depth 20 } else { '{}' }

if ($PersistToDotEnv) {
    if ($cookieHeader) {
        Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_COOKIE_HEADER' -Value $cookieHeader
    }

    Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_EXTRA_HEADERS_JSON' -Value $extraHeadersJson -RawValue
}

if ($SetProcessEnvironment) {
    if ($cookieHeader) {
        [Environment]::SetEnvironmentVariable('NEPTUNE_COOKIE_HEADER', $cookieHeader, [EnvironmentVariableTarget]::Process)
    }

    if ($token) {
        [Environment]::SetEnvironmentVariable('NEPTUNE_ACCESS_TOKEN', $token, [EnvironmentVariableTarget]::Process)
    }

    if ($rootAuth) {
        [Environment]::SetEnvironmentVariable('NEPTUNE_ROOT_AUTH_TOKEN', $rootAuth, [EnvironmentVariableTarget]::Process)
    }

    [Environment]::SetEnvironmentVariable('NEPTUNE_EXTRA_HEADERS_JSON', $extraHeadersJson, [EnvironmentVariableTarget]::Process)
}

[pscustomobject]@{
    HarPath             = $HarPath
    DotEnvPath          = if ($PersistToDotEnv) { $DotEnvPath } else { '' }
    PersistedToDotEnv   = [bool]$PersistToDotEnv
    ProcessEnvUpdated   = [bool]$SetProcessEnvironment
    FoundCookieHeader   = -not [string]::IsNullOrWhiteSpace($cookieHeader)
    FoundBearerToken    = -not [string]::IsNullOrWhiteSpace($token)
    FoundRootAuthToken  = -not [string]::IsNullOrWhiteSpace($rootAuth)
    ExtraHeaderCount    = $extraHeaders.Count
    RequestUrl          = $entry.request.url
}