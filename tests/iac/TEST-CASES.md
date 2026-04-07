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
- [ ] Clustering policy: Omit `clusteringPolicy` if non-clustered source and target ≤ 24GB; otherwise set to `EnterpriseCluster` or `OSSCluster`

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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source non-clustered, target 6GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source shardCount=0, target 6GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source shardCount=0, target 13GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source non-clustered, target 13GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source non-clustered, target 6GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source shardCount=0, target 6GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source non-clustered, target 6GB ≤ 24GB)
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
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source non-clustered, target 6GB ≤ 24GB)

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
- [ ] Resource type: `azurerm_redis_cache` → `azurerm_managed_redis` (single resource)
- [ ] SKU → `Balanced_B5`
- [ ] Eviction: `noeviction` → `NoEviction`
- [ ] Clustering: Non-clustered (omit `clustering_policy` — source non-clustered, target 6GB ≤ 24GB)
- [ ] Identity preserved (SystemAssigned) via `identity` block
- [ ] Database config in `default_database` inline block (not separate resource)
- [ ] Removed: `enable_non_ssl_port`, `redis_version`, `redis_configuration` block, `minimum_tls_version`
- [ ] Output: `hostname` uses `azurerm_managed_redis.this.hostname` (computed)

---

### TC-14: Terraform Premium Clustered + RDB

| Field | Value |
|---|---|
| **Source** | `terraform/premium-clustered/acr.tf` |
| **Expected** | `terraform/premium-clustered/amr.tf` |
| **ACR Config** | Premium P2 × 3 shards + RDB persistence in Terraform syntax |

**Validations:**
- [ ] Resource type: `azurerm_redis_cache` → `azurerm_managed_redis` (single resource)
- [ ] SKU → `Balanced_B50` (P2 × 3 shards = 39 GB)
- [ ] Clustering: `EnterpriseCluster` (default; source had shard_count=3 but default is EnterpriseCluster)
- [ ] RDB persistence: `persistence_redis_database_backup_frequency = "1h"` in `default_database` block
- [ ] Storage connection string removed
- [ ] Identity preserved (`SystemAssigned, UserAssigned` + identity_ids)
- [ ] Zones removed
- [ ] Removed: `shard_count`, `maxmemory_reserved`, `maxfragmentationmemory_reserved`, `minimum_tls_version`

---

## Edge Case Tests

### TC-15: Standard C2 + enableNonSslPort (Non-TLS)

| Field | Value |
|---|---|
| **Source** | `arm/standard-nontls/acr.json` |
| **Expected** | `arm/standard-nontls/amr.json` |
| **ACR Config** | Standard C2 (6 GB), `enableNonSslPort: true`, `allkeys-lru` |

**Validations:**
- [ ] SKU → `Balanced_B5`
- [ ] Clustering: Non-clustered (omit `clusteringPolicy` — source non-clustered, target 6GB ≤ 24GB)
- [ ] Protocol: `enableNonSslPort: true` → `clientProtocol: "Plaintext"` (NOT `"Encrypted"`)
- [ ] Port: 10000 (always 10000 for AMR regardless of protocol)
- [ ] Eviction: `allkeys-lru` → `AllKeysLRU`
- [ ] `minimumTlsVersion` still preserved on cluster resource (independent of clientProtocol)
- [ ] `enableNonSslPort` removed from output

---

### TC-16: Premium P2 × 3 + Geo-Replication (linkedServers)

| Field | Value |
|---|---|
| **Source** | `arm/premium-georeplication/acr.json` |
| **Expected** | `arm/premium-georeplication/amr.json` |
| **ACR Config** | Premium P2 (13 GB) × 3 shards, passive geo-replication via `linkedServers` child resource |

**Validations:**
- [ ] SKU → `Balanced_B50` (13 GB × 3 shards = 39 GB)
- [ ] Clustering: `EnterpriseCluster` (source clustered, target > 24GB)
- [ ] `linkedServers` child resource removed entirely
- [ ] `geoReplication` property added to database resource with `groupNickname` and `linkedDatabases`
- [ ] `linkedDatabases` array includes self (primary) and the secondary cache database reference
- [ ] Metadata note explains passive → active-active conversion
- [ ] Link to geo-replication docs in metadata
- [ ] No persistence properties (persistence conflicts with active geo-replication)
- [ ] Zones removed from AMR output

---

### TC-17: Premium P3 Non-Clustered (>24GB Boundary)

| Field | Value |
|---|---|
| **Source** | `arm/premium-p3-nonclustered/acr.json` |
| **Expected** | `arm/premium-p3-nonclustered/amr.json` |
| **ACR Config** | Premium P3 (26 GB), non-clustered (no `shardCount`), `volatile-ttl`, SystemAssigned identity |

**Validations:**
- [ ] SKU → `Balanced_B20` (Premium P3 = 26 GB)
- [ ] Clustering: `EnterpriseCluster` (required — target 26GB > 24GB, even though source was non-clustered)
- [ ] Eviction: `volatile-ttl` → `VolatileTTL`
- [ ] This is the key boundary test: source has no `shardCount` (non-clustered) but target exceeds 24GB
- [ ] `maxmemory-reserved` and `maxfragmentationmemory-reserved` removed
- [ ] Identity preserved: `SystemAssigned`

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
| Identity preservation | TC-01, TC-03, TC-06, TC-17 | TC-07, TC-08 | — | TC-13, TC-14 |
| publicNetworkAccess | TC-01, TC-02, TC-04, TC-06 | TC-08, TC-09 | — | — |
| shardCount: 0 handling | TC-02, TC-04 | TC-08 | — | — |
| Separate params file | — | TC-07–TC-10 | — | — |
| No zones in AMR output | TC-02, TC-03, TC-06, TC-16 | TC-08 | — | TC-14 |
| No sku.capacity in AMR | All (universal) | All (universal) | All (universal) | All (universal) |
| enableNonSslPort → Plaintext | TC-15 | — | — | — |
| Geo-replication conversion | TC-16 | — | — | — |
| Non-clustered >24GB boundary | TC-17 | — | — | — |
