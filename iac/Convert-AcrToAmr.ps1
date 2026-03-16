<#
.SYNOPSIS
    Converts Azure Cache for Redis (ACR) IaC templates to Azure Managed Redis (AMR).

.DESCRIPTION
    Standalone script that migrates ACR Bicep, ARM JSON, or Terraform templates to AMR.
    Supports two usage modes:
      - Standalone: Run directly with interactive prompts and console output.
      - Skill wrapper: Called by the Copilot skill with -ReturnObject for structured output.

    The script encodes all transformation rules from the AMR migration skill reference docs.
    No AI/LLM dependency — all mappings are deterministic table lookups.

    Pipeline: Parse → Map SKU → Price → Gap Analysis → [Confirm] → Transform → Write → Report

.PARAMETER TemplatePath
    Path to the source ACR template (.json, .bicep, .tf). Required.

.PARAMETER ParametersPath
    Path to the source parameters file (.json, .bicepparam). Optional.

.PARAMETER OutputDirectory
    Output folder for migrated files. Default: ./migrated/ relative to source template.

.PARAMETER Region
    Azure region for pricing lookup (e.g., westus2, eastus). Required.

.PARAMETER ClusteringPolicy
    AMR clustering policy. Default: OSSCluster (recommended for best performance). Use EnterpriseCluster for backward compatibility with non-cluster-aware clients.

.PARAMETER TargetSku
    Override auto-detected AMR SKU (e.g., Balanced_B50). Optional.

.PARAMETER Currency
    Currency code for pricing. Default: USD.

.PARAMETER Force
    Skip interactive confirmation gate.

.PARAMETER SkipPricing
    Skip Azure Retail Pricing API calls.

.PARAMETER AnalyzeOnly
    Run Steps 1-4 only (parse, map, price, gaps). No transformation or file output.
    Use with -ReturnObject for skill integration (Phase 1).

.PARAMETER ReturnObject
    Return structured PSCustomObject instead of console output.
    Designed for programmatic consumption by the Copilot skill.

.PARAMETER WhatIf
    Show what would be done without writing files.

.EXAMPLE
    # Standalone: migrate an ARM JSON template interactively
    .\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2

.EXAMPLE
    # Standalone: migrate with parameters file, skip confirmation
    .\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -ParametersPath .\acr-cache.parameters.json -Region westus2 -Force

.EXAMPLE
    # Skill Phase 1: analyze only, return structured object
    $analysis = .\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2 -AnalyzeOnly -ReturnObject

.EXAMPLE
    # Skill Phase 2: transform and return structured object
    $result = .\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2 -Force -ReturnObject

.EXAMPLE
    # Migrate a Bicep template
    .\Convert-AcrToAmr.ps1 -TemplatePath .\main.bicep -Region eastus -Force

.EXAMPLE
    # Migrate a Terraform template
    .\Convert-AcrToAmr.ps1 -TemplatePath .\main.tf -Region eastus -Force

.EXAMPLE
    # Override target SKU and use OSSCluster
    .\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2 -TargetSku Balanced_B100 -ClusteringPolicy OSSCluster -Force

.NOTES
    Requires PowerShell 7.0 or later (cross-platform: Windows, macOS, Linux).
    Install: https://aka.ms/install-powershell

    Optional: Azure CLI with Bicep extension for .bicep input/output.
    Install: https://learn.microsoft.com/cli/azure/install-azure-cli
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "Path to ACR template (.json, .bicep, .tf)")]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$TemplatePath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to parameters file (.json, .bicepparam)")]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ParametersPath,

    [Parameter(Mandatory = $false, HelpMessage = "Output folder for migrated files")]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true, HelpMessage = "Azure region for pricing (e.g., westus2)")]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [ValidateSet("EnterpriseCluster", "OSSCluster")]
    [string]$ClusteringPolicy = "OSSCluster",

    [Parameter(Mandatory = $false, HelpMessage = "Override auto-detected AMR SKU")]
    [string]$TargetSku,

    [Parameter(Mandatory = $false)]
    [string]$Currency = "USD",

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPricing,

    [Parameter(Mandatory = $false, HelpMessage = "Analyze only — no transformation (Steps 1-4)")]
    [switch]$AnalyzeOnly,

    [Parameter(Mandatory = $false, HelpMessage = "Return PSObject instead of console output")]
    [switch]$ReturnObject,

    [Parameter(Mandatory = $false, HelpMessage = "Skip parameter file output")]
    [switch]$SkipParameterOutput
)

