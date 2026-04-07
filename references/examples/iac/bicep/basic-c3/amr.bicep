// AMR Balanced_B5 — Bicep template (after migration from Basic C3)
// Changes:
//   - Resource type: Microsoft.Cache/redis → Microsoft.Cache/redisEnterprise + databases
//   - SKU: Basic/C/3 → Balanced_B5
//   - Eviction: noeviction → NoEviction (PascalCase)
//   - Clustering: Non-clustered (omitted — source non-clustered, target ≤ 24GB)
//   - Port: 6380 → 10000
//   - publicNetworkAccess: Required in 2025-07-01, set to 'Enabled'
//   - Removed: enableNonSslPort, redisVersion, redisConfiguration

param location string = 'westus2'

resource redisCluster 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: 'my-basic-cache'
  location: location
  tags: {
    Environment: 'Production'
    Service: 'WebApp'
  }
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'Balanced_B5'
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  name: 'default'
  parent: redisCluster
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    evictionPolicy: 'NoEviction'
  }
}

output cacheId string = redisCluster.id
output hostName string = '${redisCluster.name}.${location}.redis.azure.net'
