# IaC Migration Workflow

Use this workflow when the user asks to convert ACR Bicep/ARM/Terraform templates to AMR format. The AI reads the user's template, applies transformation rules from the reference docs, and generates the migrated output directly. Scripts are only used for pricing lookups (Step 3).

> **Critical**: Do NOT skip the customer confirmation gate (Step 5). Always present pricing and feature gaps before generating the migrated template.

## Step 1: Parse ACR Template

Read the user's ACR template (ARM JSON, Bicep, or Terraform). Follow the [ACR Template Parsing Guide](iac-acr-template-parsing.md) to extract the SKU, enabled features, and all configuration settings.

> **`shardCount: 0` warning**: Azure portal exports may include `"shardCount": 0` for non-clustered Premium caches. This is an export artifact — treat it the same as absent (non-clustered). Do NOT include `shardCount: 0` in any generated template; ARM rejects it on deployment.

## Step 2: Select Target AMR SKU

Look up the source SKU in the [SKU Mapping Guide](sku-mapping.md) to find the target AMR SKU.

- For **Basic/Standard** (C0-C6): map directly using the table-based mapping
- For **Premium** (P1-P5): account for shard count — total memory = capacity × (shardCount + 1)

> **Optimization opportunity**: If the user has Azure access and wants to right-size, suggest running **Migration Workflow Step 1** first to gather actual usage metrics. Otherwise, use the table-based mapping from the SKU Mapping Guide.

## Step 3: Get Pricing Comparison

Run the pricing scripts for both source and target SKUs to show the cost impact:

```powershell
# Source ACR pricing
.\scripts\get_redis_price.ps1 -SKU <source-sku> -Region <region> [-Shards N] [-Replicas N]

# Target AMR pricing
.\scripts\get_redis_price.ps1 -SKU <target-amr-sku> -Region <region>
```

## Step 4: Identify Feature Gaps

Check [Feature Comparison](feature-comparison.md) for features that change or are removed in AMR. Key items to flag:
- **Clustering policy decision**: If source had `shardCount ≥ 1`, ask whether the client is cluster-aware (determines `OSSCluster` vs `EnterpriseCluster`)
- **VNet injection → Private Endpoint**: Source `subnetId` requires a PE resource in the output
- **Geo-replication**: ACR `linkedServers` (passive) cannot be auto-converted to AMR active geo-replication — warn the user
- **Removed properties**: `enableNonSslPort`, `redisVersion`, `replicasPerPrimary`, memory reservation configs

## Step 5: ⛔ Customer Confirmation Gate

**STOP.** Present the following to the user and wait for explicit approval before generating the template:

1. **Target AMR SKU** and how it was selected
2. **Pricing comparison** — source monthly cost vs target monthly cost
3. **Feature gaps** — what changes, what's removed, what needs manual attention
4. **Clustering policy recommendation** — and why (default: `EnterpriseCluster` unless user confirms cluster-aware client)

**Wait for explicit confirmation before proceeding to Step 6.**

## Step 6: Generate AMR Template

Apply the transformation rules from the [AMR Template Structure Guide](iac-amr-template-structure.md) to generate the migrated template. Reference the [example templates](examples/iac/) for grounding on the expected output format.

Generate the output in the **same IaC format** as the input (ARM JSON → ARM JSON, Bicep → Bicep, Terraform → Terraform).

> **Deployment-validated gotchas** (these cause deployment failures if missed):
> - **API version**: Must be `2025-07-01` — earlier versions reject `publicNetworkAccess`
> - **`publicNetworkAccess`**: REQUIRED in `2025-07-01`. Preserve from source; default `"Enabled"` if absent.
> - **`sku.capacity`**: Do NOT include — B/M/X/A series encode size in the name (e.g., `Balanced_B10`)
> - **`zones`**: Do NOT include — AMR auto-manages zone redundancy. Specifying it causes deployment errors.
> - **Terraform**: Use `azurerm_managed_redis` (NOT the deprecated `azurerm_redis_enterprise_cluster`). Single resource with inline `default_database` block. See [AMR Template Structure §12](iac-amr-template-structure.md#12-terraform-output-structure).

## Step 7: Present Output

Show the migrated template and a summary of changes:
- List every property that was transformed, added, or removed
- Highlight any items requiring manual attention (e.g., geo-replication, PE subnet selection)
- Provide the validation command:

```bash
# ARM JSON
az deployment group validate -g <resource-group> --template-file <migrated-file>

# Bicep
az deployment group validate -g <resource-group> --template-file <migrated-file>.bicep
```
