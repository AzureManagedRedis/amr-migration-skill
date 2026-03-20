# IaC Migration Test Cases

Test cases for validating the AI-driven IaC migration workflow (ACR → AMR template conversion).

Source/expected files are organized under `references/examples/iac/` by format:
- `arm/` — ARM JSON with inline values
- `arm-parameterized/` — ARM JSON with separate parameter files
- `bicep/` — Bicep format

---

## How to Test

1. Invoke the `amr-migration-skill`
2. Ask: *"Convert this ACR template to AMR: `<path-to-source-file>`"*
   - For parameterized tests, provide both files: *"...template `<template>` with parameters file `<params>`"*
3. Verify the AI follows the **7-step IaC Migration Workflow** (Parse → SKU → Pricing → Gaps → ⛔ Gate → Generate → Present)
4. Compare generated output against the expected `amr*.json` file in the same directory

### Universal Validations (apply to every test)

**Resource structure:**
- [ ] Resource split: `Microsoft.Cache/redis` → `redisEnterprise` cluster + `databases/default`
- [ ] API version: `2025-07-01`
- [ ] SKU uses compound name format (e.g., `Balanced_B5`) — no `capacity` field
- [ ] No `zones` property on cluster resource (AMR auto-manages zone redundancy)
- [ ] `publicNetworkAccess` present on cluster resource (required in `2025-07-01`) — preserve from source, default `"Enabled"`

**Database properties:**
- [ ] `clientProtocol: "Encrypted"`, `port: 10000`
- [ ] Eviction policy converted to PascalCase
- [ ] Clustering policy explicitly set (`EnterpriseCluster` or `OSSCluster`)

**Workflow:**
- [ ] Confirmation gate presented before generating template
- [ ] Pricing comparison shown (source vs target, monthly cost, delta)

**Removed properties:**
- [ ] `enableNonSslPort`, `redisVersion`, `aad-enabled`
- [ ] `shardCount` (AMR does not expose sharding)
- [ ] `replicasPerPrimary`, `maxmemoryReserved`, `maxfragmentationmemoryReserved`

**Preserved properties:**
- [ ] `name`, `location`, `tags`, `identity` (type + userAssignedIdentities, NOT principalId/tenantId), `minimumTlsVersion`

**Noted in output:**
- [ ] Connection string change: `*.redis.cache.windows.net:6380` → `*.<region>.redis.azure.net:10000`

---

## Concrete Template Tests

These use hardcoded values (no parameters file).

### TC-01: Basic C3 — Simplest Cache

| Field | Value |
|---|---|
| **Source** | `arm/basic-c3/acr.json` |
| **Expected** | `arm/basic-c3/amr.json` |
| **ACR Config** | Basic C3 (6 GB), `noeviction`, SystemAssigned identity, no Premium features |

**Validations:**
- [ ] SKU → `Balanced_B5`
- [ ] Eviction: `noeviction` → `NoEviction`
- [ ] Removes `enableNonSslPort`, `redisVersion`, `aad-enabled`
- [ ] `publicNetworkAccess: "Enabled"` on cluster (source was `Enabled`)
- [ ] Preserves `identity.type: "SystemAssigned"` on cluster resource
- [ ] Preserves tags
- [ ] No persistence, no VNet in output

---

### TC-02: Premium P1 Non-Clustered

| Field | Value |
|---|---|
| **Source** | `arm/premium-nonclustered/acr.json` |
| **Expected** | `arm/premium-nonclustered/amr.json` |
| **ACR Config** | Premium P1 (6 GB), `shardCount: 0`, `publicNetworkAccess: Enabled`, zones [1,2,3] |

**Validations:**
- [ ] SKU → `Balanced_B5`
- [ ] Clustering: `EnterpriseCluster` (shardCount=0 means non-clustered — omit from output)
- [ ] `publicNetworkAccess: "Enabled"` on cluster resource
- [ ] Source zones `["1","2","3"]` NOT carried to AMR output (auto-managed)
- [ ] No persistence or VNet resources generated

---

### TC-03: Premium P2 × 3 Shards + RDB Persistence

| Field | Value |
|---|---|
| **Source** | `arm/premium-clustered/acr.json` |
| **Expected** | `arm/premium-clustered/amr.json` |
| **ACR Config** | Premium P2 (13 GB) × 3 shards, RDB backup every 60 min, UserAssigned identity, zones [1,2,3] |

