# Breaking Changes Reference

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

Azure Managed Redis (AMR) is the next generation of Azure Cache for Redis Enterprise. When a cache is migrated from ACRE to AMR, the underlying resource type stays the same (`Microsoft.Cache/redisEnterprise`), but several properties change significantly.

## Properties That Change

| Property | ACRE (Gen1) | AMR (Gen2) | Action Required |
|----------|-------------|------------|-----------------|
| `sku.name` | `Enterprise_E*` / `EnterpriseFlash_F*` | `Balanced_B*` / `MemoryOptimized_M*` / `ComputeOptimized_X*` / `FlashOptimized_A*` | **Change** to new SKU name |
| `sku.capacity` | Required (e.g., `2`, `4`, `6`) | Must be **omitted** | **Remove** property entirely |
| `zones` | Optional array (e.g., `["1","2","3"]`) | Must be **omitted** | **Remove** property entirely |
| Hostname (GET response) | `{name}.{region}.redisenterprise.cache.azure.net` | `{name}.{region}.redis.azure.net` | **Update** connection strings & DNS references |
| Private Link DNS zone | `privatelink.redisenterprise.cache.azure.net` | `privatelink.redis.azure.net` | **Update** Private DNS zone configs |
| Private Endpoint | Existing PE linked to old DNS zone | New PE needed linked to new DNS zone | **Recreate** PE — see [Private Endpoint Migration Strategies](#private-endpoint-migration-strategies) below |
| API version | Any | **`2025-07-01`** (recommended) | **Update** to `2025-07-01` |
| Scaling mechanism | Change `sku.capacity` and/or `sku.name` | Change `sku.name` only | **Rewrite** scaling logic |
| `accessKeysAuthentication` | Was `Enabled` by default | Now `Disabled` by default | **Add** `Enabled` explicitly if using access keys |
| `publicNetworkAccess` | Not required | **Mandatory** property | **Add** — set to `Disabled` if Private Link exists, or `Enabled` if public access is needed |

## Properties That Do NOT Change

| Property | Notes |
|----------|-------|
| ARM resource type | `Microsoft.Cache/redisEnterprise` — same for both |
| Database resource type | `Microsoft.Cache/redisEnterprise/databases` — same |
| Database port | `10000` — same default |
| `clientProtocol` | `Encrypted` / `Plaintext` — same |
| `clusteringPolicy` | `OSSCluster` / `EnterpriseCluster` — same (AMR adds `NoCluster` for small SKUs) |
| `evictionPolicy` | Same options |
| `persistence` | Same (AOF: `1s`/`always`, RDB: `1h`/`6h`/`12h`) |
| `modules` | Same module names and args |
| `geoReplication` | Same structure |

---

## DNS and Connection String Updates

| | ACRE (Gen1) | AMR (Gen2) |
|--|-------------|------------|
| **Public endpoint** | `{name}.{region}.redisenterprise.cache.azure.net` | `{name}.{region}.redis.azure.net` |
| **Private Link DNS zone** | `privatelink.redisenterprise.cache.azure.net` | `privatelink.redis.azure.net` |
| **Regional Private Link** | `{region}.privatelink.redisenterprise.cache.azure.net` | `{region}.privatelink.redis.azure.net` |

When analyzing scripts, search for these patterns that indicate hostname/DNS references needing updates:
- Hardcoded hostnames: `*.redisenterprise.cache.azure.net`
- Connection string construction building `{name}.{region}.redisenterprise.cache.azure.net`
- Private DNS zone names: `privatelink.redisenterprise.cache.azure.net`
- Environment variables or config files referencing the old hostname pattern

The default database port is **10000** for both ACRE and AMR. No port-related changes are needed.

### Post-Migration Dual Endpoints (In-Place Migration Only)

After an in-place migration, **both** the old ACRE endpoint (`*.redisenterprise.cache.azure.net`) and the new AMR endpoint (`*.redis.azure.net`) remain active and can be used to connect to the cache. However, we **recommend switching to the new AMR endpoint** as soon as possible. A future `unlinkMigratedEndpoint` API will allow you to fully decommission the old ACRE endpoint from the cache resource once all applications have migrated to the new endpoint.

---

## Private Endpoint Migration Strategies

When a cache has Private Link configured, the Private Endpoint must be recreated after migration because the DNS zone changes. Present **both options** and let the user choose:

**Option A: Sequential (simpler)** — Replace the old PE and DNS zone with new ones targeting `privatelink.redis.azure.net`. Deploy/run **after** the cache has been migrated. **Order**: (1) Migrate the cache. (2) Create new DNS zone + PE. (3) Update app connection string to AMR hostname (`*.redis.azure.net`). (4) Verify connectivity. (5) Delete old PE and old DNS zone.

**Option B: Coexist old + new PE (recommended for zero-downtime)** — Keep existing PE/DNS resources unchanged and add **new** resources alongside them for `privatelink.redis.azure.net` (new DNS zone, VNet link, new PE, DNS zone group). Both endpoints coexist during migration. **Order**: (1) Deploy with both old and new PE/DNS resources. (2) Migrate the cache. (3) New PE resolves via `privatelink.redis.azure.net` once migration completes. (4) Update app connection string to AMR hostname. (5) Verify connectivity through new PE. (6) Remove old PE resources and redeploy. (7) Manually delete old PE/DNS from Azure (ARM/Bicep incremental deployments do **not** delete resources removed from templates — use `az resource delete` or the portal).

The `groupIds` value (`redisEnterprise`) and the PE structure (subnet, service connection) stay the same — only the DNS zone linkage changes. See [examples.md](examples.md) for full before/after code showing both options.

---

## API Version Guidance

| API Version | Status | Notes |
|-------------|--------|-------|
| **`2025-07-01`** | **GA (recommended)** | Recommended version for AMR. Requires `publicNetworkAccess` and defaults `accessKeysAuthentication` to `Disabled` |
| `2025-04-01` | GA | First GA version supporting Gen2 SKUs. Does not require `publicNetworkAccess`; `accessKeysAuthentication` defaults to `Enabled` |
| `2024-09-01-preview` | Preview | First preview supporting Gen2 SKUs, Entra ID auth |

**Always recommend `2025-07-01`** as the target API version for migrated scripts. This ensures:
- `publicNetworkAccess` is explicitly set (mandatory) — improves security posture
- `accessKeysAuthentication` default is `Disabled` — aligns with zero-trust best practices
- If the application uses access keys, explicitly set `accessKeysAuthentication: Enabled` in the database properties
- Set `publicNetworkAccess` to `Disabled` on the cluster if Private Link is configured (unless public access is intentionally needed). Set to `Enabled` if public access is needed.
