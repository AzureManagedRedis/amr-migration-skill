# AMR Template Structure — Output Generation Reference

This document is the AI agent's primary reference for **generating** Azure Managed Redis (AMR) infrastructure-as-code templates from extracted ACR configuration. It covers the AMR resource model, property mappings, transformation rules, and output formats (ARM JSON, Bicep, Terraform).

For **parsing** the source ACR template, see [iac-acr-template-parsing.md](iac-acr-template-parsing.md).
For SKU selection logic, see [sku-mapping.md](sku-mapping.md).
For feature parity details, see [feature-comparison.md](feature-comparison.md).

---

## 1. AMR Resource Model

One ACR resource (`Microsoft.Cache/redis`) becomes **two** AMR resources:

| # | Resource Type | API Version | Notes |
|---|---|---|---|
| 1 | `Microsoft.Cache/redisEnterprise` | `2025-07-01` | **Cluster** — SKU, location, identity, networking |
| 2 | `Microsoft.Cache/redisEnterprise/databases` | Same as cluster | **Database** — data-plane config (port, eviction, persistence) |

Key rules:
- The database name is **always** `default`.
- In ARM JSON, use `[concat(parameters('cacheName'), '/default')]` for the database name.
- The database resource **must** have `dependsOn` referencing the cluster.
- API version: **`2025-07-01`** (GA, required for `publicNetworkAccess` support). This is the minimum GA version that supports `publicNetworkAccess` as a required property. Do NOT use older preview versions for new deployments.

---

## 2. Cluster Resource Properties

### ARM JSON Skeleton

```json
{
  "type": "Microsoft.Cache/redisEnterprise",
  "apiVersion": "2025-07-01",
  "name": "[parameters('cacheName')]",
  "location": "[parameters('location')]",
  "sku": {
    "name": "[parameters('skuName')]"
  },
  "properties": {
    "minimumTlsVersion": "1.2",
    "publicNetworkAccess": "Enabled"
  },
  "identity": {},
  "tags": {}
}
```

### Cluster Property Rules

| Property | Rule |
|---|---|
| `sku.name` | Compound format like `Balanced_B50` — see [sku-mapping.md](sku-mapping.md) for full mapping from ACR tiers |
| `sku.family` | **Do NOT include** — AMR does not use this field |
| `sku.capacity` | **Do NOT include for B/M/X/A series** — capacity is encoded in the SKU name itself (e.g., `Balanced_B50` = 50GB). Only include `capacity` for Enterprise (E) and EnterpriseFlash (F) SKUs. |
| `identity.type` | Preserve from source (`SystemAssigned`, `UserAssigned`, `SystemAssigned,UserAssigned`) |
| `identity.userAssignedIdentities` | Preserve resource IDs from source |
| `identity.principalId` | **Do NOT copy** — generated at deploy time |
| `identity.tenantId` | **Do NOT copy** — generated at deploy time |
| `zones` | **Do NOT include** — AMR automatically provides zone redundancy in supported regions. Specifying `zones` will cause a deployment error. Always remove `zones` from the source template during migration. |
| `publicNetworkAccess` | **Required** in API version `2025-07-01`. Always include this property. Preserve from source if present; default to `"Enabled"` if source doesn't specify it. For VNet/Private Endpoint scenarios, use `"Disabled"`. |
| `minimumTlsVersion` | Preserve from source; default `"1.2"` |
| `tags` | Preserve as-is from source |
| `location` | Preserve as-is from source |

---

## 3. Database Resource Properties

### ARM JSON Skeleton

```json
{
  "type": "Microsoft.Cache/redisEnterprise/databases",
  "apiVersion": "2025-07-01",
  "name": "[concat(parameters('cacheName'), '/default')]",
  "dependsOn": [
    "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]"
  ],
  "properties": {
    "port": 10000,
    "clientProtocol": "Encrypted",
    "clusteringPolicy": "EnterpriseCluster",
    "evictionPolicy": "VolatileLRU"
  }
}
```

### Database Property Rules

