# Neptune Credit Requests Toolkit

Minimal PowerShell retrieval flow for:

https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests

## Files

- `Get-NeptuneCreditRequestsBearer.ps1`: Single entrypoint that uses authenticated request headers and pages through results
- `Shared/Import-DotEnv.ps1`: Loads `.env` values into process env vars
- `.env.example`: Starter template for local configuration
- `.env`: Local config (gitignored)

## Quick Start

1. Create `.env` from the template:

```powershell
Copy-Item .\.env.example .\.env
```

2. Open this page while signed in:

   `https://admin.cloud.microsoft/?source=applauncher#/copilot/cowork`

3. In browser DevTools Network, select the request to:

   `https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests...`

4. Copy the full `Cookie` header value from that request into `.env` as `NEPTUNE_COOKIE_HEADER`.

5. Run the script:

```powershell
.\Get-NeptuneCreditRequestsBearer.ps1 -MaxPages 200
```

If you want to pass cookie auth directly:

```powershell
.\Get-NeptuneCreditRequestsBearer.ps1 -CookieHeader "<cookie header value>" -MaxPages 200
```

## Behavior

- Sends `Cookie: ...` when `-CookieHeader`/`NEPTUNE_COOKIE_HEADER` is supplied
- Can also send `Authorization: Bearer ...` when `-AccessToken` is supplied directly
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

- `NEPTUNE_COOKIE_HEADER`
- `NEPTUNE_CREDITREQUESTS_BASE_URI`
- `NEPTUNE_CREDITREQUESTS_SERVICE`
- `NEPTUNE_CREDITREQUESTS_STATES`
- `NEPTUNE_INCLUDE_COUNT`
- `NEPTUNE_PAGE_SIZE`
- `NEPTUNE_MAX_PAGES`

## Notes

- The script does not attempt Azure CLI or MSAL token acquisition.
- Preferred auth is cookie header captured from a successful authenticated admin portal creditrequests request.
- `.env` is local only and should not be committed.
