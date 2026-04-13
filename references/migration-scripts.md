# Automated Migration Scripts Reference

This document describes the two migration utility scripts, the ARM REST API they wrap, and behavioral differences between them.

## Overview

Both scripts wrap the **Azure Managed Redis migration ARM REST API** (`Microsoft.Cache/redisEnterprise/migrations`). They perform the same four operations — Validate, Migrate, Status, Cancel — but use different Azure authentication and HTTP stacks:

| | PowerShell (`.ps1`) | Bash (`.sh`) |
|---|---|---|
| **File** | `Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1` | `azure-redis-migration-arm-rest-api-utility.sh` |
| **HTTP client** | `Invoke-AzRestMethod` (Az PowerShell module) | `az rest` (Azure CLI) |
| **Auth** | `Get-AzContext` / `Connect-AzAccount` | `az account show` / `az login` |
| **JSON handling** | `ConvertTo-Json` | `jq` |
| **Track mode** | Native `-WaitForCompletion` (ARM LRO polling built into cmdlet) | Manual polling loop (30s intervals, 30min timeout) |
| **Platform** | Windows (requires Az module) | Cross-platform (Linux, macOS, WSL, Windows with bash) |
| **Sovereign clouds** | `-Environment` parameter (e.g., `AzureChinaCloud`) | Uses whichever cloud `az` is configured for |

## ARM REST API Endpoints

All endpoints operate under the target AMR cache's resource path. API version: `2025-08-01-preview`.

**Base path**: `https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Cache/RedisEnterprise/{amrName}/migrations/default`

### Validate (POST)

```
POST {basePath}/validate?api-version=2025-08-01-preview
```

**Request body**:
```json
{
  "properties": {
    "sourceResourceId": "/subscriptions/.../Microsoft.Cache/Redis/{acrName}",
    "skipDataMigration": true
  }
}
```

**Response**: Returns `isValid` (bool), `errors` (blocking), and `warnings` (overridable). See [migration-validation.md](migration-validation.md) for the full list.

### Migrate (PUT)

```
PUT {basePath}?api-version=2025-08-01-preview
```

**Request body**:
```json
{
  "properties": {
    "sourceResourceId": "/subscriptions/.../Microsoft.Cache/Redis/{acrName}",
    "cacheResourceType": "AzureCacheForRedis",
    "forceMigrate": false,
    "switchDns": true,
    "skipDataMigration": true
  }
}
```

**Key fields**:
- `cacheResourceType`: Always `"AzureCacheForRedis"` for ACR → AMR migrations. **Note**: The ARM template spec (`Microsoft.Cache/redisEnterprise/migrations`) uses `sourceType` as the property name for this same field. The REST API request body uses `cacheResourceType`. Both refer to the same concept — the scripts use `cacheResourceType` which is correct for the REST API path.
- `forceMigrate`: When `true`, bypasses validation warnings (not errors). Default `false`.
- `switchDns`: When `true`, the old ACR hostname (`.redis.cache.windows.net`) is re-pointed to the AMR cache via DNS. Currently hardcoded to `true` in both scripts — this is the core value of automated migration.
- `skipDataMigration`: Currently hardcoded to `true` because data migration is not yet supported. When data migration becomes available, this field will control whether cache data is copied.

**Response**: Returns the migration resource with `provisioningState` (`Accepted` → `InProgress` → `Succeeded`/`Failed`).

### Status (GET)

```
GET {basePath}?api-version=2025-08-01-preview
```

No request body. Returns the current migration state including `provisioningState`, `sourceResourceId`, `targetResourceId`, timestamps, and `statusDetails`.

**Provisioning states**: `Accepted`, `InProgress`, `Succeeded`, `Failed`, `Canceled`.

### Cancel / Rollback (POST)

```
POST {basePath}/cancel?api-version=2025-08-01-preview
```

No request body. Reverses the DNS switch and port forwarding. Takes ~5 minutes. Can be used on both failed and successfully completed migrations.

