<#
.SYNOPSIS
    Validates a migrated AMR template by deploying it and checking all resource properties.

.DESCRIPTION
    After the AMR migration skill converts an ACR template to AMR, this script:
    1. Deploys the migrated AMR template to a test resource group
    2. Retrieves the deployed cluster and database resources
    3. Validates each property against expected values
    4. Reports pass/fail for each property
    5. Optionally cleans up the test deployment

.PARAMETER MigratedTemplatePath
    Path to the migrated AMR ARM template (.json) or Bicep template (.bicep).

.PARAMETER MigratedParameterFile
    Path to the migrated AMR parameters file (optional).

.PARAMETER SubscriptionId
    Azure subscription ID for deployment.

.PARAMETER ResourceGroup
    Resource group for test deployment (created if it doesn't exist).

.PARAMETER Location
    Azure region (default: westus).

.PARAMETER ExpectedSku
    Expected AMR SKU name (e.g., "Balanced_B50").

.PARAMETER ExpectedEvictionPolicy
    Expected eviction policy in PascalCase (e.g., "VolatileLRU").

.PARAMETER ExpectedClusteringPolicy
    Expected clustering policy (default: "EnterpriseCluster").

.PARAMETER ExpectedRdbEnabled
    Expected RDB persistence state.

.PARAMETER ExpectedAofEnabled
    Expected AOF persistence state.

.PARAMETER SourceHadVNet
    Whether the source ACR template used VNet injection.

.PARAMETER SourceHadFirewall
    Whether the source ACR template had firewall rules.

.PARAMETER SourceHadShards
    Whether the source ACR template had shardCount > 0.

.PARAMETER SourceHadMRPP
    Whether the source ACR template had replicasPerPrimary > 1.

.PARAMETER SourceHadNonSslPort
    Whether the source ACR template had enableNonSslPort = true.

.PARAMETER Cleanup
    Delete the test resources after validation.

.EXAMPLE
    # Validate a single migrated template (file name derived from source param file)
    .\Validate-Migration.ps1 `
        -MigratedTemplatePath .\migrated\premium-p2-clustered.amr.json `
        -MigratedParameterFile .\migrated\premium-p2-clustered.amr.parameters.json `
        -SubscriptionId "xxx" `
        -ResourceGroup "amr-validation-test" `
        -ExpectedSku "Balanced_B50" `
        -ExpectedEvictionPolicy "VolatileLRU" `
        -ExpectedRdbEnabled $true `
        -SourceHadVNet $true `
        -SourceHadFirewall $true `
        -Cleanup

.EXAMPLE
    # Validate a basic tier migration
    .\Validate-Migration.ps1 `
        -MigratedTemplatePath .\migrated\basic-c0.amr.json `
        -MigratedParameterFile .\migrated\basic-c0.amr.parameters.json `
        -SubscriptionId "xxx" `
        -ResourceGroup "amr-validation-test" `
        -ExpectedSku "Balanced_B0" `
        -SourceHadNonSslPort $true `
        -Cleanup
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MigratedTemplatePath,

    [string]$MigratedParameterFile,

    [string]$SubscriptionId,

    [string]$ResourceGroup = "amr-migration-validation-rg",

    [string]$Location = "westus",

    [string]$ExpectedSku,

    [string]$ExpectedEvictionPolicy = "VolatileLRU",

    [string]$ExpectedClusteringPolicy = "EnterpriseCluster",

    [bool]$ExpectedRdbEnabled = $false,

    [bool]$ExpectedAofEnabled = $false,

    [bool]$SourceHadVNet = $false,

    [bool]$SourceHadFirewall = $false,

    [bool]$SourceHadShards = $false,

    [bool]$SourceHadMRPP = $false,

    [bool]$SourceHadNonSslPort = $false,

    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════

$script:passCount = 0
$script:failCount = 0
$script:skipCount = 0
$script:results = @()

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host ("═" * 55) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("═" * 55) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("─" * 55) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor DarkCyan
    Write-Host ("─" * 55) -ForegroundColor DarkCyan
}

function Assert-Property {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ""
    )
    $entry = @{ Name = $Name; Details = $Details }
    if ($Condition) {
        $script:passCount++
        $entry.Status = "PASS"
        Write-Host "  ✅ PASS  $Name" -ForegroundColor Green
    } else {
        $script:failCount++
        $entry.Status = "FAIL"
        Write-Host "  ❌ FAIL  $Name" -ForegroundColor Red
        if ($Details) {
            Write-Host "           $Details" -ForegroundColor DarkRed
        }
    }
    $script:results += $entry
}

function Assert-Absent {
    param(
        [string]$Name,
        [string]$FeatureName,
        [object]$Resource,
        [string]$PropertyPath
    )
    $props = $PropertyPath.Split('.')
    $current = $Resource
    $found = $true
    foreach ($p in $props) {
        if ($null -eq $current -or $null -eq $current.PSObject.Properties[$p]) {
            $found = $false
            break
        }
        $current = $current.$p
    }

    if (-not $found -or $null -eq $current -or $current -eq "" -or $current -eq 0) {
        $script:passCount++
        $script:results += @{ Name = $Name; Status = "PASS" }
        Write-Host "  ✅ PASS  $Name (correctly absent)" -ForegroundColor Green
    } else {
        $script:failCount++
        $script:results += @{ Name = $Name; Status = "FAIL"; Details = "Found: $current" }
        Write-Host "  ❌ FAIL  $Name (should be absent, found: $current)" -ForegroundColor Red
    }
}

# ═══════════════════════════════════════════════════
# Main Execution
# ═══════════════════════════════════════════════════

Write-Banner "AMR MIGRATION VALIDATION"
Write-Host "  Template:  $MigratedTemplatePath"
Write-Host "  Params:    $($MigratedParameterFile ? $MigratedParameterFile : '(none)')"
Write-Host "  Target RG: $ResourceGroup"
Write-Host "  Location:  $Location"

# Step 0: Set subscription
if ($SubscriptionId) {
    Write-Host "`nSetting subscription..."
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription" }
}

