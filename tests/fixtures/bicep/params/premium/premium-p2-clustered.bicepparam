using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p2-clustered'
param location = 'westus2'
param skuCapacity = 2
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param redisVersion = '6'
param shardCount = 3
param rdbBackupEnabled = true
param rdbBackupFrequency = 60
param persistenceStorageAccountName = 'acrtoamre2etest218'
param userAssignedManagedIdentityId = '/subscriptions/fc2f20f5-602a-4ebd-97e6-4fae3f1f6424/resourcegroups/rg-acrtoamr-e2etest/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-acrtoamr-persistence'
param maxmemoryPolicy = 'volatile-lru'
param maxmemoryReserved = '642'
param maxfragmentationmemoryReserved = '642'
param aadEnabled = true
param zones = ['1', '2', '3']
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