## Script Architecture

### PowerShell Script Flow

1. Parse `TargetResourceId` via regex → extract subscription, resource group, cache name
2. Authenticate via `Get-AzContext` / `Connect-AzAccount` (Az PowerShell module)
3. Switch subscription context if needed via `Set-AzContext`
4. Build JSON payload with `ConvertTo-Json`
5. Call `Invoke-AzRestMethod` with the appropriate HTTP method and path
6. If `-TrackMigration` is set, uses the cmdlet's built-in `-WaitForCompletion` flag for ARM long-running operation (LRO) polling
7. Print response status code, correlation headers, and content via `Print-Response`

**Key dependency**: Requires the **Az PowerShell module** (`Invoke-AzRestMethod`, `Get-AzContext`). This is a separate authentication from the Azure CLI — users must run `Connect-AzAccount` even if `az login` has been done.

### Bash Script Flow

1. Parse arguments via `while/case` loop
2. Check dependencies (`az`, `jq`)
3. Parse `TargetResourceId` via bash regex (`=~`)
4. Verify Azure CLI login via `az account show`, switch subscription if needed
5. **Confirm destructive actions** (Migrate, Cancel) with interactive prompt; skip with `--yes`
6. Build JSON payload with `jq -n` (avoids shell escaping issues)
7. Call `az rest` with `--body` containing the JSON payload
8. If `--track` is set, enters a polling loop: calls GET Status every 30 seconds until a terminal state (`Succeeded`, `Failed`, `Canceled`) or timeout (30 minutes)

**Key dependency**: Requires **Azure CLI** (`az`) and **jq**. Uses whichever Azure session `az login` established.

## Behavioral Differences

| Behavior | PowerShell | Bash |
|----------|-----------|------|
| **Tracking completion** | Uses ARM LRO polling built into `Invoke-AzRestMethod -WaitForCompletion` (efficient, event-driven) | Manual polling every 30 seconds via GET Status (simple, bounded at 30 min) |
| **Destructive action confirmation** | `SupportsShouldProcess` (`-WhatIf`/`-Confirm`) | Interactive prompt with `[y/N]`; skip with `--yes` |
| **Error exit codes** | Throws PowerShell exceptions on failures (`$ErrorActionPreference = "Stop"`) | Returns non-zero exit codes; prints error to stderr |
| **Response headers** | Displays `x-ms-request-id`, `x-ms-correlation-request-id`, `x-ms-operation-identifier` | Not displayed (limitation of `az rest` output) |
| **JSON output** | Raw content string from `Invoke-AzRestMethod` response | Pretty-printed via `jq .` |
| **Sovereign cloud** | Explicit `-Environment` parameter | Implicit — uses whatever cloud the CLI is configured for |

## Troubleshooting

### Common Errors

| Symptom | Cause | Fix |
|---------|-------|-----|
| `TargetResourceId is not parsed correctly` | Malformed resource ID or wrong provider path | Ensure the target uses `Microsoft.Cache/redisEnterprise/<name>` (not `Microsoft.Cache/Redis/<name>`) |
| `Connect-AzAccount` / `Set-AzContext` fails (PS) | Az PowerShell not authenticated or wrong tenant | Run `Connect-AzAccount -TenantId <tenantId>` |
| `Not logged in to Azure CLI` (Bash) | Azure CLI session expired | Run `az login` |
| 415 Unsupported Media Type | Missing `Content-Type: application/json` header | Already handled by both scripts; if seen with raw `az rest`, add `--headers "Content-Type=application/json"` |
| 409 Conflict | Migration already in progress or target not in Running state | Check `Status` first; wait for any pending operations |
| Source and target must be in the same region | Caches are in different Azure regions | Create the target AMR cache in the same region as the source ACR cache |
| Source and target must be in the same subscription | Caches are in different subscriptions | Create the target AMR cache in the same subscription as the source ACR cache |
