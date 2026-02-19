# Azure CLI Reference: ACR Cache Discovery (Basic/Standard/Premium)

This reference provides **Azure CLI (`az`) commands** to list Azure Cache for Redis (ACR) instances and extract key details used for AMR SKU selection.

> **Scope**: ACR **Basic/Standard/Premium** only. Enterprise/Enterprise Flash use different CLI commands and are out of scope for this skill.

---

## Prerequisites

```bash
az login
az account set --subscription <subscriptionId>
```

---

## List ACR Caches

### List all caches in a subscription
```bash
az redis list --query "[].{name:name, rg:resourceGroup, location:location, tier:sku.tier, sku:sku.name, capacity:sku.capacity, shards:shardCount, replicas:replicasPerMaster}" -o table
```

### List caches in a resource group
```bash
az redis list -g <resourceGroup> --query "[].{name:name, location:location, tier:sku.tier, sku:sku.name, capacity:sku.capacity, shards:shardCount, replicas:replicasPerMaster}" -o table
```

> **Notes**
> - `shardCount` is only relevant for **Premium clustered** caches; if it is `null` or `0`, the cache is non‑clustered.
> - `replicasPerMaster` applies to Premium caches when **multiple replicas per primary (MRPP)** are enabled. A value of `null` means the default of **1 replica** is used.

---

## Show Details for One Cache

```bash
az redis show -g <resourceGroup> -n <cacheName> --query "{
  name:name,
  location:location,
  tier:sku.tier,
  sku:sku.name,
  capacity:sku.capacity,
  shardCount:shardCount,
  replicasPerMaster:replicasPerMaster,
  redisVersion:redisVersion,
  nonSslPort:enableNonSslPort,
  minimumTlsVersion:minimumTlsVersion,
  publicNetworkAccess:publicNetworkAccess
}" -o json
```

---

## Persistence & Configuration Features

```bash
az redis show -g <resourceGroup> -n <cacheName> --query "{
  rdbBackup:redisConfiguration.'rdb-backup-enabled',
  rdbFrequency:redisConfiguration.'rdb-backup-frequency',
  rdbMaxSnapshots:redisConfiguration.'rdb-backup-max-snapshots',
  aofBackup:redisConfiguration.'aof-backup-enabled',
  maxmemoryPolicy:redisConfiguration.'maxmemory-policy'
}" -o json
```

---

## Geo-Replication (Premium)

```bash
az redis server-link list -g <resourceGroup> -n <cacheName> -o table
```

If links are returned, the cache uses passive geo-replication (active geo-replication is an AMR feature, not available on ACR Premium).

---

## Export Cache Metadata to JSON

```bash
az redis show -g <resourceGroup> -n <cacheName> -o json > cache.json
```

---

## Recommended Fields to Collect

When gathering cache details for migration sizing, capture:
- **Location**
- **SKU tier/name/capacity**
- **Shard count** (Premium clustered)
- **Replicas per primary** (MRPP)
- **Redis version**
- **Persistence** (RDB/AOF)
- **Network/TLS settings**

These map directly to AMR tier selection and pricing scripts.
