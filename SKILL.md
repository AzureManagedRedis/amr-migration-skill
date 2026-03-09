---
name: amr-migration-skill
description: |
  Helps users migrate from Azure Cache for Redis (ACR/OSS) to Azure Managed Redis (AMR).
  Use when users ask about: Redis migration, ACR to AMR, OSS to AMR, automated migration,
  DNS switch migration, cache retirement deadline, SKU selection, AMR vs ACR features,
  feature compatibility, pricing comparison, cache upgrade, Basic/Standard/Premium tier migration,
  P1/P2/C3 cache migration, AMR SKU recommendation, migration rollback, or migration validation.
  Also use for: running migration scripts, checking migration status, cache assessment and metrics.
---

# Azure Managed Redis Migration Skill

This skill assists users in migrating from Azure Cache for Redis (ACR) Basic/Standard/Premium tiers to Azure Managed Redis (AMR), including automated migration via ARM REST APIs.

## 📝 Terminology Note

Users may refer to Azure Cache for Redis by several names: **OSS**, **ACR**, or by tier name (**Basic**, **Standard**, **Premium**). These all refer to the same product. Treat these terms interchangeably when users ask about migration.

## ⚠️ Scope Limitation: Enterprise Tier NOT Supported

This skill does **not** cover Azure Cache for Redis Enterprise (ACRE) migrations. If users ask about migrating from Enterprise or Enterprise Flash tiers, explain that those have different migration paths and suggest contacting Microsoft support or consulting the official documentation.

**Supported source tiers**: Basic (C0-C6), Standard (C0-C6), Premium (P1-P5)

## ⚠️ AMR Terminology: No "Shards"

Avoid using the term "shards" when describing AMR. In AMR, sharding is managed internally and not exposed to customers, so the concept doesn't apply and would be confusing. The term only applies to ACR Premium clustered caches. When discussing AMR, refer to the SKU name and its memory capacity instead.

---

## Agent Guidance

### Detecting Platform for Script Selection
Check the user's OS to choose the right migration script variant:
- **Windows / PowerShell**: Use `.ps1` scripts (requires Az PowerShell module)
- **Linux / macOS / WSL / Bash**: Use `.sh` scripts (requires Azure CLI + jq)

If the OS is unclear, prefer the bash scripts — Azure CLI (`az rest`) works cross-platform and avoids the Az PowerShell module authentication requirement.

### Constructing ARM Resource IDs
Users will typically provide a cache name, resource group, and subscription. Construct the full ARM resource IDs as follows:

- **ACR source**: `/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Cache/Redis/<cacheName>`
- **AMR target**: `/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Cache/redisEnterprise/<cacheName>`

If the user only provides a cache name, use `az redis show -n <name> -g <rg> --query id -o tsv` to retrieve the full resource ID. If the subscription or RG is also unknown, use `az redis list --query "[?name=='<name>'].{id:id, rg:resourceGroup}" -o table` to find it.

### Validating SKU Recommendations
Before recommending an AMR SKU to the user, cross-check it against the valid SKU list in [AMR SKU Specs](references/amr-sku-specs.md). Never recommend a SKU that doesn't appear in that file. If the ideal capacity falls between two SKU sizes, recommend the next size up.

### Connection Changes Reminder
Always mention these when discussing migration — they require application changes:
- **TLS port**: ACR uses **6380** → AMR uses **10000**
- **Non-TLS**: ACR 6379 → not supported on AMR
- **DNS suffix**: `.redis.cache.windows.net` → `<region>.redis.azure.net`
- **Redis version**: 6 → 7.4

If the user is using the automated migration with DNS switching, the old hostname continues to work, but the port change still applies.

## Available Resources

> **Important**: Always use the provided scripts for pricing lookups and metrics retrieval. Do not craft custom API calls or scripts — the provided ones already handle tier-specific calculation logic (HA, shards, MRPP) and metric aggregation correctly. For metrics, use a default time range of **7 days** unless the user specifies otherwise.

