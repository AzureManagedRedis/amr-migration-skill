# ACR Basic C3 — Terraform Source Template

resource "azurerm_redis_cache" "basic" {
  name                          = "my-basic-cache"
  location                      = "westus2"
  resource_group_name           = "my-rg"
  capacity                      = 3
  family                        = "C"
  sku_name                      = "Basic"
  minimum_tls_version           = "1.2"
  enable_non_ssl_port           = false
  public_network_access_enabled = true
  redis_version                 = "6"

  identity {
    type = "SystemAssigned"
  }

  redis_configuration {
    maxmemory_policy = "noeviction"
  }

  tags = {
    Environment = "Production"
    Service     = "WebApp"
  }
}

output "cache_id" {
  value = azurerm_redis_cache.basic.id
}

output "hostname" {
  value = azurerm_redis_cache.basic.hostname
}

output "ssl_port" {
  value = azurerm_redis_cache.basic.ssl_port
}
