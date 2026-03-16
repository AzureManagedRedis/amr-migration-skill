using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p1'
param location = 'westus2'
param skuCapacity = 1
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param maxmemoryPolicy = 'volatile-lru'
param aadEnabled = true
param zones = ['1', '2', '3']
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