### Documentation Access

> **Note**: Most migration guidance is already available in this skill's local reference files. Only use the MCP server to look up information not covered locally (e.g., latest release notes, region availability, or new features).

Use the Microsoft Learn MCP server to fetch up-to-date documentation:
- **MCP Endpoint**: `https://learn.microsoft.com/api/mcp`
- **Setup Guide**: See [MCP Server Configuration](references/mcp-server-config.md) for setup instructions (GitHub Copilot, Claude Desktop)
- Key documentation paths:
  - `/azure/azure-cache-for-redis/` - General Azure Redis documentation
  - `/azure/azure-cache-for-redis/managed-redis/` - AMR-specific documentation
  - `/azure/azure-cache-for-redis/cache-overview` - Product overview

### Azure CLI Command Reference
See [Azure CLI Commands](references/azure-cli-commands.md) for practical `az redis` examples to:
- List ACR caches in a subscription or resource group
- Extract cache details (region, SKU, shard count, replicas)
- Check persistence and geo-replication settings

### SKU Mapping Reference
See [SKU Mapping Guide](references/sku-mapping.md) for guidelines, ACR → AMR mapping tables, selection criteria, and decision matrix. For AMR SKU definitions (M, B, X, Flash series), see [AMR SKU Specs](references/amr-sku-specs.md).

### Dynamic Pricing Lookup
Once you've identified candidate SKUs, get real-time pricing with monthly cost calculations:

```powershell
# Windows PowerShell
.\scripts\get_redis_price.ps1 -SKU M10 -Region westus2
.\scripts\get_redis_price.ps1 -SKU M10 -Region westus2 -NoHA
.\scripts\get_redis_price.ps1 -SKU C3 -Region westus2 -Tier Standard
.\scripts\get_redis_price.ps1 -SKU P2 -Region westus2 -Shards 3 -Replicas 2

# Linux/Mac bash
./scripts/get_redis_price.sh M10 westus2
./scripts/get_redis_price.sh P2 westus2 --shards 3
```

**Script options**:
- `-NoHA` / `--no-ha` - Non-HA deployment (AMR only, 50% savings for dev/test)
- `-Shards N` / `--shards N` - Number of shards (ACR Premium clustered)
- `-Replicas N` / `--replicas N` - Replicas per primary (ACR Premium MRPP, default: 1)
- `-Currency X` / `--currency X` - Currency code (default: USD)

**SKUs supported**:
- ACR: C0-C6 (Basic/Standard - must specify tier), P1-P5 (Premium)
- AMR: M10-M2000, B0-B1000, X3-X700, A250-A4500

**Resources**:
- [Pricing Tier Rules](references/pricing-tiers.md) - Calculation logic for HA, clustering, MRPP
- [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/?service=managed-redis) - Official quotes

### Feature Comparison
See [Feature Comparison](references/feature-comparison.md) for detailed comparison between ACR (Basic/Standard/Premium) and AMR features.

### Retirement FAQ
See [Retirement FAQ](references/retirement-faq.md) for retirement dates, timelines, and common migration questions.

**Relevant to this skill (ACR Basic/Standard/Premium)**:
- **Basic/Standard/Premium**: Retire September 30, 2028

**Not covered by this skill**:
- Enterprise/Enterprise Flash retirement (March 31, 2027) - contact Microsoft support

### Migration Overview
See [Migration Overview](references/migration-overview.md) for detailed migration guidance including:
- Migration strategies (new cache, RDB export/import, dual-write, RIOT)
- Connection string changes
- Clustering policy and network isolation considerations

## Migration Workflow

### Step 1: Assess Current Cache
Gather metrics from the existing ACR cache to inform SKU selection:

```powershell
# Windows PowerShell
.\scripts\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name>
.\scripts\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name> -Days 7

# Linux/Mac bash
./scripts/get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName>
./scripts/get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName> 7
```

