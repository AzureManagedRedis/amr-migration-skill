# Per-Script Checklists

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

For before/after code examples of each script type, see [examples.md](examples.md).
For SKU name mapping, see [sku-resolution.md](sku-resolution.md#default-migration-mapping-fallback).
For property changes (DNS, access keys, public network access, PE strategies), see [breaking-changes.md](breaking-changes.md).

---

## ARM Template Checklist

1. **`apiVersion`** — Change to `2025-07-01`
2. **`sku.name`** — Change from `Enterprise_*`/`EnterpriseFlash_*` to the appropriate AMR SKU (see [mapping table](sku-resolution.md#default-migration-mapping-fallback))
3. **`sku.capacity`** — **Remove entirely** from the template. AMR does not use capacity; the SKU name determines the size
4. **`zones`** — **Remove entirely**. AMR manages zone redundancy automatically
5. **Parameter file (`*.parameters.json`)** — If a companion parameters file exists, update it too:
   - Change `skuName` value from the Gen1 SKU (e.g., `Enterprise_E5`) to the target AMR SKU
   - **Remove** the `skuCapacity` parameter entry entirely
   - Update any other parameter values affected by the migration (e.g., if the parameters file overrides DNS-related values)
6. **DNS/hostname references** — Update any hardcoded references from `redisenterprise.cache.azure.net` to `redis.azure.net`
7. **Private Link DNS zone** — If the template creates a Private DNS Zone, change from `privatelink.redisenterprise.cache.azure.net` to `privatelink.redis.azure.net`
8. **Private Endpoint** — If the template creates a PE linked to the old DNS zone, present the two migration strategies from [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies). For ARM, note that incremental deployments do **not** delete removed resources — old PE/DNS must also be deleted manually. See [examples.md](examples.md) for full before/after code.
9. **`accessKeysAuthentication`** — Add `"accessKeysAuthentication": "Enabled"` if access keys are used (default is `Disabled` in `2025-07-01`+). See [breaking-changes.md](breaking-changes.md#properties-that-change).
10. **`publicNetworkAccess`** — **Mandatory**. See [breaking-changes.md](breaking-changes.md#properties-that-change) for guidance.
11. **Scaling logic** — If the template has conditions or parameters for scaling via `sku.capacity`, rewrite to scale by changing `sku.name` instead

---

## Bicep Template Checklist

1. **API version** in resource declaration — Change `@2023-11-01` (or current) to `@2025-07-01`
2. **`sku.name`** — Change to AMR SKU name
3. **`sku.capacity`** — **Remove** the `capacity:` line
4. **`zones`** — **Remove** the `zones:` line entirely
5. **Parameter file (`.bicepparam`)** — If a companion `.bicepparam` file exists, update it too:
   - Change the `skuName` param value from the Gen1 SKU (e.g., `'Enterprise_E5'`) to the target AMR SKU
   - **Remove** the `param skuCapacity` line entirely
   - Update any other param values affected by the migration
6. **Hostname references** — Update `redisenterprise.cache.azure.net` → `redis.azure.net` in any outputs, variables, or connection string constructions
7. **Private DNS zone resource** — If creating `Microsoft.Network/privateDnsZones`, change `privatelink.redisenterprise.cache.azure.net` → `privatelink.redis.azure.net`
8. **Private Endpoint** — If the template creates a PE linked to the old DNS zone, present the two migration strategies from [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies). Note that Bicep incremental deployments do **not** delete removed resources. See [examples.md](examples.md) for full code.
9. **`accessKeysAuthentication`** — Add `accessKeysAuthentication: 'Enabled'` if access keys are used (default is `Disabled` in `2025-07-01`+). See [breaking-changes.md](breaking-changes.md#properties-that-change).
10. **`publicNetworkAccess`** — **Mandatory**. See [breaking-changes.md](breaking-changes.md#properties-that-change) for guidance.
11. **Scaling parameters** — If using a parameter for `capacity`, remove it and use `sku.name` parameter for sizing instead

---

## Azure CLI Checklist

1. **`--sku`** — Change from `Enterprise_*`/`EnterpriseFlash_*` to AMR SKU name
2. **`--capacity`** — **Remove** this parameter entirely
3. **`--zones`** — **Remove** this parameter entirely
4. **Scaling commands** — If using `az redisenterprise update --capacity ...`, rewrite to use `--sku <new-sku-name>` instead
5. **`--public-network-access`** — **Mandatory**. Add `--public-network-access Disabled` if Private Link exists, or `Enabled` if public access is needed
6. **`--access-keys-authentication`** — Add `--access-keys-authentication Enabled` to database create if access keys are used (default is `Disabled`)
7. **Private Endpoint** — If the script creates a PE (`az network private-endpoint create`) linked to the old DNS zone, present the two migration strategies from [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies). See [examples.md](examples.md) for full code.
8. **Connection string scripts** — Update any hostname parsing logic from `redisenterprise.cache.azure.net` to `redis.azure.net`

---

## Azure PowerShell Checklist

1. **`-SkuName`** — Change from `Enterprise_*`/`EnterpriseFlash_*` to AMR SKU name
2. **`-SkuCapacity`** — **Remove** this parameter entirely
3. **`-Zone`** — **Remove** this parameter entirely
4. **Scaling scripts** — If using `Update-AzRedisEnterpriseCache -SkuCapacity ...`, rewrite to use `-SkuName <new-sku-name>` instead
5. **`-PublicNetworkAccess`** — **Mandatory**. Add `-PublicNetworkAccess Disabled` if Private Link exists, or `Enabled` if public access is needed
6. **`-AccessKeysAuthentication`** — Add `-AccessKeysAuthentication Enabled` to database create if access keys are used (default is `Disabled`)
7. **Private Endpoint** — If the script creates a PE (`New-AzPrivateEndpoint`) linked to the old DNS zone, present the two migration strategies from [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies). See [examples.md](examples.md) for full code.
8. **Connection string scripts** — Update hostname parsing from `redisenterprise.cache.azure.net` to `redis.azure.net`
