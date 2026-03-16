using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p2-aof'
param location = 'westus2'
param skuCapacity = 2
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param aofBackupEnabled = true
param persistenceStorageAccountName = 'acrtoamre2etest218'
param userAssignedManagedIdentityId = '/subscriptions/fc2f20f5-602a-4ebd-97e6-4fae3f1f6424/resourcegroups/rg-acrtoamr-e2etest/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-acrtoamr-persistence'
param maxmemoryPolicy = 'allkeys-lfu'
param aadEnabled = true
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
}
