# Neptune Credit Requests Toolkit

Minimal PowerShell retrieval flow for:

https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests

## Files

- `Get-NeptuneCreditRequestsBearer.ps1`: Single entrypoint that uses a supplied bearer token and pages through results
- `Shared/Import-DotEnv.ps1`: Loads `.env` values into process env vars
- `.env.example`: Starter template for local configuration
- `.env`: Local config (gitignored)

## Quick Start

1. Create `.env` from the template:

```powershell
Copy-Item .\.env.example .\.env
```

2. Put a bearer token from the authenticated admin portal request in `.env` as `NEPTUNE_ACCESS_TOKEN`.

3. Run the script:

```powershell
.\Get-NeptuneCreditRequestsBearer.ps1 -MaxPages 200
```

If you want to pass the token directly instead of using `.env`:

```powershell
.\Get-NeptuneCreditRequestsBearer.ps1 -AccessToken "<bearer token>" -MaxPages 200
```

## Behavior

- Sends only `Authorization: Bearer ...`
- Requests `top=<PageSize>`
- Follows `continuationToken` until empty or `MaxPages` is reached
- Stops if a continuation token repeats
- De-duplicates by `requestId` when present
- Prints HTTP status/body details when a request fails

## Parameters

- `-AccessToken`
- `-Service` default: `Cowork`
- `-States` default: `Pending`
- `-IncludeCount` default: `true`
- `-PageSize` default: `50`
- `-MaxPages`
- `-OutputPath`

## .env Keys

- `NEPTUNE_ACCESS_TOKEN`
- `NEPTUNE_CREDITREQUESTS_BASE_URI`
- `NEPTUNE_CREDITREQUESTS_SERVICE`
- `NEPTUNE_CREDITREQUESTS_STATES`
- `NEPTUNE_INCLUDE_COUNT`
- `NEPTUNE_PAGE_SIZE`
- `NEPTUNE_MAX_PAGES`

## Notes

- The script does not attempt Azure CLI or MSAL token acquisition.
- The bearer token must come from a successful authenticated admin portal request.
- `.env` is local only and should not be committed.
