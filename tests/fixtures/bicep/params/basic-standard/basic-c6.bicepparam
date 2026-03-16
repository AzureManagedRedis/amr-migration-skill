using '../../acr-basic-standard.bicep'

param redisCacheName = 'acr-test-basic-c6'
param location = 'westus2'
param skuName = 'Basic'
param skuFamily = 'C'
param skuCapacity = 6
param enableNonSslPort = true
param minimumTlsVersion = '1.2'
param maxmemoryPolicy = 'allkeys-lru'
param aadEnabled = false
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