# ── Prerequisites check ──
#Requires -Version 7.0
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7.0 or later. Current version: $($PSVersionTable.PSVersion)`nInstall from: https://aka.ms/install-powershell"
    exit 1
}

$ErrorActionPreference = "Stop"
$script:ScriptVersion = "1.2.0"
$script:LastUpdated = "2026-03-03"
$script:Region = $Region  # Store for use in nested functions (PSRule region override)

# ── Dot-source shared AMR SKU data module ──
$sharedModulePath = Join-Path (Split-Path $PSScriptRoot) "scripts\AmrMigrationHelpers.ps1"
if (-not (Test-Path $sharedModulePath)) { $sharedModulePath = Join-Path $PSScriptRoot "AmrMigrationHelpers.ps1" }
if (-not (Test-Path $sharedModulePath)) {
    Write-Error "AmrMigrationHelpers.ps1 not found — expected at: $(Join-Path (Split-Path $PSScriptRoot) 'scripts\AmrMigrationHelpers.ps1')"
    return
}
. $sharedModulePath

# ═══════════════════════════════════════════════════════════════
# Region: Embedded Data Tables
# ═══════════════════════════════════════════════════════════════

# Eviction policy: ACR kebab-case → AMR PascalCase
$script:EvictionPolicyMap = @{
    "volatile-lru"    = "VolatileLRU"
    "allkeys-lru"     = "AllKeysLRU"
    "volatile-lfu"    = "VolatileLFU"
    "allkeys-lfu"     = "AllKeysLFU"
    "volatile-random" = "VolatileRandom"
    "allkeys-random"  = "AllKeysRandom"
    "volatile-ttl"    = "VolatileTTL"
    "noeviction"      = "NoEviction"
}

# RDB frequency: ACR minutes (string) → AMR duration string
$script:RdbFrequencyMap = @{
    "60"   = "1h"
    "360"  = "6h"
    "720"  = "12h"
    "1440" = "12h"  # 24h capped to 12h max in AMR
}

# Basic/Standard C0-C6 → AMR SKU (Basic=NoHA, Standard=HA)
$script:BasicStandardSkuMap = @{
    "C0" = "Balanced_B0"
    "C1" = "Balanced_B1"
    "C2" = "Balanced_B3"
    "C3" = "Balanced_B5"
    "C4" = "MemoryOptimized_M10"
    "C5" = "MemoryOptimized_M20"
    "C6" = "MemoryOptimized_M50"
}

# Premium non-clustered P1-P5 → AMR SKU (always HA)
$script:PremiumNonClusteredSkuMap = @{
    "P1" = "Balanced_B5"
    "P2" = "Balanced_B10"
    "P3" = "Balanced_B20"
    "P4" = "Balanced_B50"
    "P5" = "Balanced_B100"
}

# Premium clustered: P{capacity} → @{ shardCount → AMR SKU }
$script:PremiumClusteredSkuMap = @{
    "P1" = @{
        1 = "Balanced_B5";   2 = "Balanced_B10";  3 = "Balanced_B20";  4 = "Balanced_B20"
        5 = "Balanced_B50";  6 = "Balanced_B50";  7 = "Balanced_B50";  8 = "Balanced_B50"
        9 = "Balanced_B50"; 10 = "Balanced_B50"; 11 = "Balanced_B100"; 12 = "Balanced_B100"
        13 = "Balanced_B100"; 14 = "Balanced_B100"; 15 = "Balanced_B100"
    }
    "P2" = @{
        1 = "Balanced_B20";   2 = "Balanced_B50";   3 = "Balanced_B50";   4 = "Balanced_B50"
        5 = "Balanced_B100";  6 = "Balanced_B100";  7 = "Balanced_B100";  8 = "Balanced_B100"
        9 = "Balanced_B100"; 10 = "Balanced_B150";  11 = "Balanced_B150"; 12 = "Balanced_B150"
        13 = "Balanced_B250"; 14 = "Balanced_B250"; 15 = "Balanced_B250"
    }
    "P3" = @{
        1 = "Balanced_B50";   2 = "Balanced_B50";   3 = "Balanced_B100";  4 = "Balanced_B100"
        5 = "Balanced_B150";  6 = "Balanced_B150";  7 = "Balanced_B250";  8 = "Balanced_B250"
        9 = "Balanced_B250"; 10 = "Balanced_B350";  11 = "Balanced_B350"; 12 = "Balanced_B350"
        13 = "Balanced_B350"; 14 = "Balanced_B500"; 15 = "Balanced_B500"
    }
    "P4" = @{
        1 = "Balanced_B50";   2 = "Balanced_B100";  3 = "Balanced_B150";  4 = "Balanced_B250"
        5 = "Balanced_B350";  6 = "Balanced_B350";  7 = "Balanced_B500";  8 = "Balanced_B500"
        9 = "Balanced_B500"; 10 = "Balanced_B700";  11 = "Balanced_B700"; 12 = "Balanced_B700"
        13 = "Balanced_B700"; 14 = "Balanced_B1000"; 15 = "Balanced_B1000"
    }
    "P5" = @{
        1 = "Balanced_B100";  2 = "Balanced_B250";   3 = "Balanced_B350";   4 = "Balanced_B500"
        5 = "Balanced_B700";  6 = "Balanced_B700";   7 = "Balanced_B1000";  8 = "Balanced_B1000"
        9 = "MemoryOptimized_M1500"; 10 = "MemoryOptimized_M1500"; 11 = "MemoryOptimized_M1500"
        12 = "MemoryOptimized_M1500"; 13 = "MemoryOptimized_M2000"; 14 = "MemoryOptimized_M2000"
        15 = "MemoryOptimized_M2000"
    }
}

# AMR SKU specs provided by AmrMigrationHelpers.ps1 (dot-sourced above)

# Properties to remove from ACR templates (no AMR equivalent)
$script:RemovedProperties = @(
    "enableNonSslPort"
    "shardCount"
    "replicasPerPrimary"
    "replicasPerMaster"
    "redisVersion"
    "staticIP"
    "subnetId"
    "redisConfiguration.maxmemory-reserved"
    "redisConfiguration.maxfragmentationmemory-reserved"
    "redisConfiguration.maxmemory-delta"
    "redisConfiguration.preferred-data-archive-auth-method"
    "redisConfiguration.preferred-data-persistence-auth-method"
    "redisConfiguration.aad-enabled"
    "redisConfiguration.rdb-storage-connection-string"
    "redisConfiguration.aof-storage-connection-string-0"
    "redisConfiguration.aof-storage-connection-string-1"
)

# ═══════════════════════════════════════════════════════════════
# Region: Helper Functions
# ═══════════════════════════════════════════════════════════════

function Write-Banner {
    param([string]$Text)
    if ($script:ReturnObject) { return }
    Write-Host ""
    Write-Host ("═" * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("═" * 60) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Text)
    if ($script:ReturnObject) { return }
    Write-Host ""
    Write-Host ("─" * 60) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor DarkCyan
    Write-Host ("─" * 60) -ForegroundColor DarkCyan
}

function Write-Info {
    param([string]$Text)
    if ($script:ReturnObject) { return }
    Write-Host "  $Text"
}

function Write-Success {
    param([string]$Text)
    if ($script:ReturnObject) { return }
    Write-Host "  ✅ $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    if ($script:ReturnObject) { return }
    Write-Host "  ⚠️  $Text" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    if ($script:ReturnObject) { return }
    Write-Host "  ❌ $Text" -ForegroundColor Red
}

# ═══════════════════════════════════════════════════════════════
# Region: Core Functions
# ═══════════════════════════════════════════════════════════════

function Parse-AcrTemplate {
    <#
    .SYNOPSIS
        Parses an ACR template and returns a structured source config object.
        For ARM/Bicep templates, tries PSRule.Rules.Azure for full expression resolution first,
        then falls back to basic Resolve-ArmValue if PSRule is unavailable or fails.
    #>
    param(
        [string]$TemplatePath,
        [string]$ParametersPath
    )

    $extension = [System.IO.Path]::GetExtension($TemplatePath).ToLower()
    $format = switch ($extension) {
        ".json" { "ARM" }
        ".bicep" { "Bicep" }
        ".tf"    { "Terraform" }
        default  { throw "Unsupported template format: $extension. Supported: .json, .bicep, .tf" }
    }

    $rawTemplate = $null
    $rawParameters = $null
    $sourceConfig = $null
    $parsingMethod = "basic"  # Track which method was used

    # ── PSRule path: try full expression resolution for ARM/Bicep ──
    if ($format -ne "Terraform") {
        $psRuleAvailable = Ensure-PSRuleModule
        if ($psRuleAvailable) {
            Write-Info "Using PSRule.Rules.Azure for full ARM expression resolution..."

            $psRuleParams = @{
                TemplatePath = $TemplatePath
                Region       = if ($script:Region) { $script:Region } else { 'eastus' }
            }

            # PSRule supports Bicep natively via -TemplateFile (requires bicep CLI in PATH)
            # For ARM JSON, pass parameters file separately; .bicepparam parsed manually
            if ($ParametersPath -and $ParametersPath -match '\.json$') {
                $psRuleParams['ParametersPath'] = $ParametersPath
            } elseif ($ParametersPath -and $ParametersPath -match '\.bicepparam$') {
                $rawParameters = Parse-BicepParamFile -Path $ParametersPath
            }

            $expandedResources = Resolve-TemplateWithPSRule @psRuleParams

            if ($expandedResources) {
                # Find the Microsoft.Cache/redis resource from all expanded resources
                $redisResource = $expandedResources | Where-Object {
                    $_.type -eq 'Microsoft.Cache/redis' -or $_.Type -eq 'Microsoft.Cache/redis'
                } | Select-Object -First 1

                if ($redisResource) {
                    $sourceConfig = Parse-PsRuleExpandedConfig -Resource $redisResource -AllResources $expandedResources
                    $parsingMethod = "PSRule"
                    Write-Success "Template parsed via PSRule (full expression resolution)"
                } else {
                    Write-Warning "PSRule expansion found no Microsoft.Cache/redis resource — falling back to basic parser"
                }
            } else {
                Write-Warning "PSRule expansion did not return resources — falling back to basic parser"
            }
        }
    }

    # ── Fallback / Terraform path ──
    if (-not $sourceConfig) {
        switch ($format) {
            "ARM" {
                $rawTemplate = Get-Content $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
                if ($ParametersPath) {
                    $rawParameters = Get-Content $ParametersPath -Raw | ConvertFrom-Json -AsHashtable
                }
            }
            "Bicep" {
                # Compile Bicep to ARM JSON for parsing
                $tempArm = [System.IO.Path]::GetTempFileName() + ".json"
                try {
                    $buildResult = & az bicep build --file $TemplatePath --outfile $tempArm 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "az bicep build failed: $buildResult. Ensure Azure CLI with Bicep is installed."
                    }
                    $rawTemplate = Get-Content $tempArm -Raw | ConvertFrom-Json -AsHashtable
                } finally {
                    if (Test-Path $tempArm) { Remove-Item $tempArm -Force }
                }
                if ($ParametersPath) {
                    if ($ParametersPath -match '\.json$') {
                        $rawParameters = Get-Content $ParametersPath -Raw | ConvertFrom-Json -AsHashtable
                    } elseif ($ParametersPath -match '\.bicepparam$') {
                        $rawParameters = Parse-BicepParamFile -Path $ParametersPath
                    }
                }
            }
            "Terraform" {
                $rawTemplate = @{ _tfContent = Get-Content $TemplatePath -Raw }
            }
        }

        if ($format -eq "Terraform") {
            $sourceConfig = Parse-TerraformConfig -TfContent $rawTemplate._tfContent
        } else {
            $sourceConfig = Parse-ArmConfig -Template $rawTemplate -Parameters $rawParameters
        }
        $parsingMethod = if ($format -eq "Terraform") { "regex" } else { "basic" }
    }

    # ── Always load raw template for transformation step ──
    if (-not $rawTemplate -and $format -ne "Terraform") {
        if ($format -eq "Bicep") {
            $tempArm = [System.IO.Path]::GetTempFileName() + ".json"
            try {
                & az bicep build --file $TemplatePath --outfile $tempArm 2>&1 | Out-Null
                $rawTemplate = Get-Content $tempArm -Raw | ConvertFrom-Json -AsHashtable
            } finally {
                if (Test-Path $tempArm) { Remove-Item $tempArm -Force }
            }
        } else {
            $rawTemplate = Get-Content $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
        }
        if ($ParametersPath -and $ParametersPath -match '\.json$') {
            $rawParameters = Get-Content $ParametersPath -Raw | ConvertFrom-Json -AsHashtable
        } elseif ($ParametersPath -and $ParametersPath -match '\.bicepparam$') {
            $rawParameters = Parse-BicepParamFile -Path $ParametersPath
        }
    }

    $parametersFormat = if ($ParametersPath -match '\.bicepparam$') { "Bicepparam" } elseif ($ParametersPath) { "JSON" } else { $null }
    $sourceConfig | Add-Member -NotePropertyName "Format" -NotePropertyValue $format
    $sourceConfig | Add-Member -NotePropertyName "_RawTemplate" -NotePropertyValue $rawTemplate
    $sourceConfig | Add-Member -NotePropertyName "_RawParameters" -NotePropertyValue $rawParameters
    $sourceConfig | Add-Member -NotePropertyName "_ParametersFormat" -NotePropertyValue $parametersFormat
    $sourceConfig | Add-Member -NotePropertyName "_ParsingMethod" -NotePropertyValue $parsingMethod
    return $sourceConfig
}

function Parse-ArmConfig {
    <#
    .SYNOPSIS
        Extracts ACR configuration from ARM JSON template + optional parameters.
    #>
    param(
        [hashtable]$Template,
        [hashtable]$Parameters
    )

    # Find Microsoft.Cache/redis resource
    $resources = $Template["resources"]
    if (-not $resources) { throw "No resources found in ARM template" }

    $acrResource = $null
    foreach ($r in $resources) {
        $type = $r["type"]
        if ($type -eq "Microsoft.Cache/redis") {
            $acrResource = $r
            break
        }
    }
    if (-not $acrResource) { throw "No Microsoft.Cache/redis resource found in template" }

    # Extract and resolve the cache name
    $rawCacheName = $acrResource["name"]
    $resolvedCacheName = Resolve-ArmValue $rawCacheName $Parameters

    $props = $acrResource["properties"]
    $sku = $acrResource["sku"]
    if (-not $sku) { $sku = $props["sku"] }

    # Resolve parameter references — use params file values if available
    $skuName = Resolve-ArmValue $sku["name"] $Parameters      # Basic, Standard, Premium
    $skuFamily = Resolve-ArmValue $sku["family"] $Parameters   # C or P
    $skuCapacity = Resolve-ArmValue $sku["capacity"] $Parameters

    # Determine tier
    $tier = $skuName
    $skuCode = "$skuFamily$skuCapacity"  # e.g., C3 or P2

    # Extract properties with parameter resolution
    $shardCount = Resolve-ArmValue ($props["shardCount"]) $Parameters
    if (-not $shardCount -or ($shardCount -is [string] -and $shardCount -match '^\[')) { $shardCount = 0 }
    $shardCount = [int]$shardCount

    $replicasPerPrimary = Resolve-ArmValue ($props["replicasPerPrimary"]) $Parameters
    if (-not $replicasPerPrimary) {
        $replicasPerPrimary = Resolve-ArmValue ($props["replicasPerMaster"]) $Parameters
    }
    if (-not $replicasPerPrimary -or ($replicasPerPrimary -is [string] -and $replicasPerPrimary -match '^\[')) { $replicasPerPrimary = 1 }
    $replicasPerPrimary = [int]$replicasPerPrimary

    $redisConfig = $props["redisConfiguration"]
    if (-not $redisConfig -or $redisConfig -is [string]) {
        # redisConfiguration is either missing or an unresolvable expression (e.g. [variables('redisConfiguration')])
        # Fall back to an empty hashtable — persistence/eviction will be resolved from parameters below
        $redisConfig = @{}
    }

    $rdbEnabled = Resolve-ArmValue ($redisConfig["rdb-backup-enabled"]) $Parameters
    $rdbFrequency = Resolve-ArmValue ($redisConfig["rdb-backup-frequency"]) $Parameters
    $aofEnabled = Resolve-ArmValue ($redisConfig["aof-backup-enabled"]) $Parameters
    $evictionPolicy = Resolve-ArmValue ($redisConfig["maxmemory-policy"]) $Parameters

    # Fallback: if redisConfiguration was unresolvable, check source parameters directly
    # This handles Bicep-decompiled templates where redisConfiguration is a variable reference
    if ($null -eq $rdbEnabled -and $Parameters) {
        $rdbEnabled = Resolve-ArmValue "[parameters('rdbBackupEnabled')]" $Parameters
        if ($null -eq $rdbEnabled) { $rdbEnabled = Resolve-ArmValue "[parameters('rdb-backup-enabled')]" $Parameters }
    }
    if ($null -eq $rdbFrequency -and $Parameters) {
        $rdbFrequency = Resolve-ArmValue "[parameters('rdbBackupFrequency')]" $Parameters
        if ($null -eq $rdbFrequency) { $rdbFrequency = Resolve-ArmValue "[parameters('rdb-backup-frequency')]" $Parameters }
    }
    if ($null -eq $aofEnabled -and $Parameters) {
        $aofEnabled = Resolve-ArmValue "[parameters('aofBackupEnabled')]" $Parameters
        if ($null -eq $aofEnabled) { $aofEnabled = Resolve-ArmValue "[parameters('aof-backup-enabled')]" $Parameters }
    }
    # Note: eviction policy fallback is intentionally omitted — Convert-ArmTemplate
    # defaults to "VolatileLRU" when EvictionPolicy is null, which is correct.
    # Attempting to resolve from parameters can return unresolvable ARM expressions
    # (e.g. "[parameters('maxmemoryPolicy')]") that poison the output template.

    $enableNonSslPort = Resolve-ArmValue ($props["enableNonSslPort"]) $Parameters
    $subnetId = Resolve-ArmValue ($props["subnetId"]) $Parameters
    $minimumTlsVersion = Resolve-ArmValue ($props["minimumTlsVersion"]) $Parameters
    $zones = $acrResource["zones"]

    # Check for firewall rules as child resources
    $hasFirewall = $false
    foreach ($r in $resources) {
        if ($r["type"] -match "Microsoft\.Cache/redis/firewallRules") {
            $hasFirewall = $true
            break
        }
    }

    # Check for private endpoint
    $hasPrivateEndpoint = $false
    foreach ($r in $resources) {
        if ($r["type"] -eq "Microsoft.Network/privateEndpoints") {
            $plsConns = $r["properties"]["privateLinkServiceConnections"]
            if ($plsConns) {
                foreach ($pls in $plsConns) {
                    $groupIds = $pls["properties"]["groupIds"]
                    if ($groupIds -contains "redisCache") {
                        $hasPrivateEndpoint = $true
                        break
                    }
                }
            }
        }
    }

    # Check for identity
    $hasIdentity = $null -ne $acrResource["identity"]
    $identity = $acrResource["identity"]

    # Tags
    $tags = $acrResource["tags"]

    return [PSCustomObject]@{
        CacheName         = $resolvedCacheName
        RawCacheName      = $rawCacheName
        Tier              = $tier
        Sku               = $skuCode
        Capacity          = [int]$skuCapacity
        ShardCount        = $shardCount
        ReplicasPerPrimary = $replicasPerPrimary
        Persistence       = [PSCustomObject]@{
            RdbEnabled   = ($rdbEnabled -eq "true" -or $rdbEnabled -eq $true)
            RdbFrequency = $rdbFrequency
            AofEnabled   = ($aofEnabled -eq "true" -or $aofEnabled -eq $true)
        }
        Networking        = [PSCustomObject]@{
            HasVNet            = (-not [string]::IsNullOrEmpty($subnetId))
            HasFirewall        = $hasFirewall
            HasPrivateEndpoint = $hasPrivateEndpoint
            SubnetId           = $subnetId
        }
        EvictionPolicy    = $evictionPolicy
        EnableNonSslPort  = ($enableNonSslPort -eq "true" -or $enableNonSslPort -eq $true)
        MinimumTlsVersion = if ($minimumTlsVersion) { $minimumTlsVersion } else { "1.2" }
        Zones             = $zones
        HasIdentity       = $hasIdentity
        Identity          = $identity
        HasMRPP           = ($replicasPerPrimary -gt 1)
        Tags              = $tags
    }
}

function Resolve-ArmValue {
    <#
    .SYNOPSIS
        Resolves ARM template parameter references against a parameters file.
        This is the FALLBACK resolver — only handles [parameters('x')] expressions.
        For full expression resolution, use Resolve-TemplateWithPSRule.
    #>
    param(
        [object]$Value,
        [hashtable]$Parameters
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and $Value -match "^\[parameters\('([^']+)'\)\]$") {
        $paramName = $Matches[1]
        if ($Parameters -and $Parameters["parameters"] -and $Parameters["parameters"][$paramName]) {
            $paramEntry = $Parameters["parameters"][$paramName]
            if ($paramEntry.ContainsKey("value")) {
                return $paramEntry["value"]
            }
        }
        # Can't resolve — return the reference as-is
        return $Value
    }
    # Handle complex ARM expressions containing parameters('x') — e.g., [if(greater(parameters('shardCount'), 0), ...)]
    # Extract the first parameter reference and resolve it as a best-effort fallback
    if ($Value -is [string] -and $Value -match "^\[" -and $Value -match "parameters\('([^']+)'\)") {
        $paramName = $Matches[1]
        if ($Parameters -and $Parameters["parameters"] -and $Parameters["parameters"][$paramName]) {
            $paramEntry = $Parameters["parameters"][$paramName]
            if ($paramEntry.ContainsKey("value")) {
                return $paramEntry["value"]
            }
        }
    }
    return $Value
}

function Ensure-PSRuleModule {
    <#
    .SYNOPSIS
        Checks if PSRule.Rules.Azure is installed, auto-installs if missing.
        Returns $true if the module is available, $false otherwise.
    #>
    $module = Get-Module -ListAvailable -Name 'PSRule.Rules.Azure' | Select-Object -First 1
    if ($module) {
        Write-Verbose "PSRule.Rules.Azure v$($module.Version) found"
        return $true
    }

    Write-Info "PSRule.Rules.Azure not found — attempting auto-install..."
    try {
        Install-Module -Name 'PSRule.Rules.Azure' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Success "PSRule.Rules.Azure installed successfully"
        return $true
    } catch {
        Write-Warning "Failed to install PSRule.Rules.Azure: $($_.Exception.Message)"
        Write-Warning "Falling back to basic parameter resolution. For full expression support, install manually:"
        Write-Warning "  Install-Module -Name 'PSRule.Rules.Azure' -Scope CurrentUser -Force"
        return $false
    }
}

function Resolve-TemplateWithPSRule {
    <#
    .SYNOPSIS
        Uses PSRule.Rules.Azure Export-AzRuleTemplateData to fully resolve all ARM
        template expressions (parameters, variables, concat, if, resourceGroup().location, etc.)
        Returns ALL expanded resources as an array, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [string]$ParametersPath,

        [string]$Region = 'eastus'
    )

    # Build resource group override so resourceGroup().location resolves correctly
    $rgOverride = @{
        name     = 'psrule-migration-rg'
        location = $Region
    }

    $exportParams = @{
        TemplateFile  = $TemplatePath
        ResourceGroup = $rgOverride
        PassThru      = $true
        ErrorAction   = 'Stop'
    }

    if ($ParametersPath) {
        $exportParams['ParameterFile'] = $ParametersPath
    }

    try {
        $expandedResources = @(Export-AzRuleTemplateData @exportParams)

        if (-not $expandedResources -or $expandedResources.Count -eq 0) {
            Write-Warning "PSRule returned no resources from template"
            return $null
        }

        return $expandedResources
    } catch {
        Write-Warning "PSRule template expansion failed: $($_.Exception.Message)"
        return $null
    }
}

function Parse-PsRuleExpandedConfig {
    <#
    .SYNOPSIS
        Builds a SourceConfig object from PSRule-expanded resource data.
        Maps the fully-resolved resource properties to the same shape as Parse-ArmConfig output.
    #>
    param(
        [Parameter(Mandatory)]
        [PSObject]$Resource,

        [array]$AllResources
    )

    $props = $Resource.properties
    $sku = $Resource.sku
    if (-not $sku -and $props.sku) { $sku = $props.sku }

    # All values are already resolved — no Resolve-ArmValue needed
    $skuName = $sku.name          # Basic, Standard, Premium
    $skuFamily = $sku.family      # C or P
    $skuCapacity = $sku.capacity

    $tier = $skuName
    $skuCode = "$skuFamily$skuCapacity"

    $shardCount = $props.shardCount
    if (-not $shardCount) { $shardCount = 0 }
    $shardCount = [int]$shardCount

    $replicasPerPrimary = $props.replicasPerPrimary
    if (-not $replicasPerPrimary) { $replicasPerPrimary = $props.replicasPerMaster }
    if (-not $replicasPerPrimary) { $replicasPerPrimary = 1 }
    $replicasPerPrimary = [int]$replicasPerPrimary

    $redisConfig = $props.redisConfiguration
    if (-not $redisConfig) { $redisConfig = @{} }

    # PSRule resolves these to actual values (strings or booleans)
    $rdbEnabled = $redisConfig.'rdb-backup-enabled'
    $rdbFrequency = $redisConfig.'rdb-backup-frequency'
    $aofEnabled = $redisConfig.'aof-backup-enabled'
    $evictionPolicy = $redisConfig.'maxmemory-policy'

    $enableNonSslPort = $props.enableNonSslPort
    $subnetId = $props.subnetId
    $minimumTlsVersion = $props.minimumTlsVersion
    $zones = $Resource.zones

    # Check for firewall rules in expanded resources
    $hasFirewall = $false
    if ($AllResources) {
        foreach ($r in $AllResources) {
            if ($r.type -match 'Microsoft\.Cache/redis/firewallRules') {
                $hasFirewall = $true
                break
            }
        }
    }

    # Check for private endpoint in expanded resources
    $hasPrivateEndpoint = $false
    if ($AllResources) {
        foreach ($r in $AllResources) {
            if ($r.type -eq 'Microsoft.Network/privateEndpoints') {
                $plsConns = $r.properties.privateLinkServiceConnections
                if ($plsConns) {
                    foreach ($pls in $plsConns) {
                        $groupIds = $pls.properties.groupIds
                        if ($groupIds -contains 'redisCache') {
                            $hasPrivateEndpoint = $true
                            break
                        }
                    }
                }
            }
        }
    }

    $hasIdentity = $null -ne $Resource.identity
    $identity = $Resource.identity
    $tags = $Resource.tags

    # Cache name is fully resolved (concat, variables, etc. all expanded)
    $resolvedCacheName = $Resource.name

    return [PSCustomObject]@{
        CacheName          = $resolvedCacheName
        RawCacheName       = $resolvedCacheName  # PSRule fully resolves — raw IS resolved
        Tier               = $tier
        Sku                = $skuCode
        Capacity           = [int]$skuCapacity
        ShardCount         = $shardCount
        ReplicasPerPrimary = $replicasPerPrimary
        Persistence        = [PSCustomObject]@{
            RdbEnabled   = ($rdbEnabled -eq "true" -or $rdbEnabled -eq $true)
            RdbFrequency = $rdbFrequency
            AofEnabled   = ($aofEnabled -eq "true" -or $aofEnabled -eq $true)
        }
        Networking         = [PSCustomObject]@{
            HasVNet            = (-not [string]::IsNullOrEmpty($subnetId))
            HasFirewall        = $hasFirewall
            HasPrivateEndpoint = $hasPrivateEndpoint
            SubnetId           = $subnetId
        }
        EvictionPolicy     = $evictionPolicy
        EnableNonSslPort   = ($enableNonSslPort -eq "true" -or $enableNonSslPort -eq $true)
        MinimumTlsVersion  = if ($minimumTlsVersion) { $minimumTlsVersion } else { "1.2" }
        Zones              = $zones
        HasIdentity        = $hasIdentity
        Identity           = $identity
        HasMRPP            = ($replicasPerPrimary -gt 1)
        Tags               = $tags
    }
}

function Parse-TerraformConfig {
    <#
    .SYNOPSIS
        Extracts ACR configuration from a Terraform .tf file via regex parsing.
    #>
    param([string]$TfContent)

    # Find azurerm_redis_cache resource block
    if ($TfContent -notmatch 'resource\s+"azurerm_redis_cache"') {
        throw "No azurerm_redis_cache resource found in Terraform file"
    }

    # Extract values via regex
    $skuName = if ($TfContent -match 'sku_name\s*=\s*"([^"]+)"') { $Matches[1] } else { "Standard" }
    $family = if ($TfContent -match 'family\s*=\s*"([^"]+)"') { $Matches[1] } else { "C" }
    $capacity = if ($TfContent -match 'capacity\s*=\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $shardCount = if ($TfContent -match 'shard_count\s*=\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $replicasPerPrimary = if ($TfContent -match 'replicas_per_primary\s*=\s*(\d+)') { [int]$Matches[1] } else { 1 }
    $enableNonSslPort = $TfContent -match 'enable_non_ssl_port\s*=\s*true'
    $subnetId = $TfContent -match 'subnet_id\s*='
    $minimumTlsVersion = if ($TfContent -match 'minimum_tls_version\s*=\s*"([^"]+)"') { $Matches[1] } else { "1.2" }

    # Redis configuration block
    $rdbEnabled = $TfContent -match 'rdb_backup_enabled\s*=\s*true'
    $rdbFrequency = if ($TfContent -match 'rdb_backup_frequency\s*=\s*(\d+)') { $Matches[1] } else { $null }
    $aofEnabled = $TfContent -match 'aof_backup_enabled\s*=\s*true'
    $evictionPolicy = if ($TfContent -match 'maxmemory_policy\s*=\s*"([^"]+)"') { $Matches[1] } else { $null }

    $tier = switch ($skuName) {
        "Basic"    { "Basic" }
        "Standard" { "Standard" }
        "Premium"  { "Premium" }
        default    { $skuName }
    }

    $skuCode = "$family$capacity"

    return [PSCustomObject]@{
        Tier              = $tier
        Sku               = $skuCode
        Capacity          = $capacity
        ShardCount        = $shardCount
        ReplicasPerPrimary = $replicasPerPrimary
        Persistence       = [PSCustomObject]@{
            RdbEnabled   = $rdbEnabled
            RdbFrequency = $rdbFrequency
            AofEnabled   = $aofEnabled
        }
        Networking        = [PSCustomObject]@{
            HasVNet            = $subnetId
            HasFirewall        = $false
            HasPrivateEndpoint = $false
            SubnetId           = $null
        }
        EvictionPolicy    = $evictionPolicy
        EnableNonSslPort  = $enableNonSslPort
        MinimumTlsVersion = $minimumTlsVersion
        Zones             = @()
        HasIdentity       = ($TfContent -match 'identity\s*\{')
        Identity          = $null
        HasMRPP           = ($replicasPerPrimary -gt 1)
        Tags              = $null
    }
}

function Get-AmrSkuMapping {
    <#
    .SYNOPSIS
        Maps an ACR SKU configuration to the recommended AMR SKU.
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [string]$TargetSkuOverride
    )

    # Allow manual override
    if ($TargetSkuOverride) {
        if (-not $script:AmrSkuSpecs.ContainsKey($TargetSkuOverride)) {
            throw "Unknown target SKU '$TargetSkuOverride'. Valid SKUs: $($script:AmrSkuSpecs.Keys -join ', ')"
        }
        $specs = $script:AmrSkuSpecs[$TargetSkuOverride]
        $ha = ($SourceConfig.Tier -ne "Basic")
        return [PSCustomObject]@{
            Name           = $TargetSkuOverride
            Advertised     = "$($specs.Advertised) GB"
            Usable         = "$($specs.Usable) GB"
            HA             = $ha
        }
    }

    $tier = $SourceConfig.Tier
    $sku = $SourceConfig.Sku
    $shardCount = $SourceConfig.ShardCount
    $amrSkuName = $null
    $ha = $true

    switch ($tier) {
        "Basic" {
            $amrSkuName = $script:BasicStandardSkuMap[$sku]
            $ha = $false
        }
        "Standard" {
            $amrSkuName = $script:BasicStandardSkuMap[$sku]
            $ha = $true
        }
        "Premium" {
            if ($shardCount -gt 1) {
                $pSku = $sku  # e.g., "P2"
                if ($script:PremiumClusteredSkuMap.ContainsKey($pSku)) {
                    $shardMap = $script:PremiumClusteredSkuMap[$pSku]
                    $clampedShards = [Math]::Min($shardCount, 15)
                    $amrSkuName = $shardMap[$clampedShards]
                }
            }
            if (-not $amrSkuName) {
                $amrSkuName = $script:PremiumNonClusteredSkuMap[$sku]
            }
            $ha = $true
        }
    }

    if (-not $amrSkuName) {
        throw "No AMR SKU mapping found for $tier $sku (shards: $shardCount)"
    }

    $specs = $script:AmrSkuSpecs[$amrSkuName]
    return [PSCustomObject]@{
        Name           = $amrSkuName
        Advertised     = "$($specs.Advertised) GB"
        Usable         = "$($specs.Usable) GB"
        HA             = $ha
    }
}

function Get-PricingComparison {
    <#
    .SYNOPSIS
        Fetches pricing from Azure Retail Prices API and computes monthly cost comparison.
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [PSCustomObject]$TargetSku,
        [string]$Region,
        [string]$Currency
    )

    $result = [PSCustomObject]@{
        SourceMonthly = $null
        TargetMonthly = $null
        Delta         = $null
        Currency      = $Currency
        SourceError   = $null
        TargetError   = $null
    }

    # --- Source ACR pricing ---
    $acrMeter = "$($SourceConfig.Sku) Cache Instance"
    $acrHourly = Get-RetailPrice -MeterName $acrMeter -Region $Region -Currency $Currency
    if ($null -ne $acrHourly) {
        $nodes = Get-CacheNodeCount -Tier $SourceConfig.Tier -ShardCount $SourceConfig.ShardCount -ReplicasPerPrimary $SourceConfig.ReplicasPerPrimary
        $result.SourceMonthly = [math]::Round($acrHourly * 730 * $nodes, 2)
    } else {
        $result.SourceError = "No pricing found for ACR $($SourceConfig.Sku) in $Region"
    }

    # --- Target AMR pricing ---
    $amrMeter = "$($TargetSku.Name) Cache Instance"
    $amrHourly = Get-RetailPrice -MeterName $amrMeter -Region $Region -Currency $Currency
    if ($null -ne $amrHourly) {
        $amrNodes = Get-CacheNodeCount -Tier "AMR" -HA $TargetSku.HA
        $result.TargetMonthly = [math]::Round($amrHourly * 730 * $amrNodes, 2)
    } else {
        $result.TargetError = "No pricing found for AMR $($TargetSku.Name) in $Region"
    }

    if ($null -ne $result.SourceMonthly -and $null -ne $result.TargetMonthly) {
        $result.Delta = [math]::Round($result.TargetMonthly - $result.SourceMonthly, 2)
    }

    return $result
}

# Get-RetailPrice is provided by AmrMigrationHelpers.ps1 (dot-sourced above)

function Get-FeatureGaps {
    <#
    .SYNOPSIS
        Identifies features in the source ACR template that are unavailable or changed in AMR.
    #>
    param(
        [PSCustomObject]$SourceConfig
    )

    $gaps = @()

    # --- Removed features ---
    if ($SourceConfig.Networking.HasVNet) {
        $gaps += [PSCustomObject]@{ Feature = "VNet injection"; Status = "Removed"; Action = "Use Private Endpoint instead. AMR does not support VNet injection." }
    }
    if ($SourceConfig.Networking.HasFirewall) {
        $gaps += [PSCustomObject]@{ Feature = "Firewall rules"; Status = "Removed"; Action = "Use Private Endpoint + NSG for network isolation." }
    }
    if ($SourceConfig.EnableNonSslPort) {
        $gaps += [PSCustomObject]@{ Feature = "Non-SSL port (6379)"; Status = "Removed"; Action = "AMR is TLS-only on port 10000. Update client connections." }
    }
    if ($SourceConfig.ShardCount -gt 1) {
        $gaps += [PSCustomObject]@{ Feature = "Explicit shard count ($($SourceConfig.ShardCount))"; Status = "Removed"; Action = "AMR manages sharding internally. No shard count parameter." }
    }
    if ($SourceConfig.HasMRPP) {
        $gaps += [PSCustomObject]@{ Feature = "Multi-replica (MRPP: $($SourceConfig.ReplicasPerPrimary) replicas)"; Status = "Removed"; Action = "Use active geo-replication for read scaling instead." }
    }

    # --- Changed features ---
    if ($SourceConfig.EvictionPolicy) {
        $mapped = $script:EvictionPolicyMap[$SourceConfig.EvictionPolicy]
        if ($mapped -and $mapped -ne $SourceConfig.EvictionPolicy) {
            $gaps += [PSCustomObject]@{ Feature = "Eviction policy"; Status = "Changed"; Action = "Format changed from '$($SourceConfig.EvictionPolicy)' to '$mapped' (PascalCase)." }
        }
    }
    if ($SourceConfig.Persistence.RdbEnabled) {
        $gaps += [PSCustomObject]@{ Feature = "RDB persistence"; Status = "Changed"; Action = "Restructured: flat config strings become structured object. Storage connection strings removed (AMR manages storage)." }
    }
    if ($SourceConfig.Persistence.AofEnabled) {
        $gaps += [PSCustomObject]@{ Feature = "AOF persistence"; Status = "Changed"; Action = "Restructured: storage connection strings removed. AMR manages AOF storage internally." }
    }

    # Always-applicable gaps
    $gaps += [PSCustomObject]@{ Feature = "Port"; Status = "Changed"; Action = "Port changes from 6380 to 10000. Update client connection strings." }
    $gaps += [PSCustomObject]@{ Feature = "SKU format"; Status = "Changed"; Action = "SKU changes from 3-field (name/family/capacity) to compound name (e.g., Balanced_B50)." }
    $gaps += [PSCustomObject]@{ Feature = "Resource type"; Status = "Changed"; Action = "Single resource splits into cluster (redisEnterprise) + database (redisEnterprise/databases)." }

    # --- New capabilities ---
    $gaps += [PSCustomObject]@{ Feature = "Redis Stack modules"; Status = "New"; Action = "RedisJSON, RediSearch, RedisTimeSeries, RedisBloom now available." }
    $gaps += [PSCustomObject]@{ Feature = "Active geo-replication"; Status = "New"; Action = "Multi-region active-active replication available (replaces passive geo-replication)." }
    $gaps += [PSCustomObject]@{ Feature = "Managed persistence"; Status = "New"; Action = "AMR manages persistence storage — no storage account connection strings needed." }
    $gaps += [PSCustomObject]@{ Feature = "Redis 7.4"; Status = "New"; Action = "AMR runs Redis 7.4 with latest features and performance improvements." }

    # --- Best practice recommendations ---
    $gaps += [PSCustomObject]@{ Feature = "Microsoft Entra authentication"; Status = "Recommended"; Action = "Enable Entra ID auth and disable access keys for improved security (accessKeysAuthentication: Disabled)." }
    $gaps += [PSCustomObject]@{ Feature = "Public network access"; Status = "Recommended"; Action = "Set publicNetworkAccess: Disabled and use Private Endpoints for secure connectivity." }

    return $gaps
}

function Show-ConfirmationSummary {
    <#
    .SYNOPSIS
        Displays the migration summary and prompts for confirmation.
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [PSCustomObject]$TargetSku,
        [PSCustomObject]$Pricing,
        [array]$FeatureGaps
    )

    # If -ReturnObject, skip display — the skill handles presentation
    if ($script:ReturnObject) { return $true }

    Write-Section "MIGRATION SUMMARY"

    # Source
    Write-Info "Source: ACR $($SourceConfig.Tier) $($SourceConfig.Sku)"
    if ($SourceConfig.ShardCount -gt 1) {
        Write-Info "  Shards: $($SourceConfig.ShardCount)"
    }
    if ($SourceConfig.HasMRPP) {
        Write-Info "  Replicas per primary: $($SourceConfig.ReplicasPerPrimary)"
    }
    Write-Host ""

    # Target
    Write-Info "Target: AMR $($TargetSku.Name)"
    Write-Info "  Memory: $($TargetSku.Advertised) (Usable: $($TargetSku.Usable))"
    Write-Info "  HA: $(if ($TargetSku.HA) { 'Yes' } else { 'No' })"
    Write-Host ""

    # Pricing
    Write-Section "PRICING COMPARISON"
    if ($Pricing.SourceMonthly) {
        Write-Info "Source ACR monthly:  $($Pricing.Currency) $($Pricing.SourceMonthly)"
    } else {
        Write-Warn "Source ACR monthly:  $($Pricing.SourceError)"
    }
    if ($Pricing.TargetMonthly) {
        Write-Info "Target AMR monthly:  $($Pricing.Currency) $($Pricing.TargetMonthly)"
    } else {
        Write-Warn "Target AMR monthly:  $($Pricing.TargetError)"
    }
    if ($null -ne $Pricing.Delta) {
        $deltaStr = if ($Pricing.Delta -ge 0) { "+$($Pricing.Delta)" } else { "$($Pricing.Delta)" }
        $color = if ($Pricing.Delta -le 0) { "Green" } else { "Yellow" }
        Write-Host "  Delta:               $($Pricing.Currency) $deltaStr/month" -ForegroundColor $color
    }
    Write-Host ""

    # Feature gaps — Removed
    $removed = $FeatureGaps | Where-Object { $_.Status -eq "Removed" }
    if ($removed) {
        Write-Section "FEATURES REMOVED"
        foreach ($gap in $removed) {
            Write-Warn "  $($gap.Feature)"
            Write-Host "    Action: $($gap.Action)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # Feature gaps — Changed
    $changed = $FeatureGaps | Where-Object { $_.Status -eq "Changed" }
    if ($changed) {
        Write-Section "FEATURES CHANGED"
        foreach ($gap in $changed) {
            Write-Info "  $($gap.Feature)"
            Write-Host "    $($gap.Action)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # Feature gaps — New
    $new = $FeatureGaps | Where-Object { $_.Status -eq "New" }
    if ($new) {
        Write-Section "NEW CAPABILITIES"
        foreach ($gap in $new) {
            Write-Success "  $($gap.Feature): $($gap.Action)"
        }
        Write-Host ""
    }

    # Confirmation
    if ($script:ForceMode) {
        Write-Info "(-Force specified, proceeding automatically)"
        return $true
    }

    Write-Host ""
    $response = Read-Host "Proceed with migration? [Y/n]"
    if ($response -match "^[Nn]") {
        Write-Warn "Migration cancelled by user."
        return $false
    }
    return $true
}

function Convert-ArmTemplate {
    <#
    .SYNOPSIS
        Transforms an ACR ARM JSON template to AMR (cluster + database resources).
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [PSCustomObject]$TargetSku,
        [string]$ClusteringPolicy,
        [hashtable]$SourceTemplate,
        [hashtable]$SourceParameters
    )

    # Find the ACR resource
    $acrResource = $null
    $acrIndex = -1
    for ($i = 0; $i -lt $SourceTemplate["resources"].Count; $i++) {
        if ($SourceTemplate["resources"][$i]["type"] -eq "Microsoft.Cache/redis") {
            $acrResource = $SourceTemplate["resources"][$i]
            $acrIndex = $i
            break
        }
    }
    if (-not $acrResource) { throw "No Microsoft.Cache/redis resource found" }

    $cacheName = $acrResource["name"]  # May be "[parameters('cacheName')]"
    $location = $acrResource["location"]
    $props = $acrResource["properties"]

    # Map eviction policy
    $eviction = $SourceConfig.EvictionPolicy
    if ($eviction -and $script:EvictionPolicyMap.ContainsKey($eviction)) {
        $eviction = $script:EvictionPolicyMap[$eviction]
    }
    if (-not $eviction) { $eviction = "VolatileLRU" }

    # Build persistence object
    $persistence = $null
    if ($SourceConfig.Persistence.RdbEnabled -or $SourceConfig.Persistence.AofEnabled) {
        $persistence = @{}
        if ($SourceConfig.Persistence.RdbEnabled) {
            $persistence["rdbEnabled"] = $true
            $freq = $SourceConfig.Persistence.RdbFrequency
            if ($freq -and $script:RdbFrequencyMap.ContainsKey($freq)) {
                $persistence["rdbFrequency"] = $script:RdbFrequencyMap[$freq]
            } else {
                $persistence["rdbFrequency"] = "1h"
            }
        }
        if ($SourceConfig.Persistence.AofEnabled) {
            $persistence["aofEnabled"] = $true
            $persistence["aofFrequency"] = "1s"
        }
    }

    # Build cluster resource
    $clusterResource = [ordered]@{
        type       = "Microsoft.Cache/redisEnterprise"
        apiVersion = "2025-07-01"
        name       = $cacheName
        location   = $location
        sku        = [ordered]@{ name = $TargetSku.Name }
        properties = [ordered]@{
            minimumTlsVersion   = if ($SourceConfig.MinimumTlsVersion) { $SourceConfig.MinimumTlsVersion } else { "1.2" }
            publicNetworkAccess = "Enabled"
        }
    }
    # AMR handles zone redundancy automatically — do not copy source zones
    if ($SourceConfig.HasIdentity -and $SourceConfig.Identity) {
        # Only copy identity type — principalId/tenantId are assigned by ARM at deploy time
        $identityType = if ($SourceConfig.Identity.type) { $SourceConfig.Identity.type } else { "SystemAssigned" }
        $identityObj = @{ type = $identityType }
        # If UserAssigned is included, copy the userAssignedIdentities map
        if ($identityType -match 'UserAssigned' -and $SourceConfig.Identity.userAssignedIdentities) {
            $identityObj["userAssignedIdentities"] = $SourceConfig.Identity.userAssignedIdentities
        } elseif ($identityType -match 'UserAssigned') {
            # UserAssigned specified but no identities listed — downgrade to SystemAssigned
            $identityObj["type"] = ($identityType -replace ',?\s*UserAssigned', '').Trim(',').Trim()
            if ([string]::IsNullOrWhiteSpace($identityObj["type"])) { $identityObj["type"] = "SystemAssigned" }
        }
        $clusterResource["identity"] = $identityObj
    }
    if ($SourceConfig.Tags) { $clusterResource["tags"] = $SourceConfig.Tags }

    # Build database resource
    $dbName = if ($cacheName -match "^\[") {
        "[concat($($cacheName.TrimStart('[').TrimEnd(']')), '/default')]"
    } else {
        "$cacheName/default"
    }

    $dbProperties = [ordered]@{
        port             = 10000
        clientProtocol   = "Encrypted"
        clusteringPolicy = "[parameters('clusteringPolicy')]"
        evictionPolicy   = "[parameters('evictionPolicy')]"
    }
    if ($persistence) {
        $dbPersistence = [ordered]@{}
        if ($persistence.ContainsKey("rdbEnabled")) {
            $dbPersistence["rdbEnabled"] = $true
            $dbPersistence["rdbFrequency"] = "[parameters('rdbFrequency')]"
        }
        if ($persistence.ContainsKey("aofEnabled")) {
            $dbPersistence["aofEnabled"] = $true
            $dbPersistence["aofFrequency"] = "1s"
        }
        $dbProperties["persistence"] = $dbPersistence
    }

    # Build dependsOn — derive resourceId from cache name
    $dependsOnId = if ($cacheName -match "^\[parameters\('([^']+)'\)\]$") {
        "[resourceId('Microsoft.Cache/redisEnterprise', parameters('$($Matches[1])'))]"
    } elseif ($cacheName -match "^\[") {
        "[resourceId('Microsoft.Cache/redisEnterprise', $($cacheName.TrimStart('[').TrimEnd(']')))]"
    } else {
        "[resourceId('Microsoft.Cache/redisEnterprise', '$cacheName')]"
    }

    $databaseResource = [ordered]@{
        type       = "Microsoft.Cache/redisEnterprise/databases"
        apiVersion = "2025-07-01"
        name       = $dbName
        dependsOn  = @($dependsOnId)
        properties = $dbProperties
    }

    # Clone template and replace the ACR resource with cluster + database
    $newTemplate = $SourceTemplate.Clone()
    $newResources = [System.Collections.ArrayList]::new()
    $sourceHasPeResource = $false
    for ($i = 0; $i -lt $SourceTemplate["resources"].Count; $i++) {
        $r = $SourceTemplate["resources"][$i]
        if ($r["type"] -eq "Microsoft.Cache/redis") {
            [void]$newResources.Add($clusterResource)
            [void]$newResources.Add($databaseResource)
        } elseif ($r["type"] -match "^Microsoft\.Cache/redis/") {
            # Remove all ACR child resources (firewallRules, patchSchedules, linkedServers)
            continue
        } else {
            # Update resource type references from redis to redisEnterprise
            $updated = Update-DependsOn -Resource $r -OldType "Microsoft.Cache/redis" -NewType "Microsoft.Cache/redisEnterprise"
            # Update privateLinkServiceId, scope, and groupId references
            if ($updated -is [hashtable]) {
                $json = $updated | ConvertTo-Json -Depth 20 -Compress
                if ($json -match "Microsoft\.Cache/redis[^E]" -or $json -match "Microsoft\.Cache/redis'") {
                    $json = $json -replace "Microsoft\.Cache/redis(?=/|')", "Microsoft.Cache/redisEnterprise"
                    $updated = $json | ConvertFrom-Json -AsHashtable
                }
                # Update PE groupId from ACR (redisCache) to AMR (redisEnterprise)
                if ($json -match '"redisCache"') {
                    $json = ($updated | ConvertTo-Json -Depth 20 -Compress) -replace '"redisCache"', '"redisEnterprise"'
                    $updated = $json | ConvertFrom-Json -AsHashtable
                }
            }
            # Track whether source already has PE resources (avoid adding duplicates)
            if ($r["type"] -eq "Microsoft.Network/privateEndpoints") {
                $sourceHasPeResource = $true
            }
            [void]$newResources.Add($updated)
        }
    }

    # Add Private Endpoint if source had VNet or firewall, but only if the source
    # template doesn't already include PE resources (e.g., Bicep templates with conditional PEs)
    if (($SourceConfig.Networking.HasVNet -or $SourceConfig.Networking.HasFirewall) -and -not $sourceHasPeResource) {
        $peResource = Build-PrivateEndpointResource -CacheName $cacheName -Location $location -DependsOnId $dependsOnId
        [void]$newResources.Add($peResource)
        $clusterResource["properties"]["publicNetworkAccess"] = "Disabled"
    } elseif ($sourceHasPeResource) {
        # Source already has PE — still disable public access for security
        $clusterResource["properties"]["publicNetworkAccess"] = "Disabled"
    }

    $newTemplate["resources"] = $newResources.ToArray()

    # Clean up template-level parameters that are no longer needed
    if ($newTemplate.ContainsKey("parameters")) {
        $paramsToRemove = @("skuFamily", "skuCapacity", "enableNonSslPort", "shardCount",
            "replicasPerPrimary", "replicasPerMaster", "redisVersion", "staticIP",
            "rdbStorageConnectionString", "aofStorageConnectionString0", "aofStorageConnectionString1",
            "maxmemoryPolicy", "rdbBackupFrequency",
            "maxmemoryReserved", "maxfragmentationmemoryReserved", "maxmemoryDelta", "zones")
        foreach ($p in $paramsToRemove) {
            if ($newTemplate["parameters"].ContainsKey($p)) {
                $newTemplate["parameters"].Remove($p)
            }
        }

        # Add AMR-specific parameter definitions
        $newTemplate["parameters"]["evictionPolicy"] = [ordered]@{
            type         = "string"
            defaultValue = $eviction
            metadata     = @{ description = "Eviction policy for the AMR database" }
        }
        $newTemplate["parameters"]["clusteringPolicy"] = [ordered]@{
            type         = "string"
            defaultValue = $ClusteringPolicy
            allowedValues = @("EnterpriseCluster", "OSSCluster")
            metadata     = @{ description = "Clustering policy for the AMR database" }
        }
        if ($persistence -and $persistence.ContainsKey("rdbEnabled")) {
            $rdbDefault = if ($persistence["rdbFrequency"]) { $persistence["rdbFrequency"] } else { "1h" }
            $newTemplate["parameters"]["rdbFrequency"] = [ordered]@{
                type         = "string"
                defaultValue = $rdbDefault
                allowedValues = @("1h", "6h", "12h")
                metadata     = @{ description = "RDB backup frequency for the AMR database" }
            }
        }

        # Ensure skuName parameter exists in AMR template (source may hardcode the SKU)
        $newTemplate["parameters"]["skuName"] = [ordered]@{
            type         = "string"
            defaultValue = $TargetSku.Name
            metadata     = @{ description = "AMR SKU name (e.g. Balanced_B0, MemoryOptimized_X5)" }
        }
    }

    # Clean up variables that reference removed ACR parameters
    if ($newTemplate.ContainsKey("variables") -and $newTemplate["variables"] -is [hashtable]) {
        $removedParamPattern = "maxmemoryPolicy|maxmemoryReserved|maxfragmentationmemory|rdbStorageConnection|aofStorageConnection|enableNonSslPort|shardCount|rdbBackupFrequency|rdbBackupEnabled|aofBackupEnabled"
        # Two-pass: first find vars referencing removed params, then find vars referencing removed vars
        $varsToRemove = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($varName in @($newTemplate["variables"].Keys)) {
            $varJson = $newTemplate["variables"][$varName] | ConvertTo-Json -Depth 10 -Compress 2>$null
            if ($varJson -match $removedParamPattern) {
                [void]$varsToRemove.Add($varName)
            }
        }
        # Chain removal: remove variables that reference already-removed variables
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($varName in @($newTemplate["variables"].Keys)) {
                if ($varsToRemove.Contains($varName)) { continue }
                $varJson = $newTemplate["variables"][$varName] | ConvertTo-Json -Depth 10 -Compress 2>$null
                foreach ($removed in $varsToRemove) {
                    if ($varJson -match "variables\('$removed'\)") {
                        [void]$varsToRemove.Add($varName)
                        $changed = $true
                        break
                    }
                }
            }
        }
        # Also remove isPremium if it checks for ACR SKU name 'Premium'
        foreach ($varName in @($newTemplate["variables"].Keys)) {
            $varJson = $newTemplate["variables"][$varName] | ConvertTo-Json -Depth 10 -Compress 2>$null
            if ($varJson -match "equals\(parameters\('skuName'\),\s*'Premium'\)") {
                [void]$varsToRemove.Add($varName)
            }
        }
        foreach ($v in $varsToRemove) {
            $newTemplate["variables"].Remove($v)
        }
        if ($newTemplate["variables"].Count -eq 0) {
            $newTemplate.Remove("variables")
        }
    }

    # Clean up outputs that reference Microsoft.Cache/redis (not redisEnterprise)
    if ($newTemplate.ContainsKey("outputs") -and $newTemplate["outputs"] -is [hashtable]) {
        $outputsToRemove = @()
        foreach ($outName in @($newTemplate["outputs"].Keys)) {
            $outJson = $newTemplate["outputs"][$outName] | ConvertTo-Json -Depth 10 -Compress 2>$null
            if ($outJson -match "Microsoft\.Cache/redis[^E]" -or $outJson -match "Microsoft\.Cache/redis'" -or
                $outJson -match "\.hostName|\.sslPort|\.nonSslPort") {
                $outputsToRemove += $outName
            }
        }
        foreach ($o in $outputsToRemove) {
            $newTemplate["outputs"].Remove($o)
        }
        if ($newTemplate["outputs"].Count -eq 0) {
            $newTemplate.Remove("outputs")
        }
    }

    return $newTemplate
}

function Update-DependsOn {
    param(
        [object]$Resource,
        [string]$OldType,
        [string]$NewType
    )
    if ($Resource -is [hashtable] -and $Resource.ContainsKey("dependsOn")) {
        $deps = $Resource["dependsOn"]
        if ($deps) {
            $newDeps = @()
            foreach ($dep in $deps) {
                if ($dep -is [string]) {
                    $newDeps += $dep.Replace($OldType, $NewType)
                } else {
                    $newDeps += $dep
                }
            }
            $Resource["dependsOn"] = $newDeps
        }
    }
    return $Resource
}

function Build-PrivateEndpointResource {
    param(
        [string]$CacheName,
        [string]$Location,
        [string]$DependsOnId
    )

    $peName = if ($CacheName -match "^\[parameters\('([^']+)'\)\]$") {
        "[concat(parameters('$($Matches[1])'), '-pe')]"
    } elseif ($CacheName -match "^\[") {
        "[concat($($CacheName.TrimStart('[').TrimEnd(']')), '-pe')]"
    } else {
        "$CacheName-pe"
    }

    return [ordered]@{
        condition  = "[not(empty(parameters('subnetId')))]"
        type       = "Microsoft.Network/privateEndpoints"
        apiVersion = "2023-11-01"
        name       = $peName
        location   = $Location
        dependsOn  = @($DependsOnId)
        properties = [ordered]@{
            privateLinkServiceConnections = @(
                [ordered]@{
                    name       = "redisEnterprise"
                    properties = [ordered]@{
                        privateLinkServiceId = $DependsOnId.Replace("[resourceId(", "[resourceId(").Replace(")]", ")]")
                        groupIds             = @("redisEnterprise")
                    }
                }
            )
            subnet = [ordered]@{
                id = "[parameters('subnetId')]"
            }
        }
        comments   = "Private Endpoint added to replace ACR VNet injection / firewall rules"
    }
}

function Parse-BicepParamFile {
    <#
    .SYNOPSIS
        Parses a .bicepparam file into an ARM-compatible parameters hashtable.
    .DESCRIPTION
        Uses 'az bicep build-params' to compile .bicepparam to ARM JSON parameters.
        Falls back to basic regex parsing if az bicep is not available.
    #>
    param(
        [string]$Path
    )

    # ── Primary: az bicep build-params (handles expressions, variables, imports) ──
    $tempJson = [System.IO.Path]::GetTempFileName() + ".json"
    try {
        $buildResult = & az bicep build-params --file $Path --outfile $tempJson 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $tempJson)) {
            $compiled = Get-Content $tempJson -Raw | ConvertFrom-Json -AsHashtable
            # build-params output has the same schema as ARM parameters files
            if ($compiled -and $compiled['parameters']) {
                return $compiled
            }
        }
        Write-Warning "az bicep build-params failed — falling back to basic .bicepparam parser"
    } catch {
        Write-Warning "az bicep build-params not available — falling back to basic .bicepparam parser"
    } finally {
        if (Test-Path $tempJson) { Remove-Item $tempJson -Force }
    }

    # ── Fallback: basic regex parsing (simple param = literal only) ──
    $parameters = [ordered]@{}
    $lines = (Get-Content $Path -Raw) -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^using\s' -or $trimmed -match '^//' -or $trimmed -eq '') { continue }

        if ($trimmed -match "^param\s+(\w+)\s*=\s*(.+)$") {
            $paramName = $Matches[1]
            $rawValue = $Matches[2].Trim()

            $value = switch -Regex ($rawValue) {
                "^'(.*)'$"    { $Matches[1] }
                "^true$"      { $true }
                "^false$"     { $false }
                "^\d+$"       { [int]$rawValue }
                "^\d+\.\d+$"  { [double]$rawValue }
                default       { $rawValue }
            }

            $parameters[$paramName] = @{ value = $value }
        }
    }

    return @{
        '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
        contentVersion = "1.0.0.0"
        parameters     = $parameters
    }
}

function Convert-ParametersFile {
    <#
    .SYNOPSIS
        Transforms an ACR parameters file to AMR parameters.
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [PSCustomObject]$TargetSku,
        [string]$ClusteringPolicy,
        [hashtable]$SourceParameters
    )

    $newParams = [ordered]@{
        '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
        contentVersion = "1.0.0.0"
        parameters     = [ordered]@{}
    }

    $paramsToRemove = @(
        "skuName", "skuFamily", "skuCapacity", "enableNonSslPort", "shardCount",
        "replicasPerPrimary", "replicasPerMaster", "redisVersion", "staticIP",
        "rdbStorageConnectionString", "aofStorageConnectionString0", "aofStorageConnectionString1",
        "maxmemoryReserved", "maxfragmentationmemoryReserved", "maxmemoryDelta",
        "aadEnabled", "subnetId", "firewallRules", "zones"
    )

    $sourceParamEntries = $SourceParameters["parameters"]
    if ($sourceParamEntries) {
        foreach ($key in $sourceParamEntries.Keys) {
            $lowerKey = $key.ToLower()
            # Skip removed params
            if ($paramsToRemove | Where-Object { $_.ToLower() -eq $lowerKey }) { continue }

            $entry = $sourceParamEntries[$key]

            # Transform specific parameter values
            switch -Regex ($lowerKey) {
                "rdbbackupfrequency|rdb.*frequency" {
                    $val = $entry["value"]
                    if ($val -and $script:RdbFrequencyMap.ContainsKey([string]$val)) {
                        $newParams["parameters"]["rdbFrequency"] = @{ value = $script:RdbFrequencyMap[[string]$val] }
                    }
                    continue
                }
                "maxmemorypolicy|evictionpolicy" {
                    $val = $entry["value"]
                    if ($val -and $script:EvictionPolicyMap.ContainsKey($val)) {
                        $newParams["parameters"]["evictionPolicy"] = @{ value = $script:EvictionPolicyMap[$val] }
                    } elseif ($val) {
                        $newParams["parameters"]["evictionPolicy"] = @{ value = $val }
                    }
                    continue
                }
                default {
                    # Carry over as-is (preserves KeyVault references)
                    $newParams["parameters"][$key] = $entry
                }
            }
        }
    }

    # Add new AMR parameters
    $newParams["parameters"]["skuName"] = @{ value = $TargetSku.Name }
    $newParams["parameters"]["clusteringPolicy"] = @{ value = $ClusteringPolicy }

    # Add Private Endpoint flag if source had VNet
    if ($SourceConfig.Networking.HasVNet) {
        $newParams["parameters"]["enablePrivateEndpoint"] = @{ value = $true }
    }

    # Migration metadata is report-only — not injected into params (would fail ARM deployment without template declaration)

    return $newParams
}

function ConvertTo-BicepLiteral {
    <#
    .SYNOPSIS
        Converts a PowerShell value to valid Bicep literal syntax.
        Handles strings, booleans, numbers, arrays, and hashtables/objects.
    #>
    param([object]$Value, [int]$Indent = 0)

    if ($null -eq $Value) { return 'null' }

    $pad = '  ' * $Indent
    $innerPad = '  ' * ($Indent + 1)

    switch ($Value) {
        { $_ -is [bool] } { return $_.ToString().ToLower() }
        { $_ -is [int] -or $_ -is [long] -or $_ -is [double] } { return $_.ToString() }
        { $_ -is [array] -or $_ -is [System.Collections.IList] } {
            if ($_.Count -eq 0) { return '[]' }
            $items = foreach ($item in $_) { "$innerPad$(ConvertTo-BicepLiteral $item ($Indent + 1))" }
            return "[$([Environment]::NewLine)$($items -join [Environment]::NewLine)$([Environment]::NewLine)$pad]"
        }
        { $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary] -or $_ -is [System.Collections.Specialized.OrderedDictionary] } {
            if ($_.Count -eq 0) { return '{}' }
            $entries = foreach ($k in $_.Keys) {
                $v = ConvertTo-BicepLiteral $_[$k] ($Indent + 1)
                "$innerPad$k`: $v"
            }
            return "{$([Environment]::NewLine)$($entries -join [Environment]::NewLine)$([Environment]::NewLine)$pad}"
        }
        { $_ -is [PSCustomObject] } {
            $dict = @{}
            $_.PSObject.Properties | ForEach-Object { $dict[$_.Name] = $_.Value }
            return ConvertTo-BicepLiteral $dict $Indent
        }
        default { return "'$($_ -replace "'", "\'")'" }
    }
}

