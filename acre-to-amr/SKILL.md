---
name: acre-to-amr-migration-skill
description: "Use when a customer needs to (1) understand what changes are required in their automation scripts (ARM templates, Bicep templates, Azure CLI commands, Azure PowerShell commands) after migrating from Azure Cache for Redis Enterprise (ACRE) to Azure Managed Redis (AMR), (2) get step-by-step interactive guidance to migrate their ACRE caches to AMR, including discovering ACRE caches in a subscription, executing migration with user confirmation at each step, and handling geo-replicated cache scenarios, or (3) get a generic recommended step-by-step migration guide or flowchart for ACRE to AMR migration without executing any commands against a live subscription. The agent analyzes the user's existing scripts, identifies required changes, produces a tailored checklist with before/after examples — but does NOT modify files directly. For migration execution, the agent discovers caches, determines the migration path (in-place vs. create-new for geo-replicated), and walks the user through each step interactively. For generic guidance, the agent presents the recommended migration process as a step-by-step guide without requiring Azure credentials or cache details. Trigger phrases include: update ARM template for AMR, convert ACRE script, fix Bicep after migration, update Bicep for AMR, az redisenterprise script migration, update PowerShell for AMR, migrate Redis Enterprise automation script, migrate ACRE caches, migrate my Redis Enterprise caches, help me migrate to AMR, migrate geo-replicated caches, step by step process to migrate, how to migrate ACRE to AMR, migration guide, migration flowchart, what are the steps to migrate, recommended migration process, ACRE to AMR migration steps."
license: MIT
metadata:
  author: azure-redis-team
  version: "4.0"
---

# ACRE to AMR Migration & Automation Script Update Guide

This skill provides **three modes** of assistance for ACRE → AMR migration:

1. **Automation Script Update** — Analyzes existing ACRE automation scripts (ARM, Bicep, CLI, PowerShell) and produces a tailored checklist of required changes with before/after examples. Does NOT modify files directly.
2. **Interactive Cache Migration** — Discovers ACRE caches in the user's subscription, determines the migration path for each (in-place for standalone caches, create-new-and-swap for geo-replicated caches), and walks the user through each step interactively with confirmation gates.
3. **Generic Migration Guide** — Presents a recommended step-by-step migration process (for both standalone and geo-replicated caches) without executing any commands or accessing the user's Azure subscription. Use this mode when the user asks for general guidance, a flowchart, or a process overview rather than requesting hands-on migration of specific caches.

---

## Quick Reference Index

Navigate to the relevant reference document based on your task:

| Reference | Description | When to Use |
|-----------|-------------|-------------|
| [Breaking Changes](references/breaking-changes.md) | Property changes, DNS updates, API versions, PE migration strategies | Understanding what changes between ACRE and AMR |
| [Script Analysis](references/script-analysis.md) | Detection patterns, companion parameter files, Gen1 indicators, validation checklist | Detecting script type, reading params, validating before checklist |
| [SKU Resolution](references/sku-resolution.md) | `listSkusForScaling` procedure + fallback mapping table + AMR SKU families | Determining the target AMR SKU |
| [Per-Script Checklists](references/checklists.md) | Numbered checklists for ARM, Bicep, Azure CLI, Azure PowerShell | Producing the tailored migration checklist for a script |
| [Before/After Examples](references/examples.md) | Full code examples (before ACRE / after AMR) for each script type | Showing the user exact code transformations |
| [Generic Migration Guide](references/migration-guide.md) | Step-by-step process overview, flowchart, Path A and Path B summaries | Presenting the recommended migration process without executing commands |
| [Interactive Migration](references/interactive-migration.md) | Discovery, in-place migration steps, geo-replicated migration steps | Hands-on migration with cache discovery and confirmation gates |
| [Troubleshooting & FAQ](references/troubleshooting.md) | Common pitfalls, error messages, interactive Q&A patterns | Answering follow-up questions and debugging deployment failures |
---

## Scope Boundary — READ FIRST