**Validations:**
- [ ] SKU → `Balanced_B50` (13 GB × 3 shards = 39 GB)
- [ ] RDB: `rdb-backup-frequency: "60"` → `rdbFrequency: "1h"`
- [ ] `rdb-storage-connection-string` removed (AMR manages persistence storage)
- [ ] Clustering decision: default `EnterpriseCluster` unless user confirms cluster-aware client
- [ ] Source zones NOT carried to AMR output
- [ ] Identity: source `"SystemAssigned, UserAssigned"` → preserved as-is on cluster. `userAssignedIdentities` preserved (without `principalId`/`tenantId`)
- [ ] `preferred-data-persistence-auth-method` and `storage-subscription-id` removed

---

### TC-04: Premium P2 + VNet Injection

| Field | Value |
|---|---|
| **Source** | `arm/premium-vnet/acr.json` |
| **Expected** | `arm/premium-vnet/amr.json` |
| **ACR Config** | Premium P2 (13 GB) + `subnetId` (VNet injection), firewall rules, `staticIP`, `shardCount: 0` |

**Validations:**
- [ ] SKU → `Balanced_B10` (Premium P2 = 13 GB)
- [ ] VNet injection → Private Endpoint resource generated
- [ ] `subnetId` removed from cache, used for Private Endpoint subnet
- [ ] `staticIP` removed (not applicable with Private Endpoint)
- [ ] Firewall rules removed with warning: *"not supported in AMR, use Private Endpoint + NSG"*
- [ ] DNS zone: `privatelink.redis.azure.net` (NOT `privatelink.redisenterprise.cache.azure.net`)
- [ ] `groupIds: ["redisEnterprise"]` (NOT `["redisCache"]`)
- [ ] `privateLinkServiceId` references `Microsoft.Cache/redisEnterprise`
- [ ] `publicNetworkAccess: "Disabled"` on cluster resource (source had `"Disabled"`)
- [ ] `shardCount: 0` in source treated as non-clustered, not included in output

---

### TC-05: Premium P2 + AOF Persistence

| Field | Value |
|---|---|
| **Source** | `arm/premium-persistence/acr.json` |
| **Expected** | `arm/premium-persistence/amr.json` |
| **ACR Config** | Premium P2 (13 GB), AOF persistence, `allkeys-lfu`, SystemAssigned + UserAssigned identity |

**Validations:**
- [ ] SKU → `Balanced_B10` (Premium P2 = 13 GB)
- [ ] Eviction: `allkeys-lfu` → `AllKeysLFU`
- [ ] AOF: → `aofEnabled: true`, `aofFrequency: "1s"` on database persistence
- [ ] `aof-storage-connection-string-0` removed
- [ ] `preferred-data-persistence-auth-method` and `storage-subscription-id` removed
- [ ] No RDB properties in output
- [ ] Identity: `SystemAssigned, UserAssigned` → preserved as-is on cluster

---

### TC-06: Premium P2 Kitchen Sink (All Features)

| Field | Value |
|---|---|
| **Source** | `arm/premium-all-features/acr.json` |
| **Expected** | `arm/premium-all-features/amr.json` |
| **ACR Config** | Clustering + RDB + VNet + zones + UserAssigned identity + tags — everything combined |

**Validations:**
- [ ] All individual transformations applied correctly together
- [ ] Private Endpoint generated (from VNet)
- [ ] Persistence converted (RDB)
- [ ] Source zones NOT carried to AMR output
- [ ] Identity preserved (type + userAssignedIdentities)
- [ ] No conflicting or duplicate properties
- [ ] `publicNetworkAccess: "Disabled"` on cluster resource (source had `"Disabled"` due to VNet + firewall)

---

## Parameterized Template Tests

These have separate template + parameters files. The AI must read **both** files.

### TC-07: Param — Standard C2 (Dev/Test)

| Field | Value |
|---|---|
| **Source Template** | `arm-parameterized/standard-c2/acr-cache.json` |
| **Source Params** | `arm-parameterized/standard-c2/acr-cache.parameters.json` |
| **Expected Template** | `arm-parameterized/standard-c2/amr-cache.json` |
| **Expected Params** | `arm-parameterized/standard-c2/amr-cache.parameters.json` |
| **ACR Config** | Standard C2 (6 GB), `allkeys-lru`, no Premium features |