function Convert-BicepParamFile {
    <#
    .SYNOPSIS
        Converts migrated ARM parameters to .bicepparam format.
    .DESCRIPTION
        Uses 'az bicep decompile-params' to convert ARM JSON params to .bicepparam.
        Falls back to manual string generation if az bicep is not available.
    #>
    param(
        [hashtable]$MigratedParameters,
        [string]$BicepTemplateName
    )

    # ── Primary: az bicep decompile-params ──
    $tempJson = [System.IO.Path]::GetTempFileName() + ".json"
    $tempBicepParam = [System.IO.Path]::ChangeExtension($tempJson, ".bicepparam")
    try {
        $MigratedParameters | ConvertTo-Json -Depth 20 | Set-Content $tempJson -Encoding UTF8

        $decompileResult = & az bicep decompile-params --file $tempJson --force 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $tempBicepParam)) {
            $content = Get-Content $tempBicepParam -Raw
            # Replace the using declaration to point to migrated template
            $content = $content -replace "using\s+'[^']*'", "using './$BicepTemplateName'"
            return $content.TrimEnd()
        }

        Write-Warn "az bicep decompile-params failed — falling back to manual .bicepparam generation"
    } catch {
        Write-Warn "az bicep decompile-params not available — falling back to manual .bicepparam generation"
    } finally {
        if (Test-Path $tempJson) { Remove-Item $tempJson -Force }
        if (Test-Path $tempBicepParam) { Remove-Item $tempBicepParam -Force }
    }

    # ── Fallback: manual string generation ──
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("using './$BicepTemplateName'")
    [void]$sb.AppendLine()

    $params = $MigratedParameters["parameters"]
    if ($params) {
        foreach ($key in $params.Keys) {
            $val = $params[$key]["value"]
            $formatted = ConvertTo-BicepLiteral $val
            [void]$sb.AppendLine("param $key = $formatted")
        }
    }

    return $sb.ToString().TrimEnd()
}

