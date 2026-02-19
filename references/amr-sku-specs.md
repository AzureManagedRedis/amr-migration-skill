# AMR SKU Specifications

> **Last Updated**: February 2026

For migration guidelines, mapping tables, and decision matrix, see [SKU Mapping Guide](sku-mapping.md).

---

## AMR SKU Definitions

> **Note**: "Advertised" is the SKU size. Usable memory is ~80% of this value.

### Memory Optimized (M-Series)
Best for: Caching workloads with large datasets and moderate throughput requirements. Memory-to-vCPU ratio: 8:1.

| SKU | Advertised (GB) | Usable ~(GB) | vCPUs | Max Connections |
|-----|-----------------|--------------|-------|-----------------|
| M10 | 12 | 9.6 | 2 | 15,000 |
| M20 | 24 | 19.2 | 4 | 30,000 |
| M50 | 60 | 48 | 8 | 75,000 |
| M100 | 120 | 96 | 16 | 150,000 |
| M150 | 175 | 140 | 24 | 200,000 |
| M250 | 235 | 188 | 32 | 200,000 |
| M350* | 360 | 288 | 48 | 200,000 |
| M500* | 480 | 384 | 64 | 200,000 |
| M700* | 720 | 576 | 96 | 200,000 |
| M1000* | 960 | 768 | 128 | 200,000 |
| M1500* | 1440 | 1152 | 192 | 200,000 |
| M2000* | 1920 | 1536 | 256 | 200,000 |

### Balanced (B-Series)
Best for: General-purpose workloads with balanced compute and memory needs. Memory-to-vCPU ratio: 4:1.

| SKU | Advertised (GB) | Usable ~(GB) | vCPUs | Max Connections |
|-----|-----------------|--------------|-------|-----------------|
| B0 | 0.5 | 0.4 | 2 (burstable) | 15,000 |
| B1 | 1 | 0.8 | 2 (burstable) | 15,000 |
| B3 | 3 | 2.4 | 2 | 15,000 |
| B5 | 6 | 4.8 | 2 | 15,000 |
| B10 | 12 | 9.6 | 4 | 30,000 |
| B20 | 24 | 19.2 | 8 | 75,000 |
| B50 | 60 | 48 | 16 | 150,000 |
| B100 | 120 | 96 | 32 | 200,000 |
| B150 | 180 | 144 | 48 | 200,000 |
| B250 | 240 | 192 | 64 | 200,000 |
| B350* | 360 | 288 | 96 | 200,000 |
| B500* | 480 | 384 | 128 | 200,000 |
| B700* | 720 | 576 | 192 | 200,000 |
| B1000* | 960 | 768 | 256 | 200,000 |

### Compute Optimized (X-Series)
Best for: Performance-intensive workloads requiring maximum throughput. Memory-to-vCPU ratio: 2:1.

| SKU | Advertised (GB) | Usable ~(GB) | vCPUs | Max Connections |
|-----|-----------------|--------------|-------|-----------------|
| X3 | 3 | 2.4 | 4 | 30,000 |
| X5 | 6 | 4.8 | 4 | 30,000 |
| X10 | 12 | 9.6 | 8 | 75,000 |
| X20 | 24 | 19.2 | 16 | 150,000 |
| X50 | 60 | 48 | 32 | 200,000 |
| X100 | 120 | 96 | 64 | 200,000 |
| X150 | 180 | 144 | 96 | 200,000 |
| X250 | 240 | 192 | 128 | 200,000 |
| X350* | 360 | 288 | 192 | 200,000 |
| X500* | 480 | 384 | 256 | 200,000 |
| X700* | 720 | 576 | 384 | 200,000 |

\* Sizes marked with asterisk are in Public Preview.

### Flash Optimized (Auto Tiering)
Best for: Very large datasets where tiered storage (RAM + SSD) is cost-effective.

> **Note**: Flash Optimized uses a combination of RAM and NVMe disk. The "Cache Size" represents total effective capacity. Memory reservation applies to the RAM portion. More info: [Flash Optimized Architecture](https://learn.microsoft.com/en-us/azure/redis/architecture#flash-optimized-tier)

| SKU | Cache Size (GB) | VM Memory (GiB) | Disk Size (GiB) | vCPUs | Max Connections |
|-----|-----------------|-----------------|-----------------|-------|-----------------|
| A250* | 250 | 64 | 1920 | 8 | 75,000 |
| A500* | 500 | 128 | 3840 | 16 | 150,000 |
| A700* | 750 | 192 | 5760 | 24 | 200,000 |
| A1000* | 1000 | 256 | 7680 | 32 | 200,000 |
| A1500* | 1500 | 384 | 11520 | 48 | 200,000 |
| A2000* | 2000 | 512 | 15360 | 64 | 200,000 |
| A4500* | 4500 | 1152 | 34560 | 144 | 200,000 |

\* All Flash Optimized SKUs are in Public Preview.

---

## Max Connections by Tier (at same memory size)

| Size (GB) | Memory Optimized | Balanced | Compute Optimized |
|-----------|------------------|----------|-------------------|
| 12 | 15,000 | 30,000 | 75,000 |
| 24 | 30,000 | 75,000 | 150,000 |
| 60 | 75,000 | 150,000 | 200,000 |
| 120 | 150,000 | 200,000 | 200,000 |