**Validations:**
- [ ] Reads parameters file to determine actual SKU (Standard C2, not Premium default)
- [ ] SKU → `Balanced_B5`
- [ ] Eviction: `allkeys-lru` → `AllKeysLRU`
- [ ] Outputs **both** template + parameters files
- [ ] No Premium-only params in output (no persistence, VNet, shardCount)
- [ ] `_removedParams` metadata in output params file
- [ ] Clean parameter set: only AMR-relevant params remain

---

### TC-08: Param — Premium P1 Non-Clustered

| Field | Value |
|---|---|
| **Source Template** | `arm-parameterized/premium-nonclustered/acr-cache.json` |
| **Source Params** | `arm-parameterized/premium-nonclustered/acr-cache.parameters.json` |
| **Expected Template** | `arm-parameterized/premium-nonclustered/amr-cache.json` |
| **Expected Params** | `arm-parameterized/premium-nonclustered/amr-cache.parameters.json` |
| **ACR Config** | Premium P1 (6 GB), `shardCount: 0`, `publicNetworkAccess: Disabled`, `volatile-ttl`, zones |

**Validations:**
- [ ] Reads `shardCount: 0` from params → confirms non-clustered
- [ ] SKU → `Balanced_B5` (not B50 — no shards)
- [ ] `publicNetworkAccess: "Disabled"` preserved in output params
- [ ] Eviction: `volatile-ttl` → `VolatileTTL`
- [ ] `maxmemoryReserved` and `maxfragmentationmemoryReserved` removed from output params
- [ ] Source zones NOT carried to AMR output params
- [ ] Outputs both template + parameters files

---

### TC-09: Param — Premium P1 + VNet + Firewall Rules

| Field | Value |
|---|---|
| **Source Template** | `arm-parameterized/premium-vnet/acr-cache.json` |
| **Source Params** | `arm-parameterized/premium-vnet/acr-cache.parameters.json` |
| **Expected Template** | `arm-parameterized/premium-vnet/amr-cache.json` |
| **Expected Params** | `arm-parameterized/premium-vnet/amr-cache.parameters.json` |
| **ACR Config** | Premium P1, `subnetId` + `staticIP` in params, 1 firewall rule, `Disabled` public access |

**Validations:**
- [ ] `subnetId` param → replaced by `privateEndpointSubnetId` param
- [ ] `staticIP` param removed entirely
- [ ] `firewallRules` param removed with warning
- [ ] Private Endpoint resource generated in template
- [ ] DNS zone: `privatelink.redis.azure.net`
- [ ] `groupIds: ["redisEnterprise"]`
- [ ] `_networkingNote` metadata in output params explaining VNet→PE migration
- [ ] `privateDnsZoneId` param added in output
- [ ] `publicNetworkAccess: "Disabled"` on cluster resource (source had `"Disabled"`)
- [ ] Outputs both template + parameters files

---

### TC-10: Param — Premium P2 × 3 Shards + RDB + Firewall + KeyVault

| Field | Value |
|---|---|
| **Source Template** | `arm-parameterized/premium-clustered/acr-cache.json` |
| **Source Params** | `arm-parameterized/premium-clustered/acr-cache.parameters.json` |
| **Expected Template** | `arm-parameterized/premium-clustered/amr-cache.json` |
| **Expected Params** | `arm-parameterized/premium-clustered/amr-cache.parameters.json` |
| **ACR Config** | Premium P2 × 3 shards, RDB 60 min, KeyVault ref for storage, 2 firewall rules, zones, memory reserved |

**Validations:**
- [ ] Params override template defaults: `shardCount: 3` (not default 0) determines SKU
- [ ] SKU → `Balanced_B50` (13 GB × 3 = 39 GB)
- [ ] RDB: frequency 60 → `1h`, storage connection string removed
- [ ] KeyVault reference for `rdbStorageConnectionString` → removed gracefully (not error)
- [ ] Firewall rules warned and removed
- [ ] `maxmemoryReserved: "642"` removed from output params
- [ ] Outputs **both** template + parameters files
- [ ] `_removedParams` metadata documents all removed params with reasons
- [ ] Conditional resources from template (patchSchedules, geoReplication) handled correctly

---

