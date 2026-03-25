---
name: amr-migration-skill
description: |
  Helps users migrate from Azure Cache for Redis (ACR/OSS) Basic, Standard, and Premium tiers
  to Azure Managed Redis (AMR). Provides SKU mapping, real-time pricing scripts, cache metrics
  assessment, automated migration via ARM REST APIs with DNS switching, and IaC template
  migration (ARM, Bicep, Terraform).
  Use when users ask about: Redis migration, ACR to AMR, OSS to AMR, automated migration,
  DNS switch migration, cache retirement deadline, ACR retirement date, SKU selection,
  AMR vs ACR features, feature compatibility, Redis module support, pricing comparison,
  cache upgrade, Basic/Standard/Premium tier migration, P1/P2/C3 cache migration,
  AMR SKU recommendation, migration rollback, migration validation, connection string changes,
  port changes, cache assessment and metrics, IaC template migration (ARM, Bicep, Terraform),
  or checking for amr-migration-skill updates.
  Do NOT use for: Enterprise (ACRE) tier migrations, creating new Redis caches, or general
  Redis performance tuning.
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

### Version Check (manual only — triggered by user request)
Do **not** check for updates automatically. Only perform a version check when the user explicitly asks (e.g., "check for updates for the amr skill", "is there a newer version of amr-migration-skill?").

When requested:
1. Read the local `VERSION` file in this skill's root directory.
2. Fetch the remote version from: `https://raw.githubusercontent.com/AzureManagedRedis/amr-migration-skill/main/VERSION`
3. If the remote version is newer, tell the user: _"A newer version of the AMR Migration Skill is available (local: X, latest: Y). Update from: https://github.com/AzureManagedRedis/amr-migration-skill"_
4. If versions match, tell the user: _"You're on the latest version (X)."_
5. If the fetch fails, tell the user the check failed and suggest trying again later.

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

### Infrastructure-as-Code (IaC) Template Migration
For converting ACR templates (ARM, Bicep, Terraform) to AMR format, use these reference docs:
- [ACR Template Parsing Guide](references/iac-acr-template-parsing.md) — How to read and extract configuration from ACR templates
- [AMR Template Structure Guide](references/iac-amr-template-structure.md) — Transformation rules, property mappings, and output structure for AMR templates
- [Example Templates](references/examples/iac/) — Before/after template pairs organized by format:
  - `arm/` — 6 ARM JSON scenarios (basic, premium non-clustered, clustered, VNet, persistence, all-features)
  - `arm-parameterized/` — 4 ARM JSON scenarios with separate parameter files
  - `bicep/` — 2 Bicep scenarios (basic, premium clustered)
  - `terraform/` — 2 Terraform scenarios (basic, premium clustered)

## Workflow Selection

**Choose the correct workflow based on the user's intent.** The two workflows are independent — do not mix their steps.

| User Intent | Signal Phrases | Workflow |
|---|---|---|
| Move a live cache to AMR | "migrate cache", "move to AMR", "select SKU", "assess metrics", "migration strategy", "switch traffic" | **Migration Workflow** (Steps 1-4) |
| Convert IaC templates to AMR format | "convert template", "Bicep migration", "ARM to AMR", "Terraform", "IaC", "template transformation", "region buildout" | **IaC Migration Workflow** (Steps 1-7) |
| Compare features or answer general questions | "compare ACR vs AMR", "feature compatibility", "retirement date", "best practices" | Answer directly using reference docs — no workflow needed |

### Ambiguous Requests

If the user's intent is unclear (e.g., "help me migrate to AMR" could mean either), ask:

> "Are you looking to **migrate a live cache** (data migration, SKU selection, traffic cutover) or **convert your infrastructure-as-code templates** (Bicep/ARM/Terraform) to AMR format? Or both?"

### Both Workflows

If the user needs both (e.g., "migrate everything including our IaC"):
1. Run **Migration Workflow** first — this determines the target AMR SKU and validates sizing with metrics
2. Then run **IaC Migration Workflow** — using the SKU selected in step 1 as the target

---

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

> **Clustered caches**: For Premium caches with multiple shards, the scripts automatically detect the shard count and aggregate metrics across all shards. Memory and bandwidth are **summed** (total capacity), while Server Load and Connected Clients report the **max per shard** (bottleneck value). The output header indicates when shard aggregation is active.

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

## IaC Migration Workflow

> For the full 7-step workflow, see [IaC Migration Workflow](references/iac-migration-workflow.md).

Converts ACR templates (ARM JSON, Bicep, Terraform) to AMR format using AI-driven transformation with reference docs for grounding. Includes SKU mapping, pricing comparison, feature gap analysis, customer confirmation gate, and template generation. Scripts are only used for pricing lookups.

---

## Automated Migration (ARM REST API)

Azure offers an **automated migration path** from ACR to AMR via ARM REST APIs, handling DNS switching automatically so clients using the old OSS endpoint continue to work after migration.

> **Important**: This feature is currently in **Public Preview**. Use the manual migration strategies (Steps 1–4 above) for production workloads until GA.

**Key facts:**
- Supported: All Basic/Standard/Premium SKUs — **except** Private Link, VNet injected, or Geo-Replicated caches
- Source and target must be in the **same region and subscription**
- Migrates: access keys, OSS host endpoint (DNS switch), OSS port. Does **not** migrate cache data, Entra ID, persistence config, or managed identities
- Workflow: **Validate → Migrate → Status → Cancel (Rollback)**
- Also available via the [Azure Portal](https://aka.ms/redis/portal/prod/migrate) behind a feature flag

**Scripts:**
- **PowerShell**: `scripts/Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1` (requires Az module)
- **Bash**: `scripts/azure-redis-migration-arm-rest-api-utility.sh` (requires Azure CLI + jq)

📖 For the full workflow, prerequisites, script parameters, and troubleshooting, read [Automated Migration Reference](references/automated-migration.md).
For ARM API internals, see [Migration Scripts Reference](references/migration-scripts.md).
For validation error codes, see [Validation Errors & Warnings](references/migration-validation.md).

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
