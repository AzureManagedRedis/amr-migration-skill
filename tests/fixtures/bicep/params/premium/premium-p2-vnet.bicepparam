using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p2-vnet'
param location = 'westus2'
param skuCapacity = 2
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param redisVersion = '6'
param shardCount = 0
param subnetId = ''
param staticIP = ''
param aadEnabled = true
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
