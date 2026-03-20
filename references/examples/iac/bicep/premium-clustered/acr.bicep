// ACR Premium P2 Clustered — Bicep template (before migration)
// Scenario: Premium P2 with 3 shards, RDB persistence, zones, user-assigned MI

param location string = 'westus2'

var blobEndpoint = 'https://mystorageaccount.blob.${environment().suffixes.storage}'
var userAssignedMI = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-persistence'

resource redisCache 'Microsoft.Cache/redis@2024-03-01' = {
  name: 'my-clustered-cache'
  location: location
  tags: {
    Environment: 'Production'
    Service: 'SessionStore'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userAssignedMI}': {}
    }
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
    publicNetworkAccess: 'Enabled'
    shardCount: 3
    redisConfiguration: {
      'maxmemory-policy': 'volatile-lru'
      'aad-enabled': 'true'
      'rdb-backup-enabled': 'true'
      'rdb-backup-frequency': '60'
      'rdb-storage-connection-string': blobEndpoint
      'preferred-data-persistence-auth-method': 'ManagedIdentity'
      'storage-subscription-id': subscription().subscriptionId
      'maxmemory-reserved': '642'
      'maxfragmentationmemory-reserved': '642'
    }
  }
}

output cacheId string = redisCache.id
output hostName string = redisCache.properties.hostName
output sslPort int = redisCache.properties.sslPort