function Convert-BicepTemplate {
    <#
    .SYNOPSIS
        Converts migrated ARM JSON output to Bicep format.
    #>
    param(
        [object]$ArmResult
    )

    # Write ARM JSON to temp file and decompile to Bicep
    $tempArm = [System.IO.Path]::GetTempFileName() + ".json"
    $tempBicep = [System.IO.Path]::ChangeExtension($tempArm, ".bicep")
    try {
        $ArmResult | ConvertTo-Json -Depth 20 | Set-Content $tempArm -Encoding UTF8

        $decompileResult = & az bicep decompile --file $tempArm --force 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $tempBicep)) {
            return (Get-Content $tempBicep -Raw)
        }

        # Fallback: return a note that manual conversion is needed
        Write-Warn "az bicep decompile failed. ARM JSON will be used instead."
        Write-Warn "Run 'az bicep decompile --file <output>.json' manually to get Bicep."
        return $null
    } finally {
        if (Test-Path $tempArm) { Remove-Item $tempArm -Force }
        if (Test-Path $tempBicep) { Remove-Item $tempBicep -Force }
    }
}

function Convert-TerraformTemplate {
    <#
    .SYNOPSIS
        Generates migrated Terraform configuration from transformed config.
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [PSCustomObject]$TargetSku,
        [string]$ClusteringPolicy
    )

    # Map eviction policy
    $eviction = $SourceConfig.EvictionPolicy
    if ($eviction -and $script:EvictionPolicyMap.ContainsKey($eviction)) {
        $eviction = $script:EvictionPolicyMap[$eviction]
    }
    if (-not $eviction) { $eviction = "VolatileLRU" }

    # Build persistence block
    $persistenceBlock = ""
    if ($SourceConfig.Persistence.RdbEnabled -or $SourceConfig.Persistence.AofEnabled) {
        $persistenceLines = @()
        if ($SourceConfig.Persistence.RdbEnabled) {
            $freq = $SourceConfig.Persistence.RdbFrequency
            $mappedFreq = if ($freq -and $script:RdbFrequencyMap.ContainsKey($freq)) { $script:RdbFrequencyMap[$freq] } else { "1h" }
            $persistenceLines += "    rdb_enabled   = true"
            $persistenceLines += "    rdb_frequency = `"$mappedFreq`""
        }
        if ($SourceConfig.Persistence.AofEnabled) {
            $persistenceLines += "    aof_enabled   = true"
            $persistenceLines += "    aof_frequency = `"1s`""
        }
        $persistenceBlock = @"

  linked_database_group_nickname = null
$($persistenceLines -join "`n")
"@
    }

    # AMR handles zone redundancy automatically — no zones block needed
    $zonesBlock = ""

    # Build Private Endpoint resource
    $peBlock = ""
    if ($SourceConfig.Networking.HasVNet -or $SourceConfig.Networking.HasFirewall) {
        $peBlock = @"


# Private Endpoint (replaces VNet injection / firewall rules)
resource "azurerm_private_endpoint" "redis_pe" {
  name                = "`${var.cache_name}-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "redis-enterprise"
    private_connection_resource_id = azurerm_redis_enterprise_cluster.this.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }
}
"@
    }

    $terraform = @"
