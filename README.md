# AMR Migration Skill

An [Open Agent Skill](https://agentskills.io) to help users migrate from Azure Cache for Redis to Azure Managed Redis (AMR).

## Overview

This skill assists AI agents in helping users:
- Compare features between Azure Cache for Redis and Azure Managed Redis
- Select appropriate AMR SKUs based on existing ACR cache configurations
- Plan and execute migrations with best practices
- Troubleshoot common migration issues

## Usage

Load this skill into your AI agent (GitHub Copilot, Claude, etc.) to get assistance with Azure Redis migration tasks.

### With GitHub Copilot

```
# Reference this skill in your copilot configuration
```

### With Claude Code

```
# Add to your agent skills directory
```

## Example Prompts

Try these prompts to get started:

- **"I need to migrate my Azure Cache for Redis to AMR"** — starts a guided migration workflow
- **"What AMR SKU should I use for my P2 cache with 3 shards?"** — gets a SKU recommendation
- **"Compare pricing between my current P2 and AMR M20 in westus2"** — runs the pricing scripts
- **"Pull metrics for my cache `my-redis` in resource group `my-rg`"** — fetches Server Load, memory, connections
- **"What are the connection string differences between ACR and AMR?"** — highlights port/DNS changes
- **"When is Azure Cache for Redis being retired?"** — retirement dates and timeline

## Skill Structure

```
amr-migration-skill/
├── SKILL.md              # Main skill definition and instructions
├── README.md             # This file
├── TODO.md               # Roadmap items
├── references/
│   ├── azure-cli-commands.md    # Azure CLI reference for ACR discovery
│   ├── feature-comparison.md    # ACR vs AMR feature matrix
│   ├── mcp-server-config.md     # MCP server setup for live documentation
│   ├── migration-overview.md    # Migration strategies and guidance
│   ├── pricing-tiers.md         # Pricing calculation rules
│   ├── retirement-faq.md        # ACR retirement dates and FAQ
│   ├── sku-mapping.md           # SKU selection guidelines & decision matrix
│   └── amr-sku-specs.md         # AMR SKU definitions (M, B, X, Flash series)
└── scripts/
    ├── get_acr_metrics.ps1      # Pull ACR metrics for SKU sizing
    ├── get_acr_metrics.sh
    ├── get_redis_price.ps1      # Pricing with HA/shards/MRPP logic
    └── get_redis_price.sh
```

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
