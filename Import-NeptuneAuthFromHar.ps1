[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HarPath,

    [string]$DotEnvPath = (Join-Path $PSScriptRoot '.env')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $HarPath)) {
    throw "HAR file not found: $HarPath"
}

if (-not (Test-Path -Path $DotEnvPath)) {
    throw ".env file not found: $DotEnvPath"
}

function Set-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $safeValue = $Value.Replace('"', '\"')
    $newLine = $Name + '="' + $safeValue + '"'
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

$har = Get-Content -Path $HarPath -Raw | ConvertFrom-Json -Depth 100
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

$cookieHeader = ($headers | Where-Object { $_.name -ieq 'Cookie' } | Select-Object -First 1).value
$authHeader = ($headers | Where-Object { $_.name -ieq 'Authorization' } | Select-Object -First 1).value

$token = $null
if ($authHeader) {
    $authMatch = [regex]::Match($authHeader, '^Bearer\s+(.+)$')
    if ($authMatch.Success) {
        $token = $authMatch.Groups[1].Value
    }
}

if ($cookieHeader) {
    Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_COOKIE_HEADER' -Value $cookieHeader
}

if ($token) {
    Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_ACCESS_TOKEN' -Value $token
}

$rootAuth = $null
if ($cookieHeader) {
    $rootMatch = [regex]::Match($cookieHeader, '(?:^|;\s*)RootAuthToken=([^;]+)')
    if ($rootMatch.Success) {
        $rootAuth = $rootMatch.Groups[1].Value
    }
}

if ($rootAuth) {
    Set-DotEnvValue -Path $DotEnvPath -Name 'NEPTUNE_ROOT_AUTH_TOKEN' -Value $rootAuth
}

[pscustomobject]@{
    HarPath             = $HarPath
    DotEnvPath          = $DotEnvPath
    FoundCookieHeader   = -not [string]::IsNullOrWhiteSpace($cookieHeader)
    FoundBearerToken    = -not [string]::IsNullOrWhiteSpace($token)
    FoundRootAuthToken  = -not [string]::IsNullOrWhiteSpace($rootAuth)
    RequestUrl          = $entry.request.url
} | Format-List