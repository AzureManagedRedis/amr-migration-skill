// ============================================================
// TEST INPUT: ACR Premium P2 — clustered, persistence, VNet, firewall, redisVersion
// ============================================================

@description('Name of the Redis cache')
param cacheName string

@description('Location for the cache')
param location string = resourceGroup().location

@description('Subnet ID for VNet injection')
param subnetId string

@description('Storage account connection string for persistence')
param storageConnectionString string

resource redis 'Microsoft.Cache/redis@2024-03-01' = {
  name: cacheName
  location: location
  zones: ['1', '2', '3']
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Premium'
      family: 'P'
      capacity: 2
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    redisVersion: '6'
    shardCount: 3
    replicasPerPrimary: 1
    subnetId: subnetId
    staticIP: '10.0.1.4'
    redisConfiguration: {
      'maxmemory-policy': 'volatile-lru'
      'maxmemory-reserved': '256'
      'maxfragmentationmemory-reserved': '256'
      'rdb-backup-enabled': 'true'
      'rdb-backup-frequency': '60'
      'rdb-storage-connection-string': storageConnectionString
      'aad-enabled': 'true'
    }
  }
  tags: {
    environment: 'production'
    team: 'platform'
  }
}

resource firewallRule 'Microsoft.Cache/redis/firewallRules@2024-03-01' = {
  parent: redis
  name: 'AllowCorp'
  properties: {
    startIP: '10.0.0.0'
    endIP: '10.0.255.255'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${cacheName}-diag'
  scope: redis
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

output hostName string = redis.properties.hostName
output sslPort int = redis.properties.sslPort
