# AMR Balanced_B5 — Terraform Migrated Template
#
# Migrated from: Basic C3 (6 GB) → Balanced_B5
# Changes:
#   - Resource: azurerm_redis_cache → azurerm_redis_enterprise_cluster + azurerm_redis_enterprise_database
#   - SKU: Basic/C/3 → Balanced_B5
#   - Eviction: noeviction → NoEviction (PascalCase)
#   - Clustering: EnterpriseCluster (default for non-clustered source)
#   - Port: 6380 → 10000
#   - Removed: enable_non_ssl_port, redis_version, redis_configuration block
#   - Added: client_protocol Encrypted, database resource

resource "azurerm_redis_enterprise_cluster" "this" {
  name                = "my-basic-cache"
  location            = "westus2"
  resource_group_name = "my-rg"
  sku_name            = "Balanced_B5"
  minimum_tls_version = "1.2"

  identity {
    type = "SystemAssigned"
  }

  tags = {
    Environment = "Production"
    Service     = "WebApp"
  }
}

resource "azurerm_redis_enterprise_database" "default" {
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.this.id
  port              = 10000
  client_protocol   = "Encrypted"
  clustering_policy = "EnterpriseCluster"
  eviction_policy   = "NoEviction"
}

output "cache_id" {
  value = azurerm_redis_enterprise_cluster.this.id
}

output "hostname" {
  value = "${azurerm_redis_enterprise_cluster.this.name}.westus2.redis.azure.net"
}
