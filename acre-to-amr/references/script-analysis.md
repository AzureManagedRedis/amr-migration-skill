# Script Analysis Guide

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

This document covers how to **detect**, **validate**, and **prepare** a user's automation script for ACRE → AMR migration analysis.

---

## Step 1 — Detect the Script Type

| Automation Type | Detection Pattern |
|----------------|-------------------|
| **ARM Template** | JSON file containing `"type": "Microsoft.Cache/redisEnterprise"` and `"apiVersion"` |
| **ARM Parameters File** | JSON file with `"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"` — typically named `*.parameters.json` |
| **Bicep Template** | `.bicep` file containing `resource ... 'Microsoft.Cache/redisEnterprise@...'` |
| **Bicep Parameters File** | `.bicepparam` file with `using '...'` reference to a `.bicep` file |
| **Azure CLI** | Shell script with commands starting with `az redisenterprise` |
| **Azure PowerShell** | PowerShell script with cmdlets like `New-AzRedisEnterpriseCache`, `Get-AzRedisEnterpriseCache`, `Set-AzRedisEnterpriseCache`, `New-AzRedisEnterpriseCacheDatabase` |

---

## Step 2 — Read Companion Parameter Files

ARM and Bicep templates often use **companion parameter files** that supply concrete values for parameters defined in the main template. **Always search for and read these files** before concluding that a parameter value is missing or unresolvable.

- **ARM**: Look for `*.parameters.json` files in the same directory as the template, or elsewhere in the workspace. The parameter file contains a `"parameters"` object with concrete values that override template `defaultValue` entries. For example, a `subscriptionId` parameter with `defaultValue` of `[subscription().subscriptionId]` in the template may have a real GUID like `"abd54813-fc1c-4d37-8457-723f2b3e480b"` in the parameters file.
- **Bicep**: Look for `.bicepparam` files (e.g., `main.bicepparam`) in the same directory. These files use `using 'main.bicep'` syntax and assign concrete values with `param paramName = 'value'`.

**Resolution order for parameter values**: (1) companion parameter file value → (2) template `defaultValue` / default → (3) ask the user.

---

## Step 3 — Confirm it is an ACRE (Gen1) Script

Look for these Gen1 indicators:
- SKU names: `Enterprise_E1`, `Enterprise_E5`, `Enterprise_E10`, `Enterprise_E20`, `Enterprise_E50`, `Enterprise_E100`, `Enterprise_E200`, `Enterprise_E400`, `EnterpriseFlash_F300`, `EnterpriseFlash_F700`, `EnterpriseFlash_F1500`
- `sku.capacity` property is present and set (e.g., `2`, `4`, `6` for Enterprise; `3`, `9` for EnterpriseFlash)
- `zones` property is present (e.g., `["1", "2", "3"]`)
- API version older than `2024-09-01-preview`
- DNS references to `redisenterprise.cache.azure.net`

If the SKU is already a Gen2 SKU (`Balanced_*`, `MemoryOptimized_*`, `ComputeOptimized_*`, `FlashOptimized_*`), inform the user no migration changes are needed.

---

## Step 4 — Validate Before Producing the Checklist

After detecting the script type and confirming Gen1, verify the following:

1. **Scope check**: Confirm the script targets `Microsoft.Cache/redisEnterprise` (not `Microsoft.Cache/redis`). If it targets ACR, stop and explain.
2. **Execute `listSkusForScaling` API call**: Extract the cluster name, resource group, and subscription ID from the script **and its companion parameter files** (see Step 2 above for resolution order). If any required value cannot be resolved to a concrete value, **stop and ask the user, then WAIT for the response**. Do NOT proceed to the checklist or fall back to the mapping table while waiting. Once all parameters are available, execute the API call per [sku-resolution.md](sku-resolution.md). Only if the API call fails after execution, fall back to the [default mapping table](sku-resolution.md#default-migration-mapping-fallback).
3. **SKU name**: Verify the old SKU name is a valid Gen1 SKU. The parameter file value takes precedence over template defaults. If unresolvable, ask the user.
4. **Capacity removal**: Confirm that `capacity` (or `--capacity` or `-SkuCapacity`) exists and needs to be removed. Check parameter files too.
5. **Zones removal**: Check if `zones` (or `--zones` or `-Zone`) is present and flag for removal.
6. **API version**: Flag for update to `2025-07-01` if using any older version.
7. **DNS references**: Scan for any `redisenterprise.cache.azure.net` strings and flag for update. See [breaking-changes.md — DNS and Connection String Updates](breaking-changes.md#dns-and-connection-string-updates).
8. **Private DNS zone and Private Endpoint**: Scan for `privatelink.redisenterprise.cache.azure.net` and PE resources. If found, present the two migration options described in [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies). For ARM/Bicep, remind the user that incremental deployments do **not** delete resources removed from the template.
9. **Access keys**: Check whether `accessKeysAuthentication` is explicitly set. If not, warn per [breaking-changes.md — accessKeysAuthentication](breaking-changes.md#properties-that-change).
10. **Public network access**: Check whether `publicNetworkAccess` is specified. If not, flag as **mandatory**. If the script configures Private Link, suggest `Disabled`. Otherwise, ask the user.
11. **Scaling logic**: Look for any capacity-based scaling patterns and flag for rewrite.

For common deployment failures and their fixes, see [troubleshooting.md](troubleshooting.md).