# Migrated from azurerm_redis_cache to Azure Managed Redis (AMR)
# Generated by Convert-AcrToAmr.ps1 on $(Get-Date -Format "yyyy-MM-dd")
# Source: ACR $($SourceConfig.Tier) $($SourceConfig.Sku)

resource "azurerm_redis_enterprise_cluster" "this" {
  name                = var.cache_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "$($TargetSku.Name)"$zonesBlock

  minimum_tls_version = "$($SourceConfig.MinimumTlsVersion)"

  tags = var.tags
}

resource "azurerm_redis_enterprise_database" "default" {
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.this.id
  port              = 10000
  client_protocol   = "Encrypted"
  clustering_policy = "$ClusteringPolicy"
  eviction_policy   = "$eviction"$persistenceBlock
}
$peBlock
"@

    return $terraform
}

function Write-MigratedOutput {
    <#
    .SYNOPSIS
        Writes migrated template and parameters files to the output directory.
    #>
    param(
        [string]$SourcePath,
        [string]$OutputDirectory,
        [string]$Format,
        [object]$MigratedTemplate,
        [object]$MigratedParameters,
        [string]$MigratedBicep,
        [string]$MigratedBicepParam,
        [string]$MigratedTerraform
    )

    $outputFiles = @()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    # Remove .parameters suffix if present for consistent naming
    $baseName = $baseName -replace '\.parameters$', ''

    # Create output directory
    if (-not (Test-Path $OutputDirectory)) {
        if ($WhatIf) {
            Write-Info "Would create directory: $OutputDirectory"
        } else {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }
    }

    switch ($Format) {
        "ARM" {
            $templatePath = Join-Path $OutputDirectory "$baseName.amr.json"
            if ($WhatIf) {
                Write-Info "Would write: $templatePath"
            } else {
                $MigratedTemplate | ConvertTo-Json -Depth 20 | Set-Content $templatePath -Encoding UTF8
            }
            $outputFiles += [PSCustomObject]@{ Path = $templatePath; Type = "Template" }

            if ($MigratedParameters) {
                $paramsPath = Join-Path $OutputDirectory "$baseName.amr.parameters.json"
                if ($WhatIf) {
                    Write-Info "Would write: $paramsPath"
                } else {
                    $MigratedParameters | ConvertTo-Json -Depth 20 | Set-Content $paramsPath -Encoding UTF8
                }
                $outputFiles += [PSCustomObject]@{ Path = $paramsPath; Type = "Parameters" }
            }
        }
        "Bicep" {
            if ($MigratedBicep) {
                $bicepPath = Join-Path $OutputDirectory "$baseName.amr.bicep"
                if ($WhatIf) {
                    Write-Info "Would write: $bicepPath"
                } else {
                    $MigratedBicep | Set-Content $bicepPath -Encoding UTF8
                }
                $outputFiles += [PSCustomObject]@{ Path = $bicepPath; Type = "Template" }
            } else {
                # Fallback to ARM JSON if Bicep decompile failed
                $templatePath = Join-Path $OutputDirectory "$baseName.amr.json"
                if ($WhatIf) {
                    Write-Info "Would write: $templatePath (ARM JSON fallback)"
                } else {
                    $MigratedTemplate | ConvertTo-Json -Depth 20 | Set-Content $templatePath -Encoding UTF8
                }
                $outputFiles += [PSCustomObject]@{ Path = $templatePath; Type = "Template" }
            }
            if ($MigratedBicepParam) {
                # .bicepparam output (preferred when source used .bicepparam)
                $bicepParamPath = Join-Path $OutputDirectory "$baseName.amr.bicepparam"
                if ($WhatIf) {
                    Write-Info "Would write: $bicepParamPath"
                } else {
                    $MigratedBicepParam | Set-Content $bicepParamPath -Encoding UTF8
                }
                $outputFiles += [PSCustomObject]@{ Path = $bicepParamPath; Type = "Parameters" }
            } elseif ($MigratedParameters) {
                $paramsPath = Join-Path $OutputDirectory "$baseName.amr.parameters.json"
                if ($WhatIf) {
                    Write-Info "Would write: $paramsPath"
                } else {
                    $MigratedParameters | ConvertTo-Json -Depth 20 | Set-Content $paramsPath -Encoding UTF8
                }
                $outputFiles += [PSCustomObject]@{ Path = $paramsPath; Type = "Parameters" }
            }
        }
        "Terraform" {
            $tfPath = Join-Path $OutputDirectory "$baseName.amr.tf"
            if ($WhatIf) {
                Write-Info "Would write: $tfPath"
            } else {
                $MigratedTerraform | Set-Content $tfPath -Encoding UTF8
            }
            $outputFiles += [PSCustomObject]@{ Path = $tfPath; Type = "Template" }
        }
    }

    return $outputFiles
}

