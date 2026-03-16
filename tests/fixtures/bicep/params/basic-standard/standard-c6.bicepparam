using '../../acr-basic-standard.bicep'

param redisCacheName = 'acr-test-standard-c6'
param location = 'westus2'
param skuName = 'Standard'
param skuFamily = 'C'
param skuCapacity = 6
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param maxmemoryPolicy = 'volatile-ttl'
param aadEnabled = true
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