Also retrieve the actual memory reservation to determine true usable capacity (defaults in the SKU mapping tables assume ~20%):

```bash
az redis show -n <cache-name> -g <resource-group> -o json \
  --query "{maxfragmentationmemoryReserved: redisConfiguration.maxfragmentationmemoryReserved, maxmemoryReserved: redisConfiguration.maxmemoryReserved}"
```

Both values are in MB. **Actual Usable = SKU Capacity − (maxmemoryReserved + maxfragmentationmemoryReserved)**. Use this as the source of truth for sizing.

**Requires**: Azure CLI logged in (`az login`)

> **Fallback**: If the scripts fail (e.g., locked tenant, insufficient permissions, no CLI access), direct the user to retrieve the same metrics manually from the **Azure Portal** under their cache's **Monitoring → Metrics** blade.

**Metrics retrieved** (Peak, P95, and Average for each):
- Used Memory RSS (bytes and GB)
- Server Load (%)
- Connected Clients
- Network Bandwidth — Cache Read and Cache Write (bytes/sec)

Use these values to:
1. Size the target AMR SKU (usable memory ≥ peak used memory — no extra buffer needed with an eviction policy)
2. Choose tier (high Server Load + low memory → Compute Optimized X-series)
3. Verify connection limits are sufficient
4. Use P95 values to distinguish sustained load from occasional spikes

### Step 2: Select Target AMR SKU
1. Refer to the [SKU Mapping Guide](references/sku-mapping.md)
2. Use metrics from Step 1 to validate sizing
3. Get pricing for candidate SKUs:
   ```powershell
   .\scripts\get_redis_price.ps1 -SKU M20 -Region westus2
   .\scripts\get_redis_price.ps1 -SKU B20 -Region westus2
   ```

### Step 3: Plan Migration
1. Determine migration strategy (dual-write, snapshot/restore, etc.)
2. **Clustering policy**: For non-clustered ACR caches (Basic, Standard, non-clustered Premium), create the AMR cache with **Enterprise clustering policy** to avoid client application changes. OSS clustering policy exposes cluster topology and may require a cluster-aware client.
3. **Network isolation**: ACR caches using VNet injection must be replaced with **Private Link** on AMR, as AMR does not support VNet injection. Ensure Private Endpoints are configured before cutover.
4. Plan for potential downtime or data sync requirements
5. Update application connection strings and configuration

### Step 4: Execute Migration
1. Create the target AMR cache
2. Migrate data using appropriate method
3. Validate data integrity
4. Switch application traffic to new cache

---

## Automated Migration (ARM REST API)

Azure now offers an **automated migration path** from Azure Cache for Redis (ACR) to Azure Managed Redis (AMR) via ARM REST APIs. This handles DNS switching automatically so clients using the old OSS endpoint continue to work after migration. Two utility scripts wrap these APIs:

- **PowerShell** (`scripts/Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1`) — uses Az PowerShell module (`Invoke-AzRestMethod`)
- **Bash** (`scripts/azure-redis-migration-arm-rest-api-utility.sh`) — uses Azure CLI (`az rest`), works on Linux, macOS, and WSL

For detailed documentation on the underlying ARM API endpoints, request/response payloads, script architecture, behavioral differences, and troubleshooting, see [Migration Scripts Reference](references/migration-scripts.md).

> **Important**: This feature is currently in **Public Preview**. Use the manual migration strategies (Steps 1–4 above) for production workloads until GA, or if your cache falls outside the supported scope below.

### Supported Scope

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
- Entra ID configurations
- Auto-update schedules
- Custom ACL definitions
- Keyspace notifications
- User-assigned managed identities
- Data persistence configuration

### Prerequisites

#### PowerShell (Windows)

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

#### Bash (Linux / macOS / WSL)

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

### Automated Migration Workflow

The migration utility supports four actions: **Validate → Migrate → Status → Cancel (Rollback)**.