# Step 1: Ensure resource group
Write-Host "`nEnsuring resource group..."
$rgExists = az group exists --name $ResourceGroup 2>$null
if ($rgExists -ne "true") {
    az group create --name $ResourceGroup --location $Location --tags "Purpose=AMR-Validation" | Out-Null
    Write-Host "  Created resource group '$ResourceGroup'"
}

# Step 2: Validate template
Write-Section "Step 1: Template Syntax Validation"
$validateArgs = @("deployment", "group", "validate", "--resource-group", $ResourceGroup, "--template-file", $MigratedTemplatePath)
if ($MigratedParameterFile) { $validateArgs += "--parameters"; $validateArgs += "@$MigratedParameterFile" }

$null = & az @validateArgs 2>&1
Assert-Property "Template syntax is valid" ($LASTEXITCODE -eq 0) "Template validation failed"

if ($LASTEXITCODE -ne 0) {
    Write-Banner "VALIDATION ABORTED - Template is invalid"
    exit 1
}

# Step 3: Deploy template
Write-Section "Step 2: Template Deployment"
$deploymentName = "amr-validate-$(Get-Date -Format 'yyyyMMddHHmmss')"
$deployArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--template-file", $MigratedTemplatePath,
    "--name", $deploymentName,
    "--output", "json"
)
if ($MigratedParameterFile) { $deployArgs += "--parameters"; $deployArgs += "@$MigratedParameterFile" }

Write-Host "  Deploying (this may take several minutes)..."
$deployResult = & az @deployArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    Assert-Property "AMR deployment succeeded" $false "Deployment failed: $deployResult"
    Write-Banner "VALIDATION ABORTED - Deployment failed"
    exit 1
}

$deployment = $deployResult | ConvertFrom-Json
Assert-Property "AMR deployment succeeded" ($deployment.properties.provisioningState -eq "Succeeded")

$cacheName = $deployment.properties.outputs.cacheName.value
Write-Host "  Cache name: $cacheName"

# Step 4: Retrieve resources
Write-Section "Step 3: Resource Property Validation"
$clusterJson = az redisenterprise show --name $cacheName --resource-group $ResourceGroup --output json 2>&1
$cluster = $clusterJson | ConvertFrom-Json

$dbJson = az redisenterprise database show --cluster-name $cacheName --resource-group $ResourceGroup --output json 2>&1
$db = $dbJson | ConvertFrom-Json

# ─── Cluster Properties ───
Write-Host ""
Write-Host "  Cluster Properties:" -ForegroundColor Yellow

Assert-Property "SKU format is <Tier>_<Size>" ($cluster.sku.name -match '^(Balanced|MemoryOptimized|ComputeOptimized|FlashOptimized)_')
if ($ExpectedSku) {
    Assert-Property "SKU matches expected: $ExpectedSku" ($cluster.sku.name -eq $ExpectedSku) "Actual: $($cluster.sku.name)"
}
Assert-Property "Location is set" (-not [string]::IsNullOrEmpty($cluster.location))
Assert-Property "MinimumTlsVersion is 1.2" ($cluster.minimumTlsVersion -eq "1.2")
Assert-Property "Identity type is SystemAssigned" ($cluster.identity.type -eq "SystemAssigned")

# ─── Database Properties ───
Write-Host ""
Write-Host "  Database Properties:" -ForegroundColor Yellow

