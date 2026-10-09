# Automated Migration (ARM REST API)

Azure offers an **automated migration path** from Azure Cache for Redis (ACR) to Azure Managed Redis (AMR) via ARM REST APIs. This handles DNS switching automatically so clients using the old OSS endpoint continue to work after migration.

> **Important**: This feature is currently in **Public Preview**. Use the manual migration strategies for production workloads until GA, or if the cache falls outside the supported scope below.

Two utility scripts wrap these APIs — both use **Azure CLI** (`az rest`) as their only dependency:
- **PowerShell** (`scripts/Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1`) — for Windows (PowerShell 7+)
- **Bash** (`scripts/azure-redis-migration-arm-rest-api-utility.sh`) — for Linux, macOS, and WSL

For detailed documentation on the underlying ARM API endpoints, request/response payloads, script architecture, behavioral differences, and troubleshooting, see [Migration Scripts Reference](migration-scripts.md).

---

## Supported Scope

**Supported source SKUs**: All Basic (C0–C6), Standard (C0–C6), and Premium (P1–P5) — **except**:
- VNet injected caches
- Geo-Replication enabled caches

These exclusions are expected to be supported in future releases.

Private Link enabled caches and clustered caches can be migrated, but are not eligible for data migration.

**Requirements**:
- Source and target must be in the **same Azure region** (validation error if not)
- Source and target must be in the **same subscription**
- The source ACR cache must be in **Running** state (not creating, scaling, or failed)
- The target AMR cache must be in **Running** state with at least one database

**Artifacts migrated automatically**:
- Access keys (if enabled on the source)
- OSS host endpoint (via DNS switch — the old `.redis.cache.windows.net` hostname routes to AMR)
- OSS cache port (via port forwarding)
- Cache data, when explicitly selected

**Artifacts NOT migrated** (manual action required after migration):
- Entra ID configurations — consider adopting [Microsoft Entra ID authentication](https://learn.microsoft.com/en-us/azure/redis/entra-for-authentication) post-migration as the recommended auth method
- Firewall rules
- Maintenance schedules
- Keyspace notifications
- Managed identity for storage accounts (used for import/export, not for persistence — AMR manages persistence storage internally)
- Data persistence configuration

---

## Prerequisites

### PowerShell (Windows)

1. **Azure CLI** (`az`) installed — see [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli):
   ```powershell
   winget install -e --id Microsoft.AzureCLI
   ```
2. **PowerShell 7 (x64)** required.
3. **Unblock the script** (Windows only):
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force -Scope CurrentUser
   Unblock-File -Path ".\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1"
   ```
4. **Login to Azure**:
   ```powershell
   az login
   az account set --subscription <subscriptionId>
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

### Cache Data Migration (Opt-In)

Determine the user's choice before running Validate:

- The user asked for cache data to be migrated → use `-MigrateData` / `--migrate-data`.
- The user said they do not need cache data migrated → omit it.
- The user did not mention cache data → ask `Should the migration copy the cache data from <source cache> to <target cache>?`.

Use the same choice for Validate and Migrate.

If the user has chosen to migrate cache data, do the following:

- Compare the source SKU's memory size in [SKU Mapping](sku-mapping.md) against the target SKU's memory size in [AMR SKU Specifications](amr-sku-specs.md). If the target is smaller, warn the user, naming both sizes, that keys may be silently evicted or the migration may fail if the target cannot hold the source data.
- Run `scripts/get_acr_metrics.ps1` or `scripts/get_acr_metrics.sh` to read the source cache's actual peak **Used Memory RSS**, and tell the user whether it fits within the target's memory size.

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

To validate with data migration enabled:

```powershell
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Validate" `
  -SourceResourceId "<sourceACRResourceId>" -TargetResourceId "<targetAMRResourceId>" `
  -MigrateData
```

```bash
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Validate \
  --source "<sourceACRResourceId>" --target "<targetAMRResourceId>" \
  --migrate-data
```

### 2. Migrate

Triggers the actual migration (~5+ minutes). DNS is switched automatically so existing clients using the old OSS endpoint are routed to the new AMR cache.

When data migration is included, the migration takes longer because cache data is synchronized before DNS is switched. The tracking timeout is raised from 30 to 60 minutes when `-MigrateData` / `--migrate-data` is set. A tracking timeout does not mean the migration failed — re-check with the **Status** action.

```powershell
# PowerShell — fire-and-forget
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Migrate" `
  -SourceResourceId "<sourceACRResourceId>" -TargetResourceId "<targetAMRResourceId>"

# Add -TrackMigration to wait for completion, -ForceMigrate $true to bypass warnings
# Add -MigrateData only when the preceding Validate action used -MigrateData
```

```bash
# Bash — fire-and-forget
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Migrate \
  --source "<sourceACRResourceId>" --target "<targetAMRResourceId>"

# Add --track to wait for completion, --force-migrate to bypass warnings
# Add --migrate-data only when the preceding Validate action used --migrate-data
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

> [!IMPORTANT]
> Rollback is only available for a limited time after a successful migration. Validate application behavior promptly if you might need to cancel.
>
> If the migration included cache data, canceling or rolling back does not remove data already copied to AMR.

### 5. Post-Migration

After a successful migration with DNS switching:
- The **source ACR cache continues to exist** and will incur charges. It is not automatically deleted.
- The old Azure Cache for Redis hostname continues to point to AMR for a limited time, but it will be automatically deleted in the future.
- Update your applications to use the new AMR hostname as soon as possible.
- Verify your application is working correctly against the new AMR instance — monitor for expected behavior, performance, and error rates.
- Once validated, **delete the old ACR instance** to stop billing.
- Consider switching to [Microsoft Entra ID authentication](https://learn.microsoft.com/en-us/azure/redis/entra-for-authentication) instead of access keys.

---

## Script Parameters Reference

| PowerShell | Bash | Required | Description |
|-----------|------|----------|-------------|
| `-Action` | `--action`, `-a` | Yes | `Validate`, `Migrate`, `Status`, or `Cancel` |
| `-SourceResourceId` | `--source`, `-s` | Validate, Migrate | Full ARM resource ID of the source ACR cache (`Microsoft.Cache/Redis/<name>`) |
| `-TargetResourceId` | `--target`, `-t` | Always | Full ARM resource ID of the target AMR cache (`Microsoft.Cache/redisEnterprise/<name>`) |
| `-ForceMigrate $true` | `--force-migrate` | No | Bypass validation warnings (default: false) |
| `-MigrateData` | `--migrate-data` | No | Include cache data; use for both Validate and Migrate (default: off) |
| `-TrackMigration` | `--track` | No | Wait for long-running operation to complete (default: off). Timeout is 30 minutes, or 60 minutes when data migration is enabled |
| — | — | — | Both scripts use whichever Azure cloud `az` is logged into |

---

## Portal Alternative

Automated migration is also available via the Azure Portal behind a feature flag:
- **Portal URL**: [https://aka.ms/redis/portal/prod/migrate](https://aka.ms/redis/portal/prod/migrate)
- Navigate to the source ACR cache → click **Migrate** → follow the wizard
- After completion, a link to the target AMR cache is displayed
- Use the **Rollback Migration** button to revert

## Validation Errors & Warnings

See [Validation Errors & Warnings Reference](migration-validation.md) for the full list of blocking errors and overridable warnings returned by the Validate action.