#### 1. Validate

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

Fix any errors before proceeding. Warnings can be bypassed with `-ForceMigrate $true` / `--force-migrate` if the user accepts the trade-offs. See [Validation Errors & Warnings Reference](references/migration-validation.md) for the full list.

#### 2. Migrate

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

#### 3. Check Status

Poll the migration status (only requires TargetResourceId):

```powershell
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Status" -TargetResourceId "<targetAMRResourceId>"
```

```bash
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Status --target "<targetAMRResourceId>"
```

#### 4. Cancel / Rollback

Cancel a failed or completed migration. Reverses DNS changes (~5+ minutes):

```powershell
.\scripts\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action "Cancel" -TargetResourceId "<targetAMRResourceId>"
# Add -TrackMigration to wait for completion
```

```bash
./scripts/azure-redis-migration-arm-rest-api-utility.sh --action Cancel --target "<targetAMRResourceId>"
# Add --track to wait for completion
```

### Script Parameters Reference

| PowerShell | Bash | Required | Description |
|-----------|------|----------|-------------|
| `-Action` | `--action`, `-a` | Yes | `Validate`, `Migrate`, `Status`, or `Cancel` |
| `-SourceResourceId` | `--source`, `-s` | Validate, Migrate | Full ARM resource ID of the source ACR cache (`Microsoft.Cache/Redis/<name>`) |
| `-TargetResourceId` | `--target`, `-t` | Always | Full ARM resource ID of the target AMR cache (`Microsoft.Cache/redisEnterprise/<name>`) |
| `-ForceMigrate $true` | `--force-migrate` | No | Bypass validation warnings (default: false) |
| `-TrackMigration` | `--track` | No | Wait for long-running operation to complete (default: off) |
| `-Environment` | — | No | Azure environment (default: `AzureCloud`). PowerShell only; bash uses whatever `az` is logged into |

### Portal Alternative

Automated migration is also available via the Azure Portal behind a feature flag:
- **Portal URL**: [https://aka.ms/redis/portal/prod/migrate](https://aka.ms/redis/portal/prod/migrate)
- Navigate to the source ACR cache → click **Migrate** → follow the wizard
- After completion, a link to the target AMR cache is displayed
- Use the **Rollback Migration** button to revert

### Validation Errors & Warnings

See [Validation Errors & Warnings Reference](references/migration-validation.md) for the full list of blocking errors and overridable warnings returned by the Validate action.

## Common Questions

### What is the difference between Azure Cache for Redis (ACR) and Azure Managed Redis (AMR)?
Refer to [Feature Comparison](references/feature-comparison.md) for the full matrix. Key differences include:
- AMR offers Redis Stack features (JSON, Search, Time Series, Bloom filters)
- AMR has different SKU tiers optimized for different workloads
- AMR provides enhanced performance and scalability options

### How do I choose the right AMR SKU?
Refer to [SKU Mapping Guide](references/sku-mapping.md) and consider:
- Current memory usage
- Compute pressure (Server Load %)
- Feature requirements (clustering, geo-replication, Redis modules)
- Budget constraints

### What features are not available in AMR?
Check [Feature Comparison](references/feature-comparison.md) for the current feature matrix. Use the MCP server to fetch the latest documentation for authoritative information.

### What about Enterprise tier migration?
**This skill does not cover Enterprise tier migrations.** If asked about ACRE (Azure Cache for Redis Enterprise) migration, inform the user that Enterprise tier has different considerations and they should consult Microsoft support or official documentation.

## Tips for Effective Migration

1. **Test thoroughly**: Always test in a non-production environment first
2. **Monitor performance**: Compare baseline metrics before and after migration
3. **Plan for rollback**: Have a rollback strategy in case of issues
4. **Update client libraries**: Ensure Redis client libraries support AMR features
5. **Review security settings**: Update firewall rules, private endpoints, and authentication
