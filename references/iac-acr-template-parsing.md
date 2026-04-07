# ACR IaC Template Parsing Reference

## Table of Contents
- [Template Format Detection](#template-format-detection)
- [ARM Deployment Templates](#arm-deployment-templates)
- [ARM Parameter Resolution](#arm-parameter-resolution)
- [Bicep Templates](#bicep-templates)
- [Terraform Templates](#terraform-templates)
- [Feature Detection](#feature-detection)
- [Extracted Configuration Model](#extracted-configuration-model)
- [Common Pitfalls](#common-pitfalls)

This document teaches an AI agent how to read and extract configuration from Azure Cache for Redis (ACR) Infrastructure-as-Code templates.The extracted configuration feeds into the ACR → AMR migration transformation step. The agent should parse the user's template, resolve parameter references, and build a complete picture of the source cache's configuration before consulting `sku-mapping.md` and `feature-comparison.md` for the conversion.

---

## Template Format Detection

Determine the IaC format from the file extension:

| Extension | Format | Notes |
|-----------|--------|-------|
| `.json` | ARM template | May have a companion `.parameters.json` file |
| `.bicep` | Bicep template | May have `.bicepparam` or `.parameters.json` |
| `.tf` | Terraform (HCL) | Variables in `.tfvars` files |

---

## ARM Deployment Templates

### Resource Identification

Search the top-level `resources` array for the object with:

```json
"type": "Microsoft.Cache/redis"
```

The API version varies across templates (e.g., `2023-08-01`, `2024-03-01`, etc.) — do not assume a specific version. The resource object contains `sku`, `properties`, `identity`, `tags`, `zones`, and `location` at the top level.

### SKU Extraction

The SKU block can appear at the resource root (`sku`) or nested under `properties.sku`. Check both locations.

```json
"sku": {
  "name": "Premium",
  "family": "P",
  "capacity": 2
}
```

| Field | Values | Description |
|-------|--------|-------------|
| `sku.name` | `Basic`, `Standard`, `Premium` | Tier name |
| `sku.family` | `C` (Basic/Standard), `P` (Premium) | Family code |
| `sku.capacity` | `0`–`6` for C family, `1`–`5` for P family | Size number |

Derive the combined SKU code as `{family}{capacity}` — e.g., `P2`, `C3`. See `sku-mapping.md` for full SKU-to-AMR mapping tables.

### Core Properties

All under the `properties` object of the resource:

Example values (these vary per deployment — do not treat as universal):

```json
"properties": {
  "shardCount": 3,
  "replicasPerPrimary": 2,
  "enableNonSslPort": false,
  "minimumTlsVersion": "1.2",
  "patchSchedule": [ { "dayOfWeek": "Monday", "startHourUtc": 2 } ],
  "subnetId": "/subscriptions/.../subnets/redis-subnet",
  "redisConfiguration": { ... }
}
```

| Property | Type | Default | Notes |
|----------|------|---------|-------|
| `shardCount` | int | `0` or absent | Premium only. `0` or absent = non-clustered. `≥ 1` = clustered (OSS Cluster protocol). Even `1` shard means clustered. |
| `replicasPerPrimary` | int | `1` | Premium MRPP. Legacy name: `replicasPerMaster`. |
| `enableNonSslPort` | bool | `false` | Enables the non-TLS port (6379). In AMR, convert to the AMR-equivalent `clientProtocol` setting (see [AMR template structure](iac-amr-template-structure.md)). |
| `minimumTlsVersion` | string | `"1.2"` | Typically `"1.0"`, `"1.1"`, `"1.2"`, or `"1.3"`. |
| `publicNetworkAccess` | string | `"Enabled"` | `"Enabled"` or `"Disabled"`. Preserve in AMR output if `"Disabled"`. |
| `staticIP` | string | absent | Premium VNet-injected only. Not available in AMR — note for client IP dependency awareness. |
| `subnetId` | string | absent | Resource ID of the VNet subnet. Premium only. VNet injection is not available in AMR — must convert to Private Endpoint. |
| `patchSchedule` | array | absent | Scheduled patching windows. Each entry has `dayOfWeek` and `startHourUtc`. Not available in AMR — AMR manages patching automatically. |
| `zones` | array | absent | Availability zones, e.g., `["1", "2", "3"]`. |

### Redis Configuration Block

Under `properties.redisConfiguration`:

```json
"redisConfiguration": {
  "maxmemory-policy": "volatile-lru",
  "rdb-backup-enabled": "true",
  "rdb-backup-frequency": "360",
  "rdb-storage-connection-string": "DefaultEndpointsProtocol=https;...",
  "aof-backup-enabled": "false"
}
```

> **Note:** Not all `redisConfiguration` keys transfer directly to AMR. Eviction policy and persistence enablement/frequency map to AMR database properties, but storage connection strings are not needed (AMR manages storage internally). See the AMR column below.

| Key | Type | AMR Transfer | Notes |
|-----|------|-------------|-------|
| `maxmemory-policy` | string | ✅ Converts to `evictionPolicy` | Eviction policy: `volatile-lru`, `allkeys-lru`, `noeviction`, etc. |
| `rdb-backup-enabled` | string or bool | ✅ Maps to `persistence.rdbEnabled` | `"true"` / `"false"` or `true` / `false` |
| `rdb-backup-frequency` | string | ✅ Maps to `persistence.rdbFrequency` | Minutes: `"15"`, `"30"`, `"60"`, `"360"`, `"720"`, or `"1440"`. Map to AMR values: `1h`, `6h`, `12h`. |
| `rdb-storage-connection-string` | string | ❌ Not needed | Storage account connection. **Not available in AMR** — AMR manages persistence storage internally. |
| `aof-backup-enabled` | string or bool | ✅ Maps to `persistence.aofEnabled` | `"true"` / `"false"` or `true` / `false` |
| `aof-storage-connection-string-0` | string | ❌ Not needed | Primary storage connection. **Not available in AMR** — managed internally. |
| `aof-storage-connection-string-1` | string | ❌ Not needed | Secondary storage connection. **Not available in AMR** — managed internally. |

### Identity Block

At the resource root level (sibling to `properties`):

```json
"identity": {
  "type": "SystemAssigned, UserAssigned",
  "userAssignedIdentities": {
    "/subscriptions/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity": {}
  }
}
```

| Field | Values |
|-------|--------|
| `identity.type` | `SystemAssigned`, `UserAssigned`, or `SystemAssigned, UserAssigned` |
| `identity.userAssignedIdentities` | Map of identity resource IDs to empty objects |

### Tags

At the resource root level:

```json
"tags": {
  "environment": "production",
  "team": "caching"
}
```

### Child Resources

Scan the full `resources` array for these related resource types:

| Resource Type | What It Means |
|---------------|---------------|
| `Microsoft.Cache/redis/firewallRules` | Firewall rules on the cache. **Not available in AMR** — must use Private Endpoint + NSG instead. |
| `Microsoft.Cache/redis/linkedServers` | Geo-replication links |
| `Microsoft.Cache/redis/patchSchedules` | Scheduled patching windows. **Not available in AMR** — AMR manages patching automatically. |
| `Microsoft.Network/privateEndpoints` with `"redisCache"` in `groupIds` | Existing private endpoint |

For firewall rules, each resource has `properties.startIP` and `properties.endIP`. Note that firewall rules are **not available in AMR** — advise the user to use NSG rules on the Private Endpoint subnet instead. For private endpoints, check the `privateLinkServiceConnections[].groupIds` array for `"redisCache"`.

---

## ARM Parameter Resolution

ARM templates use expressions like `[parameters('paramName')]` for dynamic values. The agent must resolve these to extract actual configuration.

### Resolution Order

1. **Parameters file** (`.parameters.json`): Look in `parameters.{paramName}.value`
2. **Template defaults**: Look in the template's `parameters.{paramName}.defaultValue`
3. **Unresolvable**: If neither exists (or the expression is complex), preserve the expression and flag it for the user

### Parameters File Structure

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "cacheName": { "value": "my-redis-cache" },
    "skuName": { "value": "Premium" },
    "skuFamily": { "value": "P" },
    "skuCapacity": { "value": 2 },
    "shardCount": { "value": 3 }
  }
}
```

### Simple Parameter References

Pattern: `[parameters('x')]` → look up `x` in parameters file → return the value.

Example: if `"sku.name": "[parameters('skuName')]"` and the parameters file has `"skuName": { "value": "Premium" }`, resolve to `"Premium"`.

### Complex Expressions

Expressions like `[if(greater(parameters('shardCount'), 0), ...)]` or `[concat(parameters('prefix'), '-redis')]` cannot be fully evaluated. Best-effort approach:

1. Extract all `parameters('x')` references within the expression
2. Resolve each individual parameter
3. If the expression is a simple conditional (`if`), try to evaluate it based on the resolved values
4. Otherwise, flag the value as requiring user confirmation

For more on ARM template expressions and built-in functions, see [ARM template functions reference](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/template-functions).

### Variable References for redisConfiguration

When `redisConfiguration` is a variable reference like `[variables('redisConfiguration')]`, the entire block is defined in the template's `variables` section. Attempt to:

1. Find the variable in the template's `variables` object
2. If the variable itself contains parameter references, resolve those
3. As a fallback, check the parameters file for common persistence parameter names:
   - `rdbBackupEnabled` or `rdb-backup-enabled`
   - `rdbBackupFrequency` or `rdb-backup-frequency`
   - `aofBackupEnabled` or `aof-backup-enabled`

---

## Bicep Templates

### Resource Identification

Look for the resource declaration:

```bicep
resource redisCache 'Microsoft.Cache/redis@2023-08-01' = {
  name: cacheName
  location: location
  sku: {
    name: skuName
    family: skuFamily
    capacity: skuCapacity
  }
  properties: {
    // ...
  }
}
```

The symbolic name (e.g., `redisCache`) varies. The resource type string `'Microsoft.Cache/redis@2023-08-01'` is the identifier.

### Property Paths

Property paths are identical to ARM JSON but use Bicep dot-notation syntax without brackets. The same extraction rules apply for `sku`, `properties`, `identity`, `tags`, and `zones`.

Child resources may be declared as nested resources or separate resources with a `parent` property:

```bicep
// Nested
resource firewallRule 'firewallRules' = {
  parent: redisCache
  name: 'allow-azure'
  properties: { startIP: '0.0.0.0', endIP: '0.0.0.0' }
}

// Or separate
resource firewallRule 'Microsoft.Cache/redis/firewallRules@2023-08-01' = {
  name: '${redisCache.name}/allow-azure'
  properties: { startIP: '0.0.0.0', endIP: '0.0.0.0' }
}
```

### Bicep Parameter Resolution

Bicep parameters are declared with `param`:

```bicep
param cacheName string
param skuName string = 'Premium'   // has default
param skuCapacity int = 2          // has default
```

Actual values come from one of two file formats:

**`.bicepparam` file** (newer format):

```bicep
using './main.bicep'

param cacheName = 'my-redis'
param skuName = 'Premium'
param skuCapacity = 2
param shardCount = 3
```

Parse each `param <name> = <value>` line. String values are in single quotes. Numbers and booleans are bare.

**Standard ARM `.parameters.json` file**: Same structure as described in the ARM section above.

Resolution order:
1. `.bicepparam` file or `.parameters.json` file
2. Default values in the `param` declarations in the `.bicep` file
3. Flag as unresolvable and ask the user

---

## Terraform Templates

### Resource Identification

Look for the resource block:

```hcl
resource "azurerm_redis_cache" "example" {
  name                = "my-redis"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  capacity            = 2
  family              = "P"
  sku_name            = "Premium"
  shard_count         = 3

  redis_configuration {
    maxmemory_policy       = "volatile-lru"
    rdb_backup_enabled     = true
    rdb_backup_frequency   = 360
  }
}
```

The resource type is `"azurerm_redis_cache"`. The label (e.g., `"example"`) varies.

### Terraform ↔ ARM Property Mapping

Terraform uses underscores and different attribute names than ARM:

| Terraform Attribute | ARM Equivalent | Type | Notes |
|---------------------|---------------|------|-------|
| `sku_name` | `sku.name` | string | `Basic`, `Standard`, `Premium` |
| `family` | `sku.family` | string | `C` or `P` |
| `capacity` | `sku.capacity` | int | Numeric size |
| `shard_count` | `properties.shardCount` | int | Premium only |
| `replicas_per_primary` | `properties.replicasPerPrimary` | int | Premium only |
| `enable_non_ssl_port` | `properties.enableNonSslPort` | bool | Always native bool in TF |
| `minimum_tls_version` | `properties.minimumTlsVersion` | string | |
| `public_network_access_enabled` | `properties.publicNetworkAccess` | bool | `true`/`false` in TF; `"Enabled"`/`"Disabled"` in ARM |
| `subnet_id` | `properties.subnetId` | string | VNet injection |
| `private_static_ip_address` | `properties.staticIP` | string | Premium VNet only |
| `zones` | `zones` | list | Availability zones |
| `tags` | `tags` | map | Key-value pairs |

**`redis_configuration` block** (nested inside the resource):

| Terraform Attribute | ARM Equivalent | Type |
|---------------------|---------------|------|
| `rdb_backup_enabled` | `rdb-backup-enabled` | bool |
| `rdb_backup_frequency` | `rdb-backup-frequency` | int (minutes) |
| `aof_backup_enabled` | `aof-backup-enabled` | bool |
| `maxmemory_policy` | `maxmemory-policy` | string |

Note: Terraform uses native booleans (`true`/`false`) and native integers, not strings.

### Terraform Variable Resolution

Variables use `var.name` syntax. Locals use `local.name`.

Variable definitions appear in:
- `variables.tf`: declares the variable with optional `default`
- `*.tfvars` or `terraform.tfvars`: assigns values

```hcl
# variables.tf
variable "sku_name" {
  type    = string
  default = "Premium"
}

# terraform.tfvars
sku_name    = "Premium"
capacity    = 2
shard_count = 3
```

Resolution order:
1. `.tfvars` file values
2. `default` in the variable declaration
3. Flag as unresolvable

### Terraform Related Resources

Firewall rules and private endpoints are separate resources in Terraform:

```hcl
resource "azurerm_redis_firewall_rule" "example" {
  name                = "allow-azure"
  redis_cache_name    = azurerm_redis_cache.example.name
  resource_group_name = azurerm_resource_group.example.name
  start_ip            = "0.0.0.0"
  end_ip              = "0.0.0.0"
}

resource "azurerm_private_endpoint" "example" {
  # look for private_service_connection with subresource_names = ["redisCache"]
}
```

Geo-replication uses `azurerm_redis_linked_server`. Scheduled patching uses the `patch_schedule` block inside `azurerm_redis_cache` — this is not available in AMR.

---

## Feature Detection

After extracting all properties, determine which features are active. This table drives the migration path selection and AMR template generation.

| Feature | Detection Criteria | Migration Impact |
|---------|-------------------|------------------|
| **VNet injection** | `subnetId` is present and non-empty | Not available in AMR — must create a Private Endpoint resource |
| **Persistence (RDB)** | `rdb-backup-enabled` = `true` or `"true"` | Map frequency: `15` → `1h`, `30` → `1h`, `60` → `1h`, `360` → `6h`, `720` → `12h`, `1440` → `12h` |
| **Persistence (AOF)** | `aof-backup-enabled` = `true` or `"true"` | Map to `aofFrequency: "always"` or `"1s"` |
| **Clustering** | `shardCount` ≥ 1 (including 1) | Affects SKU selection and clustering policy. `shardCount: 1` = OSS Cluster. |
| **Multi-replica (MRPP)** | `replicasPerPrimary` > 1 | Affects SKU selection |
| **Firewall rules** | Child resources of type `firewallRules` present | Not available in AMR — must use Private Endpoint + NSG |
| **Geo-replication** | Child resources of type `linkedServers` present | Convert to AMR active geo-replication (active-active model) |
| **Managed identity** | `identity` block is present | Preserved in the AMR cluster resource |
| **Non-SSL port** | `enableNonSslPort` = `true` | Convert to AMR `clientProtocol` setting. AMR supports a "Non-TLS access only" mode. |
| **Scheduled patching** | `patchSchedule` child resource or property present | Not available in AMR — AMR manages patching automatically. Remove and note for user. |
| **Availability zones** | `zones` array is present and non-empty | Do NOT include in AMR — zone redundancy is automatic |
| **Diagnostic settings** | `Microsoft.Insights/diagnosticSettings` resources targeting the cache | These do not transfer directly to AMR. The resource ID and category names change for `Microsoft.Cache/redisEnterprise`. Advise the user to reconfigure diagnostics for the new AMR resource. |

See `feature-comparison.md` for detailed feature gap analysis between ACR and AMR.

---

## Extracted Configuration Model

After parsing, the agent should have resolved values for all of the following. This is the complete set of inputs needed for the transformation step:

```
Source Configuration
├── Cache Name
├── Tier: Basic | Standard | Premium
├── SKU Code: e.g. C3, P2
├── Capacity: 0-6 (C) or 1-5 (P)
├── Shard Count: 0+ (Premium only)
├── Replicas Per Primary: 1+ (Premium only)
├── Persistence
│   ├── RDB Enabled: true/false
│   ├── RDB Frequency: 60/360/720 (minutes)
│   ├── AOF Enabled: true/false
│   └── Storage connections (noted but not migrated)
├── Networking
│   ├── Has VNet Injection: true/false
│   ├── Subnet ID: resource ID string
│   ├── Static IP: string (Premium VNet only)
│   ├── Public Network Access: Enabled/Disabled
│   ├── Has Firewall Rules: true/false
│   └── Has Private Endpoint: true/false
├── Eviction Policy: maxmemory-policy value
├── Enable Non-SSL Port: true/false
├── Minimum TLS Version: string
├── Zones: array of zone IDs
├── Identity
│   ├── Has Identity: true/false
│   └── Identity Block: full identity object
├── Tags: key-value map
├── Has Geo-Replication: true/false
└── Has MRPP: true/false (replicasPerPrimary > 1)
```

If any value could not be resolved from the template and parameters, mark it as `<unresolved: paramName>` and surface it to the user for clarification before proceeding with transformation.

---

## Common Pitfalls

### Boolean-as-String vs Native Boolean

In ARM JSON `redisConfiguration`, persistence flags are frequently strings:

```json
"rdb-backup-enabled": "true"
```

Not native booleans. Always normalize to a real boolean during extraction. Check for both `"true"` (string) and `true` (boolean). In Terraform, these are always native booleans.

### `redisConfiguration` as a Variable Reference

Some ARM templates set the entire `redisConfiguration` to a variable:

```json
"redisConfiguration": "[variables('redisConfiguration')]"
```

When this happens:
1. Resolve the variable from the template's `variables` section
2. If the variable itself contains parameter references, resolve those too
3. As a last resort, scan the parameters file for common parameter names like `rdbBackupEnabled`, `rdb-backup-enabled`, `aofBackupEnabled`, `aof-backup-enabled`, `maxmemoryPolicy`

Do not assume persistence is disabled just because `redisConfiguration` is a variable — always attempt resolution.

### `shardCount` = 0 vs Absent vs 1+

- `shardCount` absent → non-clustered cache (default behavior)
- `shardCount` = `0` → also non-clustered (explicit zero)
  - ⚠️ Note: Azure portal exports may include `shardCount: 0`, but this value is **invalid for new deployments** — the ARM API rejects it. When parsing, treat `0` the same as absent (non-clustered). Our example templates omit `shardCount` for non-clustered scenarios.
- `shardCount` = `1` → **clustered** (OSS Cluster protocol with 1 shard — this is NOT the same as non-clustered)
- `shardCount` > `1` → clustered cache with multiple shards

⚠️ **Critical distinction**: `shardCount: 1` means the cache uses OSS Cluster protocol — this is NOT the same as non-clustered. Only `0` or absent = truly non-clustered. See [iac-amr-template-structure.md § Clustering Policy Decision Matrix](iac-amr-template-structure.md#6-clustering-policy-decision-matrix) for how to choose the AMR `clusteringPolicy` based on this value.

### `replicasPerMaster` (Legacy) vs `replicasPerPrimary`

Older ARM templates use the deprecated property name `replicasPerMaster`. It is functionally identical to `replicasPerPrimary`. Check for both:

```json
"replicasPerPrimary": 2
// or in older templates:
"replicasPerMaster": 2
```

If both are present (unlikely but possible), prefer `replicasPerPrimary`.

### Nested vs Flat Resource Declarations

ARM templates can declare child resources in two ways:

**Flat** (separate entry in `resources` array):
```json
{
  "type": "Microsoft.Cache/redis/firewallRules",
  "name": "[concat(parameters('cacheName'), '/allowAzure')]",
  "dependsOn": ["[resourceId('Microsoft.Cache/redis', parameters('cacheName'))]"],
  "properties": { "startIP": "0.0.0.0", "endIP": "0.0.0.0" }
}
```

**Nested** (inside the parent resource's `resources` array):
```json
{
  "type": "Microsoft.Cache/redis",
  "resources": [
    {
      "type": "firewallRules",
      "name": "allowAzure",
      "properties": { "startIP": "0.0.0.0", "endIP": "0.0.0.0" }
    }
  ]
}
```

Scan both the top-level `resources` array and any nested `resources` arrays within the cache resource.

### Parameter Expressions in SKU Fields

SKU fields are frequently parameterized. A common pattern:

```json
"sku": {
  "name": "[parameters('skuName')]",
  "family": "[parameters('skuFamily')]",
  "capacity": "[parameters('skuCapacity')]"
}
```

All three must be resolved to determine the source SKU. If any cannot be resolved, the agent cannot determine the correct AMR target SKU and must ask the user.
