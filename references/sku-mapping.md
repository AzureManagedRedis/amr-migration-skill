# SKU Mapping Guide: Azure Cache for Redis to Azure Managed Redis

This guide helps you select the appropriate Azure Managed Redis (AMR) SKU when migrating from Azure Cache for Redis.

> **Source**: Internal SKU mapping spreadsheet (ACR_AMR.xlsx)
> 
> **Last Updated**: February 2026

---

## 💰 Dynamic Pricing

Use the pricing scripts to get real-time pricing with monthly cost calculations. See [Pricing Tier Rules](pricing-tiers.md) for detailed calculation logic and examples.

```powershell
# Quick examples
.\scripts\get_redis_price.ps1 -SKU M10 -Region westus2          # AMR with HA
.\scripts\get_redis_price.ps1 -SKU M10 -Region westus2 -NoHA    # AMR without HA
.\scripts\get_redis_price.ps1 -SKU P2 -Region westus2 -Shards 3 # ACR Premium clustered
```

> **Official Quotes**: Use [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/?service=managed-redis)

---

## ⚠️ Important: Memory Reservation

**Both Azure Cache for Redis (ACR) and Azure Managed Redis (AMR) reserve ~20% of memory for system overhead by default.** However, customers may have configured custom memory reservations. The "ACR Usable" values in the tables below assume default (~20%) reservations.

**To get the actual usable memory for an ACR cache**, query the custom reservation settings whenever possible:

```bash
az redis show -n <cache-name> -g <resource-group> -o json \
  --query "{maxfragmentationmemoryReserved: redisConfiguration.maxfragmentationmemoryReserved, maxmemoryReserved: redisConfiguration.maxmemoryReserved}"
```

Both values are returned in **MB**. Add them together and subtract from the nominal SKU capacity to get the actual usable memory:

> **Actual Usable = SKU Capacity − (maxmemoryReserved + maxfragmentationmemoryReserved)**

Use this as the source of truth for sizing instead of the default "ACR Usable" column values.

| Metric | Description |
|--------|-------------|
| **Advertised Size** | The SKU label (e.g., M20 = 24 GB, B50 = 60 GB) |
| **Usable Memory** | ~80% of advertised size available for your data |

### Example Calculation
- **M50 SKU**: Advertised 60 GB → **~48 GB usable** for data
- **B100 SKU**: Advertised 120 GB → **~96 GB usable** for data

### Migration Sizing Rule
When migrating, compare **usable memory to usable memory**:
1. Check your current ACR cache's **actual used memory** (not SKU size) using `scripts/get_acr_metrics.ps1` (or `.sh`)
2. Select an AMR SKU whose **usable memory** (80% of advertised size) covers your peak usage

**Example**: If your P2 cache (13 GB advertised, ~10.4 GB usable) is using 8 GB of data:
- Need AMR with at least 8 GB usable
- **M10 (12 GB × 80% = 9.6 GB usable) - sufficient** ✓
- With an eviction policy set, AMR can safely run at full memory utilization

---

## Mapping Guiding Principles

1. **Use ACR metrics to determine workload dimensions**: Assess dataset size, Server Load, bandwidth, and connected clients using the metrics scripts. Choose the cheapest AMR SKU that covers all dimensions.
2. Memory Optimized (M-series) offers the most capacity per dollar, but starts from M10. If the workload is compute-heavy, a higher tier (B or X-series) may be needed despite lower memory requirements.
3. For ACR clustered caches, the right AMR tier depends on *why* it was clustered:
   - **Clustered for capacity** (large dataset, low load) → **M-series** is most cost-effective
   - **Clustered for processing power** (small dataset, high Server Load) → **X-series** is best
   - **Truly balanced workload** (moderate data + moderate compute) → **B-series**
4. For compute-intensive tasks, Compute Optimized (X-Series) offers more compute power for the same amount of memory, but at a higher cost.
5. **Always calculate usable memory (advertised × 0.8) when comparing SKUs**

---

## AMR SKU Specs

For complete AMR SKU definitions (M, B, X, Flash series) with memory, vCPUs, and max connections, see [AMR SKU Specs](amr-sku-specs.md).

---

## Basic/Standard Non-Clustered → AMR Mapping

