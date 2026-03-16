// ============================================================
// EXPECTED OUTPUT: AMR Balanced B50 — migrated from Premium P2 with 3 shards
// ============================================================
// Migration notes:
//   - Premium P2 × 3 shards (31.2 GB usable) → Balanced_B50 (60 GB, ~48 GB usable)
//   - redisVersion: REMOVED (AMR always runs Redis 7.4)
//   - enableNonSslPort: REMOVED (AMR is TLS-only)
//   - shardCount: REMOVED (AMR manages clustering internally)
//   - replicasPerPrimary: REMOVED (not supported; use active geo-replication)
//   - subnetId + staticIP: REMOVED (VNet injection not supported → Private Endpoint)
//   - Firewall rules: REMOVED (not supported → Private Endpoint + publicNetworkAccess disabled)
//   - maxmemory-reserved, maxfragmentationmemory-reserved: REMOVED (managed internally)
//   - aad-enabled: REMOVED (use identity on cluster resource)
//   - rdb-storage-connection-string: REMOVED (AMR uses managed storage)
//   - Eviction policy: volatile-lru → VolatileLRU
//   - RDB frequency: 60 (minutes) → 1h
//   - Persistence: flat config → structured object
//   - SKU: Premium P2 × 3 shards → Balanced_B50
//   - Private Endpoint added to replace VNet injection
//   - Private DNS zone updated
//   - Diagnostics scope updated to redisEnterprise
// ============================================================

@description('Name of the Redis cache')
param cacheName string

@description('Location for the cache')
param location string = resourceGroup().location

@description('Subnet ID for Private Endpoint')
param subnetId string

resource cluster 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' = {
  name: cacheName
  location: location
  sku: {
    name: 'Balanced_B50'
  }
  zones: ['1', '2', '3']
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
  tags: {
    environment: 'production'
    team: 'platform'
  }
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' = {
  parent: cluster
  name: 'default'
  properties: {
    port: 10000
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'VolatileLRU'
    persistence: {
      rdbEnabled: true
      rdbFrequency: '1h'
      aofEnabled: false
    }
  }
}

// Private Endpoint replaces VNet injection and firewall rules
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${cacheName}-pe'
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${cacheName}-pls'
        properties: {
          privateLinkServiceId: cluster.id
          groupIds: ['redisEnterprise']
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redisenterprise.cache.azure.net'
  location: 'global'
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${cacheName}-diag'
  scope: cluster
  properties: {
    workspaceId: '/subscriptions/xxx/resourceGroups/xxx/providers/Microsoft.OperationalInsights/workspaces/xxx'
    logs: [
      {
        category: 'ConnectedClientList'
        enabled: true
      }
    ]
  }
}

output hostName string = '${cacheName}.${location}.redis.azure.net'
output port int = 10000
