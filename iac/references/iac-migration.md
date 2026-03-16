# IaC Migration Reference: ACR → AMR Template Transformation

Quick reference for understanding what `Convert-AcrToAmr.ps1` transforms. The script handles all transformation logic — this doc covers decisions requiring human judgment and a property quick-reference for customer conversations.

> **Scope**: ACR Basic, Standard, and Premium tiers only. Enterprise/Enterprise Flash is NOT covered.

---

## Clustering Policy Decision Matrix

AMR uses clustering internally for all SKUs. The `clusteringPolicy` property determines how this is exposed to the client. **This is the one decision that may require customer input.**

| Source ACR Configuration | Recommended AMR `clusteringPolicy` | Reason |
|-------------------------|-----------------------------------|--------|
| Basic/Standard (any C*) | `EnterpriseCluster` | Preserves single-endpoint behavior |
| Premium non-clustered (`shardCount` ≤ 1) | `EnterpriseCluster` | Preserves single-endpoint behavior |
| Premium clustered (`shardCount` > 1), client NOT cluster-aware | `EnterpriseCluster` | Avoids app code changes |
| Premium clustered (`shardCount` > 1), client IS cluster-aware | `OSSCluster` | Client already handles cluster topology |

**Default**: Always use `EnterpriseCluster` unless the customer explicitly confirms a cluster-aware client (e.g., StackExchange.Redis cluster mode, Lettuce cluster mode, redis-py ClusterClient).

> **Warning**: `OSSCluster` requires a cluster-aware client library. Using it with a non-cluster-aware client causes connection failures.

---

## Properties Quick Reference

### Removed (No AMR Equivalent)

| ACR Property | Why Removed |
|-------------|------------|
| `enableNonSslPort` | AMR is TLS-only (port 10000) |
| `shardCount` | AMR manages sharding internally |
| `replicasPerPrimary` / `replicasPerMaster` | Not supported; use active geo-replication |
| `redisVersion` | AMR always runs Redis 7.4 |
| `staticIP` | Not supported |
| `subnetId` | VNet injection → Private Endpoint (auto-converted by script) |
| `maxmemory-reserved`, `maxfragmentationmemory-reserved`, `maxmemory-delta` | AMR manages internally |
| `aad-enabled` | Use `identity` on cluster resource instead |
| Storage connection strings (RDB/AOF) | AMR uses managed storage |

### Changed

| ACR | AMR | Change |
|-----|-----|--------|
| Single resource (`Microsoft.Cache/redis`) | Two resources: cluster + database | Script splits automatically |
| SKU: `name`/`family`/`capacity` | SKU: compound name (e.g., `Balanced_B50`) | Script maps via [SKU Mapping Guide](../../references/sku-mapping.md) |
| `maxmemory-policy` (kebab-case) | `evictionPolicy` (PascalCase) | e.g., `volatile-lru` → `VolatileLRU` |
| Persistence: flat config strings | Persistence: structured object | `rdb-backup-frequency: "60"` → `rdbFrequency: "1h"` |
| VNet injection / firewall rules | Private Endpoint | Script auto-adds PE resource; DNS zone changes to `privatelink.redisenterprise.cache.azure.net` |
| Passive geo-replication | Active geo-replication | Different configuration model |

### Preserved As-Is
`name`, `location`, `zones`, `identity`, `tags`, `minimumTlsVersion`
