# Azure Cache for Redis Retirement FAQ

> **Source**: https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/retirement-faq
> 
> **Last Updated**: February 2026 - Check source URL for the latest information.

> **Scope Note**: This skill focuses on Basic/Standard/Premium migrations. Enterprise tier details below are provided for retirement awareness only.

## Key Retirement Dates

| Tier | Retirement Date | Disabled From |
|------|-----------------|---------------|
| Basic, Standard, Premium | September 30, 2028 | October 1, 2028 |
| Enterprise, Enterprise Flash | March 31, 2027 | April 1, 2027 |

## Basic, Standard, and Premium Tiers

### What is retiring?
All instances of Azure Cache for Redis (Basic, Standard, and Premium tiers) will be retired on **September 30, 2028**.

### What happens to existing instances?
- Instances remain available until September 30, 2028
- Regular maintenance continues to keep instances secure and stable
- Starting October 1, 2028, all remaining instances will be **disabled**

### Why upgrade to Azure Managed Redis?
- Greater performance and more cost-effective
- Enterprise features: active geo-replication, Redis modules
- Zone redundant by default
- Built for Microsoft Entra ID authentication (more secure than access keys)

### Application changes required
- Update Redis hostname and access key to new AMR instance
- For non-clustered ACR caches, use **Enterprise clustering policy** on AMR to preserve single-endpoint behavior and avoid client code changes
- If using OSS clustering policy, ensure your client library supports cluster mode
- Check for [cross-slot commands](https://redis.io/blog/redis-clustering-best-practices-with-keys/) compatibility

### Reservations
- Existing reservations supported until September 30, 2028
- Can cancel or exchange reservations before that date

## Enterprise and Enterprise Flash Tiers

### What is retiring?
All instances of Azure Cache for Redis Enterprise and Enterprise Flash tiers will be retired on **March 31, 2027**.

### Why upgrade Enterprise to AMR?
- Better performance and more cost-effective
- Azure first-party offering (no Marketplace component)
- Eliminates quorum node (reduces overhead and costs)
- Available in more Azure regions
- Zone redundant by default
- Non-HA options for dev/test at reduced cost
- Simplified SKU structure based on memory/performance
- Microsoft Entra ID authentication built-in

### Reservations
- Existing reservations supported until March 31, 2027
- Can cancel or exchange reservations before that date

## Migration Guidance

### How to choose the right AMR tier?
See the [SKU Mapping Guide](sku-mapping.md) for detailed mapping tables and selection criteria, or the [official Migration Overview](https://learn.microsoft.com/azure/redis/migrate/migrate-overview).

### How to retain data during migration?
See [Migration Overview](migration-overview.md) for strategies (dual-write, RDB export/import, RIOT), or the [official migration documentation](https://learn.microsoft.com/azure/redis/migrate/migrate-overview).

### Feature support
AMR supports all Redis functionality from existing Azure Cache for Redis SKUs. Some management operations, regions, and SKU sizes may not yet be available - contact support if blocked.

## Quick Reference Links

- [What is Azure Managed Redis?](https://learn.microsoft.com/azure/redis/overview)
- [Migration Overview](https://learn.microsoft.com/azure/redis/migrate/migrate-overview)
- [AMR Client Libraries](https://learn.microsoft.com/azure/redis/best-practices-client-libraries)
- [Cluster Policies](https://learn.microsoft.com/azure/redis/architecture)
- [Reservation Policies](https://learn.microsoft.com/azure/cost-management-billing/reservations/exchange-and-refund-azure-reservations)