function Write-MigrationReport {
    <#
    .SYNOPSIS
        Displays the post-migration summary report and writes report file.
    #>
    param(
        [PSCustomObject]$SourceConfig,
        [PSCustomObject]$TargetSku,
        [PSCustomObject]$Pricing,
        [array]$FeatureGaps,
        [array]$OutputFiles
    )

    $reportLines = @()
    $reportLines += "═══════════════════════════════════════════════════"
    $reportLines += "  MIGRATION COMPLETE — SUMMARY"
    $reportLines += "═══════════════════════════════════════════════════"
    $reportLines += ""
    $reportLines += "Source: ACR $($SourceConfig.Tier) $($SourceConfig.Sku)"
    $reportLines += "Target: AMR $($TargetSku.Name)"
    $reportLines += ""
    $reportLines += "AMR SKU Specs:"
    $reportLines += "  Memory:          $($TargetSku.Advertised) (Usable: $($TargetSku.Usable))"
    $reportLines += "  HA:              $(if ($TargetSku.HA) { 'Yes' } else { 'No' })"
    $reportLines += ""

    if ($Pricing) {
        $reportLines += "Pricing:"
        if ($Pricing.SourceMonthly) { $reportLines += "  ACR monthly: $($Pricing.Currency) $($Pricing.SourceMonthly)" }
        if ($Pricing.TargetMonthly) { $reportLines += "  AMR monthly: $($Pricing.Currency) $($Pricing.TargetMonthly)" }
        if ($null -ne $Pricing.Delta) {
            $deltaStr = if ($Pricing.Delta -ge 0) { "+$($Pricing.Delta)" } else { "$($Pricing.Delta)" }
            $reportLines += "  Delta:       $($Pricing.Currency) $deltaStr/month"
        }
        $reportLines += ""
    }

    $reportLines += "Connection Details:"
    $reportLines += "  Endpoint: <name>.$($Region).redis.azure.net"
    $reportLines += "  Port:     10000 (TLS only)"
    $reportLines += ""

    $reportLines += "Features Available:"
    $available = @("Redis 7.4", "RedisJSON", "RediSearch", "RedisBloom", "RedisTimeSeries",
        "Active geo-replication", "Managed persistence", "Zone redundancy",
        "Import/Export", "Online scaling", "Microsoft Entra ID auth")
    foreach ($f in $available) { $reportLines += "  ✅ $f" }
    $reportLines += ""

    $removed = $FeatureGaps | Where-Object { $_.Status -eq "Removed" }
    if ($removed) {
        $reportLines += "Features Not Carried Over:"
        foreach ($gap in $removed) { $reportLines += "  ❌ $($gap.Feature) — $($gap.Action)" }
        $reportLines += ""
    }

    $reportLines += "Output Files:"
    foreach ($f in $OutputFiles) { $reportLines += "  📄 $($f.Path) ($($f.Type))" }
    $reportLines += ""

    # Display to console
    if (-not $script:ReturnObject) {
        Write-Host ""
        foreach ($line in $reportLines) {
            if ($line -match "^═") { Write-Host $line -ForegroundColor Cyan }
            elseif ($line -match "^  ✅") { Write-Host $line -ForegroundColor Green }
            elseif ($line -match "^  ❌") { Write-Host $line -ForegroundColor Yellow }
            elseif ($line -match "^  📄") { Write-Host $line -ForegroundColor DarkCyan }
            else { Write-Host $line }
        }
    }

    # Write report file alongside output
    if ($OutputFiles -and $OutputFiles.Count -gt 0 -and -not $WhatIf) {
        $reportDir = Split-Path $OutputFiles[0].Path -Parent
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($TemplatePath) -replace '\.parameters$', ''
        $reportPath = Join-Path $reportDir "$baseName.amr.report.txt"
        $reportLines | Set-Content $reportPath -Encoding UTF8
    }
}

