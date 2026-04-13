# Automated Migration (ARM REST API)

Azure offers an **automated migration path** from Azure Cache for Redis (ACR) to Azure Managed Redis (AMR) via ARM REST APIs. This handles DNS switching automatically so clients using the old OSS endpoint continue to work after migration.

> **Important**: This feature is currently in **Public Preview**. Use the manual migration strategies for production workloads until GA, or if the cache falls outside the supported scope below.

Two utility scripts wrap these APIs:
- **PowerShell** (`scripts/Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1`) — uses Az PowerShell module (`Invoke-AzRestMethod`)
- **Bash** (`scripts/azure-redis-migration-arm-rest-api-utility.sh`) — uses Azure CLI (`az rest`), works on Linux, macOS, and WSL

For detailed documentation on the underlying ARM API endpoints, request/response payloads, script architecture, behavioral differences, and troubleshooting, see [Migration Scripts Reference](migration-scripts.md).

---

## Supported Scope

**Supported source SKUs**: All Basic (C0–C6), Standard (C0–C6), and Premium (P1–P5) — **except**:
- Private Link enabled caches
- VNet injected caches
- Geo-Replication enabled caches

These exclusions are expected to be supported in future releases.

**Requirements**:
- Source and target must be in the **same Azure region** (validation error if not)
- Source and target must be in the **same subscription**
- The target AMR cache must be in **Running** state with at least one database

**Artifacts migrated automatically**:
- Access keys (if enabled on the source)
- OSS host endpoint (via DNS switch — the old `.redis.cache.windows.net` hostname routes to AMR)
- OSS cache port (via port forwarding)

**Artifacts NOT migrated** (manual action required after migration):
- Cache data (not yet supported)
- Entra ID configurations — consider adopting [Microsoft Entra ID authentication](https://learn.microsoft.com/en-us/azure/redis/managed-redis/managed-redis-entra-for-access-control-configuration) post-migration as the recommended auth method
- Auto-update schedules
- Custom ACL definitions
- Keyspace notifications
- User-assigned managed identities
- Data persistence configuration

---

## Prerequisites

### PowerShell (Windows)

1. **Az PowerShell module** (v15.4.0+) — the script uses `Invoke-AzRestMethod` and `Get-AzContext`:
   ```powershell
   Install-Module -Name Az -AllowClobber -Scope CurrentUser
   ```
2. **PowerShell 7 (x64)** recommended.
3. **Unblock the script** (Windows only):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force -Scope CurrentUser
   Unblock-File -Path ".\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1"
   ```
4. **Login to Azure**:
   ```powershell
   Connect-AzAccount
   Set-AzContext -Subscription <subscriptionId>
   ```

### Bash (Linux / macOS / WSL)

1. **Azure CLI** (`az`) installed and logged in:
   ```bash
   az login
   az account set --subscription <subscriptionId>
   ```
2. **jq** installed for JSON processing:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install jq
   # macOS
   brew install jq
   ```
3. **Make the script executable**:
   ```bash
   chmod +x ./scripts/azure-redis-migration-arm-rest-api-utility.sh
   ```

---

## Automated Migration Workflow

> ⚠️ **Operational Impact**: Migration causes a brief connectivity blip similar to regular maintenance operations. Perform migrations during **off-business hours** to minimize user impact.

The migration utility supports four actions: **Validate → Migrate → Status → Cancel (Rollback)**.

### 1. Validate

Performs a dry-run comparison of source and target configurations. Returns validation **errors** (blocking) and **warnings** (overridable). Always validate before migrating.

```powershell
# PowerShell
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Validate" `
  -SourceResourceId "<sourceACRResourceId>" -TargetResourceId "<targetAMRResourceId>"
```

```bash
# Bash
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Validate \
  --source "<sourceACRResourceId>" --target "<targetAMRResourceId>"
```

Fix any errors before proceeding. Warnings can be bypassed with `-ForceMigrate $true` / `--force-migrate` if the user accepts the trade-offs. See [Validation Errors & Warnings Reference](migration-validation.md) for the full list.

### 2. Migrate

Triggers the actual migration (~5+ minutes). DNS is switched automatically so existing clients using the old OSS endpoint are routed to the new AMR cache.

```powershell
# PowerShell — fire-and-forget
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Migrate" `
  -SourceResourceId "<sourceACRResourceId>" -TargetResourceId "<targetAMRResourceId>"

# Add -TrackMigration to wait for completion, -ForceMigrate $true to bypass warnings
```

```bash
# Bash — fire-and-forget
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Migrate \
  --source "<sourceACRResourceId>" --target "<targetAMRResourceId>"

# Add --track to wait for completion, --force-migrate to bypass warnings
```

### 3. Check Status

Poll the migration status (only requires TargetResourceId):

```powershell
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Status" -TargetResourceId "<targetAMRResourceId>"
```

```bash
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Status --target "<targetAMRResourceId>"
```

### 4. Cancel / Rollback

Cancel a failed or completed migration. Reverses DNS changes (~5+ minutes):

```powershell
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Cancel" -TargetResourceId "<targetAMRResourceId>"
# Add -TrackMigration to wait for completion
```

```bash
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Cancel --target "<targetAMRResourceId>"
# Add --track to wait for completion
```

### 5. Post-Migration

After a successful migration with DNS switching:
- The **source ACR cache continues to exist** and will incur charges. It is not automatically deleted.
- Verify your application is working correctly against the new AMR instance — monitor for expected behavior, performance, and error rates.
- Once validated, **delete the old ACR instance** to stop billing.
- Consider switching to [Microsoft Entra ID authentication](https://learn.microsoft.com/en-us/azure/redis/managed-redis/managed-redis-entra-for-access-control-configuration) instead of access keys.

---

## Script Parameters Reference

| PowerShell | Bash | Required | Description |
|-----------|------|----------|-------------|
| `-Action` | `--action`, `-a` | Yes | `Validate`, `Migrate`, `Status`, or `Cancel` |
| `-SourceResourceId` | `--source`, `-s` | Validate, Migrate | Full ARM resource ID of the source ACR cache (`Microsoft.Cache/Redis/<name>`) |
| `-TargetResourceId` | `--target`, `-t` | Always | Full ARM resource ID of the target AMR cache (`Microsoft.Cache/redisEnterprise/<name>`) |
| `-ForceMigrate $true` | `--force-migrate` | No | Bypass validation warnings (default: false) |
| `-TrackMigration` | `--track` | No | Wait for long-running operation to complete (default: off) |
| `-Environment` | — | No | Azure environment (default: `AzureCloud`). PowerShell only; bash uses whatever `az` is logged into |

---

## Portal Alternative

Automated migration is also available via the Azure Portal behind a feature flag:
- **Portal URL**: [https://aka.ms/redis/portal/prod/migrate](https://aka.ms/redis/portal/prod/migrate)
- Navigate to the source ACR cache → click **Migrate** → follow the wizard
- After completion, a link to the target AMR cache is displayed
- Use the **Rollback Migration** button to revert

## Validation Errors & Warnings

See [Validation Errors & Warnings Reference](migration-validation.md) for the full list of blocking errors and overridable warnings returned by the Validate action.
