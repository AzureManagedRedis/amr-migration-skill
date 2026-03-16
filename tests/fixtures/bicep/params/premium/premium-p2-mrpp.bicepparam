using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p2-mrpp'
param location = 'westus2'
param skuCapacity = 2
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param redisVersion = '6'
param shardCount = 2
param replicasPerPrimary = 2
param aadEnabled = true
param zones = ['1', '2', '3']
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