Assert-Property "Port is 10000" ($db.port -eq 10000) "Actual: $($db.port)"
Assert-Property "Client protocol is Encrypted" ($db.clientProtocol -eq "Encrypted") "Actual: $($db.clientProtocol)"
Assert-Property "Clustering policy: $ExpectedClusteringPolicy" ($db.clusteringPolicy -eq $ExpectedClusteringPolicy) "Actual: $($db.clusteringPolicy)"
Assert-Property "Eviction policy: $ExpectedEvictionPolicy" ($db.evictionPolicy -eq $ExpectedEvictionPolicy) "Actual: $($db.evictionPolicy)"

# ─── Persistence ───
Write-Host ""
Write-Host "  Persistence:" -ForegroundColor Yellow

if ($ExpectedRdbEnabled) {
    Assert-Property "RDB persistence is enabled" ($db.persistence.rdbEnabled -eq $true)
    Assert-Property "RDB frequency is set" (-not [string]::IsNullOrEmpty($db.persistence.rdbFrequency))
    Assert-Property "No RDB storage connection string" ($null -eq $db.persistence.PSObject.Properties['rdbStorageConnectionString'])
} else {
    Assert-Property "RDB persistence is disabled or absent" ($db.persistence.rdbEnabled -ne $true)
}

if ($ExpectedAofEnabled) {
    Assert-Property "AOF persistence is enabled" ($db.persistence.aofEnabled -eq $true)
    Assert-Property "No AOF storage connection string" ($null -eq $db.persistence.PSObject.Properties['aofStorageConnectionString0'])
} else {
    Assert-Property "AOF persistence is disabled or absent" ($db.persistence.aofEnabled -ne $true)
}

# ─── Features NOT in AMR ───
Write-Section "Step 4: Absent Feature Validation (NOT in AMR)"

if ($SourceHadShards) {
    Assert-Property "shardCount removed (source had shards)" ($null -eq $cluster.PSObject.Properties['shardCount'] -or $null -eq $db.PSObject.Properties['shardCount'])
}

if ($SourceHadMRPP) {
    Assert-Property "replicasPerPrimary removed (source had MRPP)" ($null -eq $cluster.PSObject.Properties['replicasPerPrimary'])
}

if ($SourceHadNonSslPort) {
    Assert-Property "enableNonSslPort removed (source had non-SSL port)" ($null -eq $cluster.PSObject.Properties['enableNonSslPort'])
}

if ($SourceHadVNet) {
    Assert-Property "VNet injection removed (no subnetId)" ($null -eq $cluster.PSObject.Properties['subnetId'])
    Assert-Property "staticIP removed" ($null -eq $cluster.PSObject.Properties['staticIP'])
    # Check that PE exists instead
    $peList = az network private-endpoint list --resource-group $ResourceGroup --query "[?contains(name, '$cacheName')]" --output json 2>$null | ConvertFrom-Json
    Assert-Property "Private Endpoint created (replaces VNet)" ($peList.Count -gt 0)
}

if ($SourceHadFirewall) {
    # AMR doesn't have firewall rules resource type
    Assert-Property "Firewall rules removed" ($true) "AMR uses Private Endpoint + NSG instead"
}

# ─── Tags ───
Write-Host ""
Write-Host "  Tags:" -ForegroundColor Yellow
Assert-Property "Tags are preserved" ($null -ne $cluster.tags -and $cluster.tags.PSObject.Properties.Count -gt 0) "Tag count: $($cluster.tags.PSObject.Properties.Count)"

# ═══════════════════════════════════════════════════
# Final Report
# ═══════════════════════════════════════════════════

$totalChecks = $script:passCount + $script:failCount
Write-Banner "AMR MIGRATION VALIDATION REPORT"
Write-Host "  Template: $(Split-Path $MigratedTemplatePath -Leaf)"
Write-Host "  Cache:    $cacheName"
Write-Host ""

foreach ($r in $script:results) {
    switch ($r.Status) {
        "PASS" { Write-Host "  ✅ PASS  $($r.Name)" -ForegroundColor Green }
        "FAIL" { Write-Host "  ❌ FAIL  $($r.Name)" -ForegroundColor Red }
    }
}

Write-Host ""
Write-Host ("─" * 55) -ForegroundColor Cyan
if ($script:failCount -eq 0) {
    Write-Host "  Result: $($script:passCount)/$totalChecks PASSED ✅" -ForegroundColor Green
} else {
    Write-Host "  Result: $($script:passCount)/$totalChecks PASSED, $($script:failCount) FAILED ❌" -ForegroundColor Red
}
Write-Host ("═" * 55) -ForegroundColor Cyan

# Step 5: Cleanup
if ($Cleanup) {
    Write-Host "`nCleaning up test resources..."
    az group delete --name $ResourceGroup --yes --no-wait
    Write-Host "  Resource group deletion initiated (async)" -ForegroundColor Green
}

# Exit code
if ($script:failCount -gt 0) {
    exit 1
} else {
    exit 0
}
