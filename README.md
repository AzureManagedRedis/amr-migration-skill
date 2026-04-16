# AMR Migration Skill

An [Open Agent Skill](https://agentskills.io) to help users migrate from Azure Cache for Redis to Azure Managed Redis (AMR).

## Overview

This skill assists AI agents in helping users:
- Compare features between Azure Cache for Redis and Azure Managed Redis
- Select appropriate AMR SKUs based on existing ACR cache configurations
- **Convert IaC templates (ARM, Bicep, Terraform) from ACR to AMR format** — pure AI-driven, no conversion scripts needed
- Plan and execute migrations with best practices
- Troubleshoot common migration issues

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

Clone the repo and copy the skill into Claude Code's skills directory:

```bash
git clone https://github.com/AzureManagedRedis/amr-migration-skill
```

**Personal (global) skill** — available in all projects:

```bash
mkdir -p ~/.claude/skills/amr-migration-skill
cp -r ./amr-migration-skill/* ~/.claude/skills/amr-migration-skill/
```

**Project-scoped skill** — available only in a specific repo:

```bash
mkdir -p .claude/skills/amr-migration-skill
cp -r ./amr-migration-skill/* .claude/skills/amr-migration-skill/
```

Restart Claude Code, then verify the skill is loaded by asking:
```
Is the amr-migration-skill loaded?
```

## Example Prompts

Try these prompts to get started:

### Migration Planning
- **"I have an Azure Cache for Redis Standard C3 in westus2. Help me migrate to Azure Managed Redis."**
- **"We're running a Premium P2 cache with 3 shards and geo-replication. What's the best AMR SKU and migration strategy?"**

### Automated Migration (ARM REST API)
- **"Validate whether my ACR cache can be migrated to AMR automatically using the migration script."**
- **"Run the automated migration from my ACR cache `my-cache` to my AMR cache `my-amr-cache` with DNS switching."**
- **"Check the status of my ongoing AMR migration."**
- **"Cancel / rollback my AMR migration."**
- **"I'm getting a validation warning about clustering policy mismatch. Should I force the migration?"**

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

### IaC Template Migration
- **"Convert this ARM template from ACR to AMR format."** *(paste or point to your template)*
- **"I have a Bicep file for a Premium P2 cache with VNet injection. Migrate it to AMR."**
- **"Convert our clustered Premium P2 ARM template to AMR. We use 3 shards with RDB persistence."**
- **"Migrate our Terraform ACR module to AMR — we need Private Endpoint instead of VNet injection."**

### Quick Questions
- **"What port does AMR use? Our app currently connects on 6380."**
- **"What changes do I need to make to my connection string when moving to AMR?"**

## Skill Structure

```
amr-migration-skill/
├── SKILL.md              # Main skill definition and instructions
├── README.md             # This file
├── VERSION               # Skill version (used by manual update check)
├── TODO.md               # Roadmap items
├── evals/
│   ├── evals.json            # Test cases with prompts and assertions
│   └── eval-config.json      # Run modes (quick/standard/full) and grader context
├── references/
│   ├── amr-sku-specs.md              # AMR SKU definitions (M, B, X, Flash series)
│   ├── automated-migration.md        # Full automated migration workflow & prerequisites
│   ├── azure-cli-commands.md         # Azure CLI reference for ACR discovery
│   ├── feature-comparison.md         # ACR vs AMR feature matrix
│   ├── iac-acr-template-parsing.md   # How to parse ACR IaC templates
│   ├── iac-amr-template-structure.md # AMR template transformation rules
│   ├── mcp-server-config.md          # MCP server setup for live documentation
│   ├── migration-overview.md         # Migration strategies and guidance
│   ├── migration-scripts.md          # Automated migration ARM API deep-dive
│   ├── migration-validation.md       # Validation errors & warnings reference
│   ├── pricing-tiers.md              # Pricing calculation rules
│   ├── retirement-faq.md             # ACR retirement dates and FAQ
│   ├── sku-mapping.md                # SKU selection guidelines & decision matrix
│   └── examples/iac/                 # Before/after template pairs
│       ├── arm/                      # ARM JSON (inline values) — 6 scenarios
│       ├── arm-parameterized/        # ARM JSON with parameter files — 4 scenarios
│       └── bicep/                    # Bicep format — 2 scenarios
└── scripts/
    ├── Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1  # Automated migration via ARM REST API (PowerShell)
    ├── azure-redis-migration-arm-rest-api-utility.sh    # Automated migration via ARM REST API (Bash)
    ├── get_acr_metrics.ps1      # Pull ACR metrics for SKU sizing
    ├── get_acr_metrics.sh
    ├── get_redis_price.ps1      # Pricing with HA/shards/MRPP logic
    └── get_redis_price.sh
```

> **Note**: IaC template conversion is AI-driven — the agent reads the reference docs and example templates to generate migrated output directly. Scripts are only used for pricing lookups and metrics retrieval. For CI/CD pipeline automation (batch conversion without an AI agent), a standalone PowerShell tool will be available in a separate repository.

## Evaluation & Benchmarking

The skill includes test cases in `evals/` to measure quality. Three run modes are defined in `eval-config.json`:

| Mode | Models | Runs | Without-Skill Baseline | Use When |
|------|--------|------|----------------------|----------|
| **quick** | Sonnet | 1× | Skipped | Iterating on skill content |
| **standard** | Sonnet + Haiku | 1× | Included | Before opening a PR |
| **full** | Opus + Sonnet + Haiku + GPT-5-mini | 2× | Included | Before merging |

To run evals, ask Copilot CLI:
```
Run the amr-migration-skill evals in quick mode
```

The `grader_context` in `eval-config.json` includes domain facts (valid SKU names, retirement dates) so the grader doesn't hallucinate during evaluation.

## External Resources

This skill leverages:
- **Microsoft Learn MCP Server**: `https://learn.microsoft.com/api/mcp` for up-to-date Azure documentation
- **SKU Mapping Data**: `references/sku-mapping.md`
- **Azure CLI Reference**: `references/azure-cli-commands.md`

## Feedback & Issues

We welcome your feedback! If you have suggestions, feature requests, or run into any problems, please [open an issue](https://github.com/AzureManagedRedis/amr-migration-skill/issues) on GitHub. Whether it's a bug report, an idea for improvement, or a question about usage — we'd love to hear from you.

## Contributing

1. Keep documentation up-to-date with latest Azure Redis features
2. Update SKU mappings when new AMR SKUs are released
3. Add scripts for common migration automation tasks

## License

MIT
