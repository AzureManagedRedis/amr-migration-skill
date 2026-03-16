using '../../acr-premium.bicep'

param redisCacheName = 'acr-test-premium-p2-all'
param location = 'westus2'
param skuCapacity = 2
param enableNonSslPort = false
param minimumTlsVersion = '1.2'
param shardCount = 3
param replicasPerPrimary = 2
param rdbBackupEnabled = true
param rdbBackupFrequency = 360
param persistenceStorageAccountName = 'acrtoamre2etest218'
param userAssignedManagedIdentityId = '/subscriptions/fc2f20f5-602a-4ebd-97e6-4fae3f1f6424/resourcegroups/rg-acrtoamr-e2etest/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-acrtoamr-persistence'
param maxmemoryPolicy = 'volatile-lfu'
param maxmemoryReserved = '1024'
param maxfragmentationmemoryReserved = '1024'
param aadEnabled = true
param firewallRules = [
  {
    name: 'AllowAll'
    startIP: '10.0.0.0'
    endIP: '10.0.255.255'
  }
]
param zones = ['1', '2', '3']
param tags = {
  Environment: 'Test'
  Service: 'MigrationValidation'
  ManagedBy: 'IaC'
  CostCenter: '99999'
  HasAllFeatures: 'true'
}
