#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 tests for PSRule.Rules.Azure integration functions:
    Ensure-PSRuleModule, Resolve-TemplateWithPSRule, Parse-PsRuleExpandedConfig,
    and the Parse-AcrTemplate PSRule/fallback integration.
.DESCRIPTION
    Uses AST-based extraction to load function definitions from Convert-AcrToAmr.ps1.
    All PSRule/module cmdlets are mocked — no actual PSRule.Rules.Azure dependency required.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot ".." "Helpers.ps1")

    $script:SutPath = Join-Path $PSScriptRoot ".." ".." "iac" "Convert-AcrToAmr.ps1"
    $script:SutScriptBlock = Get-FunctionsScriptBlock -Path $script:SutPath

    # Fixture paths
    $script:FixtureDir = Get-FixturePath
    $script:TemplatePath = Join-Path $script:FixtureDir "acr-premium.json"
    $script:ParametersPath = Join-Path $script:FixtureDir "acr-cache.parameters.json"
}

# ─────────────────────────────────────────────────────────────
# Ensure-PSRuleModule
# ─────────────────────────────────────────────────────────────
Describe "Ensure-PSRuleModule" {
    BeforeAll {
        . $script:SutScriptBlock
        # Stub Install-Module so Pester can mock it (may not exist in constrained environments)
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            function global:Install-Module { param($Name, $Scope, [switch]$Force, [switch]$AllowClobber, $ErrorAction) }
            $script:CreatedInstallModuleStub = $true
        }
    }

    AfterAll {
        if ($script:CreatedInstallModuleStub) {
            Remove-Item function:\Install-Module -ErrorAction SilentlyContinue
        }
    }

    It "returns true when PSRule.Rules.Azure is already installed" {
        Mock Get-Module {
            [PSCustomObject]@{ Name = 'PSRule.Rules.Azure'; Version = [version]'1.40.0' }
        }
        Ensure-PSRuleModule | Should -BeTrue
    }

    It "auto-installs and returns true when module is missing" {
        # Ensure-PSRuleModule uses Install-Module which is a real cmdlet
        # We need to mock it at the correct scope
        Mock Get-Module { $null }
        Mock Install-Module { } -Verifiable
        $result = Ensure-PSRuleModule
        $result | Should -BeTrue
        Should -Invoke Install-Module -Times 1
    }

    It "returns false when install fails" {
        Mock Get-Module { $null }
        Mock Install-Module { throw "Network error" }
        Ensure-PSRuleModule | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────
# Resolve-TemplateWithPSRule
# ─────────────────────────────────────────────────────────────
Describe "Resolve-TemplateWithPSRule" {
    BeforeAll {
        . $script:SutScriptBlock
    }

    Context "successful expansion" {
        BeforeAll {
            # Mock Export-AzRuleTemplateData with proper param block for splatting
            function global:Export-AzRuleTemplateData {
                param($TemplateFile, [string[]]$ParameterFile, $ResourceGroup, [switch]$PassThru, $ErrorAction)
            }
            Mock Export-AzRuleTemplateData {
                @(
                    [PSCustomObject]@{
                        type = 'Microsoft.Cache/redis'
                        name = 'myapp-redis-prod'
                        properties = @{
                            sku = @{ name = 'Premium'; family = 'P'; capacity = 2 }
                            shardCount = 3
                        }
                    },
                    [PSCustomObject]@{
                        type = 'Microsoft.Network/privateEndpoints'
                        name = 'pe-redis'
                        properties = @{}
                    }
                )
            }
        }

        AfterAll {
            Remove-Item function:\Export-AzRuleTemplateData -ErrorAction SilentlyContinue
        }

        It "returns all expanded resources as an array" {
            $result = Resolve-TemplateWithPSRule -TemplatePath $script:TemplatePath -Region 'westus2'
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 2
        }

        It "passes ParameterFile when provided" {
            Resolve-TemplateWithPSRule -TemplatePath $script:TemplatePath `
                -ParametersPath $script:ParametersPath -Region 'westus2'
            Should -Invoke Export-AzRuleTemplateData -ParameterFilter {
                $ParameterFile -eq $script:ParametersPath
            }
        }

        It "passes ResourceGroup override with correct region" {
            Resolve-TemplateWithPSRule -TemplatePath $script:TemplatePath -Region 'australiaeast'
            Should -Invoke Export-AzRuleTemplateData -ParameterFilter {
                $ResourceGroup.location -eq 'australiaeast'
            }
        }

        It "defaults region to eastus" {
            Resolve-TemplateWithPSRule -TemplatePath $script:TemplatePath
            Should -Invoke Export-AzRuleTemplateData -ParameterFilter {
                $ResourceGroup.location -eq 'eastus'
            }
        }
    }

    Context "failure scenarios" {
        BeforeAll {
            function global:Export-AzRuleTemplateData {
                param($TemplateFile, [string[]]$ParameterFile, $ResourceGroup, [switch]$PassThru, $ErrorAction)
            }
        }

        AfterAll {
            Remove-Item function:\Export-AzRuleTemplateData -ErrorAction SilentlyContinue
        }

        It "returns null when Export-AzRuleTemplateData throws" {
            Mock Export-AzRuleTemplateData { throw "Expansion error" }
            $result = Resolve-TemplateWithPSRule -TemplatePath $script:TemplatePath
            $result | Should -BeNullOrEmpty
        }

        It "returns null when Export-AzRuleTemplateData returns empty" {
            Mock Export-AzRuleTemplateData { @() }
            $result = Resolve-TemplateWithPSRule -TemplatePath $script:TemplatePath
            $result | Should -BeNullOrEmpty
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Parse-PsRuleExpandedConfig
# ─────────────────────────────────────────────────────────────
Describe "Parse-PsRuleExpandedConfig" {
    BeforeAll {
        . $script:SutScriptBlock

        # Build a realistic PSRule-expanded Redis resource (all values resolved)
        $script:ExpandedRedis = [PSCustomObject]@{
            type = 'Microsoft.Cache/redis'
            name = 'myapp-redis-prod-westus2'
            sku = [PSCustomObject]@{
                name     = 'Premium'
                family   = 'P'
                capacity = 2
            }
            properties = [PSCustomObject]@{
                shardCount          = 3
                replicasPerPrimary  = 2
                enableNonSslPort    = $false
                subnetId            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Network/virtualNetworks/vnet1/subnets/redis-subnet'
                minimumTlsVersion   = '1.2'
                redisConfiguration  = [PSCustomObject]@{
                    'rdb-backup-enabled'   = 'true'
                    'rdb-backup-frequency' = '60'
                    'aof-backup-enabled'   = 'false'
                    'maxmemory-policy'     = 'volatile-lru'
                }
            }
            zones    = @('1', '2', '3')
            identity = [PSCustomObject]@{ type = 'SystemAssigned' }
            tags     = @{ Environment = 'Production'; Service = 'MyApp' }
        }

        $script:FirewallResource = [PSCustomObject]@{
            type = 'Microsoft.Cache/redis/firewallRules'
            name = 'myapp-redis-prod-westus2/AllowAppSubnet'
        }

        $script:PrivateEndpointResource = [PSCustomObject]@{
            type = 'Microsoft.Network/privateEndpoints'
            name = 'pe-redis'
            properties = [PSCustomObject]@{
                privateLinkServiceConnections = @(
                    [PSCustomObject]@{
                        properties = [PSCustomObject]@{
                            groupIds = @('redisCache')
                        }
                    }
                )
            }
        }
    }

    It "extracts cache name as fully resolved" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.CacheName | Should -Be 'myapp-redis-prod-westus2'
        $config.RawCacheName | Should -Be 'myapp-redis-prod-westus2'
    }

    It "extracts SKU properties correctly" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.Tier | Should -Be 'Premium'
        $config.Sku | Should -Be 'P2'
        $config.Capacity | Should -Be 2
    }

    It "extracts shard count and replicas" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.ShardCount | Should -Be 3
        $config.ReplicasPerPrimary | Should -Be 2
        $config.HasMRPP | Should -BeTrue
    }

    It "extracts persistence settings" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.Persistence.RdbEnabled | Should -BeTrue
        $config.Persistence.RdbFrequency | Should -Be '60'
        $config.Persistence.AofEnabled | Should -BeFalse
    }

    It "extracts networking (VNet, subnet)" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.Networking.HasVNet | Should -BeTrue
        $config.Networking.SubnetId | Should -BeLike '*/subnets/redis-subnet'
    }

    It "detects firewall rules from AllResources" {
        $all = @($script:ExpandedRedis, $script:FirewallResource)
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources $all
        $config.Networking.HasFirewall | Should -BeTrue
    }

    It "detects private endpoint from AllResources" {
        $all = @($script:ExpandedRedis, $script:PrivateEndpointResource)
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources $all
        $config.Networking.HasPrivateEndpoint | Should -BeTrue
    }

    It "extracts identity" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.HasIdentity | Should -BeTrue
        $config.Identity.type | Should -Be 'SystemAssigned'
    }

    It "extracts zones" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.Zones | Should -Be @('1', '2', '3')
    }

    It "extracts tags" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.Tags.Environment | Should -Be 'Production'
    }

    It "extracts eviction policy" {
        $config = Parse-PsRuleExpandedConfig -Resource $script:ExpandedRedis -AllResources @($script:ExpandedRedis)
        $config.EvictionPolicy | Should -Be 'volatile-lru'
    }

    It "defaults replicasPerPrimary to 1 when not set" {
        $minimalRedis = [PSCustomObject]@{
            type = 'Microsoft.Cache/redis'
            name = 'basic-redis'
            sku = [PSCustomObject]@{ name = 'Basic'; family = 'C'; capacity = 0 }
            properties = [PSCustomObject]@{
                redisConfiguration = @{}
            }
        }
        $config = Parse-PsRuleExpandedConfig -Resource $minimalRedis -AllResources @($minimalRedis)
        $config.ReplicasPerPrimary | Should -Be 1
        $config.HasMRPP | Should -BeFalse
    }

    It "defaults MinimumTlsVersion to 1.2 when not set" {
        $minimalRedis = [PSCustomObject]@{
            type = 'Microsoft.Cache/redis'
            name = 'basic-redis'
            sku = [PSCustomObject]@{ name = 'Basic'; family = 'C'; capacity = 0 }
            properties = [PSCustomObject]@{
                redisConfiguration = @{}
            }
        }
        $config = Parse-PsRuleExpandedConfig -Resource $minimalRedis -AllResources @($minimalRedis)
        $config.MinimumTlsVersion | Should -Be '1.2'
    }
}

# ─────────────────────────────────────────────────────────────
# Parse-AcrTemplate — PSRule integration and fallback
# ─────────────────────────────────────────────────────────────
Describe "Parse-AcrTemplate PSRule integration" {
    BeforeAll {
        . $script:SutScriptBlock
        $script:Region = 'westus2'  # Set script-scope region for PSRule override

        # Define global stub with params so splatting works
        function global:Export-AzRuleTemplateData {
            param($TemplateFile, [string[]]$ParameterFile, $ResourceGroup, [switch]$PassThru, $ErrorAction)
        }
    }

    AfterAll {
        Remove-Item function:\Export-AzRuleTemplateData -ErrorAction SilentlyContinue
    }

    Context "when PSRule is available and succeeds" {
        It "uses PSRule path and sets _ParsingMethod to PSRule" {
            Mock Ensure-PSRuleModule { $true }
            Mock Export-AzRuleTemplateData {
                @(
                    [PSCustomObject]@{
                        type = 'Microsoft.Cache/redis'
                        name = 'myapp-redis-prod-westus2'
                        sku = [PSCustomObject]@{ name = 'Premium'; family = 'P'; capacity = 2 }
                        properties = [PSCustomObject]@{
                            shardCount = 3
                            enableNonSslPort = $false
                            minimumTlsVersion = '1.2'
                            redisConfiguration = @{}
                        }
                        zones = @('1', '2', '3')
                    }
                )
            }

            $result = Parse-AcrTemplate -TemplatePath $script:TemplatePath -ParametersPath $script:ParametersPath
            $result._ParsingMethod | Should -Be 'PSRule'
            $result.Tier | Should -Be 'Premium'
            $result.Sku | Should -Be 'P2'
            $result.CacheName | Should -Be 'myapp-redis-prod-westus2'
        }

        It "still loads _RawTemplate for transformation step" {
            Mock Ensure-PSRuleModule { $true }
            Mock Export-AzRuleTemplateData {
                @(
                    [PSCustomObject]@{
                        type = 'Microsoft.Cache/redis'
                        name = 'test-redis'
                        sku = [PSCustomObject]@{ name = 'Standard'; family = 'C'; capacity = 1 }
                        properties = [PSCustomObject]@{
                            redisConfiguration = @{}
                        }
                    }
                )
            }

            $result = Parse-AcrTemplate -TemplatePath $script:TemplatePath -ParametersPath $script:ParametersPath
            $result._RawTemplate | Should -Not -BeNullOrEmpty
            $result._RawTemplate["resources"] | Should -Not -BeNullOrEmpty
        }
    }

    Context "when PSRule is unavailable" {
        BeforeAll {
            # Create a simple ARM template that basic parser CAN handle (no [if(...)], no [variables(...)])
            $script:SimpleTemplate = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "redisCacheName": { "type": "string" },
    "skuName": { "type": "string", "defaultValue": "Premium" },
    "skuFamily": { "type": "string", "defaultValue": "P" },
    "skuCapacity": { "type": "int", "defaultValue": 2 }
  },
  "resources": [
    {
      "type": "Microsoft.Cache/redis",
      "apiVersion": "2023-08-01",
      "name": "[parameters('redisCacheName')]",
      "location": "westus2",
      "properties": {
        "sku": { "name": "[parameters('skuName')]", "family": "[parameters('skuFamily')]", "capacity": "[parameters('skuCapacity')]" },
        "enableNonSslPort": false,
        "minimumTlsVersion": "1.2",
        "redisConfiguration": {}
      }
    }
  ]
}
'@
            $script:SimpleParams = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "redisCacheName": { "value": "test-redis" },
    "skuName": { "value": "Premium" },
    "skuFamily": { "value": "P" },
    "skuCapacity": { "value": 2 }
  }
}
'@
            $script:SimpleTemplatePath = Join-Path $TestDrive "simple-acr.json"
            $script:SimpleParamsPath = Join-Path $TestDrive "simple-acr.parameters.json"
            $script:SimpleTemplate | Set-Content $script:SimpleTemplatePath
            $script:SimpleParams | Set-Content $script:SimpleParamsPath
        }

        It "falls back to basic parser when module not installed" {
            Mock Ensure-PSRuleModule { $false }

            $result = Parse-AcrTemplate -TemplatePath $script:SimpleTemplatePath -ParametersPath $script:SimpleParamsPath
            $result._ParsingMethod | Should -Be 'basic'
            $result.Tier | Should -Be 'Premium'
            $result.Format | Should -Be 'ARM'
        }
    }

    Context "when PSRule expansion fails" {
        BeforeAll {
            # Same simple template for fallback
            $script:SimpleTemplate2 = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "cacheName": { "type": "string" }
  },
  "resources": [
    {
      "type": "Microsoft.Cache/redis",
      "apiVersion": "2023-08-01",
      "name": "[parameters('cacheName')]",
      "location": "westus2",
      "properties": {
        "sku": { "name": "Standard", "family": "C", "capacity": 1 },
        "enableNonSslPort": false,
        "minimumTlsVersion": "1.2",
        "redisConfiguration": {}
      }
    }
  ]
}
'@
            $script:SimpleParams2 = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "cacheName": { "value": "fallback-redis" }
  }
}
'@
            $script:SimpleTemplatePath2 = Join-Path $TestDrive "simple-acr2.json"
            $script:SimpleParamsPath2 = Join-Path $TestDrive "simple-acr2.parameters.json"
            $script:SimpleTemplate2 | Set-Content $script:SimpleTemplatePath2
            $script:SimpleParams2 | Set-Content $script:SimpleParamsPath2
        }

        It "falls back to basic parser when Export-AzRuleTemplateData throws" {
            Mock Ensure-PSRuleModule { $true }
            Mock Export-AzRuleTemplateData { throw "PSRule error" }

            $result = Parse-AcrTemplate -TemplatePath $script:SimpleTemplatePath2 -ParametersPath $script:SimpleParamsPath2
            $result._ParsingMethod | Should -Be 'basic'
            $result.Tier | Should -Be 'Standard'
        }

        It "falls back when no Redis resource in PSRule output" {
            Mock Ensure-PSRuleModule { $true }
            Mock Export-AzRuleTemplateData {
                @(
                    [PSCustomObject]@{
                        type = 'Microsoft.Storage/storageAccounts'
                        name = 'mystorage'
                    }
                )
            }

            $result = Parse-AcrTemplate -TemplatePath $script:SimpleTemplatePath2 -ParametersPath $script:SimpleParamsPath2
            $result._ParsingMethod | Should -Be 'basic'
            $result.CacheName | Should -Be 'fallback-redis'
        }
    }

    Context "Terraform files skip PSRule" {
        It "uses regex parser for .tf files without trying PSRule" {
            $tfContent = @'
resource "azurerm_redis_cache" "example" {
  name                = "myredis"
  location            = "westus2"
  resource_group_name = "myrg"
  capacity            = 1
  family              = "C"
  sku_name            = "Standard"
  minimum_tls_version = "1.2"
}
'@
            $tfPath = Join-Path $TestDrive "test.tf"
            $tfContent | Set-Content $tfPath

            Mock Ensure-PSRuleModule { $true }  # Should NOT be called for TF

            $result = Parse-AcrTemplate -TemplatePath $tfPath
            $result._ParsingMethod | Should -Be 'regex'
            $result.Format | Should -Be 'Terraform'
            Should -Invoke Ensure-PSRuleModule -Times 0
        }
    }
}
