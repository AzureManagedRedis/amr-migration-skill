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

### Azure Cache for Redis
- `/azure/azure-cache-for-redis/cache-overview`
- `/azure/azure-cache-for-redis/cache-planning-faq`
- `/azure/azure-cache-for-redis/cache-best-practices`

### Azure Managed Redis (AMR)
- `/azure/azure-cache-for-redis/managed-redis/managed-redis-overview`
- `/azure/azure-cache-for-redis/managed-redis/managed-redis-architecture`
- `/azure/azure-cache-for-redis/managed-redis/managed-redis-best-practices-sku`

### Migration
- `/azure/azure-cache-for-redis/managed-redis/managed-redis-migration`
- `/azure/azure-cache-for-redis/cache-migration-guide`

## Example MCP Queries

```
# Fetch AMR overview
mcp:microsoft-learn/fetch?path=/azure/azure-cache-for-redis/managed-redis/managed-redis-overview

# Fetch migration guide
mcp:microsoft-learn/fetch?path=/azure/azure-cache-for-redis/managed-redis/managed-redis-migration
```
