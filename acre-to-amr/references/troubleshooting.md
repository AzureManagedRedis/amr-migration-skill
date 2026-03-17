# Troubleshooting & FAQ

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

Common pitfalls and interactive Q&A patterns for ACRE→AMR migration.

---

## Common Pitfalls

These are the most frequent causes of deployment failures after ACRE→AMR migration:

### 1. Leaving `sku.capacity` in the template
**Error**: `"sku.capacity is not supported by SKU Balanced_B20"`
**Fix**: Remove the `capacity` property (or `--capacity` / `-SkuCapacity` parameter) entirely.

### 2. Leaving `zones` in the template
**Error**: `"zones not allowed for SKU Balanced_B20"`
**Fix**: Remove the `zones` property (or `--zones` / `-Zone` parameter) entirely. AMR manages zone redundancy automatically.

### 3. Using an old API version
**Error**: The Gen2 SKU name is not recognized as a valid SKU.
**Fix**: Update `apiVersion` to `2025-07-01` or later.

### 4. Not updating connection strings
**Symptom**: Application fails to connect after migration.
**Root cause**: Hostname changed from `*.redisenterprise.cache.azure.net` to `*.redis.azure.net`.
**Fix**: Update all connection strings, environment variables, and config files to use the new hostname. If using Private Link, also update the Private DNS zone.

### 5. Access keys stop working (API `2025-07-01`+)
**Symptom**: Application gets authentication errors after redeployment.
**Root cause**: Default for `accessKeysAuthentication` changed from `Enabled` to `Disabled` in API version `2025-07-01`+.
**Fix**: Explicitly add `"accessKeysAuthentication": "Enabled"` to the database properties.

### 6. Scaling scripts break
**Symptom**: Scaling automation fails with errors about invalid capacity.
**Root cause**: AMR does not use `sku.capacity` for scaling. Scaling is done by changing `sku.name`.
**Fix**: Rewrite scaling logic to change the SKU name (e.g., `Balanced_B20` → `Balanced_B50`) instead of changing capacity.

### 7. Private DNS zone mismatch
**Symptom**: Private endpoint connectivity fails.
**Root cause**: ACRE uses `privatelink.redisenterprise.cache.azure.net` but AMR uses `privatelink.redis.azure.net`.
**Fix**: See [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies).

### 8. Old Private Endpoint not replaced
**Symptom**: Private endpoint connectivity fails even after updating the DNS zone.
**Root cause**: The old PE is still linked to the old DNS zone. After migration, the hostname resolves under the new zone.
**Fix**: Create a new PE linked to `privatelink.redis.azure.net`, update app, verify, then delete old PE. See [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies) and [examples.md](examples.md).

### 9. Missing `publicNetworkAccess` (API `2025-07-01`+)
**Error**: Deployment fails because `publicNetworkAccess` is a mandatory property.
**Root cause**: In API version `2025-07-01` and later, `publicNetworkAccess` must be explicitly specified on the cluster resource. Older API versions did not require it.
**Fix**: Add `publicNetworkAccess` to the cluster properties. If the cache has Private Link configured, set to `"Disabled"` (unless it was explicitly enabled via Azure Portal or other means and you want to keep public access). Otherwise, set to `"Enabled"`.

