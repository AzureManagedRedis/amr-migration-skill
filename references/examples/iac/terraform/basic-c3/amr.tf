# AMR Balanced_B5 — Terraform Migrated Template
#
# Migrated from: Basic C3 (6 GB) → Balanced_B5
# Changes:
#   - Resource: azurerm_redis_cache → azurerm_managed_redis (single resource with inline database)
#   - SKU: Basic/C/3 → Balanced_B5
#   - Eviction: noeviction → NoEviction (PascalCase)
#   - Clustering: EnterpriseCluster (default for non-clustered source)
#   - Port: 6380 → 10000
#   - Removed: enable_non_ssl_port, redis_version, redis_configuration block, minimum_tls_version
#   - Added: client_protocol Encrypted, default_database block

resource "azurerm_managed_redis" "this" {
  name                = "my-basic-cache"
  location            = "westus2"
  resource_group_name = "my-rg"
  sku_name            = "Balanced_B5"

  identity {
    type = "SystemAssigned"
  }

  default_database {
    client_protocol   = "Encrypted"
    clustering_policy = "EnterpriseCluster"
    eviction_policy   = "NoEviction"
  }

  tags = {
    Environment = "Production"
    Service     = "WebApp"
  }
}

output "cache_id" {
  value = azurerm_managed_redis.this.id
}

output "hostname" {
  value = azurerm_managed_redis.this.hostname
}