| Property | Value | Notes |
|---|---|---|
| `port` | `10000` | **Always** 10000 — non-negotiable |
| `clientProtocol` | `"Encrypted"` | **Always** encrypted — AMR is TLS-only |
| `clusteringPolicy` | `"EnterpriseCluster"` or `"OSSCluster"` | See [Section 6](#6-clustering-policy-decision-matrix) |
| `evictionPolicy` | PascalCase value | See [Section 4](#4-eviction-policy-mapping) |
| `persistence` | Structured object | See [Section 5](#5-persistence-transformation); omit if source had no persistence |

---

## 4. Eviction Policy Mapping

Map the ACR `redisConfiguration.maxmemory-policy` (kebab-case string) to the AMR `evictionPolicy` (PascalCase enum):

| ACR Value (`maxmemory-policy`) | AMR Value (`evictionPolicy`) |
|---|---|
| `noeviction` | `NoEviction` |
| `allkeys-lru` | `AllKeysLRU` |
| `volatile-lru` | `VolatileLRU` |
| `allkeys-random` | `AllKeysRandom` |
| `volatile-random` | `VolatileRandom` |
| `volatile-ttl` | `VolatileTTL` |
| `allkeys-lfu` | `AllKeysLFU` |
| `volatile-lfu` | `VolatileLFU` |

**Default:** If the source value is `null`, absent, or an unresolvable parameter expression, use `VolatileLRU`.

---

## 5. Persistence Transformation

ACR stores persistence as flat config strings inside `redisConfiguration`. AMR uses a structured `persistence` object on the database resource.

### RDB Persistence

**Source** (flat strings in `redisConfiguration`):
```json
"rdb-backup-enabled": "true",
"rdb-backup-frequency": "360",
"rdb-storage-connection-string": "DefaultEndpointsProtocol=https;..."
```

**Target** (structured object in database `properties`):
```json
"persistence": {
  "rdbEnabled": true,
  "rdbFrequency": "6h"
}
```

**RDB Frequency Mapping:**

| ACR Value (minutes) | AMR Value |
|---|---|
| `15` | `1h` |
| `30` | `1h` |
| `60` | `1h` |
| `360` | `6h` |
| `720` | `12h` |
| `1440` | `12h` |

Values ≤ 60 minutes round up to `1h` (AMR minimum). Values > 720 round down to `12h` (AMR maximum).

### AOF Persistence

**Source:**
```json
"aof-backup-enabled": "true",
"aof-storage-connection-string-0": "...",
"aof-storage-connection-string-1": "..."
```

**Target:**
```json
"persistence": {
  "aofEnabled": true,
  "aofFrequency": "1s"
}
```

### Persistence Rules

- **Storage connection strings are always REMOVED** — AMR manages persistence storage internally.
- If source has both RDB and AOF enabled, include both `rdbEnabled`/`rdbFrequency` and `aofEnabled`/`aofFrequency` in the same `persistence` object.
- If source has no persistence config (or `rdb-backup-enabled: "false"`), **omit** the `persistence` property entirely.
- `aofFrequency` is always `"1s"` — AMR does not support other AOF frequencies.

---

## 6. Clustering Policy Decision Matrix

⚠️ **This decision may require user input.** Choosing the wrong policy can cause connection failures.

| Source ACR Config | Recommended `clusteringPolicy` | Reason |
|---|---|---|
| Basic or Standard tier (any C* SKU) | `EnterpriseCluster` | Single-endpoint behavior matches source |
| Premium, non-clustered (`shardCount` = 0 or absent) | `EnterpriseCluster` | Single-endpoint behavior matches source |
| Premium, clustered (`shardCount` ≥ 1), client **not** cluster-aware | `EnterpriseCluster` | Avoids application code changes |
| Premium, clustered (`shardCount` ≥ 1), client **is** cluster-aware | `OSSCluster` | Client already handles cluster topology |

**Default behavior:** Always output `EnterpriseCluster` unless the user explicitly confirms their client is cluster-aware and wants `OSSCluster`.

⚠️ **Warning:** Using `OSSCluster` with a non-cluster-aware client **will cause connection failures**. When uncertain, always default to `EnterpriseCluster`.

---

## 7. Removed Properties

These ACR properties have **no equivalent** in AMR and must be removed during transformation:

| ACR Property | Why Removed | AMR Replacement |
|---|---|---|
| `enableNonSslPort` | AMR is TLS-only (port 10000) | None — always encrypted |
| `shardCount` | AMR manages sharding internally | None — handled by SKU tier |
| `replicasPerPrimary` | Not supported in AMR | Active geo-replication for read scaling |
| `replicasPerMaster` | Deprecated alias for above | Active geo-replication for read scaling |
| `redisVersion` | AMR always runs Redis 7.4+ | None — always latest |
| `staticIP` | Not supported in AMR networking | Private Endpoint |
| `subnetId` | VNet injection not supported | Private Endpoint resource |
| `maxmemory-reserved` | AMR manages memory internally | None |
| `maxfragmentationmemory-reserved` | AMR manages memory internally | None |
| `maxmemory-delta` | AMR manages memory internally | None |
| `aad-enabled` | AAD auth uses `identity` on cluster | `identity` block on cluster resource |
| `rdb-storage-connection-string` | AMR manages persistence storage | None — managed internally |
| `aof-storage-connection-string-0` | AMR manages persistence storage | None — managed internally |
| `aof-storage-connection-string-1` | AMR manages persistence storage | None — managed internally |

**Rule:** If any of these properties appear as parameter references, those parameters must also be removed from the parameters section.

### Geo-Replication (Special Case)

ACR passive geo-replication uses `Microsoft.Cache/redis/linkedServers` child resources. AMR uses **active geo-replication**, which is a fundamentally different model configured via the database resource's `geoReplication` property with linked database groups. **This is NOT a simple property mapping** — it requires redesigning the replication topology.

If the source template contains `linkedServers`:
1. **Remove** the `linkedServers` child resources
2. **Warn the user** that geo-replication must be reconfigured manually for AMR
3. Point them to [Azure Managed Redis active geo-replication docs](https://learn.microsoft.com/en-us/azure/redis/how-to-active-geo-replication)

Do NOT attempt to auto-convert geo-replication configuration.

---

## 8. Networking: VNet Injection → Private Endpoint

ACR VNet injection (`subnetId`) is not supported in AMR. Transform to Private Endpoint.

### Detection

Source has VNet injection if any of these are true:
- `properties.subnetId` is set
- A `subnetId` parameter exists
- `redisConfiguration` contains firewall rules

### Transformation Steps

1. **Remove** `subnetId` from cluster properties.
2. **Set** `publicNetworkAccess: "Disabled"` on the cluster resource.
3. **Add** a Private Endpoint resource (see skeleton below).
4. **Remove** any firewall rule resources (`Microsoft.Cache/redis/firewallRules`) — AMR does not support firewall rules; use NSG on the PE subnet instead.

### ARM Private Endpoint Skeleton

```json
{
  "type": "Microsoft.Network/privateEndpoints",
  "apiVersion": "2023-11-01",
  "name": "[concat(parameters('cacheName'), '-pe')]",
  "location": "[parameters('location')]",
  "dependsOn": [
    "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]"
  ],
  "properties": {
    "privateLinkServiceConnections": [
      {
        "name": "redisEnterprise",
        "properties": {
          "privateLinkServiceId": "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]",
          "groupIds": ["redisEnterprise"]
        }
      }
    ],
    "subnet": {
      "id": "[parameters('subnetId')]"
    }
  }
}
```

### Updating Existing Private Endpoint Resources

If the source template already has PE resources targeting ACR, update them in-place:

| Property | ACR Value | AMR Value |
|---|---|---|
| `privateLinkServiceId` | `Microsoft.Cache/redis` | `Microsoft.Cache/redisEnterprise` |
| `groupIds` | `["redisCache"]` | `["redisEnterprise"]` |
| DNS zone | `privatelink.redis.cache.windows.net` | `privatelink.redis.azure.net` |

> ⚠️ **DNS zone update**: The AMR private DNS zone is `privatelink.redis.azure.net` (NOT the older Enterprise zone `privatelink.redisenterprise.cache.azure.net`). The hostname format also changes to `<cache>.<region>.redis.azure.net`.

### Firewall Rules

ACR firewall rules (`Microsoft.Cache/redis/firewallRules`) are **not supported** in AMR. Remove these resources entirely and advise the user to use NSG rules on the Private Endpoint subnet instead.

---

## 9. Preserved Properties

These properties carry over from ACR to the AMR **cluster** resource unchanged:

| Property | Notes |
|---|---|
| `name` / `cacheName` parameter | Identical |
| `location` | Identical |
| `zones` | **Do NOT include** — zone redundancy is automatic in AMR. Always remove from source. |
| `publicNetworkAccess` | **Required** — always include. Preserve from source; default to `"Enabled"` if absent. Use `"Disabled"` for VNet/PE scenarios. |
| `identity.type` | Preserve (`SystemAssigned`, `UserAssigned`, etc.) |
| `identity.userAssignedIdentities` | Preserve resource ID keys; do NOT copy `principalId`/`tenantId` values |
| `tags` | Preserve all key-value pairs |
| `minimumTlsVersion` | Preserve; default `"1.2"` |

---

## 10. Parameters File Transformation

When transforming ARM template parameter definitions:

### Parameters to Remove

These parameters are no longer needed in AMR and should be deleted:

- `skuFamily`
- `skuCapacity`
- `enableNonSslPort`
- `shardCount`
- `replicasPerPrimary` / `replicasPerMaster`
- `redisVersion`
- `staticIP`
- `rdbStorageConnectionString`
- `aofStorageConnectionString0` / `aofStorageConnectionString1`
- `maxmemoryPolicy`
- `rdbBackupFrequency`
- `maxmemoryReserved`
- `maxfragmentationmemoryReserved`
- `maxmemoryDelta`

> **Note:** `zones` parameter should always be **removed** — zone redundancy is automatic in AMR and specifying zones will cause a deployment error. See [Section 2](#2-cluster-resource-properties).

### Parameters to Add

```json
{
  "skuName": {
    "type": "string",
    "defaultValue": "Balanced_B50",
    "metadata": { "description": "AMR SKU name (e.g., Balanced_B50, MemoryOptimized_M100)" }
  },
  "evictionPolicy": {
    "type": "string",
    "defaultValue": "VolatileLRU",
    "allowedValues": [
      "NoEviction", "AllKeysLRU", "VolatileLRU", "AllKeysRandom",
      "VolatileRandom", "VolatileTTL", "AllKeysLFU", "VolatileLFU"
    ],
    "metadata": { "description": "Eviction policy for the database" }
  },
  "clusteringPolicy": {
    "type": "string",
    "defaultValue": "EnterpriseCluster",
    "allowedValues": ["EnterpriseCluster", "OSSCluster"],
    "metadata": { "description": "Clustering policy for the database" }
  }
}
```

**Conditional parameter** — only add if source had RDB persistence:
```json
{
  "rdbFrequency": {
    "type": "string",
    "defaultValue": "6h",
    "allowedValues": ["1h", "6h", "12h"],
    "metadata": { "description": "RDB snapshot frequency" }
  }
}
```

### Update Existing `skuName` Parameter

If a `skuName` parameter already exists, change its `defaultValue` from the ACR tier name (e.g., `"Premium"`) to the AMR compound name (e.g., `"Balanced_B50"`). Remove any `allowedValues` that reference ACR tier names.

---

## 11. Variables and Outputs Cleanup

### Variables

- **Remove** any variable that references a removed parameter (e.g., a variable computing `maxmemoryPolicy`, `rdbStorageConnection`, `enableNonSslPort`).
- **Chain removal:** If variable `A` references removed variable `B`, remove `A` too. Trace the full dependency chain.
- **Preserve** variables that reference surviving parameters (`cacheName`, `location`, `tags`, etc.).

### Outputs

- **Remove** outputs that reference `Microsoft.Cache/redis` properties:
  - `hostName` — does not exist on `Microsoft.Cache/redisEnterprise`
  - `sslPort` — AMR uses port 10000, not 6380
  - `port` / `nonSslPort` — non-SSL not supported
  - `accessKeys` — key retrieval uses a different API path
- **Update** remaining `dependsOn` and `resourceId` references:
  - `Microsoft.Cache/redis` → `Microsoft.Cache/redisEnterprise`
  - `Microsoft.Cache/redis/firewallRules` → remove entirely

---

## 12. Terraform Output Structure

For Terraform, generate two resources with an implicit dependency via `cluster_id`:

### Cluster Resource

```hcl
resource "azurerm_redis_enterprise_cluster" "this" {
  name                = var.cache_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Balanced_B50"
  minimum_tls_version = "1.2"
  tags                = var.tags
}
```

### Database Resource

```hcl
resource "azurerm_redis_enterprise_database" "default" {
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.this.id
  port              = 10000
  client_protocol   = "Encrypted"
  clustering_policy = "EnterpriseCluster"
  eviction_policy   = "VolatileLRU"
}
```

### Persistence Block (inside database resource)

```hcl
resource "azurerm_redis_enterprise_database" "default" {
  # ... base properties ...

  linked_database_group_nickname = null
  rdb_enabled   = true
  rdb_frequency = "6h"
}
```

### Private Endpoint Resource

```hcl
resource "azurerm_private_endpoint" "redis" {
  name                = "${var.cache_name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "redisEnterprise"
    private_connection_resource_id = azurerm_redis_enterprise_cluster.this.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }
}
```

### Terraform Mapping Notes

| ACR Terraform Resource | AMR Terraform Resource |
|---|---|
| `azurerm_redis_cache` | `azurerm_redis_enterprise_cluster` + `azurerm_redis_enterprise_database` |
| `azurerm_redis_firewall_rule` | Remove — use NSG on PE subnet |
| `azurerm_private_endpoint` (with `redisCache`) | Update `subresource_names` to `["redisEnterprise"]` |

---

## 13. Bicep Output Structure

Generate Bicep directly (preferred) rather than ARM JSON + decompile.

### Cluster Resource

```bicep
resource redisCluster 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: cacheName
  location: location
  sku: {
    name: skuName
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
  tags: tags
}
```

### Database Resource

```bicep
resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redisCluster
  name: 'default'
  properties: {
    port: 10000
    clientProtocol: 'Encrypted'
    clusteringPolicy: clusteringPolicy
    evictionPolicy: evictionPolicy
  }
}
```

### With Persistence

```bicep
resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redisCluster
  name: 'default'
  properties: {
    port: 10000
    clientProtocol: 'Encrypted'
    clusteringPolicy: clusteringPolicy
    evictionPolicy: evictionPolicy
    persistence: {
      rdbEnabled: true
      rdbFrequency: rdbFrequency
    }
  }
}
```

### Private Endpoint

```bicep
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${cacheName}-pe'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'redisEnterprise'
        properties: {
          privateLinkServiceId: redisCluster.id
          groupIds: ['redisEnterprise']
        }
      }
    ]
    subnet: {
      id: subnetId
    }
  }
}
```

### Bicep Notes

- Use `parent: redisCluster` instead of `concat` for the database name — Bicep handles the naming.
- `dependsOn` is implicit via `parent` and resource references; do not add explicit `dependsOn` unless needed for non-parent dependencies.
- Users can also decompile generated ARM JSON: `az bicep decompile --file template.json`

---

## 14. Example Templates

For complete before/after template examples, see [references/examples/iac/](examples/iac/):

### ARM JSON (inline values) — `arm/`

| Scenario | Directory | Description |
|---|---|---|
| Basic C3 | [arm/basic-c3/](examples/iac/arm/basic-c3/) | Simplest conversion — Basic/Standard tier |
| Premium non-clustered | [arm/premium-nonclustered/](examples/iac/arm/premium-nonclustered/) | Premium P2 without clustering |
| Premium clustered | [arm/premium-clustered/](examples/iac/arm/premium-clustered/) | Premium P2 with 3 shards |
| Premium with VNet | [arm/premium-vnet/](examples/iac/arm/premium-vnet/) | VNet injection → Private Endpoint |
| Premium with persistence | [arm/premium-persistence/](examples/iac/arm/premium-persistence/) | RDB/AOF restructuring |
| Premium all-features | [arm/premium-all-features/](examples/iac/arm/premium-all-features/) | Kitchen sink — all features combined |

Each directory contains `acr.json` (source) and `amr.json` (target).

### ARM JSON (parameterized) — `arm-parameterized/`

| Scenario | Directory | Description |
|---|---|---|
| Premium Clustered | [arm-parameterized/premium-clustered/](examples/iac/arm-parameterized/premium-clustered/) | Premium P2 × 3 shards with RDB persistence |
| Standard C2 | [arm-parameterized/standard-c2/](examples/iac/arm-parameterized/standard-c2/) | Standard tier with parameter files |
| Premium non-clustered | [arm-parameterized/premium-nonclustered/](examples/iac/arm-parameterized/premium-nonclustered/) | Premium with parameter files |
| Premium with VNet | [arm-parameterized/premium-vnet/](examples/iac/arm-parameterized/premium-vnet/) | Premium VNet with parameter files |

Each directory contains `acr-cache.json` + `acr-cache.parameters.json` (source) and `amr-cache.json` + `amr-cache.parameters.json` (target).

### Bicep — `bicep/`

| Scenario | Directory | Description |
|---|---|---|
| Basic C3 | [bicep/basic-c3/](examples/iac/bicep/basic-c3/) | Bicep format — Basic tier |
| Premium clustered | [bicep/premium-clustered/](examples/iac/bicep/premium-clustered/) | Bicep format — Premium clustered |

Each directory contains `acr.bicep` (source) and `amr.bicep` (target).