### 10. Scaling blocked in mixed ACRE+AMR geo-replication group
**Symptom**: Scaling request fails on any cache in the geo-replication group.
**Root cause**: During rolling migration, the group contains both ACRE and AMR members. Scaling is blocked on **all** caches in the group until every member has been migrated to an AMR SKU.
**Fix**: Complete the migration for all remaining ACRE members in the group first, then retry the scaling operation. See [interactive-migration.md — Mixed-Group Constraints](interactive-migration.md#mixed-group-constraints).

### 11. Cannot add ACRE cache to geo-replication group after AMR member added
**Symptom**: Adding a new ACRE cache to an existing geo-replication group fails.
**Root cause**: Once the first AMR cache is added to an ACRE geo-replication group, only AMR caches can be added as new members. ACRE additions are blocked.
**Fix**: Create a new AMR cache instead of ACRE. If you need to add another member, it must use an AMR SKU.

### 12. Exceeded geo-replication group member limit during migration
**Symptom**: Adding a new cache to the geo-replication group fails with a member limit error.
**Root cause**: Normally a geo-replication group allows max 5 members. During migration (mixed ACRE+AMR), the limit is temporarily raised to 6. If you already have 6 members (e.g., 5 original + 1 new AMR), you must remove an old member before adding the next.
**Fix**: Complete the current member's migration (switch traffic, remove old ACRE cache from group, delete it) before starting the next member's migration.

---

## Interactive Q&A Patterns

When the user asks questions, respond according to these patterns:

### "What changes do I need for my ARM/Bicep/CLI/PowerShell script?"
→ Read the user's file, detect the script type, scan for Gen1 indicators, and produce the numbered checklist of changes with before/after examples for each item found.

### "What AMR SKU should I use to replace Enterprise_E10 with capacity 2?"
→ First, try calling the `listSkusForScaling` API on the existing ACRE cluster to get the exact list of valid AMR target SKUs. If the API is unavailable, fall back to the [default mapping table](sku-resolution.md#default-migration-mapping-fallback). Ask about workload requirements if multiple options exist. Suggest 1-2 options and explain the trade-offs.

### "Will my connection strings break?"
→ Yes — explain the DNS zone change from `redisenterprise.cache.azure.net` to `redis.azure.net`. The port (10000) stays the same. List all places in their script/config where the hostname might be referenced.

### "Do I need to change the resource type?"
→ No — `Microsoft.Cache/redisEnterprise` is the same for both ACRE and AMR. The database type `Microsoft.Cache/redisEnterprise/databases` is also unchanged.

### "What API version should I use?"
→ Recommend `2025-07-01` for production. This is the latest GA version supporting Gen2 SKUs and includes mandatory fields (`publicNetworkAccess`, `accessKeysAuthentication`). Explain that `accessKeysAuthentication` defaults to `Disabled` so it must be explicitly set to `Enabled` if using access keys.

### "What about my Private Link / Private Endpoint configuration?"
→ The Private Endpoint resource must be **recreated**. See [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies) for detailed steps. The `groupIds` value (`redisEnterprise`) and PE structure stay the same — only the DNS zone linkage changes.

### "My script uses parameters/variables for the SKU name — what should I do?"
→ Explain that the parameter values need to change but the parameter structure stays the same. Suggest updating the default value and any parameter files (`.parameters.json`) or variable definitions.

### "Will my application experience downtime during in-place migration?"
→ The in-place migration causes a brief **connection blip** similar to what applications experience during regular Azure maintenance operations. Most Redis client libraries (StackExchange.Redis, Jedis, redis-py, ioredis, etc.) handle this automatically via built-in reconnect logic — connections drop momentarily and re-establish on their own. No application changes are needed to handle this. If your client does not have automatic reconnect enabled, consider enabling it before migrating. **We recommend performing the migration during non-business hours or a scheduled maintenance window** to minimize any user-facing impact. Note: once the in-place migration completes, it **cannot be rolled back** to ACRE. If you need full rollback flexibility, consider creating a separate new AMR cache, switching traffic to it, verifying, and only then decommissioning the old ACRE cache.

### "Can I use NoCluster clustering policy with AMR?"
→ `NoCluster` is supported only on small AMR SKUs (single-node SKUs with ≤25GB memory per node) with API version `2025-05-01-preview` or `2025-07-01`+. For most migrations, keep the existing `OSSCluster` or `EnterpriseCluster` policy.

### "What are the constraints during geo-replicated cache migration?"
→ During rolling migration, the geo-replication group enters a **mixed ACRE+AMR state**. Key constraints: (1) Max 6 members (up from the normal 5) to accommodate the transitional member. (2) **No scaling** on any cache in the group until all members are AMR. (3) After the first AMR cache is added, only AMR caches can be added — no more ACRE. Recommend completing the migration for all members promptly. See [interactive-migration.md — Mixed-Group Constraints](interactive-migration.md#mixed-group-constraints).
