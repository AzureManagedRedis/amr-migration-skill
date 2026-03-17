# SKU Resolution Procedure

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

The agent MUST execute the `listSkusForScaling` API call to determine the target AMR SKU. Do NOT just tell the user to call it — run it yourself.

## Step 1 — Extract Parameters from the Script and Parameter Files

For ARM templates and Bicep templates, **always check companion parameter files first** before falling back to template defaults. Parameter file values take precedence over template `defaultValue` entries.

- **ARM parameter files**: Search for `*.parameters.json` files in the same directory as the template (and elsewhere in the workspace). These contain a `"parameters"` object with concrete values.
- **Bicep parameter files**: Search for `.bicepparam` files in the same directory as the `.bicep` template. These use `param paramName = 'value'` syntax.

For each required value, use this resolution order: (1) companion parameter file → (2) template `defaultValue` / default → (3) ask the user.

- **Cluster name**: Look for the cache name in the parameter file first (e.g., `"cacheName": { "value": "myCache" }` in ARM parameters, or `param cacheName = 'myCache'` in `.bicepparam`). Then check the template parameters, variables, or hardcoded values.
- **Resource group**: Check the parameter file first (e.g., `"resourceGroupName": { "value": "my-rg" }`), then the template. If not present in either, **ask the user**.
- **Subscription ID**: Check the parameter file first for a concrete GUID (e.g., `"subscriptionId": { "value": "abd54813-..." }` in ARM parameters, or `param subscriptionId = 'abd54813-...'` in `.bicepparam`). Then check the template for a `subscriptionId` parameter with a concrete `defaultValue`. Use that exact value — do **NOT** attempt to auto-detect the subscription via `az account show`, `$(az account show --query id -o tsv)`, or any other CLI/shell command. If the subscription ID is not present in either the parameter file or the template, or if it resolves only to a runtime expression (e.g., `[subscription().subscriptionId]`, `subscription().subscriptionId`) with no parameter file override, or contains a placeholder value (e.g., `00000000-0000-0000-0000-000000000000`, empty string), **stop and ask the user** to provide their actual Azure subscription ID, then **WAIT for the user's response**. Do NOT proceed to Step 2, do NOT produce the migration checklist, and do NOT fall back to the default mapping table until the user has responded. The agent's turn should end after asking — resume only when the user provides the value.

## Step 2 — Execute the API Call

Using the `subscriptionId`, `resourceGroupName`, and `clusterName` extracted from the script in Step 1, run the following command in the terminal:

```
az rest --method post --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Cache/redisEnterprise/{clusterName}/listSkusForScaling?api-version=2025-07-01"
```

Replace `{subscriptionId}`, `{resourceGroupName}`, and `{clusterName}` with the **literal values** extracted from the script parameters or provided by the user. **Never** substitute shell expressions like `$(az account show --query id -o tsv)` or any auto-detection command — always use an explicit subscription ID string.

## Step 3 — Parse the Response

A successful response looks like:

```json
{
  "value": [
    { "resourceType": "Microsoft.Cache/redisEnterprise", "sku": { "name": "Balanced_B10" } },
    { "resourceType": "Microsoft.Cache/redisEnterprise", "sku": { "name": "Balanced_B20" } }
  ]
}
```

Use the returned SKU names to recommend the target AMR SKU. If multiple SKUs are returned, recommend the one that most closely matches the user's current capacity and workload.

## Step 4 — Fallback on Failure

This step applies ONLY when the API call in Step 2 was actually **executed** and returned an error. Do NOT use this fallback to skip the API call when parameters are missing — if parameters are missing, go back to Step 1 and ask the user.

If the API call fails (common reasons: `az` CLI not logged in, cluster doesn't exist yet, network error, permission denied), then:

1. **Inform the user** why the API call failed (include the error message).
2. **Fall back** to the [default mapping table](#default-migration-mapping-fallback) below using the ACRE SKU + capacity from the script.
3. If the ACRE SKU + capacity combination is not in the mapping table, **ask the user** to specify the target AMR SKU.

---

## Default Migration Mapping (Fallback)

If `listSkusForScaling` is unavailable, use this table. These are the exact default mappings applied by the migration tooling.

| ACRE SKU | Capacity | Default AMR SKU |
|----------|----------|-----------------|
| `Enterprise_E1` | 2 | `Balanced_B1` |
| `Enterprise_E5` | 2 | `ComputeOptimized_X5` |
| `Enterprise_E5` | 4 | `Balanced_B10` |
| `Enterprise_E5` | 6 | `Balanced_B20` |
| `Enterprise_E10` | 2 | `Balanced_B20` |
| `Enterprise_E10` | 4 | `Balanced_B50` |
| `Enterprise_E10` | 6 | `Balanced_B50` |
| `Enterprise_E10` | 8 | `Balanced_B50` |
| `Enterprise_E10` | 10 | `Balanced_B100` |
| `Enterprise_E20` | 2 | `Balanced_B50` |
| `Enterprise_E20` | 4 | `Balanced_B100` |
| `Enterprise_E20` | 6 | `Balanced_B100` |
| `Enterprise_E20` | 8 | `Balanced_B100` |
| `Enterprise_E50` | 2 | `Balanced_B100` |
| `Enterprise_E50` | 4 | `Balanced_B100` |
| `Enterprise_E100` | 2 | `Balanced_B100` |

## AMR SKU Families

| Family | Prefix | Best For |
|--------|--------|----------|
| Balanced | `Balanced_B*` | General purpose workloads |
| Memory Optimized | `MemoryOptimized_M*` | Large datasets, high memory requirements |
| Compute Optimized | `ComputeOptimized_X*` | High-throughput, low-latency requirements |
| Flash Optimized | `FlashOptimized_A*` | Large datasets with flash storage (replaces EnterpriseFlash) |
