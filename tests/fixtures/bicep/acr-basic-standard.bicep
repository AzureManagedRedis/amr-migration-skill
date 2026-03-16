// Azure Cache for Redis (ACR) - Basic/Standard tier Bicep Template.
// Used as the 'before' state for AMR migration E2E tests.

@description('Name of the Azure Cache for Redis instance.')
param redisCacheName string

@description('Azure region for the Redis cache.')
param location string = resourceGroup().location

@description('Pricing tier of the cache.')
@allowed(['Basic', 'Standard'])
param skuName string = 'Standard'

@description('SKU family. C = Basic/Standard.')
@allowed(['C'])
param skuFamily string = 'C'

@description('Cache size (0-6).')
@minValue(0)
@maxValue(6)
param skuCapacity int = 1

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

@description('Log Analytics workspace resource ID for diagnostics. Leave empty to skip.')
param logAnalyticsWorkspaceId string = ''

@description('Resource tags.')
param tags object = {}

// --- Variables ---
var baseRedisConfig = {
  'maxmemory-policy': maxmemoryPolicy
  'aad-enabled': aadEnabled ? 'true' : 'false'
}
var reservedConfig = maxmemoryReserved != '' ? { 'maxmemory-reserved': maxmemoryReserved } : {}
var fragConfig = maxfragmentationmemoryReserved != '' ? { 'maxfragmentationmemory-reserved': maxfragmentationmemoryReserved } : {}
var redisConfiguration = union(baseRedisConfig, reservedConfig, fragConfig)

// --- Resources ---
resource redisCache 'Microsoft.Cache/redis@2024-03-01' = {
  name: redisCacheName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    enableNonSslPort: enableNonSslPort
    minimumTlsVersion: minimumTlsVersion
    redisVersion: redisVersion
    publicNetworkAccess: publicNetworkAccess
    sku: {
      name: skuName
      family: skuFamily
      capacity: skuCapacity
    }
    redisConfiguration: redisConfiguration
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