| Tier | SKU | ACR HA | ACR Usable | Target AMR | AMR HA | AMR Advertised (Usable) |
|------|-----|--------|------------|------------|--------|-------------------------|
| **Basic** | C0 | No | 0.2 GB | B0 | No | 0.5 GB (0.4 GB) |
| | C1 | No | 0.8 GB | B1 | No | 1 GB (0.8 GB) |
| | C2 | No | 2 GB | B3 | No | 3 GB (2.4 GB) |
| | C3 | No | 4.8 GB | B5 | No | 6 GB (4.8 GB) |
| | C4 | No | 10.4 GB | M10 or M20 | No | 12 GB (9.6 GB) or 24 GB (19.2 GB) |
| | C5 | No | 20.8 GB | M20 or M50 | No | 24 GB (19.2 GB) or 60 GB (48 GB) |
| | C6 | No | 42.4 GB | M50 | No | 60 GB (48 GB) |
| **Standard** | C0 | Yes | 0.2 GB | B0 | Yes | 0.5 GB (0.4 GB) |
| | C1 | Yes | 0.8 GB | B1 | Yes | 1 GB (0.8 GB) |
| | C2 | Yes | 2 GB | B3 | Yes | 3 GB (2.4 GB) |
| | C3 | Yes | 4.8 GB | B5 | Yes | 6 GB (4.8 GB) |
| | C4 | Yes | 10.4 GB | M10 or M20 | Yes | 12 GB (9.6 GB) or 24 GB (19.2 GB) |
| | C5 | Yes | 20.8 GB | M20 or M50 | Yes | 24 GB (19.2 GB) or 60 GB (48 GB) |
| | C6 | Yes | 42.4 GB | M50 | Yes | 60 GB (48 GB) |

**Note**: Use the smallest SKU whose usable memory covers your peak usage — AMR can safely run at full memory utilization with an eviction policy set. Basic (No HA) migrations may use AMR non-HA (`-NoHA`) for dev/test to reduce cost; Standard (HA) migrations should use AMR with HA (the default).

---

## Premium Non-Clustered → AMR Mapping

| SKU | ACR HA | ACR Usable | Target AMR | AMR HA | AMR Advertised (Usable) |
|-----|--------|------------|------------|--------|-------------------------|
| P1 | Yes | 4.8 GB | B5 | Yes | 6 GB (4.8 GB) |
| P2 | Yes | 10.4 GB | B10 or B20 | Yes | 12 GB (9.6 GB) or 24 GB (19.2 GB) |
| P3 | Yes | 20.8 GB | B20 or B50 | Yes | 24 GB (19.2 GB) or 60 GB (48 GB) |
| P4 | Yes | 42.4 GB | B50 | Yes | 60 GB (48 GB) |
| P5 | Yes | 96 GB | B100 | Yes | 120 GB (96 GB) |

---

## Premium Clustered → AMR Mapping

> **Note**: ACR Premium is always HA, so all clustered mappings below target AMR with HA enabled (the default).

### P1 Clustered (6 GB per shard)

| Shards | ACR Usable | Target AMR | AMR Advertised (Usable) |
|--------|------------|------------|-------------------------|
| 1 | 4.8 GB | B5 | 6 GB (4.8 GB) |
| 2 | 9.6 GB | B10 | 12 GB (9.6 GB) |
| 3 | 14.4 GB | B20 | 24 GB (19.2 GB) |
| 4 | 19.2 GB | B20 | 24 GB (19.2 GB) |
| 5 | 24 GB | B50 | 60 GB (48 GB) |
| 6 | 28.8 GB | B50 | 60 GB (48 GB) |
| 7 | 33.6 GB | B50 | 60 GB (48 GB) |
| 8 | 38.4 GB | B50 | 60 GB (48 GB) |
| 9 | 43.2 GB | B50 | 60 GB (48 GB) |
| 10 | 48 GB | B50 | 60 GB (48 GB) |
| 11-15 | 52.8-72 GB | B100 | 120 GB (96 GB) |

### P2 Clustered (13 GB per shard)

