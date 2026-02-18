# Feature Comparison: Azure Cache for Redis vs Azure Managed Redis (AMR)

This document provides a comparison of features between Azure Cache for Redis and AMR.

> **Note**: For the most up-to-date information, use the Microsoft Learn MCP server to fetch current documentation from `https://learn.microsoft.com/azure/azure-cache-for-redis/`.

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
| Non-clustered Mode | ✅ | ✅ |
| Online Scaling | ✅ | ✅ |
| Max Shards | 15 (Premium) | N/A (sharding is managed internally) |

## High Availability & Disaster Recovery

| Feature | ACR Tiers | AMR |
|---------|----------|-----|
| Zone Redundancy | ✅ (Premium) | ✅ |
| Active Geo-Replication | ❌ | ✅ |
| Passive Geo-Replication | ✅ (Premium) | ✅ |
| Data Persistence (RDB) | ✅ (Premium) | ✅ |
| Data Persistence (AOF) | ✅ (Premium) | ✅ |

## Security

| Feature | ACR Tiers | AMR |
|---------|----------|-----|
| TLS Encryption | ✅ | ✅ |
| VNet Integration | ✅ (Premium) | ✅ |
| Private Endpoint | ✅ | ✅ |
| Microsoft Entra Authentication | ✅ | ✅ |
| Access Key Authentication | ✅ | ✅ |
| RBAC | ✅ | ✅ |

## Performance Tiers

### ACR Tiers (Basic/Standard/Premium)
- **Basic**: Single node, no SLA, development/test
- **Standard**: Two-node replicated, 99.9% SLA
- **Premium**: Clustering, VNet, persistence, geo-replication

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

### Breaking Changes to Watch For
- Command syntax differences between Redis versions
- Configuration parameter changes
- Connection string format changes
- Authentication method updates

## Additional Resources

Fetch the latest documentation using the MCP server:
- AMR Overview: `/azure/azure-cache-for-redis/managed-redis/managed-redis-overview`
- Migration Guide: `/azure/azure-cache-for-redis/managed-redis/managed-redis-migration`
- SKU Selection: `/azure/azure-cache-for-redis/managed-redis/managed-redis-best-practices-sku`
