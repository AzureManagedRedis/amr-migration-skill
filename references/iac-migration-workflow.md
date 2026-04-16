# IaC Migration Workflow

Use this workflow when the user asks to convert ACR Bicep/ARM/Terraform templates to AMR format. The AI reads the user's template, applies transformation rules from the reference docs, and generates the migrated output directly. Scripts are only used for pricing lookups (Step 3).

> **Critical**: Do NOT skip the customer confirmation gate (Step 5). Always present pricing and feature gaps before generating the migrated template.

## Step 1: Parse ACR Template

Read the user's ACR template (ARM JSON, Bicep, or Terraform). Follow the [ACR Template Parsing Guide](iac-acr-template-parsing.md) to extract the SKU, enabled features, and all configuration settings.

> **`shardCount: 0` warning**: Azure portal exports may include `"shardCount": 0` for non-clustered Premium caches. This is an export artifact — treat it the same as absent (non-clustered). Do NOT include `shardCount: 0` in any generated template; ARM rejects it on deployment.

## Step 2: (Optional) Pull Live Metrics for SKU Right-Sizing

If the source cache exists in Azure, offer to pull live metrics to validate SKU selection:

> _"The source cache appears to be a live `<cacheName>` in `<resourceGroup>`. Would you like me to pull usage metrics (memory, server load, connections) to optimize the AMR SKU recommendation, or just use the standard mapping from the template's SKU?"_

If the user opts in, run the metrics scripts:

```powershell
# Windows PowerShell
.\scripts\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name>

# Linux/Mac bash
./scripts/get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName>
```

Use the metrics to right-size — the cache may be over- or under-provisioned relative to its current SKU. If peak used memory is significantly below the SKU capacity, a smaller AMR SKU may be a better (and cheaper) fit.

If the user declines, or the cache doesn't exist yet (e.g., template-only conversion for a new region), skip this step and use the table-based mapping in Step 3.

## Step 3: Select Target AMR SKU

Look up the source SKU in the [SKU Mapping Guide](sku-mapping.md) to find the target AMR SKU.

- For **Basic/Standard** (C0-C6): map directly using the table-based mapping
- For **Premium** (P1-P5): account for shard count — total memory = capacity × (shardCount + 1)
- If **metrics were gathered** in Step 2, use peak used memory and server load to validate or adjust the recommendation — the actual usage may warrant a different SKU than the default mapping suggests

## Step 4: Get Pricing Comparison

Run the pricing scripts for both source and target SKUs to show the cost impact:

```powershell
# Source ACR pricing
.\scripts\get_redis_price.ps1 -SKU <source-sku> -Region <region> [-Shards N] [-Replicas N]

# Target AMR pricing
.\scripts\get_redis_price.ps1 -SKU <target-amr-sku> -Region <region>
```

## Step 5: Identify Feature Gaps