> **This skill applies ONLY to ACRE → AMR migration.**
>
> - **ACRE** = Azure Cache for Redis Enterprise: SKUs starting with `Enterprise_` or `EnterpriseFlash_`
> - **AMR** = Azure Managed Redis: SKUs starting with `Balanced_`, `MemoryOptimized_`, `ComputeOptimized_`, or `FlashOptimized_`
>
> Both ACRE and AMR use the **same ARM resource type**: `Microsoft.Cache/redisEnterprise`

### Out of Scope — STOP if you detect these

This skill does **NOT** cover migration from **Azure Cache for Redis (ACR)** Basic/Standard/Premium SKUs to AMR. That is a fundamentally different migration path.

**If the user's script contains ANY of these, STOP and explain this skill does not apply:**
- Resource type `Microsoft.Cache/redis` (note: no "Enterprise" suffix)
- SKU names: `Basic`, `Standard`, `Premium`, `C0`–`C6`, `P1`–`P5`
- CLI commands: `az redis` (not `az redisenterprise`)
- PowerShell cmdlets: `New-AzRedisCache`, `Get-AzRedisCache` (not `*-AzRedisEnterprise*`)

**Response when out-of-scope script is detected:**
> "Your script targets Azure Cache for Redis (ACR) with resource type `Microsoft.Cache/redis`, not Azure Cache for Redis Enterprise (ACRE) with resource type `Microsoft.Cache/redisEnterprise`. The ACRE-to-AMR migration guide does not apply to ACR-to-AMR migration. These are different migration paths with different resource types, properties, and conversion steps. Please consult the Azure Cache for Redis migration documentation for ACR-to-AMR guidance."

---

## Mode Detection — How to Choose the Right Mode

Before proceeding, determine which mode to use based on the user's request:

| User Intent | Mode | What the Agent Does |
|-------------|------|---------------------|
| User shares a script/template and asks what needs to change for AMR | **Automation Script Update** | Analyze the script, produce a tailored checklist with before/after examples |
| User asks to migrate their caches, discover caches, or execute migration steps | **Interactive Cache Migration** | Log in, discover caches, walk through migration step-by-step |
| User asks for a step-by-step guide, recommended process, flowchart, or general migration overview — **without** referencing specific caches or asking to execute migration | **Generic Migration Guide** | Present the recommended migration process as documentation — no commands executed, no subscription access required |

**Detection signals for Generic Migration Guide mode** (use this mode if ANY of these match):
- User says "step by step process", "step-by-step guide", "migration steps", "how to migrate", "what is the process", "recommended process", "migration flowchart", "walkthrough", or "overview"
- User does NOT mention specific cache names, resource groups, or subscription IDs
- User does NOT say "migrate my caches", "migrate our caches", or "help me migrate" (these imply hands-on interactive migration)
- User asks a general knowledge question about the migration process rather than requesting execution

**When in doubt**: If the user's request is ambiguous, **default to Generic Migration Guide mode** and offer to switch to Interactive Cache Migration mode if they want hands-on execution. For example: *"Here is the recommended step-by-step migration process. If you'd like me to discover your actual ACRE caches and walk you through the migration interactively, just let me know."*
---

## Agent Behavior Rules

When this skill is invoked, you MUST follow these rules:

### MUST — General

