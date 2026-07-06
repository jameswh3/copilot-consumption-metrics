[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Resource,

    [string]$TenantId,

    [string]$ClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46',

    [switch]$AsPlainText,

    [switch]$AllowMsal,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LastMsalError = $null

$repoRoot = $PSScriptRoot
$importDotEnvPath = Join-Path $repoRoot 'Shared\Import-DotEnv.ps1'
$dotEnvPath = Join-Path $repoRoot '.env'

if ((Test-Path -Path $importDotEnvPath) -and (Test-Path -Path $dotEnvPath)) {
    . $importDotEnvPath
    Import-DotEnv -Path $dotEnvPath
}

if (-not $PSBoundParameters.ContainsKey('TenantId') -and -not [string]::IsNullOrWhiteSpace($env:TENANT_ID)) {
    $script:TenantId = $env:TENANT_ID
}

if (-not $PSBoundParameters.ContainsKey('ClientId') -and -not [string]::IsNullOrWhiteSpace($env:CLIENT_ID)) {
    $script:ClientId = $env:CLIENT_ID
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
    return $json | ConvertFrom-Json
}

function Try-GetTokenWithAz {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Audience,

        [string]$DirectoryId
    )

    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        return $null
    }

    $commonArgs = @('account', 'get-access-token', '--output', 'json')
    if ($DirectoryId) {
        $commonArgs += @('--tenant', $DirectoryId)
    }

    $attempts = @(
        @{ Mode = 'resource'; Args = @('--resource', $Audience.TrimEnd('/')) },
        @{ Mode = 'scope'; Args = @('--scope', ('{0}/.default' -f $Audience.TrimEnd('/'))) }
    )

    foreach ($attempt in $attempts) {
        $output = & $az.Source @commonArgs @($attempt.Args) 2>$null
        if (-not $output) {
            continue
        }

        try {
            $tokenResponse = $output | ConvertFrom-Json
            if ($tokenResponse.accessToken) {
                return [pscustomobject]@{
                    Method      = 'AzureCli'
                    GrantType   = $attempt.Mode
                    Resource    = $Audience
                    AccessToken = $tokenResponse.accessToken
                    ExpiresOn   = $tokenResponse.expiresOn
                }
            }
        }
        catch {
        }
    }

    return $null
}

function Try-GetTokenWithMsal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Audience,

        [string]$DirectoryId,

        [Parameter(Mandatory = $true)]
        [string]$PublicClientId
    )

    $module = Get-Module -ListAvailable -Name MSAL.PS | Select-Object -First 1
    if (-not $module) {
        return $null
    }

    Import-Module MSAL.PS -ErrorAction Stop | Out-Null

    $scopes = '{0}/.default' -f $Audience.TrimEnd('/')
    $msalArgs = @{
        ClientId    = $PublicClientId
        Scopes      = $scopes
        DeviceCode  = $true
    }

    if ($DirectoryId) {
        $msalArgs.TenantId = $DirectoryId
    }

    try {
        $result = Get-MsalToken @msalArgs
        if ($result.AccessToken) {
            return [pscustomobject]@{
                Method      = 'MSAL.PS'
                GrantType   = 'scope'
                Resource    = $Audience
                AccessToken = $result.AccessToken
                ExpiresOn   = $result.ExpiresOn
            }
        }
    }
    catch {
        $script:LastMsalError = $_.Exception.Message
    }

    return $null
}

$tokenResult = Try-GetTokenWithAz -Audience $Resource -DirectoryId $TenantId
if (-not $tokenResult -and $AllowMsal) {
    $tokenResult = Try-GetTokenWithMsal -Audience $Resource -DirectoryId $TenantId -PublicClientId $ClientId
}

if (-not $tokenResult) {
    $message = "Unable to acquire a token for audience '$Resource'. Try 'az login', specify -TenantId, or provide -AccessToken directly from a successful admin portal request."
    if ($AllowMsal -and $script:LastMsalError) {
        $message += " MSAL failed with: $($script:LastMsalError)"
        if ($script:LastMsalError -match 'AADSTS65002') {
            $message += ' This usually means the target API is an internal Microsoft resource that does not allow the generic public client to request tokens. Graph-style interactive auth is not sufficient here; use a bearer token copied from the authenticated admin portal request.'
        }
    }

    throw $message
}

$claims = ConvertFrom-JwtPayload -Token $tokenResult.AccessToken
$scopeValue = if ($claims.PSObject.Properties.Name -contains 'scp') { $claims.scp } else { $null }
$roleValue = if ($claims.PSObject.Properties.Name -contains 'roles') { @($claims.roles) -join ',' } else { $null }
$result = [pscustomobject]@{
    Resource    = $tokenResult.Resource
    Method      = $tokenResult.Method
    GrantType   = $tokenResult.GrantType
    Audience    = $claims.aud
    TenantId    = $claims.tid
    Scopes      = $scopeValue
    Roles       = $roleValue
    ExpiresOn   = $tokenResult.ExpiresOn
    AccessToken = $tokenResult.AccessToken
}

if (-not $Quiet) {
    $summary = $result | Select-Object Resource, Method, GrantType, Audience, TenantId, Scopes, Roles, ExpiresOn
    $summary | Format-List | Out-Host
}

if ($AsPlainText) {
    $result.AccessToken
}
else {
    $result
}