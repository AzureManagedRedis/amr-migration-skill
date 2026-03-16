using '../../acr-basic-standard.bicep'

param redisCacheName = 'acr-test-standard-c1'
param location = 'westus2'
param skuName = 'Standard'
param skuFamily = 'C'
param skuCapacity = 1
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param maxmemoryPolicy = 'volatile-lru'
param aadEnabled = true
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
