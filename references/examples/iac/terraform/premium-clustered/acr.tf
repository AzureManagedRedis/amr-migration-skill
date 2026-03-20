# ACR Premium P2 x3 Shards with RDB — Terraform Source Template

resource "azurerm_redis_cache" "clustered" {
  name                          = "my-clustered-cache"
  location                      = "westus2"
  resource_group_name           = "my-rg"
  capacity                      = 2
  family                        = "P"
  sku_name                      = "Premium"
  shard_count                   = 3
  minimum_tls_version           = "1.2"
  enable_non_ssl_port           = false
  public_network_access_enabled = true
  redis_version                 = "6"
  zones                         = ["1", "2", "3"]

  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-persistence"
    ]
  }

  redis_configuration {
    maxmemory_policy              = "volatile-lru"
    maxmemory_reserved            = 642
    maxfragmentationmemory_reserved = 642
    rdb_backup_enabled            = true
    rdb_backup_frequency          = 60
    rdb_storage_connection_string = "DefaultEndpointsProtocol=https;AccountName=mystorageaccount;..."
  }

  tags = {
    Environment = "Production"
    Service     = "SessionStore"
  }
}

output "cache_id" {
  value = azurerm_redis_cache.clustered.id
}

output "hostname" {
  value = azurerm_redis_cache.clustered.hostname
}

output "ssl_port" {
  value = azurerm_redis_cache.clustered.ssl_port
}
