# Migration Overview: Azure Cache for Redis to Azure Managed Redis

> **Source**: https://learn.microsoft.com/en-us/azure/redis/migrate/migrate-overview
> 
> **Last Updated**: February 2026 - Check source URL for the latest information.

## Overview

This guide covers migrating from Azure Cache for Redis to Azure Managed Redis (AMR).

---

## Basic/Standard/Premium to AMR Migration

### Feature Comparison: ACR Tiers vs AMR

| Feature | Basic | Standard | Premium | AMR (All Tiers) |
|---------|-------|----------|---------|-----------------|
| SLA | N/A | 99.9% | 99.9% | Up to 99.999% |
| Data encryption in transit | Yes | Yes | Yes | Yes |
| Network isolation | Yes | Yes | Yes | Yes |
| Scaling up/out | Yes | Yes | Yes | Yes |
| Scaling down/in | Yes | Yes | Yes | No |
| OSS clustering | No | No | Yes | Yes |
| Data persistence | No | No | Yes | Yes |
| Zone redundancy | No | Preview | Yes | Yes (with HA) |
| Geo-replication | No | No | Passive | **Active** |
| Redis Modules | No | No | No | **Yes** |
| Import/Export | No | No | Yes | Yes |
| Microsoft Entra ID | Yes | Yes | Yes | Yes |
| Non-HA option | N/A | No | No | Yes |

### Connection Changes

| Setting | Azure Cache for Redis | Azure Managed Redis |
|---------|----------------------|---------------------|
| DNS suffix | `.redis.cache.windows.net` | `<region>.redis.azure.net` |
| TLS port | 6380 | **10000** |
| Non-TLS port | 6379 | Not supported |
| Node TLS ports | 13XXX | 85XX |
| Redis version | 6 | 7.4 |

---

## SKU Mapping: ACR to AMR

### Basic/Standard Tier Mappings

| Azure Cache for Redis | Azure Managed Redis | Memory Change |
|----------------------|---------------------|---------------|
| Basic/Standard C0 | Balanced B0 | +50% |
| Basic/Standard C1 | Balanced B1 | 0% |
| Basic/Standard C2 | Balanced B3 | +17% |
| Basic/Standard C3 | Balanced B5 | 0% |
| Basic/Standard C4 | Memory Optimized M10* | -8% |
| Basic/Standard C4 | Memory Optimized M20** | +46% |
| Basic/Standard C5 | Memory Optimized M20* | -8% |
| Basic/Standard C5 | Memory Optimized M50** | +57% |
| Basic/Standard C6 | Memory Optimized M50 | +12% |

### Premium Tier Mappings

| Azure Cache for Redis | Azure Managed Redis | Memory Change |
|----------------------|---------------------|---------------|
| Premium P1 | Balanced B5 | 0% |
| Premium P2 | Balanced B10* | -8% |
| Premium P2 | Balanced B20** | +46% |
| Premium P3 | Balanced B20* | -8% |
| Premium P3 | Balanced B50** | +57% |
| Premium P4 | Balanced B50 | +12% |
| Premium P5 | Balanced B100 | 0% |

**Notes:**
- \* Cost-efficient option - ensure peak memory usage ≤ suggested AMR usable memory
- \*\* Larger memory option if future dataset growth is expected

> **Important — Clustering Policy**: Non-clustered ACR caches (Basic, Standard, and non-clustered Premium) should be migrated to AMR with **Enterprise clustering policy** enabled. AMR uses clustering internally for all SKUs, and the default OSS clustering policy exposes cluster topology to the client, which may require application code changes (e.g., switching to a cluster-aware Redis client). Enterprise clustering policy hides this from the application, preserving the single-endpoint behavior these caches had on ACR.

> **Important — Network Isolation**: AMR does not support VNet injection. ACR Premium caches using VNet injection should be migrated to AMR with **Private Link** (Private Endpoints) for network isolation.

### Premium Clustered Caches
- Refer to the [SKU Mapping Guide — Premium Clustered tables](sku-mapping.md#premium-clustered--amr-mapping) for detailed shard-count-to-SKU mappings
- The right AMR tier depends on *why* the cache was clustered — see [Mapping Guiding Principles](sku-mapping.md#mapping-guiding-principles)

## Migration Strategies

### Option 1: Create New Cache (Simplest)
**Best for**: Look-aside caches, data can be rebuilt

1. Create new Azure Managed Redis instance
2. Update application connection string
3. Delete old cache

**Pros**: Simple  
**Cons**: Data loss (must rebuild cache)

### Option 2: Export/Import via RDB File
**Best for**: Premium tier caches, acceptable brief data inconsistency

1. Create AMR instance (same size or larger)
2. Export RDB from existing cache to Azure Storage
3. Import RDB into new AMR instance
4. Update application connection string

**Pros**: Preserves data snapshot  
**Cons**: Data written after export is lost

### Option 3: Dual-Write Strategy
**Best for**: Zero downtime requirements, session stores

1. Create AMR instance (same size or larger)
2. Modify app to write to both caches
3. Continue reading from original cache
4. After data sync period, switch reads to AMR
5. Delete original cache

**Pros**: Zero downtime, no data loss  
**Cons**: Requires two caches temporarily

### Option 4: Programmatic Migration (RIOT)
**Best for**: Full control, large datasets

Tools:
- **[RIOT](https://redis.io/docs/latest/integrate/riot/)** - Popular migration tool
- **[redis-copy](https://github.com/deepakverma/redis-copy)** - Open-source copy tool

1. Create VM in same region as source cache
2. Create AMR instance
3. Flush target cache (NOT source!)
4. Run migration tool

**Pros**: Full control, customizable  
**Cons**: Requires setup, development effort

---

## AMR Performance Tiers

For AMR tier definitions and selection guidance, see [Feature Comparison — AMR Tiers](feature-comparison.md#amr-tiers) and [SKU Mapping — Selection Criteria](sku-mapping.md#selection-criteria).

---

## Quick Reference Links

- [Create Azure Managed Redis Instance](https://learn.microsoft.com/azure/redis/quickstart-create-managed-redis)
- [Import/Export Data](https://learn.microsoft.com/azure/redis/how-to-import-export-data)
- [Scale AMR Instance](https://learn.microsoft.com/azure/redis/how-to-scale)
- [Choosing the Right Tier](https://learn.microsoft.com/azure/redis/overview#choosing-the-right-tier)
- [RIOT Migration Tool](https://redis.io/docs/latest/integrate/riot/)
- [Data Migration with RIOT-X](https://techcommunity.microsoft.com/blog/azure-managed-redis/data-migration-with-riot-x-for-azure-managed-redis/4404672)
