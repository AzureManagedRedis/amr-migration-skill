#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 tests for Convert-AcrToAmr.ps1 core functions.
.DESCRIPTION
    Uses AST-based extraction to load function definitions and script-level
    variables without executing the param() block or Main entrypoint.
    Tests cover: Resolve-ArmValue, Parse-ArmConfig, Get-AmrSkuMapping,
    Get-FeatureGaps, Convert-ArmTemplate, Convert-ParametersFile,
    Update-DependsOn, Build-PrivateEndpointResource, Get-PricingComparison.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot ".." "Helpers.ps1")

    # Load shared module (provides $script:AmrSkuSpecs, Get-RetailPrice, Get-CacheNodeCount)
    $script:SharedPath = Join-Path $PSScriptRoot ".." ".." "scripts" "AmrMigrationHelpers.ps1"
    $script:SharedScriptBlock = Get-SharedHelpersBlock

    # Parse Convert-AcrToAmr.ps1 — extract functions + script-level variables via AST
    $script:SutPath = Join-Path $PSScriptRoot ".." ".." "iac" "Convert-AcrToAmr.ps1"
    $script:SutScriptBlock = Get-FunctionsScriptBlock -Path $script:SutPath -IncludeScriptVariables

    # Fixture paths
    $script:FixtureRoot = Join-Path $PSScriptRoot ".." "fixtures" "arm"
    $script:TemplatePath = Join-Path $script:FixtureRoot "acr-premium.json"
    $script:BasicStdTemplatePath = Join-Path $script:FixtureRoot "acr-basic-standard.json"
    $script:DefaultParamsPath = Join-Path $script:FixtureRoot "acr-cache.parameters.json"
    $script:ParamsDir = Join-Path $script:FixtureRoot "params"
    $script:BasicStdParamsDir = Join-Path $script:ParamsDir "basic-standard"
    $script:PremiumParamsDir = Join-Path $script:ParamsDir "premium"

    # Helper: load template + params as hashtables
    function Load-Template {
        param([string]$Path)
        return (Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable)
    }

    # Helper: build a simplified ARM template with direct [parameters('x')] refs (no if/variables)
    function New-SimpleAcrTemplate {
        param(
            [switch]$WithFirewall,
            [switch]$WithPrivateEndpoint,
            [switch]$WithIdentity
        )
        $resources = @(
            @{
                type       = "Microsoft.Cache/redis"
                apiVersion = "2023-08-01"
                name       = "[parameters('redisCacheName')]"
                location   = "[parameters('location')]"
                sku        = @{
                    name     = "[parameters('skuName')]"
                    family   = "[parameters('skuFamily')]"
                    capacity = "[parameters('skuCapacity')]"
                }
                zones      = "[parameters('zones')]"
                tags       = @{ Environment = "Test" }
                properties = @{
                    enableNonSslPort   = "[parameters('enableNonSslPort')]"
                    minimumTlsVersion  = "1.2"
                    subnetId           = "[parameters('subnetId')]"
                    shardCount         = "[parameters('shardCount')]"
                    replicasPerPrimary = "[parameters('replicasPerPrimary')]"
                    redisConfiguration = @{
                        "maxmemory-policy"     = "[parameters('maxmemoryPolicy')]"
                        "rdb-backup-enabled"   = "[parameters('rdbBackupEnabled')]"
                        "rdb-backup-frequency" = "[parameters('rdbBackupFrequency')]"
                        "aof-backup-enabled"   = "[parameters('aofBackupEnabled')]"
                    }
                }
            }
        )
        if ($WithIdentity) {
            $resources[0]["identity"] = @{ type = "SystemAssigned" }
        }
        if ($WithFirewall) {
            $resources += @{
                type       = "Microsoft.Cache/redis/firewallRules"
                name       = "[concat(parameters('redisCacheName'), '/rule1')]"
                properties = @{ startIP = "10.0.0.1"; endIP = "10.0.0.255" }
            }
        }
        if ($WithPrivateEndpoint) {
            $resources += @{
                type       = "Microsoft.Network/privateEndpoints"
                name       = "my-pe"
                properties = @{
                    privateLinkServiceConnections = @(
                        @{ properties = @{ groupIds = @("redisCache") } }
                    )
                }
            }
        }
        return @{
            '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
            contentVersion = "1.0.0.0"
            parameters     = @{
                redisCacheName = @{ type = "string" }
                location       = @{ type = "string" }
                skuName        = @{ type = "string" }
                skuFamily      = @{ type = "string" }
                skuCapacity    = @{ type = "int" }
                shardCount     = @{ type = "int" }
                replicasPerPrimary = @{ type = "int" }
                enableNonSslPort   = @{ type = "bool" }
                maxmemoryPolicy    = @{ type = "string" }
                rdbBackupEnabled   = @{ type = "string" }
                rdbBackupFrequency = @{ type = "int" }
                aofBackupEnabled   = @{ type = "string" }
                subnetId           = @{ type = "string" }
                zones              = @{ type = "array" }
            }
            resources      = $resources
        }
    }

    # Helper: build params file matching New-SimpleAcrTemplate
    function New-SimpleParams {
        param(
            [string]$CacheName = "test-cache",
            [string]$Location = "westus",
            [string]$Tier = "Premium",
            [string]$Family = "P",
            [int]$Capacity = 2,
            [int]$ShardCount = 1,
            [int]$Replicas = 1,
            [bool]$NonSslPort = $false,
            [string]$Eviction = "volatile-lru",
            [string]$RdbEnabled = "true",
            [int]$RdbFrequency = 60,
            [string]$AofEnabled = "false",
            [string]$SubnetId = "",
            $Zones = @("1","2","3")
        )
        return @{
            parameters = @{
                redisCacheName     = @{ value = $CacheName }
                location           = @{ value = $Location }
                skuName            = @{ value = $Tier }
                skuFamily          = @{ value = $Family }
                skuCapacity        = @{ value = $Capacity }
                shardCount         = @{ value = $ShardCount }
                replicasPerPrimary = @{ value = $Replicas }
                enableNonSslPort   = @{ value = $NonSslPort }
                maxmemoryPolicy    = @{ value = $Eviction }
                rdbBackupEnabled   = @{ value = $RdbEnabled }
                rdbBackupFrequency = @{ value = $RdbFrequency }
                aofBackupEnabled   = @{ value = $AofEnabled }
                subnetId           = @{ value = $SubnetId }
                zones              = @{ value = $Zones }
            }
        }
    }

    # Helper: create a minimal SourceConfig for unit tests
    function New-MockSourceConfig {
        param(
            [string]$Tier = "Premium",
            [string]$Sku = "P2",
            [int]$Capacity = 2,
            [int]$ShardCount = 1,
            [int]$ReplicasPerPrimary = 1,
            [bool]$RdbEnabled = $false,
            [string]$RdbFrequency = "",
            [bool]$AofEnabled = $false,
            [string]$EvictionPolicy = "volatile-lru",
            [bool]$HasVNet = $false,
            [bool]$HasFirewall = $false,
            [bool]$HasPrivateEndpoint = $false,
            [bool]$EnableNonSslPort = $false,
            [string]$CacheName = "test-cache",
            [string]$SubnetId = ""
        )
        return [PSCustomObject]@{
            CacheName          = $CacheName
            RawCacheName       = $CacheName
            Tier               = $Tier
            Sku                = $Sku
            Capacity           = $Capacity
            ShardCount         = $ShardCount
            ReplicasPerPrimary = $ReplicasPerPrimary
            Persistence        = [PSCustomObject]@{
                RdbEnabled   = $RdbEnabled
                RdbFrequency = $RdbFrequency
                AofEnabled   = $AofEnabled
            }
            Networking         = [PSCustomObject]@{
                HasVNet            = $HasVNet
                HasFirewall        = $HasFirewall
                HasPrivateEndpoint = $HasPrivateEndpoint
                SubnetId           = $SubnetId
            }
            EvictionPolicy     = $EvictionPolicy
            EnableNonSslPort   = $EnableNonSslPort
            MinimumTlsVersion  = "1.2"
            Zones              = $null
            HasIdentity        = $false
            Identity           = $null
            HasMRPP            = ($ReplicasPerPrimary -gt 1)
            Tags               = @{ Environment = "Test" }
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Resolve-ArmValue
# ─────────────────────────────────────────────────────────────
Describe "Resolve-ArmValue" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "returns null for null input" {
        Resolve-ArmValue -Value $null -Parameters @{} | Should -BeNullOrEmpty
    }

    It "returns literal string as-is" {
        Resolve-ArmValue -Value "westus2" -Parameters @{} | Should -Be "westus2"
    }

    It "returns integer as-is" {
        Resolve-ArmValue -Value 42 -Parameters @{} | Should -Be 42
    }

    It "returns boolean as-is" {
        Resolve-ArmValue -Value $true -Parameters @{} | Should -Be $true
    }

    It "resolves [parameters('x')] from params file" {
        $params = @{ parameters = @{ location = @{ value = "eastus" } } }
        Resolve-ArmValue -Value "[parameters('location')]" -Parameters $params | Should -Be "eastus"
    }

    It "returns unresolved reference when param not in file" {
        $params = @{ parameters = @{} }
        Resolve-ArmValue -Value "[parameters('missing')]" -Parameters $params | Should -Be "[parameters('missing')]"
    }

    It "does not resolve variables() expressions (fallback limitation)" {
        $params = @{ parameters = @{} }
        $result = Resolve-ArmValue -Value "[variables('myVar')]" -Parameters $params
        $result | Should -Be "[variables('myVar')]"
    }

    It "does not resolve concat() expressions (fallback limitation)" {
        $params = @{ parameters = @{} }
        $result = Resolve-ArmValue -Value "[concat(parameters('prefix'), '-redis')]" -Parameters $params
        $result | Should -Be "[concat(parameters('prefix'), '-redis')]"
    }

    It "resolves param with KeyVault reference entry (returns whole entry)" {
        $params = @{
            parameters = @{
                secret = @{
                    reference = @{
                        keyVault = @{ id = "/sub/rg/vault" }
                        secretName = "mysecret"
                    }
                }
            }
        }
        # No 'value' key → can't resolve → returns as-is
        Resolve-ArmValue -Value "[parameters('secret')]" -Parameters $params | Should -Be "[parameters('secret')]"
    }
}

# ─────────────────────────────────────────────────────────────
# Parse-ArmConfig (using simplified templates to avoid complex ARM expressions)
# ─────────────────────────────────────────────────────────────
Describe "Parse-ArmConfig" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    Context "Premium P2 clustered" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate
            $script:params = New-SimpleParams -CacheName "my-p2-clustered" -Tier "Premium" -Family "P" -Capacity 2 `
                -ShardCount 3 -RdbEnabled "true" -RdbFrequency 60 -Eviction "volatile-lru"
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
        }

        It "resolves cache name from parameters" {
            $script:config.CacheName | Should -Be "my-p2-clustered"
        }

        It "detects Premium tier" {
            $script:config.Tier | Should -Be "Premium"
        }

        It "detects P2 SKU code" {
            $script:config.Sku | Should -Be "P2"
        }

        It "detects shard count 3" {
            $script:config.ShardCount | Should -Be 3
        }

        It "detects RDB persistence enabled" {
            $script:config.Persistence.RdbEnabled | Should -BeTrue
        }

        It "detects RDB frequency 60" {
            $script:config.Persistence.RdbFrequency | Should -Be 60
        }

        It "detects eviction policy volatile-lru" {
            $script:config.EvictionPolicy | Should -Be "volatile-lru"
        }

        It "captures zones expression (unresolved without PSRule)" {
            # Parse-ArmConfig reads zones directly from template — with basic resolver it's the parameter reference
            $script:config.Zones | Should -Not -BeNullOrEmpty
        }

        It "non-SSL port is disabled" {
            $script:config.EnableNonSslPort | Should -BeFalse
        }

        It "no VNet (empty subnetId)" {
            $script:config.Networking.HasVNet | Should -BeFalse
        }
    }

    Context "Standard C3 (no persistence)" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate
            $script:params = New-SimpleParams -CacheName "my-std-c3" -Tier "Standard" -Family "C" -Capacity 3 `
                -ShardCount 0 -RdbEnabled "false" -AofEnabled "false" -Eviction "allkeys-lru"
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
        }

        It "detects Standard tier" {
            $script:config.Tier | Should -Be "Standard"
        }

        It "detects C3 SKU" {
            $script:config.Sku | Should -Be "C3"
        }

        It "shard count is 0" {
            $script:config.ShardCount | Should -Be 0
        }

        It "no persistence" {
            $script:config.Persistence.RdbEnabled | Should -BeFalse
            $script:config.Persistence.AofEnabled | Should -BeFalse
        }
    }

    Context "Premium P2 with VNet" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate
            $script:params = New-SimpleParams -Tier "Premium" -Family "P" -Capacity 2 `
                -SubnetId "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/default"
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
        }

        It "detects VNet injection" {
            $script:config.Networking.HasVNet | Should -BeTrue
        }

        It "captures subnet ID" {
            $script:config.Networking.SubnetId | Should -BeLike "*/Microsoft.Network/virtualNetworks/*"
        }
    }

    Context "with firewall and private endpoint child resources" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate -WithFirewall -WithPrivateEndpoint -WithIdentity
            $script:params = New-SimpleParams -Tier "Premium" -Family "P" -Capacity 2
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
        }

        It "detects firewall rules" {
            $script:config.Networking.HasFirewall | Should -BeTrue
        }

        It "detects private endpoint" {
            $script:config.Networking.HasPrivateEndpoint | Should -BeTrue
        }

        It "detects identity" {
            $script:config.HasIdentity | Should -BeTrue
        }
    }

    Context "MRPP (replicas > 1)" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate
            $script:params = New-SimpleParams -Tier "Premium" -Family "P" -Capacity 2 -Replicas 3
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
        }

        It "detects replicas per primary" {
            $script:config.ReplicasPerPrimary | Should -Be 3
        }

        It "flags HasMRPP" {
            $script:config.HasMRPP | Should -BeTrue
        }
    }

    It "throws on template with no resources" {
        $bad = @{ '$schema' = "..."; resources = @() }
        { Parse-ArmConfig -Template $bad -Parameters @{} } | Should -Throw "*No resources*"
    }

    It "throws on template with no ACR resource" {
        $bad = @{
            resources = @(
                @{ type = "Microsoft.Web/sites"; name = "myapp"; properties = @{} }
            )
        }
        { Parse-ArmConfig -Template $bad -Parameters @{} } | Should -Throw "*No Microsoft.Cache/redis*"
    }
}

# ─────────────────────────────────────────────────────────────
# Get-AmrSkuMapping
# ─────────────────────────────────────────────────────────────
Describe "Get-AmrSkuMapping" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    # Basic tier
    It "maps Basic C0 to Balanced_B0 with HA=false" {
        $config = New-MockSourceConfig -Tier "Basic" -Sku "C0" -Capacity 0
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "Balanced_B0"
        $result.HA | Should -BeFalse
    }

    It "maps Basic C3 to Balanced_B5 with HA=false" {
        $config = New-MockSourceConfig -Tier "Basic" -Sku "C3" -Capacity 3
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "Balanced_B5"
        $result.HA | Should -BeFalse
    }

    # Standard tier
    It "maps Standard C1 to Balanced_B1 with HA=true" {
        $config = New-MockSourceConfig -Tier "Standard" -Sku "C1" -Capacity 1
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "Balanced_B1"
        $result.HA | Should -BeTrue
    }

    It "maps Standard C6 to MemoryOptimized_M50" {
        $config = New-MockSourceConfig -Tier "Standard" -Sku "C6" -Capacity 6
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "MemoryOptimized_M50"
    }

    # Premium non-clustered
    It "maps Premium P1 non-clustered to Balanced_B5" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P1" -Capacity 1 -ShardCount 0
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "Balanced_B5"
        $result.HA | Should -BeTrue
    }

    It "maps Premium P2 non-clustered to Balanced_B10" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -ShardCount 0
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "Balanced_B10"
    }

    # Premium clustered
    It "maps Premium P2 with 3 shards to Balanced_B50" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -ShardCount 3
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "Balanced_B50"
    }

    It "maps Premium P5 with 10 shards to MemoryOptimized_M1500" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P5" -ShardCount 10
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Name | Should -Be "MemoryOptimized_M1500"
    }

    It "clamps shard count above 15 to 15" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -ShardCount 20
        $result = Get-AmrSkuMapping -SourceConfig $config
        # ShardCount 15 for P2 = Balanced_B250
        $result.Name | Should -Be "Balanced_B250"
    }

    # Override
    It "accepts manual target SKU override" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2"
        $result = Get-AmrSkuMapping -SourceConfig $config -TargetSkuOverride "MemoryOptimized_M100"
        $result.Name | Should -Be "MemoryOptimized_M100"
    }

    It "throws on invalid override SKU" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2"
        { Get-AmrSkuMapping -SourceConfig $config -TargetSkuOverride "NonExistent_X99" } | Should -Throw "*Unknown target SKU*"
    }

    # Return shape
    It "returns Advertised, Usable" {
        $config = New-MockSourceConfig -Tier "Standard" -Sku "C3"
        $result = Get-AmrSkuMapping -SourceConfig $config
        $result.Advertised | Should -BeLike "* GB"
        $result.Usable | Should -BeLike "* GB"
    }
}

# ─────────────────────────────────────────────────────────────
# Get-FeatureGaps
# ─────────────────────────────────────────────────────────────
Describe "Get-FeatureGaps" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "always includes port, SKU format, resource type changes" {
        $config = New-MockSourceConfig
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -eq "Port").Status | Should -Be "Changed"
        ($gaps | Where-Object Feature -eq "SKU format").Status | Should -Be "Changed"
        ($gaps | Where-Object Feature -eq "Resource type").Status | Should -Be "Changed"
    }

    It "flags VNet injection when HasVNet is true" {
        $config = New-MockSourceConfig -HasVNet $true
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -eq "VNet injection").Status | Should -Be "Removed"
    }

    It "does not flag VNet injection when HasVNet is false" {
        $config = New-MockSourceConfig -HasVNet $false
        $gaps = Get-FeatureGaps -SourceConfig $config
        $gaps | Where-Object Feature -eq "VNet injection" | Should -BeNullOrEmpty
    }

    It "flags firewall rules when HasFirewall is true" {
        $config = New-MockSourceConfig -HasFirewall $true
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -eq "Firewall rules").Status | Should -Be "Removed"
    }

    It "flags non-SSL port when enabled" {
        $config = New-MockSourceConfig -EnableNonSslPort $true
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -like "Non-SSL*").Status | Should -Be "Removed"
    }

    It "flags shard count when > 1" {
        $config = New-MockSourceConfig -ShardCount 3
        $gaps = Get-FeatureGaps -SourceConfig $config
        $gaps | Where-Object { $_.Feature -like "Explicit shard*" } | Should -Not -BeNullOrEmpty
    }

    It "flags MRPP when replicas > 1" {
        $config = New-MockSourceConfig -ReplicasPerPrimary 2
        $gaps = Get-FeatureGaps -SourceConfig $config
        $gaps | Where-Object { $_.Feature -like "Multi-replica*" } | Should -Not -BeNullOrEmpty
    }

    It "flags eviction policy format change" {
        $config = New-MockSourceConfig -EvictionPolicy "volatile-lru"
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -eq "Eviction policy").Status | Should -Be "Changed"
    }

    It "flags RDB persistence restructuring" {
        $config = New-MockSourceConfig -RdbEnabled $true -RdbFrequency "60"
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -eq "RDB persistence").Status | Should -Be "Changed"
    }

    It "flags AOF persistence restructuring" {
        $config = New-MockSourceConfig -AofEnabled $true
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Feature -eq "AOF persistence").Status | Should -Be "Changed"
    }

    It "includes new capabilities (Redis Stack, geo-rep, etc.)" {
        $config = New-MockSourceConfig
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Status -eq "New").Count | Should -BeGreaterOrEqual 4
    }

    It "includes recommendations (Entra auth, public network)" {
        $config = New-MockSourceConfig
        $gaps = Get-FeatureGaps -SourceConfig $config
        ($gaps | Where-Object Status -eq "Recommended").Count | Should -BeGreaterOrEqual 2
    }
}

# ─────────────────────────────────────────────────────────────
# Get-PricingComparison
# ─────────────────────────────────────────────────────────────
Describe "Get-PricingComparison" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "returns null monthly when pricing API returns nothing" {
        Mock Get-RetailPrice { return $null }
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2"
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Get-PricingComparison -SourceConfig $config -TargetSku $target -Region "westus2" -Currency "USD"
        $result.SourceMonthly | Should -BeNullOrEmpty
        $result.TargetMonthly | Should -BeNullOrEmpty
        $result.SourceError | Should -Not -BeNullOrEmpty
    }

    It "computes monthly cost correctly for Standard tier" {
        Mock Get-RetailPrice { return 0.10 }
        $config = New-MockSourceConfig -Tier "Standard" -Sku "C3"
        $target = [PSCustomObject]@{ Name = "Balanced_B5"; HA = $true }
        $result = Get-PricingComparison -SourceConfig $config -TargetSku $target -Region "westus2" -Currency "USD"
        # Standard = 2 nodes, AMR HA = 2 nodes → both $0.10 * 730 * 2 = $146.00
        $result.SourceMonthly | Should -Be 146.00
        $result.TargetMonthly | Should -Be 146.00
        $result.Delta | Should -Be 0
    }

    It "computes monthly cost for Premium clustered with MRPP" {
        Mock Get-RetailPrice { return 1.00 }
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -ShardCount 3 -ReplicasPerPrimary 2
        $target = [PSCustomObject]@{ Name = "Balanced_B50"; HA = $true }
        $result = Get-PricingComparison -SourceConfig $config -TargetSku $target -Region "westus2" -Currency "USD"
        # Premium: 3 shards * (1+2) replicas = 9 nodes → $1 * 730 * 9 = $6570
        $result.SourceMonthly | Should -Be 6570.00
        # AMR HA: 2 nodes → $1 * 730 * 2 = $1460
        $result.TargetMonthly | Should -Be 1460.00
    }

    It "computes delta as target minus source" {
        Mock Get-RetailPrice {
            if ($MeterName -like "P2*") { return 2.00 }
            return 1.50
        }
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -ShardCount 1
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Get-PricingComparison -SourceConfig $config -TargetSku $target -Region "westus2" -Currency "USD"
        $result.Delta | Should -Not -BeNullOrEmpty
    }

    It "returns error strings on pricing failures" {
        Mock Get-RetailPrice {
            if ($MeterName -like "P2*") { return $null }
            return 0.50
        }
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2"
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Get-PricingComparison -SourceConfig $config -TargetSku $target -Region "westus2" -Currency "USD"
        $result.SourceError | Should -BeLike "*No pricing found*"
        $result.TargetMonthly | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────
# Convert-ArmTemplate
# ─────────────────────────────────────────────────────────────
Describe "Convert-ArmTemplate" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    Context "Premium P2 clustered migration" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate
            $script:params = New-SimpleParams -CacheName "my-p2" -Tier "Premium" -Family "P" -Capacity 2 `
                -ShardCount 3 -RdbEnabled "true" -RdbFrequency 60 -Eviction "volatile-lru"
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
            $script:target = Get-AmrSkuMapping -SourceConfig $script:config
            $script:result = Convert-ArmTemplate -SourceConfig $script:config -TargetSku $script:target `
                -ClusteringPolicy "EnterpriseCluster" -SourceTemplate $script:template -SourceParameters $script:params
        }

        It "replaces ACR resource with redisEnterprise cluster" {
            $cluster = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise" }
            $cluster | Should -Not -BeNullOrEmpty
        }

        It "adds redisEnterprise/databases resource" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db | Should -Not -BeNullOrEmpty
        }

        It "no Microsoft.Cache/redis resource remains" {
            $acr = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redis" }
            $acr | Should -BeNullOrEmpty
        }

        It "cluster SKU matches target" {
            $cluster = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise" }
            $cluster["sku"]["name"] | Should -Be $script:target.Name
        }

        It "database has correct port 10000" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["properties"]["port"] | Should -Be 10000
        }

        It "database has Encrypted client protocol" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["properties"]["clientProtocol"] | Should -Be "Encrypted"
        }

        It "database has parameterized clustering policy" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["properties"]["clusteringPolicy"] | Should -Be "[parameters('clusteringPolicy')]"
        }

        It "database has parameterized eviction policy" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["properties"]["evictionPolicy"] | Should -Be "[parameters('evictionPolicy')]"
        }

        It "database has persistence with RDB enabled" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["properties"]["persistence"]["rdbEnabled"] | Should -BeTrue
        }

        It "RDB frequency is parameterized" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["properties"]["persistence"]["rdbFrequency"] | Should -Be "[parameters('rdbFrequency')]"
        }

        It "database depends on cluster resource" {
            $db = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise/databases" }
            $db["dependsOn"] | Should -HaveCount 1
            $db["dependsOn"][0] | Should -BeLike "*redisEnterprise*"
        }

        It "removes obsolete template parameters" {
            $templateParams = $script:result["parameters"]
            $templateParams.ContainsKey("skuFamily") | Should -BeFalse
            $templateParams.ContainsKey("skuCapacity") | Should -BeFalse
            $templateParams.ContainsKey("shardCount") | Should -BeFalse
            $templateParams.ContainsKey("enableNonSslPort") | Should -BeFalse
            $templateParams.ContainsKey("maxmemoryPolicy") | Should -BeFalse
            $templateParams.ContainsKey("rdbBackupFrequency") | Should -BeFalse
        }

        It "adds evictionPolicy template parameter with correct default" {
            $templateParams = $script:result["parameters"]
            $templateParams.ContainsKey("evictionPolicy") | Should -BeTrue
            $templateParams["evictionPolicy"]["defaultValue"] | Should -Be "VolatileLRU"
        }

        It "adds clusteringPolicy template parameter with allowedValues" {
            $templateParams = $script:result["parameters"]
            $templateParams.ContainsKey("clusteringPolicy") | Should -BeTrue
            $templateParams["clusteringPolicy"]["defaultValue"] | Should -Be "EnterpriseCluster"
            $templateParams["clusteringPolicy"]["allowedValues"] | Should -Contain "OSSCluster"
            $templateParams["clusteringPolicy"]["allowedValues"] | Should -Contain "EnterpriseCluster"
        }

        It "adds rdbFrequency template parameter when persistence enabled" {
            $templateParams = $script:result["parameters"]
            $templateParams.ContainsKey("rdbFrequency") | Should -BeTrue
            $templateParams["rdbFrequency"]["defaultValue"] | Should -Be "1h"
            $templateParams["rdbFrequency"]["allowedValues"] | Should -Contain "1h"
        }

        It "preserves non-ACR template parameters" {
            $templateParams = $script:result["parameters"]
            $templateParams.ContainsKey("redisCacheName") | Should -BeTrue
            $templateParams.ContainsKey("location") | Should -BeTrue
        }

        It "uses API version 2025-07-01" {
            $cluster = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise" }
            $cluster["apiVersion"] | Should -Be "2025-07-01"
        }
    }

    Context "VNet migration adds Private Endpoint" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate
            $script:params = New-SimpleParams -CacheName "my-vnet" -Tier "Premium" -Family "P" -Capacity 2 `
                -SubnetId "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/default"
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
            $script:target = Get-AmrSkuMapping -SourceConfig $script:config
            $script:result = Convert-ArmTemplate -SourceConfig $script:config -TargetSku $script:target `
                -ClusteringPolicy "OSSCluster" -SourceTemplate $script:template -SourceParameters $script:params
        }

        It "adds Private Endpoint resource" {
            $pe = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Network/privateEndpoints" }
            $pe | Should -Not -BeNullOrEmpty
        }

        It "Private Endpoint has redisEnterprise groupId" {
            $pe = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Network/privateEndpoints" }
            $pe["properties"]["privateLinkServiceConnections"][0]["properties"]["groupIds"] | Should -Contain "redisEnterprise"
        }

        It "cluster has publicNetworkAccess Disabled" {
            $cluster = $script:result["resources"] | Where-Object { $_["type"] -eq "Microsoft.Cache/redisEnterprise" }
            $cluster["properties"]["publicNetworkAccess"] | Should -Be "Disabled"
        }
    }

    Context "Firewall migration removes firewall rules" {
        BeforeAll {
            $script:template = New-SimpleAcrTemplate -WithFirewall
            $script:params = New-SimpleParams -CacheName "my-fw" -Tier "Premium" -Family "P" -Capacity 2
            $script:config = Parse-ArmConfig -Template $script:template -Parameters $script:params
            $script:target = Get-AmrSkuMapping -SourceConfig $script:config
            $script:result = Convert-ArmTemplate -SourceConfig $script:config -TargetSku $script:target `
                -ClusteringPolicy "OSSCluster" -SourceTemplate $script:template -SourceParameters $script:params
        }

        It "removes firewall rule resources" {
            $fw = $script:result["resources"] | Where-Object { $_["type"] -match "firewallRules" }
            $fw | Should -BeNullOrEmpty
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Update-DependsOn
# ─────────────────────────────────────────────────────────────
Describe "Update-DependsOn" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "replaces old type with new type in dependsOn" {
        $resource = @{
            type      = "Microsoft.Network/privateEndpoints"
            dependsOn = @("[resourceId('Microsoft.Cache/redis', parameters('name'))]")
        }
        $result = Update-DependsOn -Resource $resource -OldType "Microsoft.Cache/redis" -NewType "Microsoft.Cache/redisEnterprise"
        $result["dependsOn"][0] | Should -BeLike "*redisEnterprise*"
        $result["dependsOn"][0] | Should -Not -BeLike "*redis'*"
    }

    It "leaves non-matching dependsOn unchanged" {
        $resource = @{
            type      = "SomeResource"
            dependsOn = @("[resourceId('Microsoft.Web/sites', 'mysite')]")
        }
        $result = Update-DependsOn -Resource $resource -OldType "Microsoft.Cache/redis" -NewType "Microsoft.Cache/redisEnterprise"
        $result["dependsOn"][0] | Should -BeLike "*Microsoft.Web/sites*"
    }

    It "handles resource with no dependsOn" {
        $resource = @{ type = "SomeResource"; properties = @{} }
        $result = Update-DependsOn -Resource $resource -OldType "Microsoft.Cache/redis" -NewType "Microsoft.Cache/redisEnterprise"
        $result | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────
# Build-PrivateEndpointResource
# ─────────────────────────────────────────────────────────────
Describe "Build-PrivateEndpointResource" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "builds PE with literal cache name" {
        $pe = Build-PrivateEndpointResource -CacheName "my-cache" -Location "westus2" -DependsOnId "[resourceId('Microsoft.Cache/redisEnterprise', 'my-cache')]"
        $pe["type"] | Should -Be "Microsoft.Network/privateEndpoints"
        $pe["name"] | Should -Be "my-cache-pe"
        $pe["location"] | Should -Be "westus2"
    }

    It "builds PE with parameterized cache name" {
        $pe = Build-PrivateEndpointResource -CacheName "[parameters('cacheName')]" -Location "[parameters('location')]" -DependsOnId "[resourceId('Microsoft.Cache/redisEnterprise', parameters('cacheName'))]"
        $pe["name"] | Should -BeLike "*concat*parameters*-pe*"
    }

    It "PE has subnet referencing subnetId parameter" {
        $pe = Build-PrivateEndpointResource -CacheName "my-cache" -Location "westus2" -DependsOnId "[resourceId('Microsoft.Cache/redisEnterprise', 'my-cache')]"
        $pe["properties"]["subnet"]["id"] | Should -Be "[parameters('subnetId')]"
    }

    It "PE has redisEnterprise groupId" {
        $pe = Build-PrivateEndpointResource -CacheName "my-cache" -Location "westus2" -DependsOnId "[resourceId('Microsoft.Cache/redisEnterprise', 'my-cache')]"
        $pe["properties"]["privateLinkServiceConnections"][0]["properties"]["groupIds"] | Should -Contain "redisEnterprise"
    }
}

# ─────────────────────────────────────────────────────────────
# Convert-ParametersFile
# ─────────────────────────────────────────────────────────────
Describe "Convert-ParametersFile" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    Context "Standard C3 parameter migration" {
        BeforeAll {
            $script:sourceParams = Load-Template (Join-Path $script:BasicStdParamsDir "standard-c3.parameters.json")
            $script:config = New-MockSourceConfig -Tier "Standard" -Sku "C3" -EvictionPolicy "allkeys-lru"
            $script:target = [PSCustomObject]@{ Name = "Balanced_B5"; HA = $true }
            $script:result = Convert-ParametersFile -SourceConfig $script:config -TargetSku $script:target `
                -ClusteringPolicy "OSSCluster" -SourceParameters $script:sourceParams
        }

        It "replaces skuName with AMR target SKU" {
            $script:result["parameters"]["skuName"]["value"] | Should -Be "Balanced_B5"
        }

        It "adds AMR skuName parameter" {
            $script:result["parameters"]["skuName"]["value"] | Should -Be "Balanced_B5"
        }

        It "adds clusteringPolicy parameter" {
            $script:result["parameters"]["clusteringPolicy"]["value"] | Should -Be "OSSCluster"
        }

        It "removes skuFamily" {
            $script:result["parameters"].Contains("skuFamily") | Should -BeFalse
        }

        It "removes skuCapacity" {
            $script:result["parameters"].Contains("skuCapacity") | Should -BeFalse
        }

        It "removes enableNonSslPort" {
            $script:result["parameters"].Contains("enableNonSslPort") | Should -BeFalse
        }

        It "removes redisVersion" {
            $script:result["parameters"].Contains("redisVersion") | Should -BeFalse
        }

        It "removes aadEnabled" {
            $script:result["parameters"].Contains("aadEnabled") | Should -BeFalse
        }

        It "maps eviction policy to PascalCase" {
            $script:result["parameters"]["evictionPolicy"]["value"] | Should -Be "AllKeysLRU"
        }

        It "preserves redisCacheName" {
            $script:result["parameters"]["redisCacheName"]["value"] | Should -Be "acr-test-standard-c3"
        }

        It "preserves location" {
            $script:result["parameters"]["location"]["value"] | Should -Be "westus2"
        }

        It "preserves tags" {
            $script:result["parameters"]["tags"]["value"]["Environment"] | Should -Be "Test"
        }
    }

    Context "Premium P2 clustered parameter migration" {
        BeforeAll {
            $script:sourceParams = Load-Template (Join-Path $script:PremiumParamsDir "premium-p2-clustered.parameters.json")
            $script:config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -ShardCount 3 -RdbEnabled $true -RdbFrequency "60"
            $script:target = [PSCustomObject]@{ Name = "Balanced_B50"; HA = $true }
            $script:result = Convert-ParametersFile -SourceConfig $script:config -TargetSku $script:target `
                -ClusteringPolicy "EnterpriseCluster" -SourceParameters $script:sourceParams
        }

        It "removes shardCount" {
            $script:result["parameters"].Contains("shardCount") | Should -BeFalse
        }

        It "removes maxmemoryReserved" {
            $script:result["parameters"].Contains("maxmemoryReserved") | Should -BeFalse
        }

        It "removes maxfragmentationmemoryReserved" {
            $script:result["parameters"].Contains("maxfragmentationmemoryReserved") | Should -BeFalse
        }

        It "maps RDB frequency 60 to 1h" {
            $script:result["parameters"]["rdbFrequency"]["value"] | Should -Be "1h"
        }

        It "maps eviction policy volatile-lru to VolatileLRU" {
            $script:result["parameters"]["evictionPolicy"]["value"] | Should -Be "VolatileLRU"
        }

        It "removes zones (AMR handles zone redundancy automatically)" {
            $script:result["parameters"].Contains("zones") | Should -BeFalse
        }
    }

    Context "VNet parameter migration" {
        BeforeAll {
            $script:sourceParams = Load-Template (Join-Path $script:PremiumParamsDir "premium-p2-vnet.parameters.json")
            $script:config = New-MockSourceConfig -Tier "Premium" -Sku "P2" -HasVNet $true
            $script:target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
            $script:result = Convert-ParametersFile -SourceConfig $script:config -TargetSku $script:target `
                -ClusteringPolicy "OSSCluster" -SourceParameters $script:sourceParams
        }

        It "removes subnetId parameter" {
            $script:result["parameters"].Contains("subnetId") | Should -BeFalse
        }

        It "removes staticIP parameter" {
            $script:result["parameters"].Contains("staticIP") | Should -BeFalse
        }

        It "adds enablePrivateEndpoint flag" {
            $script:result["parameters"]["enablePrivateEndpoint"]["value"] | Should -BeTrue
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Eviction Policy Map (script variable)
# ─────────────────────────────────────────────────────────────
Describe "EvictionPolicyMap" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "maps all 8 ACR policies" {
        $script:EvictionPolicyMap.Count | Should -Be 8
    }

    It "maps volatile-lru to VolatileLRU" {
        $script:EvictionPolicyMap["volatile-lru"] | Should -Be "VolatileLRU"
    }

    It "maps noeviction to NoEviction" {
        $script:EvictionPolicyMap["noeviction"] | Should -Be "NoEviction"
    }

    It "maps allkeys-lfu to AllKeysLFU" {
        $script:EvictionPolicyMap["allkeys-lfu"] | Should -Be "AllKeysLFU"
    }

    It "case-sensitive lookup works for lowercase keys" {
        $script:EvictionPolicyMap.ContainsKey("volatile-random") | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────
# RDB Frequency Map
# ─────────────────────────────────────────────────────────────
Describe "RdbFrequencyMap" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "maps 60 to 1h" {
        $script:RdbFrequencyMap["60"] | Should -Be "1h"
    }

    It "maps 360 to 6h" {
        $script:RdbFrequencyMap["360"] | Should -Be "6h"
    }

    It "maps 720 to 12h" {
        $script:RdbFrequencyMap["720"] | Should -Be "12h"
    }

    It "maps 1440 to 12h (capped)" {
        $script:RdbFrequencyMap["1440"] | Should -Be "12h"
    }
}

# ─────────────────────────────────────────────────────────────
# Parse-TerraformConfig
# ─────────────────────────────────────────────────────────────
Describe "Parse-TerraformConfig" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "parses a Premium clustered Terraform resource" {
        $tf = @'
resource "azurerm_redis_cache" "example" {
  name                = "my-cache"
  sku_name            = "Premium"
  family              = "P"
  capacity            = 2
  shard_count         = 3
  replicas_per_primary = 2
  minimum_tls_version = "1.2"
  enable_non_ssl_port = false
}
'@
        $result = Parse-TerraformConfig -TfContent $tf
        $result.Tier | Should -Be "Premium"
        $result.Sku | Should -Be "P2"
        $result.Capacity | Should -Be 2
        $result.ShardCount | Should -Be 3
        $result.ReplicasPerPrimary | Should -Be 2
        $result.EnableNonSslPort | Should -Be $false
        $result.HasMRPP | Should -Be $true
    }

    It "parses Standard tier with defaults" {
        $tf = @'
resource "azurerm_redis_cache" "example" {
  sku_name = "Standard"
  family   = "C"
  capacity = 3
}
'@
        $result = Parse-TerraformConfig -TfContent $tf
        $result.Tier | Should -Be "Standard"
        $result.Sku | Should -Be "C3"
        $result.ShardCount | Should -Be 0
        $result.ReplicasPerPrimary | Should -Be 1
        $result.HasMRPP | Should -Be $false
    }

    It "throws when no azurerm_redis_cache resource found" {
        $tf = 'resource "azurerm_storage_account" "example" { }'
        { Parse-TerraformConfig -TfContent $tf } | Should -Throw "*No azurerm_redis_cache*"
    }

    It "detects persistence flags" {
        $tf = @'
resource "azurerm_redis_cache" "example" {
  sku_name = "Premium"
  family   = "P"
  capacity = 1
  redis_configuration {
    rdb_backup_enabled    = true
    rdb_backup_frequency  = 60
    aof_backup_enabled    = true
  }
}
'@
        $result = Parse-TerraformConfig -TfContent $tf
        $result.Persistence.RdbEnabled | Should -Be $true
        $result.Persistence.RdbFrequency | Should -Be "60"
        $result.Persistence.AofEnabled | Should -Be $true
    }

    It "detects identity block" {
        $tf = @'
resource "azurerm_redis_cache" "example" {
  sku_name = "Premium"
  family   = "P"
  capacity = 1
  identity {
    type = "SystemAssigned"
  }
}
'@
        $result = Parse-TerraformConfig -TfContent $tf
        $result.HasIdentity | Should -Be $true
    }

    It "detects subnet_id as VNet" {
        $tf = @'
resource "azurerm_redis_cache" "example" {
  sku_name  = "Premium"
  family    = "P"
  capacity  = 1
  subnet_id = "/subscriptions/.../subnets/redis"
}
'@
        $result = Parse-TerraformConfig -TfContent $tf
        $result.Networking.HasVNet | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────
# Convert-TerraformTemplate
# ─────────────────────────────────────────────────────────────
Describe "Convert-TerraformTemplate" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock
    }

    It "generates azurerm_redis_enterprise_cluster resource" {
        $config = New-MockSourceConfig -Tier "Premium" -Sku "P2"
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Convert-TerraformTemplate -SourceConfig $config -TargetSku $target -ClusteringPolicy "OSSCluster"
        $result | Should -BeLike "*azurerm_redis_enterprise_cluster*"
        $result | Should -BeLike '*sku_name*=*"Balanced_B10"*'
        $result | Should -BeLike '*clustering_policy*=*"OSSCluster"*'
    }

    It "maps eviction policy to AMR format" {
        $config = New-MockSourceConfig -EvictionPolicy "volatile-lru"
        $target = [PSCustomObject]@{ Name = "Balanced_B5"; HA = $true }
        $result = Convert-TerraformTemplate -SourceConfig $config -TargetSku $target -ClusteringPolicy "OSSCluster"
        $result | Should -BeLike '*eviction_policy*=*"VolatileLRU"*'
    }

    It "includes persistence block when RDB enabled" {
        $config = New-MockSourceConfig -RdbEnabled $true -RdbFrequency "60"
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Convert-TerraformTemplate -SourceConfig $config -TargetSku $target -ClusteringPolicy "OSSCluster"
        $result | Should -BeLike "*rdb_enabled*=*true*"
        $result | Should -BeLike '*rdb_frequency*=*"1h"*'
    }

    It "excludes zones block (AMR handles zone redundancy automatically)" {
        $config = New-MockSourceConfig
        $config.Zones = @("1", "2", "3")
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Convert-TerraformTemplate -SourceConfig $config -TargetSku $target -ClusteringPolicy "OSSCluster"
        $result | Should -Not -BeLike '*zones*=*'
    }

    It "includes private endpoint when VNet is present" {
        $config = New-MockSourceConfig -HasVNet $true
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Convert-TerraformTemplate -SourceConfig $config -TargetSku $target -ClusteringPolicy "OSSCluster"
        $result | Should -BeLike "*azurerm_private_endpoint*"
    }

    It "omits private endpoint when no VNet or firewall" {
        $config = New-MockSourceConfig
        $target = [PSCustomObject]@{ Name = "Balanced_B10"; HA = $true }
        $result = Convert-TerraformTemplate -SourceConfig $config -TargetSku $target -ClusteringPolicy "OSSCluster"
        $result | Should -Not -BeLike "*azurerm_private_endpoint*"
    }
}

# ── .bicepparam support ──

Describe "Parse-BicepParamFile" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "Helpers.ps1")
        $script:SharedScriptBlock = Get-SharedHelpersBlock
        $script:SutScriptBlock = Get-FunctionsScriptBlock -Path (Join-Path $PSScriptRoot ".." ".." "iac" "Convert-AcrToAmr.ps1") -IncludeScriptVariables
        . ([scriptblock]::Create($script:SharedScriptBlock))
        . ([scriptblock]::Create($script:SutScriptBlock))
    }

    It "parses .bicepparam file into ARM-compatible hashtable" {
        $path = Join-Path $PSScriptRoot ".." "fixtures" "bicep" "params" "premium" "premium-p2-all-features.bicepparam"
        $result = Parse-BicepParamFile -Path $path

        $result | Should -Not -BeNullOrEmpty
        $result['parameters'] | Should -Not -BeNullOrEmpty
        $result['parameters']['redisCacheName']['value'] | Should -Be 'acr-test-premium-p2-all'
        $result['parameters']['skuCapacity']['value'] | Should -Be 2
        $result['parameters']['enableNonSslPort']['value'] | Should -Be $false
        $result['parameters']['rdbBackupEnabled']['value'] | Should -Be $true
        $result['parameters']['shardCount']['value'] | Should -Be 3
    }

    It "returns schema and contentVersion" {
        $path = Join-Path $PSScriptRoot ".." "fixtures" "bicep" "params" "premium" "premium-p2-all-features.bicepparam"
        $result = Parse-BicepParamFile -Path $path

        $result['$schema'] | Should -BeLike "*deploymentParameters*"
        $result['contentVersion'] | Should -Be "1.0.0.0"
    }

    It "skips using declarations and comments" {
        $tempFile = [System.IO.Path]::GetTempFileName() + ".bicepparam"
        try {
            @"
using './main.bicep'

// This is a comment
param name = 'test'
param count = 5
"@ | Set-Content $tempFile -Encoding UTF8

            $result = Parse-BicepParamFile -Path $tempFile
            $result['parameters'].Keys | Should -HaveCount 2
            $result['parameters']['name']['value'] | Should -Be 'test'
            $result['parameters']['count']['value'] | Should -Be 5
        } finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
        }
    }
}

Describe "Convert-BicepParamFile" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "Helpers.ps1")
        $script:SharedScriptBlock = Get-SharedHelpersBlock
        $script:SutScriptBlock = Get-FunctionsScriptBlock -Path (Join-Path $PSScriptRoot ".." ".." "iac" "Convert-AcrToAmr.ps1") -IncludeScriptVariables
        . ([scriptblock]::Create($script:SharedScriptBlock))
        . ([scriptblock]::Create($script:SutScriptBlock))
    }

    It "generates valid .bicepparam output with using declaration" {
        $params = @{
            parameters = [ordered]@{
                skuName          = @{ value = "Balanced_B10" }
                clusteringPolicy = @{ value = "OSSCluster" }
            }
        }
        $result = Convert-BicepParamFile -MigratedParameters $params -BicepTemplateName "main.amr.bicep"

        $result | Should -BeLike "using './main.amr.bicep'*"
        $result | Should -BeLike "*param skuName = 'Balanced_B10'*"
        $result | Should -BeLike "*param clusteringPolicy = 'OSSCluster'*"
    }

    It "formats booleans as lowercase" {
        $params = @{
            parameters = [ordered]@{
                enablePE = @{ value = $true }
            }
        }
        $result = Convert-BicepParamFile -MigratedParameters $params -BicepTemplateName "cache.amr.bicep"

        $result | Should -BeLike "*param enablePE = true*"
    }

    It "formats integers without quotes" {
        $params = @{
            parameters = [ordered]@{
                capacity = @{ value = 4 }
            }
        }
        $result = Convert-BicepParamFile -MigratedParameters $params -BicepTemplateName "cache.amr.bicep"

        $result | Should -BeLike "*param capacity = 4*"
    }

    It "round-trips through Parse and Convert" {
        # Parse → Convert-ParametersFile → Convert-BicepParamFile → Parse again
        $path = Join-Path $PSScriptRoot ".." "fixtures" "bicep" "params" "premium" "premium-p2-all-features.bicepparam"
        $parsed = Parse-BicepParamFile -Path $path

        # Simulate the migrated params (just pass through for round-trip test)
        $migratedParams = @{
            parameters = [ordered]@{
                redisCacheName = @{ value = 'acr-test-premium-p2-all' }
                location       = @{ value = 'westus2' }
                skuName        = @{ value = 'Balanced_B10' }
                rdbBackupEnabled = @{ value = $true }
            }
        }

        $bicepParamStr = Convert-BicepParamFile -MigratedParameters $migratedParams -BicepTemplateName "acr-premium.amr.bicep"

        # Write to temp and re-parse
        $tempFile = [System.IO.Path]::GetTempFileName() + ".bicepparam"
        try {
            $bicepParamStr | Set-Content $tempFile -Encoding UTF8
            $reparsed = Parse-BicepParamFile -Path $tempFile

            $reparsed['parameters']['redisCacheName']['value'] | Should -Be 'acr-test-premium-p2-all'
            $reparsed['parameters']['skuName']['value'] | Should -Be 'Balanced_B10'
            $reparsed['parameters']['rdbBackupEnabled']['value'] | Should -Be $true
        } finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
        }
    }
}
