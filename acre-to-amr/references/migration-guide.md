# Generic Migration Guide

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

When the user asks for a **step-by-step process**, **migration guide**, **flowchart**, or **general overview** of ACRE → AMR migration — without requesting hands-on execution against their subscription — present the following recommended migration process. **Do NOT execute any commands or access the user's Azure subscription in this mode.**

## How to Present This Guide

- Present the guide as a clear, numbered step-by-step process the user can follow on their own
- Include both the **standalone cache** path and the **geo-replicated cache** path
- Highlight key decision points and prerequisites
- Reference the [Breaking Changes](breaking-changes.md) and [SKU mapping table](sku-resolution.md#default-migration-mapping-fallback) for details
- At the end, offer to switch to **Interactive Cache Migration mode** (hands-on) or **Automation Script Update mode** (script analysis)

## Recommended Migration Process — Overview

Present this high-level overview first, then expand on the relevant path based on user questions:

```
┌─────────────────────────────────────────────┐
│         ACRE → AMR Migration Process        │
└──────────────────────┬──────────────────────┘
                       │
         ┌─────────────▼─────────────┐
         │  Step 1: Inventory &      │
         │  Assess ACRE Caches       │
         └─────────────┬─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │  Step 2: Determine Target │
         │  AMR SKU (listSkusFor-    │
         │  Scaling API or mapping)  │
         └─────────────┬─────────────┘
                       │
         ┌─────────────▼─────────────┐
         │  Step 3: Check Geo-       │
         │  Replication Status       │
         └─────────┬─────────────┬───┘
                   │             │
          Not geo- │             │ Geo-replicated
          replicated│            │
         ┌─────────▼──────┐  ┌──▼────────────────┐
         │  Path A:       │  │  Path B:           │
         │  In-Place      │  │  Create-New-and-   │
         │  Migration     │  │  Swap Migration    │
         └─────────┬──────┘  └──┬─────────────────┘
                   │            │
         ┌─────────▼──────┐  ┌──▼────────────────┐
         │  Step 4: Post- │  │  Step 4: Post-     │
         │  Migration     │  │  Migration         │
         │  Validation    │  │  Validation        │
         └─────────┬──────┘  └──┬─────────────────┘
                   │            │
         ┌─────────▼────────────▼─────────────────┐
         │  Step 5: Update DNS, Connection        │
         │  Strings, Private Endpoints & Scripts  │
         └────────────────────────────────────────┘
```

---

## Step 1 — Inventory and Assess Your ACRE Caches

Before starting migration, take inventory of all your ACRE caches:

1. **List all Redis Enterprise caches** in your subscription:
   ```
   az redisenterprise list --query "[].{name:name, resourceGroup:resourceGroup, location:location, sku:sku.name, capacity:sku.capacity, publicNetworkAccess:publicNetworkAccess, privateEndpointConnections:privateEndpointConnections}" -o table
   ```
2. **Identify ACRE (Gen1) caches** — these have SKUs starting with `Enterprise_` or `EnterpriseFlash_` and a non-null `capacity` value.
3. **For each ACRE cache, note**:
   - Cache name, resource group, region
   - Current SKU and capacity (e.g., `Enterprise_E5`, capacity `2`)
   - Whether Private Endpoints are configured
   - Whether `publicNetworkAccess` is `Enabled` or `Disabled`
   - Database configuration: modules, persistence, clustering policy, eviction policy

## Step 2 — Determine the Target AMR SKU

For each ACRE cache, determine the equivalent AMR SKU:

1. **Preferred method — Call `listSkusForScaling` API** on the existing ACRE cluster:
   ```
   az rest --method post --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{cacheName}/listSkusForScaling?api-version=2025-07-01"
   ```
   This returns the list of AMR SKUs that the cache can be migrated to. Choose the SKU that best matches your current capacity and workload requirements.

2. **Fallback — Use the default mapping table** if the API is unavailable. See [SKU Resolution — Default Mapping](sku-resolution.md#default-migration-mapping-fallback) for the ACRE SKU + capacity → AMR SKU mapping.

## Step 3 — Check Geo-Replication Status

For each ACRE cache, check whether it is part of a geo-replication group:

```
az rest --method get --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{cacheName}/databases/default?api-version=2025-07-01" --query "properties.geoReplication" -o json
```

- **If `geoReplication` is null or empty** → the cache is **standalone**. Use **Path A: In-Place Migration**.
- **If `geoReplication.linkedDatabases` has entries** → the cache is **geo-replicated**. Use **Path B: Create-New-and-Swap Migration**.

---

## Path A — In-Place Migration (Standalone Caches)

For standalone (non-geo-replicated) ACRE caches, the SKU can be updated in-place. This is the simplest migration path.

**Summary**: Set the mandatory `amr-migration-data-preserve` tag → execute in-place SKU change via REST API → verify migration → update Private Endpoint if applicable → update application connection strings.

> **Mandatory pre-migration tag**: You **must** add the resource tag `amr-migration-data-preserve` to the ACRE cache before migration. `False` (recommended) = data cleaned up, faster migration. `True` = data preserved. The API will reject the request without this tag.

> **⚠️ No rollback**: In-place migration to AMR **cannot be rolled back** to ACRE once completed. See [connection impact, rollback alternatives, and scheduling guidance](interactive-migration.md#step-2--execute-in-place-migration) before proceeding.

**For detailed step-by-step commands and confirmation gates**, see [interactive-migration.md — Phase 2A](interactive-migration.md#phase-2a--in-place-migration-standalone-caches).

## Path B — Create-New-and-Swap Migration (Geo-Replicated Caches)

For geo-replicated ACRE caches, in-place SKU migration is **NOT supported**. Instead, create a new AMR cache with the target SKU (from `listSkusForScaling`), add it to the geo-replication group, switch application traffic, then remove the old ACRE cache. Repeat for each ACRE member until the entire group is migrated.

> **Why?** In-place SKU change on a geo-replicated cache member is blocked by the platform. The group supports a temporary mixed state (ACRE + AMR members) to enable rolling migration.

### Mixed-Group Constraints

During rolling migration, the group enters a mixed ACRE+AMR state with restrictions on scaling and membership. See [interactive-migration.md — Mixed-Group Constraints](interactive-migration.md#mixed-group-constraints) for the detailed constraints table.

**Summary** (for each ACRE cache, one at a time): Pick a member → create new AMR cache in same region → create matching database → add to geo-replication group → set up PE if needed → update application → verify → remove old cache from group → delete old cache → repeat.

**Rollback**: If issues arise after adding the new AMR cache but before deleting the old, switch the app back and force-unlink the new cache from the group.

**For detailed step-by-step commands and confirmation gates**, see [interactive-migration.md — Phase 2B](interactive-migration.md#phase-2b--geo-replicated-migration).

---

## Step 4 — Post-Migration Validation

After completing migration (either Path A or Path B), verify:

1. **SKU** — Confirm all migrated caches show Gen2 AMR SKUs (`Balanced_*`, `MemoryOptimized_*`, `ComputeOptimized_*`, or `FlashOptimized_*`)
2. **Hostname** — Verify hostnames have changed to `*.redis.azure.net`
3. **Database** — Confirm database configuration (modules, persistence, clustering, eviction) is preserved
4. **Connectivity** — Test application connectivity to the new endpoints
5. **Geo-replication** (if applicable) — Verify all group members show `Linked` state
6. **Access keys** — If using access keys, verify `accessKeysAuthentication` is `Enabled`

## Step 5 — Update DNS, Connection Strings, Private Endpoints, and Automation Scripts

For the full list of property changes, see [breaking-changes.md](breaking-changes.md). Key updates:
- **Hostnames**: `*.redisenterprise.cache.azure.net` → `*.redis.azure.net`
- **Private DNS zone**: `privatelink.redisenterprise.cache.azure.net` → `privatelink.redis.azure.net`
- **Private Endpoint**: must be recreated — see [PE Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies)
- **API version**: update to `2025-07-01`
- **Remove**: `sku.capacity`, `zones`
- **Add**: `publicNetworkAccess` (mandatory), `accessKeysAuthentication: Enabled` (if using access keys)

**Update your automation scripts** (ARM, Bicep, CLI, PowerShell) per the [Per-Script Checklists](checklists.md).

---

## Key Considerations

- **Port**: The default database port is **10000** for both ACRE and AMR. No port changes needed.
- **ARM resource type**: Stays the same — `Microsoft.Cache/redisEnterprise` for both ACRE and AMR.
- **Data preservation**: Both in-place migration and create-new-and-swap (via geo-replication sync) preserve your data.
- **Connection impact**: In-place migration causes a brief connection blip (similar to regular Azure maintenance). Most Redis client libraries handle this automatically via built-in reconnect logic — no application changes needed. See [interactive-migration.md — Step 2](interactive-migration.md#step-2--execute-in-place-migration) for details.
- **No rollback for in-place migration**: Once completed, in-place migration **cannot be rolled back** to ACRE. If you need **rollback flexibility and full control** over the migration process, consider creating a separate new AMR cache, switching traffic to it, verifying, and only then decommissioning the old ACRE cache. This alternative is recommended when rollback capability is a priority — it is NOT needed to avoid the brief connection blip, which is handled automatically by client reconnect logic. For geo-replicated caches, the create-new-and-swap approach inherently provides rollback capability before deleting the old ACRE cache. See [interactive-migration.md — Step 2](interactive-migration.md#step-2--execute-in-place-migration) for details.
- **Scaling**: AMR removes `sku.capacity`. Scaling is done entirely by changing `sku.name` to a different size tier.
- **Geo-replication mixed group**: See [interactive-migration.md — Mixed-Group Constraints](interactive-migration.md#mixed-group-constraints) for limits during rolling migration.

---

**Want hands-on help?** If you'd like me to discover your ACRE caches and walk you through the migration interactively, just say "migrate my caches" or share your subscription details. If you have automation scripts (ARM, Bicep, CLI, PowerShell) that need updating, share them and I'll produce a tailored checklist of changes.
