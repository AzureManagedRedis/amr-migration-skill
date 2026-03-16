// Azure Cache for Redis (ACR) - Premium tier Bicep Template.
// Supports clustering, MI-based persistence, VNet, zones, geo-replication.
// Used as the 'before' state for AMR migration E2E tests.

@description('Name of the Azure Cache for Redis instance.')
param redisCacheName string

@description('Azure region for the Redis cache.')
param location string = resourceGroup().location

@description('Cache size (P1-P5).')
@minValue(1)
@maxValue(5)
param skuCapacity int = 2

@description('Enable the non-TLS port (6379).')
param enableNonSslPort bool = false

@description('Minimum TLS version.')
@allowed(['1.0', '1.1', '1.2'])
param minimumTlsVersion string = '1.2'

@description('Redis server version.')
param redisVersion string = '6'

@description('Public network access.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Enabled'

@description('Number of shards for clustered cache (0 = non-clustered).')
@minValue(0)
@maxValue(10)
param shardCount int = 0

@description('Replicas per primary.')
@minValue(1)
@maxValue(3)
param replicasPerPrimary int = 1

@description('Enable RDB persistence.')
param rdbBackupEnabled bool = false

@description('RDB backup frequency in minutes.')
@allowed([15, 30, 60, 360, 720, 1440])
param rdbBackupFrequency int = 60

@description('Storage account name for persistence (used with managed identity auth).')
param persistenceStorageAccountName string = ''

@description('Enable AOF persistence.')
param aofBackupEnabled bool = false

@description('Resource ID of a user-assigned managed identity for persistence storage access.')
param userAssignedManagedIdentityId string = ''

@description('Subnet resource ID for VNet injection.')
param subnetId string = ''

@description('Static IP for VNet-injected cache.')
param staticIP string = ''

@description('Max memory eviction policy.')
@allowed([
  'volatile-lru'
  'allkeys-lru'
  'volatile-lfu'
  'allkeys-lfu'
  'volatile-random'
  'allkeys-random'
  'volatile-ttl'
  'noeviction'
])
param maxmemoryPolicy string = 'volatile-lru'

@description('Max memory reserved (MB) for non-cache operations.')
param maxmemoryReserved string = ''

@description('Max fragmentation memory reserved (MB).')
param maxfragmentationmemoryReserved string = ''

@description('Enable Microsoft Entra ID (AAD) authentication.')
param aadEnabled bool = true

@description('Array of firewall rules: [{ name, startIP, endIP }].')
param firewallRules array = []

@description('Deploy a private endpoint for the cache.')
param enablePrivateEndpoint bool = false

@description('Subnet resource ID for the private endpoint.')
param privateEndpointSubnetId string = ''

@description('Private DNS Zone resource ID.')
param privateDnsZoneId string = ''

@description('Availability zones.')
param zones array = []

@description('Enable passive geo-replication by linking to another cache.')
param enableGeoReplication bool = false

@description('Resource ID of the cache to link for geo-replication.')
param linkedCacheId string = ''

@description('Location of the linked cache for geo-replication.')
param linkedCacheLocation string = ''

@description('Log Analytics workspace resource ID for diagnostics. Leave empty to skip.')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags.')
param tags object = {}

// --- Variables ---
var blobEndpoint = 'https://${persistenceStorageAccountName}.blob.${environment().suffixes.storage}'

var baseRedisConfig = {
  'maxmemory-policy': maxmemoryPolicy
  'aad-enabled': aadEnabled ? 'true' : 'false'
}
var reservedConfig = maxmemoryReserved != '' ? { 'maxmemory-reserved': maxmemoryReserved } : {}
var fragConfig = maxfragmentationmemoryReserved != '' ? { 'maxfragmentationmemory-reserved': maxfragmentationmemoryReserved } : {}
var rdbConfig = rdbBackupEnabled ? {
  'rdb-backup-enabled': 'true'
  'rdb-backup-frequency': string(rdbBackupFrequency)
  'rdb-storage-connection-string': blobEndpoint
  'preferred-data-persistence-auth-method': 'ManagedIdentity'
  'storage-subscription-id': subscription().subscriptionId
} : {}
var aofConfig = aofBackupEnabled ? {
  'aof-backup-enabled': 'true'
  'aof-storage-connection-string-0': blobEndpoint
  'preferred-data-persistence-auth-method': 'ManagedIdentity'
  'storage-subscription-id': subscription().subscriptionId
} : {}
var redisConfiguration = union(baseRedisConfig, reservedConfig, fragConfig, rdbConfig, aofConfig)

// --- Resources ---
resource redisCache 'Microsoft.Cache/redis@2024-03-01' = {
  name: redisCacheName
  location: location
  tags: tags
  zones: !empty(zones) ? zones : []
  identity: !empty(userAssignedManagedIdentityId) ? {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${userAssignedManagedIdentityId}': {}
    }
  } : {
    type: 'SystemAssigned'
  }
  properties: {
    enableNonSslPort: enableNonSslPort
    minimumTlsVersion: minimumTlsVersion
    redisVersion: redisVersion
    publicNetworkAccess: publicNetworkAccess
    sku: {
      name: 'Premium'
      family: 'P'
      capacity: skuCapacity
    }
    redisConfiguration: redisConfiguration
    shardCount: shardCount > 0 ? shardCount : null
    replicasPerPrimary: replicasPerPrimary
    subnetId: subnetId != '' ? subnetId : null
    staticIP: staticIP != '' ? staticIP : null
  }
}

resource firewallRuleResources 'Microsoft.Cache/redis/firewallRules@2024-03-01' = [
  for rule in firewallRules: {
    name: rule.name
    parent: redisCache
    properties: {
      startIP: rule.startIP
      endIP: rule.endIP
    }
  }
]

resource patchSchedule 'Microsoft.Cache/redis/patchSchedules@2024-03-01' = {
  name: 'default'
  parent: redisCache
  properties: {
    scheduleEntries: [
      {
        dayOfWeek: 'Sunday'
        startHourUtc: 2
        maintenanceWindow: 'PT5H'
      }
    ]
  }
}

resource linkedServer 'Microsoft.Cache/redis/linkedServers@2024-03-01' = if (enableGeoReplication && linkedCacheId != '') {
  name: 'linkedServer'
  parent: redisCache
  properties: {
    linkedRedisCacheId: linkedCacheId
    linkedRedisCacheLocation: linkedCacheLocation
    serverRole: 'Secondary'
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = if (enablePrivateEndpoint && privateEndpointSubnetId != '') {
  name: '${redisCacheName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${redisCacheName}-pe-conn'
        properties: {
          privateLinkServiceId: redisCache.id
          groupIds: ['redisCache']
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (enablePrivateEndpoint && privateDnsZoneId != '') {
  name: 'default'
  parent: privateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-redis-cache-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (logAnalyticsWorkspaceId != '') {
  name: '${redisCacheName}-diag'
  scope: redisCache
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// --- Outputs ---
output cacheId string = redisCache.id
output cacheHostName string = redisCache.properties.hostName
output cacheSslPort int = redisCache.properties.sslPort
output cacheName string = redisCache.name
output cachePrincipalId string = redisCache.identity.principalId
