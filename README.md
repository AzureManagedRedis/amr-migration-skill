# AMR Migration Skill

An [Open Agent Skill](https://agentskills.io) to help users migrate from Azure Cache for Redis to Azure Managed Redis (AMR).

## Overview

This skill assists AI agents in helping users:
- Compare features between Azure Cache for Redis and Azure Managed Redis
- Select appropriate AMR SKUs based on existing ACR cache configurations
- Plan and execute migrations with best practices
- Troubleshoot common migration issues
- **Migrate Bicep/ARM templates from ACR to AMR for new region buildouts**

## Usage

Load this skill into your AI agent (GitHub Copilot CLI, Claude, etc.) to get assistance with Azure Redis migration tasks.

### With GitHub Copilot CLI

#### Option A: Using the Vercel Skills CLI (`npx skills`)

```bash
npx skills add https://github.com/AzureManagedRedis/amr-migration-skill -g -a github-copilot
```

- `-g` installs the skill globally (personal skill, shared across projects)
- `-a github-copilot` targets the GitHub Copilot CLI skills directory (`~/.copilot/skills/`)

> ⚠️ **Important:** When prompted for the installation method, choose **"Copy to all agents"** instead of the symlink option. On Windows, symlink creation requires either Administrator privileges or Developer Mode to be enabled.

Then reload and verify:

```
/skills reload
/skills info amr-migration-skill
```

#### Option B: Clone and Copy

```bash
git clone https://github.com/AzureManagedRedis/amr-migration-skill
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.copilot\skills\amr-migration-skill" -Force
Copy-Item -Path ".\amr-migration-skill\*" -Destination "$env:USERPROFILE\.copilot\skills\amr-migration-skill\" -Recurse
```

**macOS / Linux:**

```bash
mkdir -p ~/.copilot/skills/amr-migration-skill
cp -r ./amr-migration-skill/* ~/.copilot/skills/amr-migration-skill/
```

Then reload and verify:

```
/skills reload
/skills info amr-migration-skill
```

You should see `Source: Personal` and the location pointing to `~/.copilot/skills/amr-migration-skill/SKILL.md`.

#### Troubleshooting

- Run `/skills reload` to refresh without restarting the CLI.
- Verify `SKILL.md` exists at `~/.copilot/skills/amr-migration-skill/SKILL.md`.
- If you used the Vercel CLI with symlinks and the skill isn't found, re-run with the **copy** method or manually copy the files from `~/.agents/skills/` to `~/.copilot/skills/`.

### With Claude Code

```
# Add to your agent skills directory
```

## Example Prompts

Try these prompts to get started:

### Migration Planning
- **"I have an Azure Cache for Redis Standard C3 in westus2. Help me migrate to Azure Managed Redis."**
- **"We're running a Premium P2 cache with 3 shards and geo-replication. What's the best AMR SKU and migration strategy?"**

### SKU Selection & Pricing
- **"Compare AMR SKU options for a workload currently using 10GB of memory with high server load."**
- **"What's the monthly cost difference between my current Standard C2 and the equivalent AMR SKU in eastus?"**

### Feature Comparison
- **"What Redis features does AMR support that ACR doesn't? We need JSON and Search modules."**
- **"Does AMR support VNet injection? We currently use that on our Premium cache."**

### Metrics & Assessment
- **"Pull the metrics from my ACR cache `my-cache` in resource group `my-rg` and recommend an AMR SKU."**
- **"Assess our current cache usage and give me a full migration plan with pricing."**

### Retirement & Timeline
- **"When is Azure Cache for Redis being retired? What's the timeline for Basic/Standard/Premium?"**

### Quick Questions
- **"What port does AMR use? Our app currently connects on 6380."**
- **"What changes do I need to make to my connection string when moving to AMR?"**

### IaC / Template Migration
- **"Convert my ACR Bicep template to AMR."**
- **"I'm doing a new region buildout — update my ARM template from ACR to AMR."**
- **"Transform this Premium P2 clustered Redis template to AMR with pricing comparison."**

## Skill Structure

```
amr-migration-skill/
├── SKILL.md                        # Copilot skill definition and instructions
├── README.md                       # This file
├── TODO.md                         # Roadmap items
│
├── iac/                            # IaC migration tooling (standalone, no skill dependency)
│   ├── README.md                   # Full IaC migration + validation guide
│   ├── Convert-AcrToAmr.ps1       # Main migration script (ARM/Bicep/Terraform)
│   ├── Validate-Migration.ps1     # Post-migration deploy + assert
│   └── references/
│       ├── iac-migration.md       # Transformation rules reference
│       └── iac-validation.md      # Validation matrix
│
├── references/                     # Skill knowledge base (used by SKILL.md)
│   ├── sku-mapping.md             # SKU selection guidelines & decision matrix
│   ├── amr-sku-specs.md           # AMR SKU definitions (M, B, X, Flash series)
│   ├── feature-comparison.md      # ACR vs AMR feature matrix
│   ├── migration-overview.md      # Migration strategies and guidance
│   ├── pricing-tiers.md           # Pricing calculation rules
│   ├── retirement-faq.md          # ACR retirement dates and FAQ
│   ├── azure-cli-commands.md      # Azure CLI reference for ACR discovery
│   └── mcp-server-config.md       # MCP server setup for live documentation
│
└── scripts/                        # Standalone utility scripts
    ├── AmrMigrationHelpers.ps1          # Shared AMR SKU data, pricing, node count functions
    ├── get_redis_price.ps1         # Pricing with HA/shards/MRPP logic
    ├── get_redis_price.sh
    ├── get_acr_metrics.ps1         # Pull ACR metrics for SKU sizing
    └── get_acr_metrics.sh
```

## Standalone IaC Migration (No Copilot CLI Required)

> 📖 **Full guide**: [iac/README.md](iac/README.md) — complete documentation with transformation rules, validation workflow, SKU tables, troubleshooting, and FAQ.

The `Convert-AcrToAmr.ps1` script enables IaC template migration without any AI/Copilot dependency:

```powershell
# ARM JSON migration with pricing comparison
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2

# With parameters file (separate template + params)
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -ParametersPath .\acr-cache.parameters.json -Region westus2

# Bicep template migration
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.bicep -Region westus2

# Terraform migration
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\main.tf -Region westus2

# Non-interactive (CI/CD pipelines)
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2 -Force -SkipPricing

# Analysis only (no file generation)
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2 -AnalyzeOnly

# Override target SKU
.\iac\Convert-AcrToAmr.ps1 -TemplatePath .\acr-cache.json -Region westus2 -TargetSku Balanced_B50
```

**Key parameters:**
| Parameter | Description |
|-----------|-------------|
| `-TemplatePath` | Path to source ACR template (.json, .bicep, .tf) |
| `-ParametersPath` | Optional ARM/Bicep parameters file |
| `-Region` | Azure region (required for pricing) |
| `-Force` | Skip interactive confirmation |
| `-SkipPricing` | Skip Azure Retail Prices API calls |
| `-AnalyzeOnly` | Run analysis only (no transformation) |
| `-ReturnObject` | Return structured PSObject (for script/skill integration) |
| `-TargetSku` | Override auto-detected AMR SKU |
| `-ClusteringPolicy` | `OSSCluster` (default, recommended) or `EnterpriseCluster` |
| `-OutputDirectory` | Custom output folder (default: `./migrated/`) |
| `-SubscriptionId` | Azure subscription ID (enables metrics-based SKU suggestion) |
| `-ResourceGroup` | Azure resource group (enables metrics-based SKU suggestion) |

### ARM Template Parsing

The script uses a two-tier parsing strategy for ARM/Bicep templates:

1. **PSRule.Rules.Azure** (preferred): Full offline ARM expression resolution via `Export-AzRuleTemplateData`. Resolves `parameters()`, `variables()`, `concat()`, `if()`, `resourceGroup().location`, nested expressions, and `defaultValue` fallbacks — all without Azure connectivity.
2. **Basic resolver** (fallback): Simple `[parameters('x')]` → params file lookup. Used when PSRule is unavailable or fails.

**PSRule auto-install**: If `PSRule.Rules.Azure` is not installed, the script attempts `Install-Module -Scope CurrentUser` automatically. If that fails, it falls back to the basic resolver with a warning.

To install manually:
```powershell
Install-Module -Name PSRule.Rules.Azure -Scope CurrentUser -Force
```

**Requirements:** PowerShell 7.0+ (cross-platform: Windows, macOS, Linux). Install: https://aka.ms/install-powershell. Bicep input/output requires Azure CLI with Bicep extension.

### Shared Module: AmrMigrationHelpers.ps1

All AMR SKU specifications (44 SKUs across M/B/X/Flash tiers), pricing API calls, and node count calculations are centralized in `scripts/AmrMigrationHelpers.ps1`. This eliminates data duplication across scripts:

- **`$script:AmrSkuSpecs`** — Canonical SKU table (Advertised/Usable GB, VCPUs, MaxConnections)
- **`Get-AmrSkuSizes`** — Derives tier-filtered size→specs lookup from the canonical table
- **`Get-RetailPrice`** — Azure Retail Prices API wrapper
- **`Get-CacheNodeCount`** — Unified node count logic (ACR Basic/Standard/Premium + AMR HA/non-HA)
- **`Get-MetricsBasedSkuSuggestion`** — Maps Azure Monitor metrics to AMR SKU recommendations

The module is dot-sourced by `Convert-AcrToAmr.ps1` and `get_redis_price.ps1`.

## External Resources

This skill leverages:
- **Microsoft Learn MCP Server**: `https://learn.microsoft.com/api/mcp` for up-to-date Azure documentation
- **SKU Mapping Data**: Internal spreadsheet (requires updates to `references/sku-mapping.md`)
- **Azure CLI Reference**: `references/azure-cli-commands.md`

## Contributing

1. Keep documentation up-to-date with latest Azure Redis features
2. Update SKU mappings when new AMR SKUs are released
3. Add scripts for common migration automation tasks

## License

MIT