# ═══════════════════════════════════════════════════════════════
# Region: Main Execution
# ═══════════════════════════════════════════════════════════════

function Main {
    Write-Banner "ACR → AMR IaC Migration (v$($script:ScriptVersion))"

    # ── Step 1: Parse source template ──
    Write-Section "Step 1: Parsing source template"
    $sourceConfig = Parse-AcrTemplate -TemplatePath $TemplatePath -ParametersPath $ParametersPath
    Write-Success "Parsed $($sourceConfig.Format) template: $($sourceConfig.Tier) $($sourceConfig.Sku) (parser: $($sourceConfig._ParsingMethod))"

    # ── Step 2: Map target AMR SKU ──
    Write-Section "Step 2: Mapping target AMR SKU"
    $targetSku = Get-AmrSkuMapping -SourceConfig $sourceConfig -TargetSkuOverride $TargetSku
    Write-Success "Recommended SKU: $($targetSku.Name) ($($targetSku.Advertised) advertised, $($targetSku.Usable) usable)"

    # ── Step 3: Pricing comparison ──
    $pricing = $null
    if (-not $SkipPricing) {
        Write-Section "Step 3: Pricing comparison"
        $pricing = Get-PricingComparison -SourceConfig $sourceConfig -TargetSku $targetSku -Region $Region -Currency $Currency
        Write-Success "Source: $Currency $($pricing.SourceMonthly)/mo → Target: $Currency $($pricing.TargetMonthly)/mo (delta: $Currency $($pricing.Delta))"
    }

    # ── Step 4: Feature gap analysis ──
    Write-Section "Step 4: Feature gap analysis"
    $featureGaps = Get-FeatureGaps -SourceConfig $sourceConfig
    Write-Success "Identified $($featureGaps.Count) feature gap(s)"

    # ── Return analysis if AnalyzeOnly ──
    if ($AnalyzeOnly) {
        if ($ReturnObject) {
            return [PSCustomObject]@{
                SourceConfig      = $sourceConfig
                TargetSku         = $targetSku
                Pricing           = $pricing
                FeatureGaps       = $featureGaps
            }
        }
        Show-ConfirmationSummary -SourceConfig $sourceConfig -TargetSku $targetSku -Pricing $pricing -FeatureGaps $featureGaps
        Write-Banner "Analysis complete (AnalyzeOnly mode — no files generated)"
        return
    }

    # ── Step 5: Confirmation gate ──
    if (-not $Force) {
        $confirmed = Show-ConfirmationSummary -SourceConfig $sourceConfig -TargetSku $targetSku -Pricing $pricing -FeatureGaps $featureGaps
        if (-not $confirmed) {
            Write-Warn "Migration cancelled by user."
            return
        }
    }

    # ── Step 6: Transform template ──
    Write-Section "Step 6: Transforming template"
    $migratedTemplate = $null
    $migratedParameters = $null
    $migratedBicep = $null
    $migratedBicepParam = $null
    $migratedTerraform = $null

    switch ($sourceConfig.Format) {
        "ARM" {
            $migratedTemplate = Convert-ArmTemplate -SourceConfig $sourceConfig -TargetSku $targetSku -ClusteringPolicy $ClusteringPolicy -SourceTemplate $sourceConfig._RawTemplate -SourceParameters $sourceConfig._RawParameters
            if ($sourceConfig._RawParameters -and -not $SkipParameterOutput) {
                $migratedParameters = Convert-ParametersFile -SourceConfig $sourceConfig -TargetSku $targetSku -ClusteringPolicy $ClusteringPolicy -SourceParameters $sourceConfig._RawParameters
            }
        }
        "Bicep" {
            # First transform as ARM, then convert to Bicep
            $migratedTemplate = Convert-ArmTemplate -SourceConfig $sourceConfig -TargetSku $targetSku -ClusteringPolicy $ClusteringPolicy -SourceTemplate $sourceConfig._RawTemplate -SourceParameters $sourceConfig._RawParameters
            $migratedBicep = Convert-BicepTemplate -ArmResult $migratedTemplate
            if ($sourceConfig._RawParameters -and -not $SkipParameterOutput) {
                $migratedParameters = Convert-ParametersFile -SourceConfig $sourceConfig -TargetSku $targetSku -ClusteringPolicy $ClusteringPolicy -SourceParameters $sourceConfig._RawParameters
                # Convert to .bicepparam format if source used .bicepparam
                if ($sourceConfig._ParametersFormat -eq 'Bicepparam' -and $migratedBicep) {
                    $bicepBaseName = [System.IO.Path]::GetFileNameWithoutExtension($TemplatePath) -replace '\.parameters$', ''
                    $migratedBicepParam = Convert-BicepParamFile -MigratedParameters $migratedParameters -BicepTemplateName "$bicepBaseName.amr.bicep"
                }
            }
        }
        "Terraform" {
            $migratedTerraform = Convert-TerraformTemplate -SourceConfig $sourceConfig -TargetSku $targetSku -ClusteringPolicy $ClusteringPolicy
        }
    }
    Write-Success "Template transformation complete"

    # ── Step 7: Write output ──
    Write-Section "Step 7: Writing migrated files"
    $resolvedOutputDir = $OutputDirectory
    if (-not $resolvedOutputDir) {
        $resolvedOutputDir = Join-Path (Split-Path $TemplatePath -Parent) "migrated"
    }

    $outputFiles = Write-MigratedOutput `
        -SourcePath $TemplatePath `
        -OutputDirectory $resolvedOutputDir `
        -Format $sourceConfig.Format `
        -MigratedTemplate $migratedTemplate `
        -MigratedParameters $migratedParameters `
        -MigratedBicep $migratedBicep `
        -MigratedBicepParam $migratedBicepParam `
        -MigratedTerraform $migratedTerraform

    foreach ($f in $outputFiles) {
        Write-Success "Written: $($f.Path) ($($f.Type))"
    }

    # ── Step 9: Post-migration report ──
    Write-MigrationReport -SourceConfig $sourceConfig -TargetSku $targetSku -Pricing $pricing -FeatureGaps $featureGaps -OutputFiles $outputFiles

    # ── Return structured result if requested ──
    if ($ReturnObject) {
        return [PSCustomObject]@{
            SourceConfig      = $sourceConfig
            TargetSku         = $targetSku
            Pricing           = $pricing
            FeatureGaps       = $featureGaps
            OutputFiles       = $outputFiles
            MigrationReport = [PSCustomObject]@{
                SkuName           = $targetSku.Name
                Endpoint          = "<name>.$Region.redis.azure.net"
                Port              = 10000
                FeaturesAvailable = @("Redis 7.4", "RedisJSON", "RediSearch", "RedisBloom", "RedisTimeSeries", "Active geo-replication", "Managed persistence", "Zone redundancy", "Import/Export", "Online scaling")
                FeaturesRemoved   = ($featureGaps | Where-Object { $_.Status -eq "Removed" } | ForEach-Object { $_.Feature })
            }
        }
    }
}

# Store switch params at script scope for nested function access
$script:ForceMode = $Force
$script:ReturnObject = $ReturnObject

# Run
Main