| Shards | ACR Usable | Target AMR | AMR Advertised (Usable) |
|--------|------------|------------|-------------------------|
| 1 | 10.4 GB | B20 | 24 GB (19.2 GB) |
| 2 | 20.8 GB | B50 | 60 GB (48 GB) |
| 3 | 31.2 GB | B50 | 60 GB (48 GB) |
| 4 | 41.6 GB | B50 | 60 GB (48 GB) |
| 5 | 52 GB | B100 | 120 GB (96 GB) |
| 6 | 62.4 GB | B100 | 120 GB (96 GB) |
| 7 | 72.8 GB | B100 | 120 GB (96 GB) |
| 8 | 83.2 GB | B100 | 120 GB (96 GB) |
| 9 | 93.6 GB | B100 | 120 GB (96 GB) |
| 10 | 104 GB | B150 | 180 GB (144 GB) |
| 11-12 | 114-125 GB | B150 | 180 GB (144 GB) |
| 13-14 | 135-146 GB | B250 | 240 GB (192 GB) |
| 15 | 156 GB | B250 | 240 GB (192 GB) |

### P3 Clustered (26 GB per shard)

| Shards | ACR Usable | Target AMR | AMR Advertised (Usable) |
|--------|------------|------------|-------------------------|
| 1 | 20.8 GB | B50 | 60 GB (48 GB) |
| 2 | 41.6 GB | B50 | 60 GB (48 GB) |
| 3 | 62.4 GB | B100 | 120 GB (96 GB) |
| 4 | 83.2 GB | B100 | 120 GB (96 GB) |
| 5 | 104 GB | B150 | 180 GB (144 GB) |
| 6 | 124.8 GB | B150 | 180 GB (144 GB) |
| 7 | 145.6 GB | B250 | 240 GB (192 GB) |
| 8 | 166.4 GB | B250 | 240 GB (192 GB) |
| 9 | 187.2 GB | B250 | 240 GB (192 GB) |
| 10 | 208 GB | B350 | 360 GB (288 GB) |
| 11-12 | 229-250 GB | B350 | 360 GB (288 GB) |
| 13 | 270.4 GB | B350 | 360 GB (288 GB) |
| 14-15 | 291-312 GB | B500 | 480 GB (384 GB) |

### P4 Clustered (53 GB per shard)

| Shards | ACR Usable | Target AMR | AMR Advertised (Usable) |
|--------|------------|------------|-------------------------|
| 1 | 42.4 GB | B50 | 60 GB (48 GB) |
| 2 | 84.8 GB | B100 | 120 GB (96 GB) |
| 3 | 127.2 GB | B150 | 180 GB (144 GB) |
| 4 | 169.6 GB | B250 | 240 GB (192 GB) |
| 5 | 212 GB | B350 | 360 GB (288 GB) |
| 6 | 254.4 GB | B350 | 360 GB (288 GB) |
| 7 | 296.8 GB | B500 | 480 GB (384 GB) |
| 8 | 339.2 GB | B500 | 480 GB (384 GB) |
| 9 | 381.6 GB | B500 | 480 GB (384 GB) |
| 10 | 424 GB | B700 | 720 GB (576 GB) |
| 11-13 | 466-551 GB | B700 | 720 GB (576 GB) |
| 14-15 | 594-636 GB | B1000 | 960 GB (768 GB) |

### P5 Clustered (120 GB per shard)

| Shards | ACR Usable | Target AMR | AMR Advertised (Usable) |
|--------|------------|------------|-------------------------|
| 1 | 96 GB | B100 | 120 GB (96 GB) |
| 2 | 192 GB | B250 | 240 GB (192 GB) |
| 3 | 288 GB | B350 | 360 GB (288 GB) |
| 4 | 384 GB | B500 | 480 GB (384 GB) |
| 5 | 480 GB | B700 | 720 GB (576 GB) |
| 6 | 576 GB | B700 | 720 GB (576 GB) |
| 7 | 672 GB | B1000 | 960 GB (768 GB) |
| 8 | 768 GB | B1000 | 960 GB (768 GB) |
| 9 | 864 GB | M1500 | 1440 GB (1152 GB) |
| 10-12 | 960-1152 GB | M1500 | 1440 GB (1152 GB) |
| 13-15 | 1248-1440 GB | M2000 | 1920 GB (1536 GB) |

---

## Choosing the Right AMR SKU

When selecting an AMR SKU, consider the following dimensions:

### Memory Requirements
- Current **actual used memory** (not SKU size) — run `scripts/get_acr_metrics.ps1` (or `.sh`) to pull these automatically
- Both ACR and AMR reserve ~20% for system overhead
- AMR can run at full memory utilization with an eviction policy set — no extra margin needed