Check [Feature Comparison](feature-comparison.md) for features that change or are removed in AMR. Key items to flag:
- **Clustering policy decision**: If the source was non-clustered and the target AMR SKU ≤ 24GB (derivable from the SKU name), use non-clustered AMR automatically. For target sizes > 24GB, or if source was clustered with `shardCount ≥ 1`, ask whether the client is cluster-aware (determines `OSSCluster` vs `EnterpriseCluster`). See [AMR template structure §6](iac-amr-template-structure.md#6-clustering-policy-decision-matrix).
- **Non-TLS port**: If source had `enableNonSslPort: true`, convert to `clientProtocol: "Plaintext"` in AMR (AMR supports non-TLS access)
- **Access policy assignments**: Map ACR `Data Owner` / `Data Contributor` → AMR `default`. Flag `Data Reader` as needing a custom policy.
- **VNet injection → Private Endpoint**: Source `subnetId` requires a PE resource in the output
- **Geo-replication**: ACR `linkedServers` (passive) should be auto-converted to AMR active geo-replication (active-active model). The output supports writes on all linked caches. See [AMR template structure §7](iac-amr-template-structure.md#7-removed-properties).
- **Eviction policy**: Convert ACR `maxmemory-policy` to AMR `evictionPolicy` (PascalCase). Do not remove — it maps directly.
- **Removed properties**: `redisVersion`, `replicasPerPrimary`, memory reservation configs, `staticIP`
- **Scheduled patching**: ACR `patchSchedule` converts to AMR `maintenanceConfiguration.maintenanceWindows[]` (preview, API `2025-08-01-preview`). Map each day+hour entry to a weekly maintenance window with minimum 4h duration.
- **Zone pinning**: If the source template has a `zones` array, warn the user that AMR does not support zone pinning — the `zones` property will be removed and AMR will automatically manage zone redundancy. If `zones` contains fewer than 3 entries (e.g., `["1"]` or `["1","2"]`), this is likely **intentional zone pinning** for co-locality with other resources (VMs, storage, etc.) — emphasize that this guarantee will not carry over to AMR. Even with 3 zones, note that the specific zone selection is not preserved; AMR chooses zones automatically.

## Step 6: ⛔ Customer Confirmation Gate

**STOP.** Present the following to the user and wait for explicit approval before generating the template:

1. **Target AMR SKU** and how it was selected
2. **Pricing comparison** — source monthly cost vs target monthly cost
3. **Feature gaps** — what changes, what's removed, what needs manual attention
4. **Clustering policy** — non-clustered if target ≤ 24GB and source was non-clustered; otherwise `EnterpriseCluster` (or `OSSCluster` if user confirmed cluster-aware client)

**Wait for explicit confirmation before proceeding to Step 7.**

## Step 7: Generate AMR Template

Apply the transformation rules from the [AMR Template Structure Guide](iac-amr-template-structure.md) to generate the migrated template. Reference the [example templates](examples/iac/) for grounding on the expected output format.

Generate the output in the **same IaC format** as the input (ARM JSON → ARM JSON, Bicep → Bicep, Terraform → Terraform).

> **Deployment-validated gotchas** (these cause deployment failures if missed):
> - **API version**: Must be `2025-07-01` — earlier versions reject `publicNetworkAccess`
> - **`publicNetworkAccess`**: REQUIRED in `2025-07-01`. Preserve from source; default `"Enabled"` if absent.
> - **`sku.capacity`**: Do NOT include — B/M/X/A series encode size in the name (e.g., `Balanced_B10`)
> - **`zones`**: Do NOT include — AMR auto-manages zone redundancy. Specifying it causes deployment errors.
> - **Terraform**: Use `azurerm_managed_redis` (NOT the deprecated `azurerm_redis_enterprise_cluster`). Single resource with inline `default_database` block. See [AMR Template Structure §12](iac-amr-template-structure.md#12-terraform-output-structure).

### Pre-flight Validation (Offline)

Before validating against Azure (Step 7), run these offline checks to catch errors early:

- **ARM JSON**: Validate syntax with any JSON linter; optionally check against the [ARM deployment template schema](https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#)
- **Bicep**: Run `bicep build <file>.bicep` — catches syntax and type errors without Azure access
- **Terraform**: Run `terraform validate` — checks configuration syntax and internal consistency offline

## Step 8: Present Output

Show the migrated template and a summary of changes:
- List every property that was transformed, added, or removed
- Highlight any items requiring manual attention (e.g., PE subnet selection, Entra auth reconfiguration)
- Provide the validation commands:

```bash
# ARM JSON — validate against Azure
az deployment group validate -g <resource-group> --template-file <migrated-file>

# ARM JSON — what-if analysis (shows what would be created/changed)
az deployment group what-if -g <resource-group> --template-file <migrated-file>

# Bicep — validate
az deployment group validate -g <resource-group> --template-file <migrated-file>.bicep

# Bicep — what-if analysis
az deployment group what-if -g <resource-group> --template-file <migrated-file>.bicep

# Terraform — validate syntax and configuration
terraform validate

# Terraform — preview changes
terraform plan
```

> **Note**: ARM `validate` and `what-if` require Azure access (a resource group and subscription). Terraform `validate` works offline; `terraform plan` requires provider authentication. These validation steps are optional but recommended before deployment.
