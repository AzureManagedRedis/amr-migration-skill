// ACR Basic/Standard C3 — Bicep template (before migration)
// Scenario: Simple Basic C3 cache with no special features

param location string = 'westus2'

resource redisCache 'Microsoft.Cache/redis@2024-03-01' = {
  name: 'my-basic-cache'
  location: location
  tags: {
    Environment: 'Production'
    Service: 'WebApp'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 3
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    redisVersion: '6'
    publicNetworkAccess: 'Enabled'
    redisConfiguration: {
      'maxmemory-policy': 'noeviction'
      'aad-enabled': 'true'
    }
  }
}

output cacheId string = redisCache.id
output hostName string = redisCache.properties.hostName
output sslPort int = redisCache.properties.sslPort
