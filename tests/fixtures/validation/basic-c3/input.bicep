// ============================================================
// TEST INPUT: ACR Basic C3 — simple cache, no clustering, no persistence
// ============================================================

@description('Name of the Redis cache')
param cacheName string

@description('Location for the cache')
param location string = resourceGroup().location

@description('Enable non-SSL port')
param enableNonSslPort bool = true

resource redis 'Microsoft.Cache/redis@2024-03-01' = {
  name: cacheName
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 3
    }
    enableNonSslPort: enableNonSslPort
    minimumTlsVersion: '1.2'
    redisVersion: '6'
    redisConfiguration: {
      'maxmemory-policy': 'allkeys-lru'
    }
  }
  tags: {
    environment: 'dev'
  }
}

output hostName string = redis.properties.hostName
output sslPort int = redis.properties.sslPort
