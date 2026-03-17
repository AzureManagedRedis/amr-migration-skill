# Before/After Code Examples

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

Detailed before (ACRE) and after (AMR) examples for each automation type.

## Table of Contents

- [ARM Template Examples](#arm-template-examples)
- [Bicep Template Examples](#bicep-template-examples)
- [Azure CLI Examples](#azure-cli-examples)
- [Azure PowerShell Examples](#azure-powershell-examples)

---

## ARM Template Examples

### Cluster Resource — Before (ACRE)

```json
{
  "type": "Microsoft.Cache/redisEnterprise",
  "apiVersion": "2023-11-01",
  "name": "[parameters('cacheName')]",
  "location": "[parameters('location')]",
  "sku": {
    "name": "Enterprise_E10",
    "capacity": 2
  },
  "zones": ["1", "2", "3"],
  "properties": {
    "minimumTlsVersion": "1.2"
  }
}
```

### Cluster Resource — After (AMR)

```json
{
  "type": "Microsoft.Cache/redisEnterprise",
  "apiVersion": "2025-07-01",
  "name": "[parameters('cacheName')]",
  "location": "[parameters('location')]",
  "sku": {
    "name": "Balanced_B20"
  },
  "properties": {
    "minimumTlsVersion": "1.2",
    "publicNetworkAccess": "Disabled"
  }
}
```

### Database Resource — Before (ACRE)

```json
{
  "type": "Microsoft.Cache/redisEnterprise/databases",
  "apiVersion": "2023-11-01",
  "name": "[concat(parameters('cacheName'), '/default')]",
  "dependsOn": [
    "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]"
  ],
  "properties": {
    "clientProtocol": "Encrypted",
    "clusteringPolicy": "OSSCluster",
    "evictionPolicy": "VolatileLRU",
    "port": 10000,
    "modules": [
      {
        "name": "RedisJSON"
      }
    ],
    "persistence": {
      "aofEnabled": false,
      "rdbEnabled": true,
      "rdbFrequency": "1h"
    }
  }
}
```

### Database Resource — After (AMR)

```json
{
  "type": "Microsoft.Cache/redisEnterprise/databases",
  "apiVersion": "2025-07-01",
  "name": "[concat(parameters('cacheName'), '/default')]",
  "dependsOn": [
    "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]"
  ],
  "properties": {
    "clientProtocol": "Encrypted",
    "clusteringPolicy": "OSSCluster",
    "evictionPolicy": "VolatileLRU",
    "port": 10000,
    "modules": [
      {
        "name": "RedisJSON"
      }
    ],
    "persistence": {
      "aofEnabled": false,
      "rdbEnabled": true,
      "rdbFrequency": "1h"
    },
    "accessKeysAuthentication": "Enabled"
  }
}
```

> Database properties are mostly unchanged. Key additions: `accessKeysAuthentication` must be explicitly set to `Enabled` if the application uses access keys (default is `Disabled`).

### Private Endpoint & DNS Zone — Before (ACRE)

```json
{
  "type": "Microsoft.Network/privateDnsZones",
  "apiVersion": "2020-06-01",
  "name": "privatelink.redisenterprise.cache.azure.net",
  "location": "global"
},
{
  "type": "Microsoft.Network/privateEndpoints",
  "apiVersion": "2023-04-01",
  "name": "[parameters('privateEndpointName')]",
  "location": "[parameters('location')]",
  "properties": {
    "subnet": {
      "id": "[parameters('subnetId')]"
    },
    "privateLinkServiceConnections": [
      {
        "name": "[parameters('privateEndpointName')]",
        "properties": {
          "privateLinkServiceId": "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]",
          "groupIds": ["redisEnterprise"]
        }
      }
    ]
  }
},
{
  "type": "Microsoft.Network/privateEndpoints/privateDnsZoneGroups",
  "apiVersion": "2023-04-01",
  "name": "[concat(parameters('privateEndpointName'), '/default')]",
  "dependsOn": [
    "[resourceId('Microsoft.Network/privateEndpoints', parameters('privateEndpointName'))]",
    "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.redisenterprise.cache.azure.net')]"
  ],
  "properties": {
    "privateDnsZoneConfigs": [
      {
        "name": "config1",
        "properties": {
          "privateDnsZoneId": "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.redisenterprise.cache.azure.net')]"
        }
      }
    ]
  }
}
```

### Private Endpoint & DNS Zone — After (AMR) — Option A: Sequential (replace old with new)

```json
{
  "type": "Microsoft.Network/privateDnsZones",
  "apiVersion": "2020-06-01",
  "name": "privatelink.redis.azure.net",
  "location": "global"
},
{
  "type": "Microsoft.Network/privateEndpoints",
  "apiVersion": "2023-04-01",
  "name": "[parameters('privateEndpointName')]",
  "location": "[parameters('location')]",
  "properties": {
    "subnet": {
      "id": "[parameters('subnetId')]"
    },
    "privateLinkServiceConnections": [
      {
        "name": "[parameters('privateEndpointName')]",
        "properties": {
          "privateLinkServiceId": "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]",
          "groupIds": ["redisEnterprise"]
        }
      }
    ]
  }
},
{
  "type": "Microsoft.Network/privateEndpoints/privateDnsZoneGroups",
  "apiVersion": "2023-04-01",
  "name": "[concat(parameters('privateEndpointName'), '/default')]",
  "dependsOn": [
    "[resourceId('Microsoft.Network/privateEndpoints', parameters('privateEndpointName'))]",
    "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.redis.azure.net')]"
  ],
  "properties": {
    "privateDnsZoneConfigs": [
      {
        "name": "config1",
        "properties": {
          "privateDnsZoneId": "[resourceId('Microsoft.Network/privateDnsZones', 'privatelink.redis.azure.net')]"
        }
      }
    ]
  }
}
```

> **Option A** replaces the old PE/DNS zone with the new one. Deploy **after** the cache is migrated. **Order**: (1) Migrate cache. (2) Deploy updated template. (3) Update app hostname. (4) Verify connectivity.

### Private Endpoint & DNS Zone — After (AMR) — Option B: Coexist old + new PE (zero-downtime)

Keep **all existing PE/DNS resources unchanged** and add these **new** resources alongside them in the same template. Add these variables:

```json
"amrPrivateEndpointName": "[concat(parameters('cacheName'), '-amr-pe')]",
"amrPrivateDnsZoneName": "privatelink.redis.azure.net",
"amrPrivateDnsZoneGroupName": "[concat(variables('amrPrivateEndpointName'), '/default')]",
"amrPrivateDnsZoneLinkName": "[concat(variables('amrPrivateDnsZoneName'), '/', parameters('vnetName'), '-link')]"
```

Add these resources (the old PE/DNS resources remain in the template):

```json
{
  "type": "Microsoft.Network/privateDnsZones",
  "apiVersion": "2020-06-01",
  "name": "[variables('amrPrivateDnsZoneName')]",
  "location": "global"
},
{
  "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
  "apiVersion": "2020-06-01",
  "name": "[variables('amrPrivateDnsZoneLinkName')]",
  "location": "global",
  "dependsOn": [
    "[resourceId('Microsoft.Network/privateDnsZones', variables('amrPrivateDnsZoneName'))]",
    "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
  ],
  "properties": {
    "registrationEnabled": false,
    "virtualNetwork": {
      "id": "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
    }
  }
},
{
  "type": "Microsoft.Network/privateEndpoints",
  "apiVersion": "2023-11-01",
  "name": "[variables('amrPrivateEndpointName')]",
  "location": "[parameters('location')]",
  "dependsOn": [
    "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]",
    "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
  ],
  "properties": {
    "subnet": {
      "id": "[resourceId('Microsoft.Network/virtualNetworks/subnets', parameters('vnetName'), parameters('subnetName'))]"
    },
    "privateLinkServiceConnections": [
      {
        "name": "[variables('amrPrivateEndpointName')]",
        "properties": {
          "privateLinkServiceId": "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]",
          "groupIds": [
            "redisEnterprise"
          ]
        }
      }
    ]
  }
},
{
  "type": "Microsoft.Network/privateEndpoints/privateDnsZoneGroups",
  "apiVersion": "2023-11-01",
  "name": "[variables('amrPrivateDnsZoneGroupName')]",
  "dependsOn": [
    "[resourceId('Microsoft.Network/privateEndpoints', variables('amrPrivateEndpointName'))]",
    "[resourceId('Microsoft.Network/privateDnsZones', variables('amrPrivateDnsZoneName'))]"
  ],
  "properties": {
    "privateDnsZoneConfigs": [
      {
        "name": "redisEnterprise",
        "properties": {
          "privateDnsZoneId": "[resourceId('Microsoft.Network/privateDnsZones', variables('amrPrivateDnsZoneName'))]"
        }
      }
    ]
  }
}
```

> **Option B workflow**: (1) Deploy this template with both old and new PE/DNS resources. (2) Migrate the cache (outside this template). (3) The new PE resolves via `privatelink.redis.azure.net` once migration completes. (4) Update app connection string to AMR hostname. (5) Verify connectivity through new PE. (6) Remove old PE resources from template and redeploy. (7) Manually delete old PE/DNS from Azure — ARM incremental deployments do **not** delete resources removed from the template (`az network private-endpoint delete`, `az network private-dns zone delete`).

---

## Bicep Template Examples

### Cluster Resource — Before (ACRE)

```bicep
resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2023-11-01' = {
  name: cacheName
  location: location
  sku: {
    name: 'Enterprise_E10'
    capacity: 2
  }
  zones: ['1', '2', '3']
  properties: {
    minimumTlsVersion: '1.2'
  }
}
```

### Cluster Resource — After (AMR)

```bicep
resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: cacheName
  location: location
  sku: {
    name: 'Balanced_B20'
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}
```

### Database Resource — Before (ACRE)

```bicep
resource database 'Microsoft.Cache/redisEnterprise/databases@2023-11-01' = {
  parent: redisEnterprise
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'OSSCluster'
    evictionPolicy: 'VolatileLRU'
    port: 10000
  }
}
```

### Database Resource — After (AMR)

```bicep
resource database 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redisEnterprise
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'OSSCluster'
    evictionPolicy: 'VolatileLRU'
    port: 10000
    accessKeysAuthentication: 'Enabled'  // Required if access keys are used (default is Disabled)
  }
}
```

### Private Endpoint & DNS Zone — Before (ACRE)

```bicep
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redisenterprise.cache.azure.net'
  location: 'global'
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: redisEnterprise.id
          groupIds: ['redisEnterprise']
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}
```

### Private Endpoint & DNS Zone — After (AMR) — Option A: Sequential (replace old with new)

```bicep
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.azure.net'
  location: 'global'
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: redisEnterprise.id
          groupIds: ['redisEnterprise']
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}
```

> **Option A** replaces the old PE/DNS with the new one. Deploy **after** migration. **Order**: (1) Migrate cache. (2) Deploy updated template. (3) Update app hostname. (4) Verify.

### Private Endpoint & DNS Zone — After (AMR) — Option B: Coexist old + new PE (zero-downtime)

Keep **all existing PE/DNS resources unchanged** and add these **new** resources alongside them:

```bicep
// --- New AMR Private DNS Zone ---
resource amrPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.azure.net'
  location: 'global'
}

resource amrPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: amrPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// --- New AMR Private Endpoint ---
resource amrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${cacheName}-amr-pe'
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${cacheName}-amr-pe'
        properties: {
          privateLinkServiceId: redisEnterprise.id
          groupIds: ['redisEnterprise']
        }
      }
    ]
  }
}

resource amrDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  parent: amrPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: amrPrivateDnsZone.id
        }
      }
    ]
  }
}
```

> **Option B workflow**: (1) Deploy with both old and new PE/DNS resources. (2) Migrate cache. (3) New PE resolves once migration completes. (4) Update app hostname. (5) Verify connectivity. (6) Remove old PE/DNS resources from template and redeploy. (7) Manually delete old resources from Azure.

---

## Azure CLI Examples

### Create Cluster — Before (ACRE)

```bash
az redisenterprise create \
  --name "mycache" \
  --resource-group "myRG" \
  --location "eastus" \
  --sku "Enterprise_E10" \
  --capacity 2 \
  --zones "1" "2" "3" \
  --minimum-tls-version "1.2"
```

### Create Cluster — After (AMR)

```bash
az redisenterprise create \
  --name "mycache" \
  --resource-group "myRG" \
  --location "eastus" \
  --sku "Balanced_B20" \
  --minimum-tls-version "1.2" \
  --public-network-access "Disabled"
```

### Create Database — Before (ACRE)

```bash
az redisenterprise database create \
  --cluster-name "mycache" \
  --resource-group "myRG" \
  --client-protocol "Encrypted" \
  --clustering-policy "OSSCluster" \
  --eviction-policy "VolatileLRU" \
  --port 10000
```

### Create Database — After (AMR)

```bash
az redisenterprise database create \
  --cluster-name "mycache" \
  --resource-group "myRG" \
  --client-protocol "Encrypted" \
  --clustering-policy "OSSCluster" \
  --eviction-policy "VolatileLRU" \
  --port 10000 \
  --access-keys-authentication "Enabled"  # Required if access keys are used (default is Disabled)
```

### Private Endpoint & DNS Zone — Before (ACRE)

```bash
# Create Private DNS Zone
az network private-dns zone create \
  --resource-group "myRG" \
  --name "privatelink.redisenterprise.cache.azure.net"

# Create Private Endpoint
az network private-endpoint create \
  --name "myPE" \
  --resource-group "myRG" \
  --vnet-name "myVNet" \
  --subnet "mySubnet" \
  --private-connection-resource-id "$(az redisenterprise show --name mycache --resource-group myRG --query id -o tsv)" \
  --group-id "redisEnterprise" \
  --connection-name "myConnection"

# Link PE to DNS Zone
az network private-endpoint dns-zone-group create \
  --endpoint-name "myPE" \
  --resource-group "myRG" \
  --name "default" \
  --private-dns-zone "privatelink.redisenterprise.cache.azure.net" \
  --zone-name "config1"
```

### Private Endpoint & DNS Zone — After (AMR) — Option A: Sequential

```bash
# Step 1: Create new Private DNS Zone (run after cache is migrated to AMR)
az network private-dns zone create \
  --resource-group "myRG" \
  --name "privatelink.redis.azure.net"

# Step 2: Create new Private Endpoint
az network private-endpoint create \
  --name "myPE-amr" \
  --resource-group "myRG" \
  --vnet-name "myVNet" \
  --subnet "mySubnet" \
  --private-connection-resource-id "$(az redisenterprise show --name mycache --resource-group myRG --query id -o tsv)" \
  --group-id "redisEnterprise" \
  --connection-name "myConnection"

# Step 3: Link new PE to new DNS Zone
az network private-endpoint dns-zone-group create \
  --endpoint-name "myPE-amr" \
  --resource-group "myRG" \
  --name "default" \
  --private-dns-zone "privatelink.redis.azure.net" \
  --zone-name "config1"

# Step 4: Update application connection string to use new AMR hostname (*.redis.azure.net)
# Step 5: Verify application connectivity through the new PE

# Step 6: Only after verifying, delete the old Private Endpoint and DNS Zone
az network private-endpoint delete \
  --name "myPE" \
  --resource-group "myRG"

az network private-dns zone delete \
  --resource-group "myRG" \
  --name "privatelink.redisenterprise.cache.azure.net" \
  --yes
```

> **Option A**: Run **after** the cache is migrated. Create new DNS zone + PE, switch app, verify, then delete old resources.

### Private Endpoint & DNS Zone — After (AMR) — Option B: Coexist old + new PE (zero-downtime)

Keep the existing PE/DNS commands and add these **before** migration:

```bash
# --- Create the old ACRE PE/DNS (keep existing commands as-is) ---
# ... (existing az network private-dns zone create, private-endpoint create, dns-zone-group create)

# --- Add new AMR PE/DNS alongside the old ones ---

# Create new AMR Private DNS Zone
az network private-dns zone create \
  --resource-group "myRG" \
  --name "privatelink.redis.azure.net"

# Link new DNS zone to VNet
az network private-dns link vnet create \
  --resource-group "myRG" \
  --zone-name "privatelink.redis.azure.net" \
  --name "myVNet-link" \
  --virtual-network "myVNet" \
  --registration-enabled false

# Create new AMR Private Endpoint
az network private-endpoint create \
  --name "myPE-amr" \
  --resource-group "myRG" \
  --vnet-name "myVNet" \
  --subnet "mySubnet" \
  --private-connection-resource-id "$(az redisenterprise show --name mycache --resource-group myRG --query id -o tsv)" \
  --group-id "redisEnterprise" \
  --connection-name "myConnection"

# Link new PE to new DNS Zone
az network private-endpoint dns-zone-group create \
  --endpoint-name "myPE-amr" \
  --resource-group "myRG" \
  --name "default" \
  --private-dns-zone "privatelink.redis.azure.net" \
  --zone-name "config1"

# --- After migration is complete and app is switched: ---
# Step 1: Migrate cache using Azure migration tooling
# Step 2: Update application connection string to AMR hostname (*.redis.azure.net)
# Step 3: Verify connectivity through the new PE

# Step 4: Only after verifying, clean up old resources
az network private-endpoint delete \
  --name "myPE" \
  --resource-group "myRG"

az network private-dns zone delete \
  --resource-group "myRG" \
  --name "privatelink.redisenterprise.cache.azure.net" \
  --yes
```

> **Option B workflow**: (1) Run script to create both old and new DNS zones + PEs. (2) Migrate cache. (3) Update app hostname. (4) Verify connectivity. (5) Delete old PE and DNS zone.

---

## Azure PowerShell Examples

### Create Cluster — Before (ACRE)

```powershell
New-AzRedisEnterpriseCache `
  -Name "mycache" `
  -ResourceGroupName "myRG" `
  -Location "eastus" `
  -SkuName "Enterprise_E10" `
  -SkuCapacity 2 `
  -Zone @("1", "2", "3") `
  -MinimumTlsVersion "1.2"
```

### Create Cluster — After (AMR)

```powershell
New-AzRedisEnterpriseCache `
  -Name "mycache" `
  -ResourceGroupName "myRG" `
  -Location "eastus" `
  -SkuName "Balanced_B20" `
  -MinimumTlsVersion "1.2" `
  -PublicNetworkAccess "Disabled"
```

### Create Database — Before (ACRE)

```powershell
New-AzRedisEnterpriseCacheDatabase `
  -ClusterName "mycache" `
  -ResourceGroupName "myRG" `
  -ClientProtocol "Encrypted" `
  -ClusteringPolicy "OSSCluster" `
  -EvictionPolicy "VolatileLRU" `
  -Port 10000
```

### Create Database — After (AMR)

```powershell
New-AzRedisEnterpriseCacheDatabase `
  -ClusterName "mycache" `
  -ResourceGroupName "myRG" `
  -ClientProtocol "Encrypted" `
  -ClusteringPolicy "OSSCluster" `
  -EvictionPolicy "VolatileLRU" `
  -Port 10000 `
  -AccessKeysAuthentication "Enabled"  # Required if access keys are used (default is Disabled)
```

### Private Endpoint & DNS Zone — Before (ACRE)

```powershell
# Create Private DNS Zone
$dnsZone = New-AzPrivateDnsZone `
  -ResourceGroupName "myRG" `
  -Name "privatelink.redisenterprise.cache.azure.net"

# Create Private Link Service Connection
$plsConnection = New-AzPrivateLinkServiceConnection `
  -Name "myConnection" `
  -PrivateLinkServiceId (Get-AzRedisEnterpriseCache -Name "mycache" -ResourceGroupName "myRG").Id `
  -GroupId "redisEnterprise"

# Create Private Endpoint
$pe = New-AzPrivateEndpoint `
  -Name "myPE" `
  -ResourceGroupName "myRG" `
  -Location "eastus" `
  -Subnet (Get-AzVirtualNetworkSubnetConfig -Name "mySubnet" -VirtualNetwork (Get-AzVirtualNetwork -Name "myVNet" -ResourceGroupName "myRG")) `
  -PrivateLinkServiceConnection $plsConnection

# Link PE to DNS Zone
$dnsConfig = New-AzPrivateDnsZoneConfig `
  -Name "config1" `
  -PrivateDnsZoneId $dnsZone.ResourceId

New-AzPrivateDnsZoneGroup `
  -ResourceGroupName "myRG" `
  -PrivateEndpointName "myPE" `
  -Name "default" `
  -PrivateDnsZoneConfig $dnsConfig
```

### Private Endpoint & DNS Zone — After (AMR) — Option A: Sequential

```powershell
# Step 1: Create new Private DNS Zone (run after cache is migrated to AMR)
$dnsZone = New-AzPrivateDnsZone `
  -ResourceGroupName "myRG" `
  -Name "privatelink.redis.azure.net"

# Step 2: Create Private Link Service Connection
$plsConnection = New-AzPrivateLinkServiceConnection `
  -Name "myConnection" `
  -PrivateLinkServiceId (Get-AzRedisEnterpriseCache -Name "mycache" -ResourceGroupName "myRG").Id `
  -GroupId "redisEnterprise"

# Step 3: Create new Private Endpoint
$pe = New-AzPrivateEndpoint `
  -Name "myPE-amr" `
  -ResourceGroupName "myRG" `
  -Location "eastus" `
  -Subnet (Get-AzVirtualNetworkSubnetConfig -Name "mySubnet" -VirtualNetwork (Get-AzVirtualNetwork -Name "myVNet" -ResourceGroupName "myRG")) `
  -PrivateLinkServiceConnection $plsConnection

# Step 4: Link new PE to new DNS Zone
$dnsConfig = New-AzPrivateDnsZoneConfig `
  -Name "config1" `
  -PrivateDnsZoneId $dnsZone.ResourceId

New-AzPrivateDnsZoneGroup `
  -ResourceGroupName "myRG" `
  -PrivateEndpointName "myPE-amr" `
  -Name "default" `
  -PrivateDnsZoneConfig $dnsConfig

# Step 5: Update application connection string to use new AMR hostname (*.redis.azure.net)
# Step 6: Verify application connectivity through the new PE

# Step 7: Only after verifying, remove the old Private Endpoint and DNS Zone
Remove-AzPrivateEndpoint `
  -Name "myPE" `
  -ResourceGroupName "myRG" `
  -Force

Remove-AzPrivateDnsZone `
  -ResourceGroupName "myRG" `
  -Name "privatelink.redisenterprise.cache.azure.net"
```

> **Option A**: Run **after** the cache is migrated. Create new DNS zone + PE, switch app, verify, then remove old resources.

### Private Endpoint & DNS Zone — After (AMR) — Option B: Coexist old + new PE (zero-downtime)

Keep the existing PE/DNS commands and add these **before** migration:

```powershell
# --- Create the old ACRE PE/DNS (keep existing commands as-is) ---
# ... (existing New-AzPrivateDnsZone, New-AzPrivateEndpoint, New-AzPrivateDnsZoneGroup)

# --- Add new AMR PE/DNS alongside the old ones ---

# Create new AMR Private DNS Zone
$amrDnsZone = New-AzPrivateDnsZone `
  -ResourceGroupName "myRG" `
  -Name "privatelink.redis.azure.net"

# Link new DNS zone to VNet
New-AzPrivateDnsVirtualNetworkLink `
  -ResourceGroupName "myRG" `
  -ZoneName "privatelink.redis.azure.net" `
  -Name "myVNet-link" `
  -VirtualNetworkId (Get-AzVirtualNetwork -Name "myVNet" -ResourceGroupName "myRG").Id `
  -EnableRegistration:$false

# Create Private Link Service Connection for new PE
$amrPlsConnection = New-AzPrivateLinkServiceConnection `
  -Name "myConnection" `
  -PrivateLinkServiceId (Get-AzRedisEnterpriseCache -Name "mycache" -ResourceGroupName "myRG").Id `
  -GroupId "redisEnterprise"

# Create new AMR Private Endpoint
$amrPe = New-AzPrivateEndpoint `
  -Name "myPE-amr" `
  -ResourceGroupName "myRG" `
  -Location "eastus" `
  -Subnet (Get-AzVirtualNetworkSubnetConfig -Name "mySubnet" -VirtualNetwork (Get-AzVirtualNetwork -Name "myVNet" -ResourceGroupName "myRG")) `
  -PrivateLinkServiceConnection $amrPlsConnection

# Link new PE to new DNS Zone
$amrDnsConfig = New-AzPrivateDnsZoneConfig `
  -Name "config1" `
  -PrivateDnsZoneId $amrDnsZone.ResourceId

New-AzPrivateDnsZoneGroup `
  -ResourceGroupName "myRG" `
  -PrivateEndpointName "myPE-amr" `
  -Name "default" `
  -PrivateDnsZoneConfig $amrDnsConfig

# --- After migration is complete and app is switched: ---
# Step 1: Migrate cache using Azure migration tooling
# Step 2: Update application connection string to AMR hostname (*.redis.azure.net)
# Step 3: Verify connectivity through the new PE

# Step 4: Only after verifying, clean up old resources
Remove-AzPrivateEndpoint `
  -Name "myPE" `
  -ResourceGroupName "myRG" `
  -Force

Remove-AzPrivateDnsZone `
  -ResourceGroupName "myRG" `
  -Name "privatelink.redisenterprise.cache.azure.net"
```

> **Option B workflow**: (1) Run script to create both old and new DNS zones + PEs. (2) Migrate cache. (3) Update app hostname. (4) Verify connectivity. (5) Remove old PE and DNS zone.
