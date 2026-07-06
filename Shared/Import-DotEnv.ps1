# Function to load .env file values into process environment variables.
function Import-DotEnv {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Get-Location).Path '.env')
    )

    if (-not (Test-Path -Path $Path)) {
        Write-Warning ".env file not found at $Path"
        return
    }

    Get-Content -Path $Path | ForEach-Object {
        if ($_ -match '^\s*#') {
            return
        }

        if ($_ -match '^\s*$') {
            return
        }

        if ($_ -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            $value = $value -replace '^("|'')|("|'')$', ''
            [Environment]::SetEnvironmentVariable($name, $value, [EnvironmentVariableTarget]::Process)
        }
    }

    Write-Host 'Loaded environment variables from .env file' -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne '.') {
    Import-DotEnv
}