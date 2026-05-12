# MCP Server Configuration for AMR Migration Skill

This skill uses the Microsoft Learn MCP server to fetch up-to-date Azure documentation.

## MCP Server Details

- **Endpoint**: `https://learn.microsoft.com/api/mcp`
- **Protocol**: MCP (Model Context Protocol)
- **Authentication**: None required for public documentation

## Configuring the MCP Server

### For GitHub Copilot

Add the following to your Copilot configuration:

```json
{
  "mcpServers": {
    "microsoft-learn": {
      "url": "https://learn.microsoft.com/api/mcp"
    }
  }
}
```

### For Claude Desktop

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "microsoft-learn": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-client", "https://learn.microsoft.com/api/mcp"]
    }
  }
}
```

## Useful Documentation Paths

When using the MCP server, these paths provide relevant Azure Redis documentation:

### Azure Managed Redis
- `/azure/redis/overview` - AMR overview and tier selection
- `/azure/redis/architecture` - AMR architecture and clustering policies

### Migration
- `/azure/redis/migrate/migrate-overview` - Migration hub (3-phase: understand, options, plan)
- `/azure/redis/migrate/migrate-basic-standard-premium-options` - BSP migration options (self-service vs tooling)
- `/azure/redis/migrate/migrate-basic-standard-premium-understand` - Feature differences and SKU selection guidance
- `/azure/redis/migrate/migrate-basic-standard-premium-self-service` - Step-by-step self-service migration
- `/azure/redis/migrate/migrate-basic-standard-premium-with-tooling` - Step-by-step migration with tooling (preview)

## Example MCP Queries

```
# Fetch AMR overview
mcp:microsoft-learn/fetch?path=/azure/redis/overview

# Fetch migration hub
mcp:microsoft-learn/fetch?path=/azure/redis/migrate/migrate-overview
```
