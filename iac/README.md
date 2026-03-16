# ACR → AMR Infrastructure-as-Code Migration Guide

Migrate Azure Cache for Redis (ACR) templates to Azure Managed Redis (AMR) using the standalone PowerShell script — no AI or Copilot dependency required.

> **Scope**: ACR Basic (C0–C6), Standard (C0–C6), and Premium (P1–P5) tiers only. Enterprise/Enterprise Flash is **not** covered.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Supported Formats](#supported-formats)
- [Parameter Reference](#parameter-reference)
- [Usage Examples](#usage-examples)
  - [ARM JSON Templates](#arm-json-templates)
  - [ARM with Parameters File](#arm-with-parameters-file)
  - [Bicep Templates](#bicep-templates)
  - [Terraform Templates](#terraform-templates)
  - [CI/CD Pipelines](#cicd-pipelines)
  - [Analysis Only (Dry Run)](#analysis-only-dry-run)
- [What Gets Transformed](#what-gets-transformed)
  - [Resource Split](#resource-split)
  - [SKU Mapping](#sku-mapping)
  - [Property Transformations](#property-transformations)
  - [Removed Properties](#removed-properties)
  - [New Defaults](#new-defaults)
- [Post-Migration Validation](#post-migration-validation)
  - [Quick Validation (Template Syntax)](#quick-validation-template-syntax)
  - [Full Validation (Deploy + Assert)](#full-validation-deploy--assert)
  - [Validation Checks](#validation-checks)
  - [Validation Examples](#validation-examples)
- [Migration Report](#migration-report)
- [Clustering Policy Guidance](#clustering-policy-guidance)
- [Best Practice Recommendations](#best-practice-recommendations)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **PowerShell 7.0+** | Cross-platform (Windows, macOS, Linux). Install: https://aka.ms/install-powershell |
| **Azure CLI** *(optional)* | Required only for `.bicep` input/output. Install: https://learn.microsoft.com/cli/azure/install-azure-cli |
| **Azure CLI Bicep** *(optional)* | Required only for `.bicep` input/output. Run: `az bicep install` |
| **Azure subscription** *(optional)* | Required only for post-migration validation deployment |

Verify your setup:

```powershell
# Check PowerShell version (must be 7.0+)
$PSVersionTable.PSVersion

# Check Azure CLI (only needed for Bicep)
az version
az bicep version
```

---

## Quick Start

```powershell
# 1. Clone the repo
git clone https://github.com/AzureManagedRedis/amr-migration-skill
cd amr-migration-skill

# 2. Run the migration (interactive — prompts for confirmation)
.\Convert-AcrToAmr.ps1 -TemplatePath .\my-acr-template.json -Region westus2

# 3. Review output in ./migrated/ folder
Get-ChildItem .\migrated\
```

That's it. The script will:
1. Parse your ACR template and detect SKU, features, and configuration
2. Map to the recommended AMR SKU with pricing comparison
3. Show a feature gap analysis (what's changed, removed, or new)
4. Ask for confirmation before proceeding
5. Generate the migrated AMR template(s) in `./migrated/`
6. Display a post-migration summary report

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    Convert-AcrToAmr.ps1                         │
│                                                                 │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────────┐  │
│  │  Parse    │──▶│  Map SKU │──▶│  Pricing │──▶│  Feature   │  │
│  │  Template │   │  Target  │   │  Compare │   │  Gap Check │  │
│  └──────────┘   └──────────┘   └──────────┘   └────────────┘  │
│       │                                              │         │
│       │              CONFIRMATION GATE                │         │
│       │         (review before proceeding)            │         │
│       ▼                                              ▼         │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────────┐  │
│  │ Transform│──▶│  Write   │──▶│ Migration│──▶│  Output    │  │
│  │ Template │   │  Files   │   │  Report  │   │  Files     │  │
│  └──────────┘   └──────────┘   └──────────┘   └────────────┘  │
│                                                                 │
│  Input:  .json / .bicep / .tf     Output:  migrated/ folder    │
│  Mode:   Interactive or -Force    Report:  .migration-report   │
└─────────────────────────────────────────────────────────────────┘
```

**Key design principles:**
- **Deterministic** — all mappings are table lookups, no AI/LLM involved
- **Self-contained** — single script file, no module dependencies
- **Cross-platform** — runs on Windows, macOS, and Linux with PowerShell 7+
- **Non-destructive** — source files are never modified; output goes to a separate directory

---

## Supported Formats

| Format | Input Extension | Output | Notes |
|--------|----------------|--------|-------|
| **ARM JSON** | `.json` | ARM JSON (cluster + database) | Fully supported. Parameters file migrated if provided. |
| **Bicep** | `.bicep` | Bicep (via `az bicep decompile`) or ARM JSON fallback | Requires Azure CLI with Bicep. Falls back to ARM JSON if `az bicep` unavailable. |
| **Terraform** | `.tf` | Terraform HCL | Generates `azurerm_redis_enterprise_cluster` + `azurerm_redis_enterprise_database` resources. |

---

## Parameter Reference

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-TemplatePath` | String | ✅ | — | Path to source ACR template (`.json`, `.bicep`, `.tf`) |
| `-ParametersPath` | String | — | — | Path to ARM/Bicep parameters file (`.json`, `.bicepparam`) |
| `-Region` | String | ✅ | — | Azure region for pricing lookup (e.g., `westus2`, `eastus`) |
| `-OutputDirectory` | String | — | `./migrated/` | Custom output folder for generated files |
| `-ClusteringPolicy` | String | — | `OSSCluster` | AMR clustering policy: `OSSCluster` (recommended) or `EnterpriseCluster` |
| `-TargetSku` | String | — | Auto-detected | Override the auto-detected AMR SKU (e.g., `Balanced_B50`) |
| `-Currency` | String | — | `USD` | Currency code for pricing display |
| `-Force` | Switch | — | `$false` | Skip interactive confirmation gate |
| `-SkipPricing` | Switch | — | `$false` | Skip Azure Retail Pricing API calls |
| `-AnalyzeOnly` | Switch | — | `$false` | Run analysis only (Steps 1–4). No transformation or file output. |
| `-ReturnObject` | Switch | — | `$false` | Return structured `PSCustomObject` instead of console output |
| `-WhatIf` | Switch | — | `$false` | Show what would be done without writing files |

---

## Usage Examples

### ARM JSON Templates

```powershell
# Interactive mode — review pricing + feature gaps before confirming
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -Region westus2
```

### ARM with Parameters File

When your deployment uses separate template + parameters files, provide **both** so the script reads actual deployed values (SKU, shard count, region, etc.) from the parameters:

```powershell
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -ParametersPath .\acr-cache.parameters.json `
    -Region westus2
```

**Output**: Both a migrated template and a migrated parameters file are generated in the output directory.

### Bicep Templates

```powershell
# Requires: az bicep install
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\main.bicep `
    -Region eastus `
    -Force
```

The script builds the Bicep to ARM JSON internally, transforms it, then decompiles back to Bicep. If `az bicep decompile` fails, it outputs ARM JSON with a warning.

### Terraform Templates

```powershell
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\main.tf `
    -Region eastus `
    -Force
```

**Output**: Terraform HCL using `azurerm_redis_enterprise_cluster` and `azurerm_redis_enterprise_database` resources.

### CI/CD Pipelines

For non-interactive use in pipelines:

```powershell
# Skip confirmation and pricing API calls for faster execution
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -Region westus2 `
    -Force `
    -SkipPricing
```

**Exit codes**: `0` = success, `1` = error.

### Analysis Only (Dry Run)

Get a full analysis without generating any files:

```powershell
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -Region westus2 `
    -AnalyzeOnly
```

For programmatic consumption (e.g., from a wrapper script or Copilot skill):

```powershell
$analysis = .\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -Region westus2 `
    -AnalyzeOnly `
    -ReturnObject

# Inspect the result
$analysis.SourceConfig    # Parsed ACR configuration
$analysis.TargetSku       # Recommended AMR SKU
$analysis.Pricing         # Cost comparison
$analysis.FeatureGaps     # Feature gap analysis
```

---

## What Gets Transformed

### Resource Split

A single ACR resource becomes **two** AMR resources:

```
┌──────────────────────────────┐         ┌──────────────────────────────────┐
│  Microsoft.Cache/redis       │         │  Microsoft.Cache/redisEnterprise │
│  (ACR - single resource)     │  ────▶  │  (AMR cluster)                   │
│                              │         ├──────────────────────────────────┤
│                              │         │  Microsoft.Cache/                │
│                              │         │    redisEnterprise/databases     │
│                              │         │  (AMR database)                  │
└──────────────────────────────┘         └──────────────────────────────────┘
```

| Property | Goes to Cluster | Goes to Database |
|----------|:---------------:|:----------------:|
| SKU | ✅ (compound name like `Balanced_B50`) | — |
| Location | ✅ | — |
| Tags | ✅ | — |
| Identity | ✅ | — |
| Zones | ✅ | — |
| Eviction policy | — | ✅ (PascalCase) |
| Persistence | — | ✅ (restructured) |
| Clustering policy | — | ✅ |
| Port | — | ✅ (always 10000) |
| Client protocol | — | ✅ (always "Encrypted") |

### SKU Mapping

The script contains deterministic lookup tables covering all ACR → AMR SKU mappings:

**Basic/Standard (C0–C6):**

| ACR SKU | ACR Memory | AMR SKU | AMR Usable Memory |
|---------|-----------|---------|-------------------|
| C0 | 250 MB | Balanced_B0 | 0.5 GB |
| C1 | 1 GB | Balanced_B1 | 2.4 GB |
| C2 | 2.5 GB | Balanced_B3 | 4.8 GB |
| C3 | 6 GB | Balanced_B5 | 9.6 GB |
| C4 | 13 GB | MemoryOptimized_M10 | 9.6 GB |
| C5 | 26 GB | MemoryOptimized_M20 | 19.2 GB |
| C6 | 53 GB | MemoryOptimized_M50 | 38.4 GB |

**Premium Non-Clustered (P1–P5):**

| ACR SKU | ACR Memory | AMR SKU |
|---------|-----------|---------|
| P1 | 6 GB | Balanced_B5 |
| P2 | 13 GB | Balanced_B10 |
| P3 | 26 GB | Balanced_B20 |
| P4 | 53 GB | Balanced_B50 |
| P5 | 120 GB | Balanced_B100 |

**Premium Clustered**: Maps based on SKU + shard count (up to 15 shards). For example, P2 with 3 shards → `Balanced_B50`.

Override the auto-detected SKU if needed:

```powershell
.\Convert-AcrToAmr.ps1 -TemplatePath .\acr.json -Region westus2 -TargetSku Balanced_B100
```

### Property Transformations

| ACR Property | AMR Equivalent | Transformation |
|-------------|---------------|----------------|
| `sku: { name, family, capacity }` | `sku: { name: "Balanced_B50" }` | 3-field → compound name |
| `apiVersion: "2023-08-01"` | `apiVersion: "2025-07-01"` | Updated to GA version |
| `maxmemory-policy: "volatile-lru"` | `evictionPolicy: "VolatileLRU"` | kebab-case → PascalCase |
| `rdb-backup-enabled: true` | `persistence: { rdbEnabled: true }` | Flat → nested object |
| `rdb-backup-frequency: "60"` | `persistence: { rdbFrequency: "1h" }` | Minutes (string) → duration |
| `rdb-storage-connection-string` | *(removed)* | AMR manages persistence storage |
| `subnetId` (VNet injection) | Private Endpoint resource | See [Networking](#removed-properties) |
| `enableNonSslPort` | *(removed)* | AMR is TLS-only on port 10000 |

### Removed Properties

These ACR properties have no AMR equivalent and are removed during migration:

| Removed Property | Reason | Post-Migration Action |
|-----------------|--------|----------------------|
| `enableNonSslPort` | AMR is TLS-only (port 10000) | Update clients to use TLS |
| `shardCount` | AMR manages clustering internally | No action needed |
| `replicasPerPrimary` (MRPP) | Not supported in AMR | Use active geo-replication instead |
| `redisVersion` | AMR runs Redis 7.4 (not configurable) | No action needed |
| `staticIP` | Not supported | Use Private Endpoint DNS |
| `subnetId` (VNet injection) | Not supported | Configure Private Endpoint |
| Firewall rules | Not supported | Use Private Endpoint + NSG |
| `redisConfiguration.*` (most) | Restructured into database properties | Handled by script |

### New Defaults

These values are set on every migrated AMR template:

| Property | Value | Location |
|----------|-------|----------|
| `port` | `10000` | Database |
| `clientProtocol` | `"Encrypted"` | Database |
| `clusteringPolicy` | `"OSSCluster"` (default) | Database |
| `minimumTlsVersion` | `"1.2"` | Cluster |
| `identity.type` | `"SystemAssigned"` | Cluster |

---

## Post-Migration Validation

After generating migrated templates, validate them before deploying to production.

### Quick Validation (Template Syntax)

Use Azure CLI to validate the template without deploying:

```powershell
az deployment group validate `
    --resource-group <test-rg> `
    --template-file .\migrated\acr-cache.amr.json `
    --parameters @.\migrated\acr-cache.amr.parameters.json
```

### Full Validation (Deploy + Assert)

The `Validate-Migration.ps1` script deploys the migrated template to a test resource group and asserts every property matches expectations:

```powershell
.\Validate-Migration.ps1 `
    -MigratedTemplatePath .\migrated\acr-cache.amr.json `
    -MigratedParameterFile .\migrated\acr-cache.amr.parameters.json `
    -SubscriptionId "<your-subscription-id>" `
    -ResourceGroup "amr-validation-test" `
    -Location westus2 `
    -ExpectedSku "Balanced_B50" `
    -ExpectedEvictionPolicy "VolatileLRU" `
    -ExpectedClusteringPolicy "OSSCluster" `
    -ExpectedRdbEnabled $true `
    -SourceHadVNet $true `
    -SourceHadFirewall $true `
    -Cleanup
```

> **Note**: Deployment takes several minutes. The `-Cleanup` flag deletes the test resource group afterwards.

### Validation Checks

The validation script performs the following assertions:

**Template Validation:**

| Check | What It Verifies |
|-------|-----------------|
| Template syntax | ARM/Bicep template passes `az deployment group validate` |
| Deployment success | Template deploys successfully with `provisioningState: Succeeded` |

**Cluster Properties:**

| Check | What It Verifies |
|-------|-----------------|
| SKU format | Name matches `<Tier>_<Size>` pattern (e.g., `Balanced_B50`) |
| SKU value | Matches the expected SKU from migration mapping |
| Location | Region is set correctly |
| TLS version | `minimumTlsVersion` is `1.2` |
| Identity | `SystemAssigned` managed identity is configured |

**Database Properties:**

| Check | What It Verifies |
|-------|-----------------|
| Port | `10000` (AMR standard port) |
| Client protocol | `Encrypted` (TLS-only) |
| Clustering policy | Matches expected (`OSSCluster` or `EnterpriseCluster`) |
| Eviction policy | PascalCase format (e.g., `VolatileLRU`) |

**Persistence:**

| Check | What It Verifies |
|-------|-----------------|
| RDB enabled/disabled | Matches source configuration |
| RDB frequency | Set when RDB is enabled |
| No storage connection string | AMR manages storage internally |
| AOF enabled/disabled | Matches source configuration |

**Absent Feature Validation:**

| Check | What It Verifies |
|-------|-----------------|
| `shardCount` removed | Not present on deployed resource |
| `replicasPerPrimary` removed | Not present on deployed resource |
| `enableNonSslPort` removed | Not present on deployed resource |
| VNet injection removed | No `subnetId` on cluster |
| Private Endpoint created | PE exists when source had VNet injection |
| Firewall rules removed | No firewall rules resource |

**Tags:**

| Check | What It Verifies |
|-------|-----------------|
| Tags preserved | All source tags carried forward to AMR cluster |

### Validation Examples

**Basic C0 with non-SSL port:**

```powershell
.\Validate-Migration.ps1 `
    -MigratedTemplatePath .\migrated\basic-c0.amr.json `
    -SubscriptionId "xxx" `
    -ResourceGroup "amr-validation-test" `
    -ExpectedSku "Balanced_B0" `
    -SourceHadNonSslPort $true `
    -Cleanup
```

**Premium P2 clustered with VNet + persistence:**

```powershell
.\Validate-Migration.ps1 `
    -MigratedTemplatePath .\migrated\premium-p2.amr.json `
    -MigratedParameterFile .\migrated\premium-p2.amr.parameters.json `
    -SubscriptionId "xxx" `
    -ResourceGroup "amr-validation-test" `
    -ExpectedSku "Balanced_B50" `
    -ExpectedEvictionPolicy "VolatileLRU" `
    -ExpectedClusteringPolicy "OSSCluster" `
    -ExpectedRdbEnabled $true `
    -SourceHadVNet $true `
    -SourceHadFirewall $true `
    -SourceHadShards $true `
    -Cleanup
```

### Validation Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-MigratedTemplatePath` | String | *(required)* | Path to migrated AMR template |
| `-MigratedParameterFile` | String | — | Path to migrated parameters file |
| `-SubscriptionId` | String | — | Azure subscription for deployment |
| `-ResourceGroup` | String | `amr-migration-validation-rg` | Test resource group name |
| `-Location` | String | `westus` | Azure region |
| `-ExpectedSku` | String | — | Expected AMR SKU name |
| `-ExpectedEvictionPolicy` | String | `VolatileLRU` | Expected eviction policy (PascalCase) |
| `-ExpectedClusteringPolicy` | String | `EnterpriseCluster` | Expected clustering policy |
| `-ExpectedRdbEnabled` | Bool | `$false` | Whether RDB persistence should be enabled |
| `-ExpectedAofEnabled` | Bool | `$false` | Whether AOF persistence should be enabled |
| `-SourceHadVNet` | Bool | `$false` | Source used VNet injection |
| `-SourceHadFirewall` | Bool | `$false` | Source had firewall rules |
| `-SourceHadShards` | Bool | `$false` | Source had shardCount > 0 |
| `-SourceHadMRPP` | Bool | `$false` | Source had replicasPerPrimary > 1 |
| `-SourceHadNonSslPort` | Bool | `$false` | Source had enableNonSslPort = true |
| `-Cleanup` | Switch | `$false` | Delete test resources after validation |

---

## End-to-End Workflow

Here's a complete migration + validation workflow:

```powershell
# Step 1: Analyze (dry run)
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -ParametersPath .\acr-cache.parameters.json `
    -Region westus2 `
    -AnalyzeOnly

# Step 2: Review output, then migrate
.\Convert-AcrToAmr.ps1 `
    -TemplatePath .\acr-cache.json `
    -ParametersPath .\acr-cache.parameters.json `
    -Region westus2

# Step 3: Validate the migrated template (template syntax only)
az deployment group validate `
    --resource-group "amr-validation-rg" `
    --template-file .\migrated\acr-cache.amr.json `
    --parameters @.\migrated\acr-cache.amr.parameters.json

# Step 4: Full deployment validation
.\Validate-Migration.ps1 `
    -MigratedTemplatePath .\migrated\acr-cache.amr.json `
    -MigratedParameterFile .\migrated\acr-cache.amr.parameters.json `
    -SubscriptionId "<sub-id>" `
    -ResourceGroup "amr-validation-test" `
    -Location westus2 `
    -ExpectedSku "Balanced_B50" `
    -SourceHadVNet $true `
    -Cleanup

# Step 5: Deploy to production
az deployment group create `
    --resource-group "my-production-rg" `
    --template-file .\migrated\acr-cache.amr.json `
    --parameters @.\migrated\acr-cache.amr.parameters.json
```

---

## Migration Report

Every migration generates a report file (`.migration-report`) alongside the output files:

```
═══════════════════════════════════════════════════
  ACR → AMR Migration Report
═══════════════════════════════════════════════════

Source: ACR Premium P2 (13 GB)
  Shards: 3
Target: Balanced_B50 (60 GB advertised, 48 GB usable)
  Connections: 25,000 max
  vCPUs: 4

Pricing:
  ACR: $X,XXX.XX/month
  AMR: $X,XXX.XX/month
  Delta: +/- $XXX.XX

New capabilities on AMR:
  ✅ Redis Stack modules (JSON, Search, TimeSeries, Bloom)
  ✅ Active geo-replication
  ✅ Managed persistence
  ✅ Redis 7.4

Features not carried over:
  ❌ VNet injection — use Private Endpoint instead
  ❌ Firewall rules — use Private Endpoint + NSG

Recommendations:
  ⚠️  Enable Entra ID auth and disable access keys (accessKeysAuthentication: Disabled)
  ⚠️  Set publicNetworkAccess: Disabled and use Private Endpoints

Output files:
  📄 acr-cache.amr.json (ARM Template)
  📄 acr-cache.amr.parameters.json (Parameters)
  📄 acr-cache.amr.migration-report (This report)
```

---

---

## Clustering Policy Guidance

| Policy | Best For | Trade-offs |
|--------|----------|------------|
| **`OSSCluster`** *(default, recommended)* | Maximum throughput and lowest latency | Requires cluster-aware Redis client (most modern clients support this) |
| **`EnterpriseCluster`** | Backward compatibility with non-cluster-aware clients | Single endpoint; may have slightly lower throughput |

**When to use `EnterpriseCluster`:**
- Your application uses a Redis client that does NOT support Redis Cluster protocol
- You're migrating from a non-clustered ACR cache and cannot update the client library
- You need a single-endpoint topology for legacy compatibility

```powershell
# Use EnterpriseCluster for legacy clients
.\Convert-AcrToAmr.ps1 -TemplatePath .\acr.json -Region westus2 -ClusteringPolicy EnterpriseCluster
```

---

## Best Practice Recommendations

The migration script includes these recommendations in the feature gap report. They are **not** applied automatically to avoid breaking existing applications — implement them as post-migration hardening steps.

### Microsoft Entra Authentication

**Recommended**: Disable access key authentication and use Microsoft Entra ID for improved security.

```json
"accessKeysAuthentication": "Disabled"
```

After migrating, configure Entra ID auth:
1. Assign the `Redis Cache Contributor` role to your application's managed identity
2. Update your Redis client to use token-based authentication
3. Disable access keys via the Azure Portal or ARM template

### Private Network Access

**Recommended**: Disable public network access and use Private Endpoints exclusively.

```json
"publicNetworkAccess": "Disabled"
```

The migration script automatically converts VNet-injected ACR caches to use Private Endpoints, but does not set `publicNetworkAccess: Disabled` by default. Configure this after verifying Private Endpoint connectivity.

---

## Troubleshooting

### "This script requires PowerShell 7.0 or later"

Install PowerShell 7+:
- **Windows**: `winget install Microsoft.PowerShell` or https://aka.ms/install-powershell
- **macOS**: `brew install powershell`
- **Linux**: See https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux

### "az bicep build failed"

The Azure CLI Bicep extension is required for `.bicep` input files:

```bash
az bicep install
az bicep upgrade
```

### "Could not determine source format"

The script detects format by file extension:
- `.json` → ARM JSON
- `.bicep` → Bicep (requires Azure CLI)
- `.tf` → Terraform

Ensure your file has the correct extension.

### "No Microsoft.Cache/redis resource found"

The template must contain a resource with `type: "Microsoft.Cache/redis"`. The script does not support:
- Nested/linked ARM template deployments
- Modules in Bicep (only single-file templates)
- Complex Terraform modules (only flat resource blocks)

### Pricing API returns empty

The Azure Retail Prices API may not have pricing for all regions. Use `-SkipPricing` to proceed without pricing:

```powershell
.\Convert-AcrToAmr.ps1 -TemplatePath .\acr.json -Region westus2 -SkipPricing -Force
```

### Parameters file values not being used

Ensure the parameters file follows ARM parameters format:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "skuName": { "value": "Premium" },
    "skuCapacity": { "value": 2 }
  }
}
```

### Validation deployment fails

Common causes:
- **Insufficient quota**: AMR SKUs require specific vCPU/memory quotas in the target region
- **Region not supported**: Not all regions support all AMR SKUs
- **Subscription not registered**: Run `az provider register --namespace Microsoft.Cache`
- **Resource name conflict**: AMR cache names must be globally unique

---

## FAQ

**Q: Does this script modify my source files?**
A: No. Source files are never modified. All output goes to the `migrated/` directory (or your custom `-OutputDirectory`).

**Q: Can I run this in a CI/CD pipeline?**
A: Yes. Use `-Force -SkipPricing` for non-interactive mode. The script returns exit code `0` on success, `1` on error.

**Q: What if the auto-detected SKU isn't right for my workload?**
A: Use `-TargetSku` to override. Example: `-TargetSku ComputeOptimized_X10` for high-CPU workloads.

**Q: Does this handle geo-replication migration?**
A: No. ACR passive geo-replication has no direct AMR equivalent in templates. After migrating, configure AMR active geo-replication manually. The feature gap report will flag this.

**Q: Can I migrate multiple templates at once?**
A: The script handles one template at a time. For batch migration, use a loop:

```powershell
Get-ChildItem .\templates\*.json | ForEach-Object {
    .\Convert-AcrToAmr.ps1 -TemplatePath $_.FullName -Region westus2 -Force -SkipPricing
}
```

**Q: What API version does the output use?**
A: `2025-07-01` (GA) for both `Microsoft.Cache/redisEnterprise` and `Microsoft.Cache/redisEnterprise/databases`.

**Q: Is the Copilot skill required?**
A: No. The script is fully standalone. The Copilot skill is an optional conversational wrapper that provides guided assistance around the script.

**Q: What about Enterprise/Enterprise Flash migration?**
A: Not supported by this tool. Contact Microsoft support for Enterprise tier migration guidance.

---

## File Structure

```
amr-migration-skill/
├── iac/                              # IaC migration tooling (this folder)
│   ├── README.md                     # This document
│   ├── Convert-AcrToAmr.ps1         # Main migration script (standalone)
│   ├── Validate-Migration.ps1       # Post-migration validation (deploy + assert)
│   └── references/
│       ├── iac-migration.md         # Detailed transformation rules
│       └── iac-validation.md        # Validation matrix
├── scripts/                          # Utility scripts
│   ├── AmrMigrationHelpers.ps1          # Shared SKU data, pricing, node count, metrics helpers
│   ├── get_redis_price.ps1          # Pricing lookup (standalone)
│   ├── get_redis_price.sh           # Pricing lookup (bash)
│   ├── get_acr_metrics.ps1          # ACR metrics retrieval (standalone)
│   └── get_acr_metrics.sh           # ACR metrics retrieval (bash)
├── tests/                            # Pester test suites
│   ├── Convert-AcrToAmr.Tests.ps1   # Core migration script tests
│   ├── Get-AcrMetrics.Tests.ps1     # ACR metrics + shared module tests
│   ├── PSRule-Integration.Tests.ps1 # PSRule validation tests
│   └── fixtures/                    # Test fixtures (ACR/AMR templates)
├── references/                       # Skill knowledge base
│   ├── sku-mapping.md               # Full SKU mapping tables
│   ├── amr-sku-specs.md             # AMR SKU definitions
│   ├── feature-comparison.md        # ACR vs AMR feature matrix
│   ├── pricing-tiers.md             # Pricing calculation formulas
│   └── ...                          # Other reference docs
├── SKILL.md                         # Copilot skill definition
└── README.md                        # Repo overview
```
