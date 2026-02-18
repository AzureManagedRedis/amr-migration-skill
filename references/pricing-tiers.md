# Redis Pricing Tiers and Calculation Rules

This document defines the pricing calculation rules for Azure Cache for Redis (ACR) and Azure Managed Redis (AMR).

> **Source**: [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/?service=managed-redis)
> 
> **API**: [Azure Retail Prices API](https://prices.azure.com/api/retail/prices)

---

## API Basics

The Azure Retail Prices API returns **hourly price per single node**.

To calculate monthly costs, multiply by **730 hours** (average hours/month), then apply tier-specific multipliers.

---

## Tier Pricing Rules

### Azure Cache for Redis (ACR)

| Tier | HA | Clustering | MRPP | Node Multiplier |
|------|-----|------------|------|-----------------|
| **Basic** (C0-C6) | ❌ No | ❌ No | ❌ No | × 1 |
| **Standard** (C0-C6) | ✅ Always | ❌ No | ❌ No | × 2 |
| **Premium** (P1-P5) | ✅ Always | ✅ Optional | ✅ Optional | × 2 × shards × (1 + replicas) |

#### ACR SKU Naming for API
All ACR SKUs use the format `<SKU> Cache Instance` (no tier qualifier):
- Basic/Standard: `C0 Cache Instance`, `C1 Cache Instance`, ..., `C6 Cache Instance`
- Premium: `P1 Cache Instance`, `P2 Cache Instance`, ..., `P5 Cache Instance`

> **Note**: Basic and Standard C* SKUs share the same per-node price. The tier determines node count (Basic = 1 node, Standard = 2 nodes).

#### ACR Pricing Formulas

```
Basic:    Monthly = Hourly × 730
Standard: Monthly = Hourly × 730 × 2
Premium:  Monthly = Hourly × 730 × (1 + replicas) × shards
```

**Premium Details**:
- `replicas` = replicas per primary (default: 1 for standard HA)
- `shards` = number of shards (default: 1 for non-clustered)
- Each shard has: 1 primary + N replicas

**Examples**:
| Configuration | Replicas | Shards | Nodes per Shard | Total Nodes | Formula |
|---------------|----------|--------|-----------------|-------------|---------|
| P2 (default) | 1 | 1 | 2 | 2 | × (1+1) × 1 = × 2 |
| P2 clustered 3 shards | 1 | 3 | 2 | 6 | × (1+1) × 3 = × 6 |
| P2 MRPP 2 replicas | 2 | 1 | 3 | 3 | × (1+2) × 1 = × 3 |
| P2 clustered + MRPP | 2 | 3 | 3 | 9 | × (1+2) × 3 = × 9 |

---

### Azure Managed Redis (AMR)

| Tier | HA | Clustering | MRPP | Node Multiplier |
|------|-----|------------|------|-----------------|
| **Memory Optimized** (M*) | ✅/❌ Optional | Yes (managed internally) | ❌ No | × 1 or × 2 |
| **Balanced** (B*) | ✅/❌ Optional | Yes (managed internally) | ❌ No | × 1 or × 2 |
| **Compute Optimized** (X*) | ✅/❌ Optional | Yes (managed internally) | ❌ No | × 1 or × 2 |
| **Flash Optimized** (A*) | ✅/❌ Optional | Yes (managed internally) | ❌ No | × 1 or × 2 |

#### AMR SKU Naming for API
- Memory Optimized: `M10 Cache Instance`, `M20 Cache Instance`, etc.
- Balanced: `B0 Cache Instance`, `B1 Cache Instance`, etc.
- Compute Optimized: `X3 Cache Instance`, `X5 Cache Instance`, etc.
- Flash Optimized: `A250 Cache Instance`, `A500 Cache Instance`, etc.

#### AMR Pricing Formulas

```
Non-HA (dev/test): Monthly = Hourly × 730
HA (production):   Monthly = Hourly × 730 × 2
```

**Note**: AMR manages clustering internally — customers cannot configure shard count. AMR does not support MRPP; for additional resiliency, use active geo-replication instead.

---

## Quick Reference Table

| Product | SKU Pattern | HA Default | Clustering | Supports MRPP |
|---------|-------------|------------|------------|---------------|
| ACR Basic | C0-C6 | No | No | No |
| ACR Standard | C0-C6 | Yes (always) | No | No |
| ACR Premium | P1-P5 | Yes (always) | Yes (1-15 shards) | Yes |
| AMR Memory | M10-M2000 | Optional | Yes (managed internally) | No |
| AMR Balanced | B0-B1000 | Optional | Yes (managed internally) | No |
| AMR Compute | X3-X700 | Optional | Yes (managed internally) | No |
| AMR Flash | A250-A4500 | Optional | Yes (managed internally) | No |

---

## Script Usage

### Basic Usage
```powershell
# Windows PowerShell - AMR pricing (defaults to HA)
.\scripts\get_redis_price.ps1 -SKU M10 -Region westus2

# Windows PowerShell - ACR pricing (must specify tier for C* SKUs)
.\scripts\get_redis_price.ps1 -SKU C3 -Region westus2 -Tier Standard
.\scripts\get_redis_price.ps1 -SKU P2 -Region westus2
```

### Advanced Options
```powershell
# AMR non-HA (dev/test)
.\scripts\get_redis_price.ps1 -SKU M10 -Region westus2 -NoHA

# ACR Premium clustered with 3 shards
.\scripts\get_redis_price.ps1 -SKU P2 -Region westus2 -Shards 3

# ACR Premium with MRPP (2 replicas per primary instead of 1)
.\scripts\get_redis_price.ps1 -SKU P2 -Region westus2 -Replicas 2

# Combined: Premium, 3 shards, 2 replicas each, in EUR
.\scripts\get_redis_price.ps1 -SKU P2 -Region westus2 -Shards 3 -Replicas 2 -Currency EUR
```

### Linux/Mac
```bash
./scripts/get_redis_price.sh M10 westus2
./scripts/get_redis_price.sh P2 westus2 --shards 3 --replicas 2
```

---

## Examples

### Example 1: AMR M10 in West US 2 (HA)
- API returns: $0.308/hour
- Calculation: $0.308 × 730 × 2 = **$449.68/month**

### Example 2: AMR M10 in West US 2 (Non-HA, dev/test)
- API returns: $0.308/hour
- Calculation: $0.308 × 730 × 1 = **$224.84/month**

### Example 3: ACR Standard C3 in East US
- API returns: $0.225/hour
- Calculation: $0.225 × 730 × 2 = **$328.50/month**

### Example 4: ACR Premium P2, 3 shards in West Europe
- API returns: $0.555/hour
- Calculation: $0.555 × 730 × (1+1) × 3 = $0.555 × 730 × 6 = **$2,430.90/month**

### Example 5: ACR Premium P2, 3 shards, 2 replicas (MRPP) in West Europe
- API returns: $0.555/hour
- Nodes per shard: 1 primary + 2 replicas = 3
- Calculation: $0.555 × 730 × (1+2) × 3 = $0.555 × 730 × 9 = **$3,646.35/month**
