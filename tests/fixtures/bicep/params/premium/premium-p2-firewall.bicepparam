using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p2-fw'
param location = 'westus2'
param skuCapacity = 2
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param redisVersion = '6'
param shardCount = 0
param firewallRules = [
  {
    name: 'AllowAppSubnet'
    startIP: '10.0.1.0'
    endIP: '10.0.1.255'
  }
  {
    name: 'AllowMonitoring'
    startIP: '10.0.5.0'
    endIP: '10.0.5.255'
  }
]
param aadEnabled = true
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
