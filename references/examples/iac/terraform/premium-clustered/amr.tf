# AMR Balanced_B50 — Terraform Migrated Template
#
# Migrated from: Premium P2 (13 GB) x 3 shards with RDB persistence
# Changes:
#   - Resource: azurerm_redis_cache → azurerm_redis_enterprise_cluster + azurerm_redis_enterprise_database
#   - SKU: Premium/P/2 x 3 shards → Balanced_B50
#   - Clustering: OSSCluster (source had shard_count=3, assumes cluster-aware clients)
#   - Eviction: volatile-lru → VolatileLRU
#   - Identity: preserved (type + identity_ids)
#   - Zones: REMOVED — AMR manages zone redundancy automatically
#   - Removed: shard_count, enable_non_ssl_port, redis_version, maxmemory_reserved, maxfragmentationmemory_reserved
#
# ⚠️ Persistence Note:
#   The azurerm provider does NOT support persistence (RDB/AOF) on azurerm_redis_enterprise_database.
#   Use the AzAPI provider to configure persistence. See the azapi_resource block below.
#   Source had: rdb_backup_frequency=60 → AMR equivalent: rdbFrequency="1h"
#   Storage connection string removed (AMR manages persistence storage internally).

resource "azurerm_redis_enterprise_cluster" "this" {
  name                = "my-clustered-cache"
  location            = "westus2"
  resource_group_name = "my-rg"
  sku_name            = "Balanced_B50"
  minimum_tls_version = "1.2"

  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-persistence"
    ]
  }

  tags = {
    Environment = "Production"
    Service     = "SessionStore"
  }
}

# Database resource using azurerm provider (persistence NOT supported here)
resource "azurerm_redis_enterprise_database" "default" {
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.this.id
  port              = 10000
  client_protocol   = "Encrypted"
  clustering_policy = "OSSCluster"
  eviction_policy   = "VolatileLRU"
}

# ── Persistence via AzAPI provider ──────────────────────────────────────────
# The azurerm provider does not expose RDB/AOF persistence attributes.
# Use azapi_update_resource to configure persistence on the database.
#
# Requires: terraform { required_providers { azapi = { source = "Azure/azapi" } } }
#
# resource "azapi_update_resource" "db_persistence" {
#   type        = "Microsoft.Cache/redisEnterprise/databases@2025-07-01"
#   resource_id = azurerm_redis_enterprise_database.default.id
#   body = {
#     properties = {
#       persistence = {
#         rdbEnabled   = true
#         rdbFrequency = "1h"
#       }
#     }
#   }
# }

output "cache_id" {
  value = azurerm_redis_enterprise_cluster.this.id
}

output "hostname" {
  value = "${azurerm_redis_enterprise_cluster.this.name}.westus2.redis.azure.net"
}
