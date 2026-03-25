# AMR Template Structure — Output Generation Reference

## Table of Contents
- [1. AMR Resource Model](#1-amr-resource-model)
- [2. Cluster Resource Properties](#2-cluster-resource-properties)
- [3. Database Resource Properties](#3-database-resource-properties)
- [4. Eviction Policy Mapping](#4-eviction-policy-mapping)
- [5. Persistence Transformation](#5-persistence-transformation)
- [6. Clustering Policy Decision Matrix](#6-clustering-policy-decision-matrix)
- [7. Removed Properties](#7-removed-properties)
- [8. Networking: VNet Injection → Private Endpoint](#8-networking-vnet-injection--private-endpoint)
- [9. Access Policy Assignment Transformation](#9-access-policy-assignment-transformation)
- [10. Preserved Properties](#10-preserved-properties)
- [11. Parameters File Transformation](#11-parameters-file-transformation)
- [12. Variables and Outputs Cleanup](#12-variables-and-outputs-cleanup)
- [13. Terraform Output Structure](#13-terraform-output-structure)
- [14. Bicep Output Structure](#14-bicep-output-structure)
- [15. Example Templates](#15-example-templates)
- [13. Bicep Output Structure](#13-bicep-output-structure)
- [14. Example Templates](#14-example-templates)

This document is the AI agent's primary reference for **generating** Azure Managed Redis (AMR) infrastructure-as-code templates from extracted ACR configuration.It covers the AMR resource model, property mappings, transformation rules, and output formats (ARM JSON, Bicep, Terraform).

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

> ⚠️ **Multiple Databases Warning:** ACR supports up to 16 Redis databases (0–15) by default, configurable up to 64 on Premium. AMR supports **only database 0** (`default`). If the source application uses multiple databases, warn the user that they need to refactor their data model to use a single database (e.g., key prefixes for logical separation) before migrating.

---

## 2. Cluster Resource Properties

### ARM JSON Skeleton

Example structure (values shown are illustrative — actual values depend on the source template and SKU mapping):

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

Example structure (values shown are illustrative — actual values come from the source template transformation):

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
| `clientProtocol` | `"Encrypted"` or `"Plaintext"` | Default `"Encrypted"` (TLS). If source had `enableNonSslPort: true`, use `"Plaintext"` to preserve non-TLS access |
| `clusteringPolicy` | `"EnterpriseCluster"`, `"OSSCluster"`, or `"NoCluster"` | See [Section 6](#6-clustering-policy-decision-matrix). Use `"NoCluster"` for non-clustered caches (≤ 24GB). **Do NOT omit** — default is `OSSCluster`. |
| `evictionPolicy` | PascalCase value | See [Section 4](#4-eviction-policy-mapping). Converted from ACR `maxmemory-policy` |
| `persistence` | Structured object | See [Section 5](#5-persistence-transformation); omit if source had no persistence |
| `accessKeysAuthentication` | `"Enabled"` or `"Disabled"` | Default `"Enabled"`. If source ACR had `disableAccessKeyAuthentication: true`, set `"Disabled"`. Omit if source was `false` or absent (default behavior is correct). |

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

See [Azure Managed Redis architecture](https://learn.microsoft.com/en-us/azure/redis/architecture) for full details on clustering policies.

⚠️ **This decision may require user input.** Choosing the wrong policy can cause connection failures.

| Source ACR Config | Target AMR SKU Size | Recommended `clusteringPolicy` | Reason |
|---|---|---|---|
| Basic/Standard (any C* SKU), non-clustered | ≤ 24GB | `NoCluster` | AMR supports non-clustered caches up to 24GB — no risk of cross-slot errors. `NoCluster` can later be upgraded to clustered without recreating the database. |
| Basic/Standard (any C* SKU), non-clustered | > 24GB | `EnterpriseCluster` | Must use clustering for sizes above 24GB |
| Premium, non-clustered (`shardCount` = 0 or absent) | ≤ 24GB | `NoCluster` | Matches source single-endpoint behavior with no cross-slot risk. `NoCluster` can later be upgraded to clustered without recreating the database. |
| Premium, non-clustered (`shardCount` = 0 or absent) | > 24GB | `EnterpriseCluster` | Must use clustering for sizes above 24GB |
| Premium, clustered (`shardCount` ≥ 1), client **not** cluster-aware | any | `EnterpriseCluster` | Avoids application code changes |
| Premium, clustered (`shardCount` ≥ 1), client **is** cluster-aware | any | `OSSCluster` | Client already handles cluster topology |

**Default behavior:** If the source was non-clustered and the target AMR SKU (from Step 2) has an advertised size ≤ 24GB, set `"clusteringPolicy": "NoCluster"` automatically — no need to ask the user about clustering. For target sizes > 24GB, use `EnterpriseCluster` unless the user explicitly confirms their client is cluster-aware and wants `OSSCluster`. The target size is encoded in the AMR SKU name (e.g., `Balanced_B5` = 6GB, `MemoryOptimized_M20` = 24GB).

> ⚠️ **Do NOT omit `clusteringPolicy`** — the default when omitted is `OSSCluster`, not non-clustered. You must explicitly set `"NoCluster"` for non-clustered caches. The `NoCluster` value is available in API version `2025-07-01` and later.

⚠️ **Warning:** Using `OSSCluster` with a non-cluster-aware client **will cause connection failures**. When uncertain, always default to `EnterpriseCluster`.

⚠️ **Cross-slot warning:** Even with `EnterpriseCluster`, keys are internally partitioned across multiple shards. Clients using multi-key commands (e.g., `MGET`, `SUNION`) or Lua scripts that access keys in different hash slots may encounter cross-slot errors. This is why non-clustered mode should be preferred when the target size allows it (≤ 24GB).

---

## 7. Removed Properties

These ACR properties have **no equivalent** in AMR and must be removed during transformation:

| ACR Property | Why Not Available | AMR Replacement |
|---|---|---|
| `enableNonSslPort` | AMR uses `clientProtocol` on the database resource | Convert: if `enableNonSslPort: true`, set `clientProtocol: "Plaintext"`. If `false` or absent, set `clientProtocol: "Encrypted"` |
| `shardCount` | AMR manages sharding internally | None — handled by SKU tier |
| `replicasPerPrimary` | Not configurable in AMR | AMR automatically provides zone redundancy via built-in HA mechanisms |
| `replicasPerMaster` | Deprecated alias for above | Same as `replicasPerPrimary` |
| `redisVersion` | AMR always runs Redis 7.4+ | None — always latest |
| `staticIP` | Not available in AMR networking | Private Endpoint |
| `subnetId` | VNet injection not available in AMR | Private Endpoint resource |
| `maxmemory-reserved` | AMR manages memory internally | None |
| `maxfragmentationmemory-reserved` | AMR manages memory internally | None |
| `maxmemory-delta` | AMR manages memory internally | None |
| `maxmemory-policy` | Replaced by `evictionPolicy` on database resource | Convert to AMR `evictionPolicy` (PascalCase) — see [Section 4](#4-eviction-policy-mapping) |
| `aad-enabled` | AMR supports Entra (AAD) auth through its own mechanism | AMR has native Entra ID support configured differently — not via `aad-enabled`. Preserve the `identity` block on the cluster resource. Advise user to configure Entra auth separately |
| `disableAccessKeyAuthentication` | Replaced by `accessKeysAuthentication` on AMR database | Convert: `true` → `accessKeysAuthentication: "Disabled"`, `false`/absent → `accessKeysAuthentication: "Enabled"` (or omit — default is `"Enabled"`). This controls whether password (access key) auth is allowed. |
| `patchSchedule` | Converted to `maintenanceConfiguration` | Map each ACR `dayOfWeek`+`startHourUtc` entry to an AMR `maintenanceWindows[]` entry with `type: "Weekly"`, matching day, start hour, and minimum 4h `duration` (e.g., `"PT5H"`). Requires API `2025-08-01-preview`. See [Section 7a](#7a-scheduled-maintenance-mapping). |
| `rdb-storage-connection-string` | AMR manages persistence storage | None — managed internally |
| `aof-storage-connection-string-0` | AMR manages persistence storage | None — managed internally |
| `aof-storage-connection-string-1` | AMR manages persistence storage | None — managed internally |
| `notify-keyspace-events` | **Not available in AMR** | ⚠️ Keyspace notifications are not currently supported in Azure Managed Redis. If the source has this set, **warn the user** that this functionality will not be available after migration. |

**Rule:** If any of these properties appear as parameter references, those parameters must also be removed from the parameters section.

> ⚠️ **patchSchedule requires special handling** — Do NOT simply remove it. If the source template contains a `Microsoft.Cache/redis/patchSchedules` child resource or a `patchSchedule` property, you MUST convert it to `maintenanceConfiguration` on the AMR cluster resource AND change the API version to `2025-08-01-preview`. See [Section 7a](#7a-scheduled-maintenance-mapping) for the full conversion rules.

### Geo-Replication Conversion

ACR passive geo-replication uses `Microsoft.Cache/redis/linkedServers` child resources. AMR uses **active geo-replication** (active-active model) configured via the database resource's `geoReplication` property with linked database groups. While the models differ, the conversion can be automated:

If the source template contains `linkedServers`:
1. **Remove** the `linkedServers` child resources
2. **Add** the AMR active geo-replication configuration to the database resource using `geoReplication.groupNickname` and `geoReplication.linkedDatabases`
3. **Note for the user**: AMR active-active means clients *can* write to any linked cache (unlike ACR passive where the secondary was read-only). No harm if clients don't take advantage of the additional write capability.
4. Point them to [Azure Managed Redis active geo-replication docs](https://learn.microsoft.com/en-us/azure/redis/how-to-active-geo-replication) for advanced configuration

**Restrictions** (flag these during conversion):
- Data persistence is **not supported** with active geo-replication — if the source template includes both `linkedServers` and persistence properties (`rdb-backup-enabled`, `aof-backup-enabled`), warn the user to choose one
- B0, B1, and Flash Optimized SKUs do not support geo-replication
- All caches in the geo-replication group must have identical configuration (SKU, eviction policy, clustering policy, modules, TLS settings)
- Only **RediSearch** and **RedisJSON** modules are supported with geo-replication

---

## 7a. Scheduled Maintenance Mapping

> **Status**: Preview (launched November 2025). Requires API version `2025-08-01-preview`.

ACR uses `patchSchedule` (a child resource `Microsoft.Cache/redis/patchSchedules` or inline property) with entries specifying `dayOfWeek` and `startHourUtc`. AMR replaces this with `maintenanceConfiguration.maintenanceWindows[]` on the cluster resource.

### Conversion Rules

1. **Map each ACR patch schedule entry** to an AMR `maintenanceWindows[]` entry
2. **Set `type`** to `"Weekly"` (only supported type)
3. **Copy `dayOfWeek`** directly (same enum values: `Monday`, `Tuesday`, etc.)
4. **Copy `startHourUtc`** directly (same 0-23 range)
5. **Set `duration`** to `"PT5H"` (minimum is 4 hours; 5h is a safe default)
6. **Ensure minimum requirements**: At least 2 windows per week, 18 hours total per week

### ARM JSON Example

**ACR source** (child resource):
```json
{
  "type": "Microsoft.Cache/redis/patchSchedules",
  "apiVersion": "2024-03-01",
  "name": "[concat(parameters('cacheName'), '/default')]",
  "properties": {
    "scheduleEntries": [
      { "dayOfWeek": "Tuesday", "startHourUtc": 2 },
      { "dayOfWeek": "Saturday", "startHourUtc": 4 }
    ]
  }
}
```

**AMR output** (inline on cluster resource):
```json
"properties": {
  "maintenanceConfiguration": {
    "maintenanceWindows": [
      {
        "type": "Weekly",
        "startHourUtc": 2,
        "duration": "PT5H",
        "schedule": { "dayOfWeek": "Tuesday" }
      },
      {
        "type": "Weekly",
        "startHourUtc": 4,
        "duration": "PT5H",
        "schedule": { "dayOfWeek": "Saturday" }
      }
    ]
  }
}
```

### Bicep Example

```bicep
properties: {
  maintenanceConfiguration: {
    maintenanceWindows: [
      {
        type: 'Weekly'
        startHourUtc: 2
        duration: 'PT5H'
        schedule: { dayOfWeek: 'Tuesday' }
      }
      {
        type: 'Weekly'
        startHourUtc: 4
        duration: 'PT5H'
        schedule: { dayOfWeek: 'Saturday' }
      }
    ]
  }
}
```

### Terraform Note

Terraform `azurerm` provider support for `maintenance_configuration` on `azurerm_redis_enterprise_cluster` may require an updated provider version. If not yet supported, include a comment in the generated template:

```hcl
# TODO: maintenance_configuration — AMR supports scheduled maintenance (preview).
# Terraform provider support pending. Configure via Azure portal or ARM API 2025-08-01-preview.
```

### Edge Cases

- **Single-entry schedule**: ACR allows a single day. AMR requires ≥2 windows/week with ≥18h total. If the source has only 1 entry, add a second window on a different day (choose a day 3-4 days apart) and note this for the user.
- **`maintenanceWindow` property absent in ACR**: If no `patchSchedule` exists in the source, do NOT add `maintenanceConfiguration` to the AMR output — Azure will manage maintenance automatically.
- **API version**: The generated template must use `2025-08-01-preview` or later if `maintenanceConfiguration` is included.

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

> ⚠️ **Tag propagation**: Copy the source cache's `tags` onto the PE resource to maintain consistent resource tagging. If the source template had tags on the ACR resource, apply the same tags to the PE.

```json
{
  "type": "Microsoft.Network/privateEndpoints",
  "apiVersion": "2023-11-01",
  "name": "[concat(parameters('cacheName'), '-pe')]",
  "location": "[parameters('location')]",
  "tags": "<<copy from source cache resource>>",
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
},
{
  "type": "Microsoft.Network/privateEndpoints/privateDnsZoneGroups",
  "apiVersion": "2023-11-01",
  "name": "[concat(parameters('cacheName'), '-pe/default')]",
  "dependsOn": [
    "[resourceId('Microsoft.Network/privateEndpoints', concat(parameters('cacheName'), '-pe'))]"
  ],
  "properties": {
    "privateDnsZoneConfigs": [
      {
        "name": "privatelink-redis-azure-net",
        "properties": {
          "privateDnsZoneId": "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.redis.azure.net')]"
        }
      }
    ]
  }
}
```

> ⚠️ **DNS zone group required**: The `privateDnsZoneGroups` child resource is essential for DNS resolution. Without it, the PE deploys but clients cannot resolve `<cache>.<region>.redis.azure.net` to the private IP. The DNS zone `privatelink.redis.azure.net` must already exist in the subscription (or be created in the template).

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

## 9. Access Policy Assignment Transformation

ACR uses `Microsoft.Cache/redis/accessPolicyAssignments` as child resources. AMR uses `Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments` — these are children of the **database**, not the cluster.

### ACR Policy → AMR Policy Mapping

| ACR Access Policy | AMR Access Policy | Notes |
|---|---|---|
| `Data Owner` | `default` | Full data access — maps to AMR's built-in `default` policy |
| `Data Contributor` | `default` | Read/write data access — maps to `default` (AMR has no separate contributor role) |
| `Data Reader` | ⚠️ No built-in equivalent | Flag for manual attention — user must create a custom access policy on AMR |

### ARM JSON Output

For each ACR `accessPolicyAssignment`, generate a corresponding AMR resource:

```json
{
  "type": "Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments",
  "apiVersion": "2025-04-01",
  "name": "[concat(parameters('cacheName'), '/default/', parameters('accessPolicyAssignmentName'))]",
  "dependsOn": [
    "[resourceId('Microsoft.Cache/redisEnterprise/databases', parameters('cacheName'), 'default')]"
  ],
  "properties": {
    "accessPolicyName": "default",
    "user": {
      "objectId": "<entra-object-id>"
    }
  }
}
```

### Transformation Rules

1. **Resource type**: `Microsoft.Cache/redis/accessPolicyAssignments` → `Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments`
2. **Parent path**: Changes from `<cacheName>/<assignmentName>` to `<cacheName>/default/<assignmentName>` (AMR assignments are scoped to the database, which is named `default`)
3. **`dependsOn`**: Must reference the AMR database resource, not the cluster
4. **`accessPolicyName`**: Map using the table above. If the source policy is `Data Owner` or `Data Contributor`, set to `default`
5. **`objectId`**: Preserve from source — the Entra object ID is unchanged
6. **`objectIdAlias`** (display name): Not a property on AMR assignments — drop it
7. **`Data Reader`**: If found, do NOT generate an AMR resource. Instead, add to the feature gaps report: _"ACR 'Data Reader' access policy for [display name] has no built-in AMR equivalent. Create a custom access policy on the AMR database after deployment."_

---

## 10. Preserved Properties

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

## 11. Parameters File Transformation

When transforming ARM template parameter definitions:

### Parameters to Remove

These parameters are no longer needed in AMR and should be deleted:

- `skuFamily`
- `skuCapacity`
- `shardCount`
- `replicasPerPrimary` / `replicasPerMaster`
- `redisVersion`
- `staticIP`
- `rdbStorageConnectionString`
- `aofStorageConnectionString0` / `aofStorageConnectionString1`
- `rdbBackupFrequency` — replaced by `rdbFrequency` parameter (see Parameters to Add)
- `maxmemoryReserved`
- `maxfragmentationmemoryReserved`
- `maxmemoryDelta`
- `patchSchedule` — **do NOT just remove**: convert to `maintenanceConfiguration.maintenanceWindows[]` on cluster resource and use API `2025-08-01-preview` (see [Section 7a](#7a-scheduled-maintenance-mapping))

### Parameters to Convert (not just remove)

These parameters have AMR equivalents and should be transformed:

| ACR Parameter | AMR Replacement | Conversion Logic |
|---|---|---|
| `enableNonSslPort` | `clientProtocol` | If value was `true`, set `clientProtocol` default to `"Plaintext"`. If `false`, set to `"Encrypted"` |
| `maxmemoryPolicy` | `evictionPolicy` | Convert kebab-case to PascalCase (see [Section 4](#4-eviction-policy-mapping)) |

> **Note:** `zones` parameter should always be **removed** — zone redundancy is automatic in AMR and specifying zones will cause a deployment error. See [Section 2](#2-cluster-resource-properties).

### Parameters to Add

Example parameter definitions (default values shown are illustrative — set actual defaults based on the source template's SKU mapping and configuration):

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

## 12. Variables and Outputs Cleanup

### Variables

- **Remove** any variable that references a removed parameter (e.g., a variable computing `maxmemoryPolicy`, `rdbStorageConnection`, `enableNonSslPort`).
- **Chain removal:** If variable `A` references removed variable `B`, remove `A` too. Trace the full dependency chain.
- **Preserve** variables that reference surviving parameters (`cacheName`, `location`, `tags`, etc.).

### Outputs

- **Remove** outputs that reference `Microsoft.Cache/redis` properties:
  - `hostName` — construct using `concat()` instead of `reference()`:
    > ⚠️ **Prefer `concat()` over `reference().hostName`**. While `hostName` is a valid read-only property on the `redisEnterprise` RP response, the `concat()` pattern is preferred because it avoids an implicit deployment dependency and works when the cache is deployed in a separate template. The AMR hostname format is deterministic: `<name>.<location>.redis.azure.net`.
    > ```json
    > "hostName": {
    >   "type": "string",
    >   "value": "[concat(parameters('cacheName'), '.', parameters('location'), '.redis.azure.net')]"
    > }
    > ```
    > Bicep: `'${cacheName}.${location}.redis.azure.net'`
  - `sslPort` — AMR uses port 10000, not 6380
  - `port` / `nonSslPort` — port is always 10000 in AMR
  - `accessKeys` — key retrieval uses a different API path. Replace the `listKeys` resource reference:
    - **ACR**: `listKeys(resourceId('Microsoft.Cache/redis', cacheName), '2023-08-01').primaryKey`
    - **AMR**: `listKeys(resourceId('Microsoft.Cache/redisEnterprise/databases', clusterName, 'default'), '2025-07-01').primaryKey`
    - The response properties (`.primaryKey`, `.secondaryKey`) remain the same; only the resource type and path change.
- **Update** remaining `dependsOn` and `resourceId` references:
  - `Microsoft.Cache/redis` → `Microsoft.Cache/redisEnterprise`
  - `Microsoft.Cache/redis/firewallRules` → remove entirely

---

## 13. Terraform Output Structure

Use `azurerm_managed_redis` — the recommended resource for AMR (replaces the deprecated `azurerm_redis_enterprise_cluster` + `azurerm_redis_enterprise_database`). This single resource includes an inline `default_database` block for database configuration.

### Resource Structure

Example (SKU name, identity type, and database settings vary based on source template — do not treat these values as universal):

```hcl
resource "azurerm_managed_redis" "this" {
  name                = var.cache_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Balanced_B50"

  identity {
    type = "SystemAssigned"
  }

  default_database {
    client_protocol   = "Encrypted"  # Use "Plaintext" if source had enable_non_ssl_port = true
    clustering_policy = "EnterpriseCluster"
    eviction_policy   = "VolatileLRU"  # Converted from source maxmemory_policy
  }

  tags = var.tags
}
```

### Key Attributes

| Attribute | Location | Notes |
|---|---|---|
| `sku_name` | top-level | Compound name (e.g., `Balanced_B5`) |
| `identity` | nested block | Supports `SystemAssigned`, `UserAssigned`, or both |
| `public_network_access` | top-level | `"Enabled"` or `"Disabled"` (string, not bool) |
| `high_availability_enabled` | top-level | Default `true` — set `false` for dev/test (50% savings) |
| `default_database` | nested block | Database properties (clustering, eviction, persistence, modules) |
| `hostname` | computed output | Use `azurerm_managed_redis.this.hostname` instead of constructing |

### Database Block Attributes

| Attribute | Maps From | Notes |
|---|---|---|
| `client_protocol` | `enable_non_ssl_port` | `"Encrypted"` (default). If source had `enable_non_ssl_port = true`, use `"Plaintext"` |
| `clustering_policy` | — | `"EnterpriseCluster"`, `"OSSCluster"`, or `"NoCluster"` for non-clustered ≤ 24GB (see [Section 6](#6-clustering-policy-decision-matrix)). **Do NOT omit** — default is `OSSCluster`. |
| `eviction_policy` | `maxmemory_policy` | PascalCase (e.g., `"VolatileLRU"`) |
| `persistence_redis_database_backup_frequency` | `rdb_backup_frequency` | `"1h"`, `"6h"`, or `"12h"` |
| `persistence_append_only_file_backup_frequency` | `aof_backup_enabled` | `"1s"` or `"always"` |
| `port` | — | Computed, defaults to `10000` |
| `geo_replication_group_name` | — | For active geo-replication |
| `access_keys_authentication` | `disableAccessKeyAuthentication` | `"Enabled"` (default). If source had `disable_access_key_authentication = true`, set `"Disabled"` |

### Persistence Mapping

| ACR `rdb_backup_frequency` | AMR `persistence_redis_database_backup_frequency` |
|---|---|
| `60` | `"1h"` |
| `360` | `"6h"` |
| `720` | `"12h"` |

For AOF, use `persistence_append_only_file_backup_frequency` = `"1s"` or `"always"`.

### Private Endpoint Resource

```hcl
resource "azurerm_private_endpoint" "redis" {
  name                = "${var.cache_name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "redisEnterprise"
    private_connection_resource_id = azurerm_managed_redis.this.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }
}
```

### Terraform Mapping Notes

| ACR Terraform Resource | AMR Terraform Resource |
|---|---|
| `azurerm_redis_cache` | `azurerm_managed_redis` (single resource with `default_database` block) |
| `azurerm_redis_firewall_rule` | Remove — use NSG on PE subnet |
| `azurerm_private_endpoint` (with `redisCache`) | Update `subresource_names` to `["redisEnterprise"]` |

### Attributes NOT on `azurerm_managed_redis`

These ACR attributes do not exist on the AMR resource — remove or convert them:
- `minimum_tls_version` — not configurable on managed redis resource
- `zones` — AMR manages zone redundancy automatically
- `capacity`, `family` — encoded in `sku_name`
- `enable_non_ssl_port` — convert to `client_protocol` in `default_database` block (`true` → `"Plaintext"`, `false` → `"Encrypted"`)
- `redis_version` — not applicable
- `shard_count`, `replicas_per_primary` — not exposed in AMR
- `redis_configuration` block — replaced by `default_database` block; convert `maxmemory_policy` to `eviction_policy`
- `patch_schedule` — convert to `maintenance_configuration` block on the AMR cluster resource (preview). See [Section 7a](#7a-scheduled-maintenance-mapping).

---

## 14. Bicep Output Structure

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

## 15. Example Templates

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
