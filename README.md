# Neptune Credit Requests Toolkit

Small PowerShell toolkit to authenticate and retrieve all records from:

https://admin.cloud.microsoft/admin/api/neptunelicensing/creditrequests

## Files

- `Get-NeptuneCreditRequestsAll.ps1`: Data retrieval script that pages by `continuationToken` until exhausted
- `Import-NeptuneAuthFromHar.ps1`: Imports auth and replay-safe request headers from a browser HAR (memory-first, optional persistence)
- `Get-AdminApiAccessToken.ps1`: Optional token acquisition helper for candidate resources
- `Shared/Import-DotEnv.ps1`: Loads `.env` values into process env vars
- `.env.example`: Starter template for local configuration
- `.env`: Local config and auth artifacts (gitignored)

## Quick Start

1. Create `.env` from the template:

```powershell
Copy-Item .\.env.example .\.env
```

2. Export a HAR from a successful Admin Center session where `creditrequests` is called.
3. Import auth from HAR:

```powershell
.\Import-NeptuneAuthFromHar.ps1 -HarPath "C:\path\to\capture.har"
```

By default, this stores sensitive auth only in current process memory.
To explicitly persist extracted values to `.env`, add `-PersistToDotEnv`.

4. Pull full result sets with continuation-token paging:

```powershell
.\Get-NeptuneCreditRequestsAll.ps1 -MaxPages 200
```

You can also load auth/header material directly from HAR in-memory for a single run:

```powershell
.\Get-NeptuneCreditRequestsAll.ps1 -HarPath "C:\path\to\capture.har" -MaxPages 200
```

## Graph Auth Mode (No HAR)

If you want to force the same Graph-style auth pattern used in MW-Toolbox scripts, run:

```powershell
.\Get-NeptuneCreditRequestsAll.ps1 -UseGraphAuth
```

You can also set this in `.env`:

```text
NEPTUNE_USE_GRAPH_AUTH="true"
```

Note: this acquires a Graph token and uses it against the Neptune endpoint. Some tenants/resources may still require portal session auth, in which case HAR/cookie auth is still needed.

## Retrieve All Records

For tenants with many records, use the retrieval script:

```powershell
.\Get-NeptuneCreditRequestsAll.ps1 -PageSize 50 -MaxPages 200 -OutputPath "C:\temp\neptune_creditrequests.json"
```

Behavior:

- Uses auth resolution order: `AccessToken`, Graph auth mode, cookie header, root auth token
- Replays optional HAR-derived request headers from `NEPTUNE_EXTRA_HEADERS_JSON` without overriding explicit auth headers
- Requests `top=<PageSize>`
- Follows `continuationToken` until it is empty or `MaxPages` is reached
- Stops if a continuation token repeats (loop protection)
- De-duplicates by `requestId` when present

## Common Parameters

Main script (`Get-NeptuneCreditRequestsAll.ps1`):

- `-Service` (default: `Cowork`)
- `-States` (default: `Pending`)
- `-IncludeCount` (default: `true`)
- `-PageSize` (default: `50`)
- `-MaxPages`
- `-AccessToken`
- `-RootAuthToken`
- `-CookieHeader`
- `-UseGraphAuth`
- `-AllowMsal` (used when token acquisition is attempted)
- `-OutputPath`

## .env Keys

- `TENANT_ID`
- `CLIENT_ID`
- `NEPTUNE_ACCESS_TOKEN`
- `NEPTUNE_ROOT_AUTH_TOKEN`
- `NEPTUNE_COOKIE_HEADER`
- `NEPTUNE_EXTRA_HEADERS_JSON`
- `NEPTUNE_CREDITREQUESTS_BASE_URI`
- `NEPTUNE_CREDITREQUESTS_SERVICE`
- `NEPTUNE_CREDITREQUESTS_STATES`
- `NEPTUNE_INCLUDE_COUNT`
- `NEPTUNE_PAGE_SIZE`
- `NEPTUNE_SKIP_PAGE_SIZE` (legacy fallback)
- `NEPTUNE_ALLOW_MSAL`
- `NEPTUNE_USE_GRAPH_AUTH`
- `NEPTUNE_MAX_PAGES`

## Notes

- For this endpoint, browser-session auth (cookie/HAR import) is often more reliable than generic Graph-style interactive token acquisition.
- HAR/cookie/token artifacts are sensitive. Keep `.env` local and rotate session material after troubleshooting.
- Default HAR import behavior avoids writing sensitive cookie/auth values to `.env`; use `-PersistToDotEnv` only when you explicitly want persistence.