### Compute Requirements
- Current Server Load (%) — the primary indicator of compute pressure
- Peak vs average load
- Read/write ratio

### Cost Considerations
- M-series offers the most memory capacity per dollar — best when dataset size is the primary constraint
- X-series is most cost-effective when Server Load is high on a smaller dataset
- B-series suits genuinely balanced workloads (moderate data + moderate compute)
- Non-HA options available for dev/test (50% savings)
- **Always check ACR metrics** (memory, Server Load, bandwidth, connections) via `scripts/get_acr_metrics.ps1` (or `.sh`) to identify the actual bottleneck before choosing a tier

### Tier Comparison

| Tier | Best For |
|------|----------|
| **Memory Optimized (M)** | Memory-intensive workloads, large datasets, lower throughput needs, dev/test |
| **Balanced (B)** | Standard workloads, good balance of memory and compute |
| **Compute Optimized (X)** | High-throughput, performance-intensive workloads |
| **Flash Optimized** | Very large datasets, cost-effective scaling with tiered storage |

### When to Choose Compute Optimized (X-Series)

Choose Compute Optimized when your existing cache has:

1. **Low memory utilization but high Server Load**
   - Your cache is using < 50% of available memory
   - But Server Load is consistently high (>70%), indicating compute pressure
   - Example: C3 Standard (6 GB) using only 2 GB memory but Server Load at 80%+

2. **High connection counts**
   - Compute Optimized SKUs support more max connections at each size
   - Example: X10 (12 GB) supports 75,000 connections vs M10's 15,000

3. **Workloads with complex Redis commands**
   - Heavy use of Lua scripts
   - Complex sorted set operations
   - Search/query operations with RediSearch

### Max Connections by Tier (at same memory size)

| Size (GB) | Memory Optimized | Balanced | Compute Optimized |
|-----------|------------------|----------|-------------------|
| 12 | 15,000 | 30,000 | 75,000 |
| 24 | 30,000 | 75,000 | 150,000 |
| 60 | 75,000 | 150,000 | 200,000 |
| 120 | 150,000 | 200,000 | 200,000 |

### Migration Decision Matrix

| Current Situation | Recommended AMR Tier |
|-------------------|---------------------|
| Memory usage > 70%, low server load | **Memory Optimized (M)** |
| Memory usage 40-70%, moderate server load | **Balanced (B)** |
| Server load > 60%, low memory usage | **Compute Optimized (X)** |
| High bandwidth usage or high connection count | **Compute Optimized (X)** or **Balanced (B)** — pick a SKU with enough vCPUs |
| Very large dataset, cost-sensitive | **Flash Optimized** |
| Unsure / General purpose | **Balanced (B)** - start here |

### How to Assess Your Current Cache

Before migrating, pull these metrics using `scripts/get_acr_metrics.ps1` (or `.sh`) for your existing cache. If the scripts are unable to connect (locked tenant, permissions issues), check the **Azure Portal → Monitoring → Metrics** blade instead:

1. **Memory Usage**: Monitor → Used Memory / Max Memory
   - If consistently < 50%, consider smaller SKU or Compute Optimized
   
2. **Server Load**: Monitor → Server Load
   - High Server Load (>70%) with low memory utilization = Compute Optimized candidate
   
3. **Connected Clients**: Monitor → Connected Clients
   - Approaching max connections = move to higher tier or Compute Optimized

### Example Migration Scenarios

**Scenario 1: Session Store with High Concurrency**
- Current: Premium P2 (13 GB), using 4 GB memory, Server Load up to 75%, 25K connections
- Recommendation: **X10 (12 GB)** - provides 75K connections and high throughput

**Scenario 2: Application Cache with Large Dataset**
- Current: Premium P3 (26 GB), using 22 GB memory, Server Load up to 30%
- Recommendation: **M20 or B20 (24 GB)** - memory-focused, adequate throughput

**Scenario 3: Real-time Analytics Dashboard**
- Current: Premium P1 (6 GB), using 2 GB memory, Server Load up to 85%
- Recommendation: **X5 (6 GB)** - maximum throughput for compute-intensive workload

**Scenario 4: General Web App Cache**
- Current: Standard C3 (6 GB), using 4 GB memory, Server Load up to 40%
- Recommendation: **B5 (6 GB)** - balanced option for moderate workloads