## Bicep Template Tests

### TC-11: Bicep Basic C3

| Field | Value |
|---|---|
| **Source** | `bicep/basic-c3/acr.bicep` |
| **Expected** | `bicep/basic-c3/amr.bicep` |
| **ACR Config** | Basic C3 in Bicep syntax |

**Validations:**
- [ ] Output is **Bicep format** (not ARM JSON)
- [ ] Uses Bicep resource declaration syntax
- [ ] Proper parent/child relationship for database resource
- [ ] All property transformations match ARM equivalents

---

### TC-12: Bicep Premium Clustered + RDB

| Field | Value |
|---|---|
| **Source** | `bicep/premium-clustered/acr.bicep` |
| **Expected** | `bicep/premium-clustered/amr.bicep` |
| **ACR Config** | Premium P2 × 3 shards + RDB in Bicep syntax |

**Validations:**
- [ ] Bicep parent/child resource syntax for cluster + database
- [ ] RDB persistence conversion in Bicep syntax
- [ ] SKU → `Balanced_B50`
- [ ] All Bicep-specific patterns preserved (no ARM JSON artifacts)

---

### TC-13: Terraform Basic C3

| Field | Value |
|---|---|
| **Source** | `terraform/basic-c3/acr.tf` |
| **Expected** | `terraform/basic-c3/amr.tf` |
| **ACR Config** | Basic C3, noeviction, SystemAssigned identity |

**Validations:**
- [ ] Resource type: `azurerm_redis_cache` → `azurerm_redis_enterprise_cluster` + `azurerm_redis_enterprise_database`
- [ ] SKU → `Balanced_B5`
- [ ] Eviction: `noeviction` → `NoEviction`
- [ ] Clustering: `EnterpriseCluster`
- [ ] Identity preserved (SystemAssigned)
- [ ] Removed: `enable_non_ssl_port`, `redis_version`, `redis_configuration` block
- [ ] Output: `ssl_port` removed, `hostname` updated to `.redis.azure.net`

---

### TC-14: Terraform Premium Clustered + RDB

| Field | Value |
|---|---|
| **Source** | `terraform/premium-clustered/acr.tf` |
| **Expected** | `terraform/premium-clustered/amr.tf` |
| **ACR Config** | Premium P2 × 3 shards + RDB persistence in Terraform syntax |

**Validations:**
- [ ] Resource split into cluster + database
- [ ] SKU → `Balanced_B50` (P2 × 3 shards = 39 GB)
- [ ] Clustering: `OSSCluster` (source had shard_count=3)
- [ ] RDB persistence: notes AzAPI provider required (azurerm does not support persistence on enterprise DB)
- [ ] Persistence shown as commented `azapi_update_resource` block with `rdbFrequency: "1h"`
- [ ] Storage connection string removed
- [ ] Identity preserved (`SystemAssigned, UserAssigned` + identity_ids)
- [ ] Zones removed
- [ ] Removed: `shard_count`, `maxmemory_reserved`, `maxfragmentationmemory_reserved`

---

## Test Coverage Matrix

| Feature | Concrete | Parameterized | Bicep | Terraform |
|---|---|---|---|---|
| Basic/Standard tier | TC-01 | TC-07 | TC-11 | TC-13 |
| Premium non-clustered | TC-02 | TC-08 | — | — |
| Premium clustered + RDB | TC-03 | TC-10 | TC-12 | TC-14 |
| VNet → Private Endpoint | TC-04 | TC-09 | — | — |
| AOF persistence | TC-05 | — | — | — |
| All features combined | TC-06 | — | — | — |
| Firewall rule removal | TC-04, TC-06 | TC-09, TC-10 | — | — |
| KeyVault reference | — | TC-10 | — | — |
| Identity preservation | TC-01, TC-03, TC-06 | TC-07, TC-08 | — | TC-13, TC-14 |
| publicNetworkAccess | TC-01, TC-02, TC-04, TC-06 | TC-08, TC-09 | — | — |
| shardCount: 0 handling | TC-02, TC-04 | TC-08 | — | — |
| Separate params file | — | TC-07–TC-10 | — | — |
| No zones in AMR output | TC-02, TC-03, TC-06 | TC-08 | — | TC-14 |
| No sku.capacity in AMR | All (universal) | All (universal) | All (universal) | All (universal) |
