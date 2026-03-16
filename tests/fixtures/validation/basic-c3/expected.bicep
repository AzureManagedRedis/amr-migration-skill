// ============================================================
// EXPECTED OUTPUT: AMR Balanced B5 — migrated from Basic C3
// ============================================================
// Migration notes:
//   - Basic C3 (6 GB, no HA) → Balanced_B5 (6 GB, no HA for dev)
//   - enableNonSslPort: REMOVED (AMR is TLS-only, port 10000)
//   - redisVersion: REMOVED (AMR always runs Redis 7.4)
//   - SKU: 3-field → compound name "Balanced_B5"
//   - Eviction policy: allkeys-lru → AllKeysLRU
//   - Single resource → cluster + database
// ============================================================

@description('Name of the Redis cache')
param cacheName string

@description('Location for the cache')
param location string = resourceGroup().location

resource cluster 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' = {
  name: cacheName
  location: location
  sku: {
    name: 'Balanced_B5'
  }
  properties: {
    minimumTlsVersion: '1.2'
  }
  tags: {
    environment: 'dev'
  }
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' = {
  parent: cluster
  name: 'default'
  properties: {
    port: 10000
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'AllKeysLRU'
  }
}

output hostName string = '${cacheName}.${location}.redis.azure.net'
output port int = 10000
