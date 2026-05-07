# Feature Comparison: Azure Cache for Redis vs Azure Managed Redis (AMR)

This document provides a comparison of features between Azure Cache for Redis and AMR.

> **Note**: For the most up-to-date information, use the Microsoft Learn MCP server to fetch current documentation from `https://learn.microsoft.com/azure/redis/`.

## Overview

| Feature Category | Azure Cache for Redis | Azure Managed Redis (AMR) |
|-----------------|---------------------------|--------------------------|
| Redis Version | Redis 6.x | Redis 7.x with Redis Stack |
| Redis Modules | No (Basic/Standard/Premium) | Full Redis Stack support |
| Availability | Up to 99.99% SLA | Up to 99.99% SLA |

## AMR Feature Comparison by Tier

| Feature | Memory Optimized | Balanced | Compute Optimized | Flash Optimized |
|---------|------------------|----------|-------------------|-----------------|
| Size (GB) | 12 - 1920 | 0.5 - 960 | 3 - 720 | 250 - 4500 |
| SLA | Yes | Yes | Yes | Yes |
| Data encryption in transit | Yes (Private endpoint) | Yes (Private endpoint) | Yes (Private endpoint) | Yes (Private endpoint) |
| Replication and failover | Yes | Yes | Yes | Yes |
| Network isolation | Yes | Yes | Yes | Yes |
| Microsoft Entra ID auth | Yes | Yes | Yes | Yes |
| Scaling | Yes | Yes | Yes | Yes |
| High availability | Yes* | Yes* | Yes* | Yes* |
| Data persistence | Yes | Yes | Yes | Yes |
| Geo-replication | Yes (Active) | Yes (Active) | Yes (Active) | No |
| Non-clustered instances | Yes | Yes | Yes | No |
| Connection audit logs | Yes (Event-based) | Yes (Event-based) | Yes (Event-based) | Yes (Event-based) |
| RedisJSON | Yes | Yes | Yes | Yes |
| RediSearch (vector search) | Yes | Yes | Yes | No |
| RedisBloom | Yes | Yes | Yes | Yes |
| RedisTimeSeries | Yes | Yes | Yes | Yes |
| Import/Export | Yes | Yes | Yes | Yes |

\* When High availability is enabled, AMR is zone redundant in regions with multiple availability zones.

> **Note**: B0 and B1 SKUs don't support active geo-replication. Sizes over 235 GB are in Public Preview.

## Redis Modules / Data Types

| Module/Feature | ACR Tiers | AMR |
|---------------|----------|-----|
| Core Redis Data Types | ✅ | ✅ |
| RedisJSON | ❌ | ✅ |
| RediSearch | ❌ | ✅ |
| RedisTimeSeries | ❌ | ✅ |
| RedisBloom | ❌ | ✅ |

## Clustering & Scaling

| Feature | ACR Tiers | AMR |
|---------|----------|-----|
| Clustering | ✅ (Premium tier) | ✅ |
| Non-clustered Mode | ✅ | ✅ (≤ 24 GB) |
| Online Scaling | ✅ | ✅ |
| Max Shards | 15 (Premium) | N/A (sharding is managed internally) |

## High Availability & Disaster Recovery

| Feature | ACR Tiers | AMR |
|---------|----------|-----|
| Zone Redundancy | ✅ (Premium) | ✅ |
| Geo-Replication | Passive (Premium; Failover supported) | Active (except B0, B1, Flash; no explicit Failover command) |
| Data Persistence (RDB) | ✅ (Premium) | ✅ |
| Data Persistence (AOF) | ✅ (Premium) | ✅ |

> **Note**: AMR geo-replication is active. Because there is no explicit Failover command, applications must handle region failover themselves.

## Security

| Feature | ACR Tiers | AMR |
|---------|----------|-----|
| TLS Encryption | ✅ | ✅ |
| TLS/Non-TLS Mode | TLS 6380 + non-TLS 6379 simultaneously | One mode only at a time on port 10000; set at creation via `clientProtocol` |
| VNet Integration | ✅ (Premium) | ❌ (use Private Link) |
| Private Endpoint | ✅ | ✅ |
| Microsoft Entra Authentication | ✅ | ✅ |
| Access Key Authentication | ✅ | ✅ |
| RBAC | ✅ | ❌ (Entra ID RBAC not yet supported; Entra ID auth only) |

## Operational & Compatibility

| Feature | ACR Tiers | AMR |
|---------|----------|-----|
| Redis Databases | Up to 16 by default, 64 on Premium | Database 0 only; use key prefixes for logical separation |
| Keyspace Notifications | ✅ | ❌ (not currently available) |
| Reboot | ✅ (manual node reboot) | ❌ (nodes managed automatically; use Flush to clear data) |
| Scheduled Updates | ✅ | ✅ (Preview) |

## Performance Tiers

### ACR Tiers (Basic/Standard/Premium)
- **Basic**: Single node, no SLA, development/test
- **Standard**: Two-node replicated, 99.9% SLA
- **Premium**: Clustering, VNet injection, persistence, geo-replication
  - **Note**: AMR does not support VNet injection — use Private Link for network isolation instead

### AMR Tiers
- **Memory Optimized**: High memory-to-compute ratio workloads
- **Balanced**: General-purpose workloads
- **Compute Optimized**: High throughput, large number of clients, or compute-intensive
- **Flash Optimized**: Large datasets with tiered storage

## Migration Considerations

### Features to Verify Before Migration
1. Check if your application uses any Premium-tier-only features
2. Verify Redis commands compatibility
3. Review client library compatibility with Redis 7.x
4. Assess impact of potential Redis module adoption
5. Check if the application uses multiple Redis databases
6. Check if the application relies on keyspace notifications
7. Check if the application connects via both TLS and non-TLS ports simultaneously

### Breaking Changes to Watch For
- Command syntax differences between Redis versions
- Configuration parameter changes
- Connection string format changes
- Authentication method updates

## Additional Resources

Fetch the latest documentation using the MCP server:
- AMR Overview: `/azure/redis/overview` - Consolidated Azure Managed Redis overview and tier selection guidance
- Migration Hub: `/azure/redis/migrate/migrate-overview` - Three-phase migration hub: understand differences, compare options, and plan execution
- Migration Options: `/azure/redis/migrate/migrate-basic-standard-premium-options` - Compares self-service (recommended) with migration tooling (preview)
- SKU Selection Guidance: `/azure/redis/migrate/migrate-basic-standard-premium-understand` - ACR vs AMR differences plus size and SKU selection guidance
