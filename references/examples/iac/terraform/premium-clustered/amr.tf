# AMR Balanced_B50 — Terraform Migrated Template
#
# Migrated from: Premium P2 (13 GB) x 3 shards with RDB persistence
# Changes:
#   - Resource: azurerm_redis_cache → azurerm_managed_redis (single resource with inline database)
#   - SKU: Premium/P/2 x 3 shards → Balanced_B50
#   - Clustering: EnterpriseCluster (default; use OSSCluster only if client is cluster-aware)
#   - Eviction: volatile-lru → VolatileLRU
#   - Persistence: rdb_backup_frequency 60 min → persistence_redis_database_backup_frequency "1h"
#   - Persistence: storage connection string removed (AMR manages internally)
#   - Identity: preserved (type + identity_ids)
#   - Zones: REMOVED — AMR manages zone redundancy automatically
#   - Removed: shard_count, enable_non_ssl_port, redis_version, maxmemory_reserved,
#              maxfragmentationmemory_reserved, minimum_tls_version

resource "azurerm_managed_redis" "this" {
  name                = "my-clustered-cache"
  location            = "westus2"
  resource_group_name = "my-rg"
  sku_name              = "Balanced_B50"
  public_network_access = "Enabled"

  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-persistence"
    ]
  }

  default_database {
    client_protocol                            = "Encrypted"
    clustering_policy                          = "EnterpriseCluster" # Use "OSSCluster" only if client is cluster-aware
    eviction_policy                            = "VolatileLRU"
    persistence_redis_database_backup_frequency = "1h"
  }

  tags = {
    Environment = "Production"
    Service     = "SessionStore"
  }
}

output "cache_id" {
  value = azurerm_managed_redis.this.id
}

output "hostname" {
  value = azurerm_managed_redis.this.hostname
}
