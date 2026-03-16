using '../../acr-basic-standard.bicep'

param redisCacheName = 'acr-test-standard-c3'
param location = 'westus2'
param skuName = 'Standard'
param skuFamily = 'C'
param skuCapacity = 3
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param maxmemoryPolicy = 'allkeys-lru'
param aadEnabled = true
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