1. **Default: DO NOT directly edit, create, or modify any user files.** You are advisory only for automation script changes. However, if the user explicitly asks you to apply the changes to their files, you may do so — but you **MUST** inform the user afterwards: *"These changes were generated by AI. Please review all modifications thoroughly before committing or deploying them to ensure correctness and completeness."*
2. **Verify scope** before proceeding — if the script is for ACR (not ACRE), stop immediately and explain (see Scope Boundary above).
3. **Warn about access keys authentication** — the default for `accessKeysAuthentication` is `Disabled` in API version `2025-07-01`+. If the application uses access keys, it must be explicitly set to `Enabled`. See [breaking-changes.md](references/breaking-changes.md#properties-that-change) for details.
4. **Resolve the AMR SKU by executing the `listSkusForScaling` API call**: The agent MUST actually execute the API call (see [SKU Resolution Procedure](references/sku-resolution.md)) using `az rest` in the terminal — do NOT just suggest the user call it. **If any required parameter (subscription ID, resource group, or cluster name) cannot be extracted from the script, the agent MUST stop, ask the user for the missing value(s), and WAIT for the user's response before proceeding.** Do NOT skip ahead to the fallback mapping table while waiting — the fallback is ONLY for when the API call itself fails after being executed. Once the agent has all parameters and executes the API call: if it succeeds, use the response to recommend the AMR SKU; if it fails (e.g., authentication error, cluster not found, `az` CLI not installed), fall back to the [default mapping table](references/sku-resolution.md#default-migration-mapping-fallback) based on the user's ACRE SKU + capacity. If that combination is also not in the table, ask the user.

### MUST — Automation Script Update Mode

5. **Analyze** the user's script/template to detect the automation type (ARM JSON, Bicep, Azure CLI, Azure PowerShell). See [Script Analysis](references/script-analysis.md).
6. **Read companion parameter files** — For ARM templates, search the same directory (and the workspace) for associated `*.parameters.json` files. For Bicep templates, search for associated `.bicepparam` files. See [Script Analysis — Companion Parameter Files](references/script-analysis.md#companion-parameter-files).
7. **Validate the script** before producing the checklist. Follow the [Script Analysis — Validation Guardrails](references/script-analysis.md#step-4--validate-before-checklist).
8. **Produce a tailored, numbered checklist** of required changes specific to what you found in the user's script **and its parameter files**. Use the [Per-Script Checklists](references/checklists.md) as the template.
9. **Show before/after examples** inline for each checklist item so the user understands the exact transformation needed. See [Before/After Examples](references/examples.md).
10. **DO NOT apply changes** to the user's files unless they explicitly ask. If the user requests you to apply changes, do so, then remind them: *"These changes were generated by AI. Please review all modifications thoroughly before committing or deploying them to ensure correctness and completeness."*

### MUST — Interactive Cache Migration Mode

11. **Safe agent principles** — Interactive migration touches **production infrastructure**. The agent MUST:
    - **Get explicit user confirmation before every step** that modifies resources (create, update, delete, unlink).
    - **NEVER delete any resource directly.** For deletion steps (old ACRE cache, old Private Endpoint, old DNS zone), provide the exact command or portal guidance and instruct the user to execute it themselves.
    - **Present each step one at a time.** After presenting a step, **WAIT for the user to confirm** before proceeding. Do NOT batch multiple steps or skip ahead.
12. **Follow the Interactive Migration Procedure** in [references/interactive-migration.md](references/interactive-migration.md), which covers:
    - **Phase 1 — Discovery**: List caches, classify ACRE vs AMR, check geo-replication, detect Private Link, call `listSkusForScaling`, present migration plan, wait for user confirmation.
    - **Phase 2A — In-Place Migration**: For standalone (non-geo-replicated) caches.
    - **Phase 2B — Geo-Replicated Migration**: For geo-replicated caches (create new AMR cache, swap traffic, remove old ACRE — one member at a time).

### MUST — Generic Migration Guide Mode

13. **Do NOT execute any commands or access the user's Azure subscription.** This mode is purely informational.
14. **Present the recommended migration process** from [references/migration-guide.md](references/migration-guide.md), covering both standalone and geo-replicated cache scenarios.
15. **Include key decision points** — help the user understand when to use in-place migration vs. create-new-and-swap, and what factors affect the choice.
16. **Reference the Breaking Changes table** — summarize the critical property changes from [references/breaking-changes.md](references/breaking-changes.md) so the user knows what to expect.
17. **Offer to switch modes** — At the end of the guide, offer to switch to Interactive Cache Migration mode if the user wants hands-on execution, or to Automation Script Update mode if they have scripts to update.

### SHOULD

18. **Answer follow-up questions** interactively about specific properties, SKU choices, DNS changes, or API version selection. See [Troubleshooting & FAQ](references/troubleshooting.md) for common Q&A patterns.
19. **Ask clarifying questions** if the target AMR SKU is unclear or if the script has ambiguous patterns (e.g., SKU name in a parameter/variable that you can't resolve).