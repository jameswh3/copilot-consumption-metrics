# Neptune Credit Requests Toolkit

Minimal PowerShell retrieval flow for:

https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests

## Files

- `Get-CopilotCoworkAccessRequests.ps1`: Single entrypoint that uses authenticated request headers and pages through results
- `Shared/Import-DotEnv.ps1`: Loads `.env` values into process env vars
- `.env.example`: Starter template for local configuration

## Quick Start

1. Create `.env` from the template:

```powershell
Copy-Item .\.env.example .\.env
```

2. Open browser DevTools and go to the Network tab.

3. Open this page while signed in (or refresh it if already open):

   `https://admin.cloud.microsoft/?source=applauncher#/copilot/cowork`

4. In browser DevTools Network, select the request to:

   `https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests...`

5. Copy the full `Cookie` header value from that request into `.env` as `NEPTUNE_COOKIE_HEADER`.

6. Run the script:

```powershell
.\Get-CopilotCoworkAccessRequests.ps1
```

If you want to pass cookie auth directly:

```powershell
.\Get-CopilotCoworkAccessRequests.ps1 -CookieHeader "<cookie header value>"
```

## Behavior

- Sends `Cookie: ...` when `-CookieHeader`/`NEPTUNE_COOKIE_HEADER` is supplied
- Adds `ajaxsessionkey` automatically from cookie key `s.AjaxSessionKey` when present
- Requests `top=<PageSize>`
- Follows `continuationToken` until empty
- Stops if a continuation token repeats
- De-duplicates by `requestId` when present
- Prints `Auth failed.` when authentication is not accepted

## Parameters

- `-BaseUri` default: `https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests`
- `-CookieHeader`
- `-Service` default: `Cowork`
- `-States` default: `Pending`
- `-IncludeCount` default: `true`
- `-PageSize` default: `50`
- `-OutputPath`

## .env Keys

- `NEPTUNE_COOKIE_HEADER`

Request defaults (service, states, include count, page size, base URI) are set with script parameters, not `.env` keys.

## Notes

- The script does not attempt Azure CLI or MSAL token acquisition.
- Preferred auth is cookie header captured from a successful authenticated admin portal creditrequests request.
- The script currently reads auth values from `.env` (`NEPTUNE_COOKIE_HEADER`).
- Use script parameters (`-BaseUri`, `-Service`, `-States`, `-IncludeCount`, `-PageSize`) to override request options.
- `.env` is local only and should not be committed.
