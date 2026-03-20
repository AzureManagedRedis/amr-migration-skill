// AMR Balanced_B50 — Bicep template (after migration from Premium P2 x3 shards)
// Changes:
//   - Resource split: redis → redisEnterprise + databases
//   - SKU: Premium/P/2 x 3 shards → Balanced_B50
//   - Clustering: OSSCluster (source had shardCount=3, cluster-aware clients assumed)
//   - Eviction: volatile-lru → VolatileLRU
//   - Persistence: rdb-backup-frequency 60 min → rdbFrequency 1h
//   - Persistence: storage connection removed (AMR manages internally)
//   - Identity: preserved (type + userAssignedIdentities)
//   - Zones: REMOVED — AMR manages zone redundancy automatically
//   - Removed: shardCount, enableNonSslPort, redisVersion, maxmemory-reserved

param location string = 'westus2'

var userAssignedMI = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-persistence'

resource redisCluster 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: 'my-clustered-cache'
  location: location
  tags: {
    Environment: 'Production'
    Service: 'SessionStore'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userAssignedMI}': {}
    }
  }
  sku: {
    name: 'Balanced_B50'
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
    evictionPolicy: 'VolatileLRU'
    clusteringPolicy: 'OSSCluster'
    persistence: {
      rdbEnabled: true
      rdbFrequency: '1h'
    }
  }
}

output cacheId string = redisCluster.id
output hostName string = '${redisCluster.name}.${location}.redis.azure.net'
