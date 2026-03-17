# Interactive Cache Migration Procedure

> **Scope**: ACRE → AMR migration only (Azure Cache for Redis Enterprise → Azure Managed Redis). Do NOT use this for ACR (Basic/Standard/Premium) to AMR migrations.

When the user asks to **migrate their ACRE caches** (not just update automation scripts), the agent enters **interactive migration mode**. This mode discovers ACRE caches in the subscription, classifies them, determines the correct migration path, and walks the user through each step with confirmation gates.

> **⚠️ Safe Agent Policy**: This procedure touches **production infrastructure**. The agent MUST:
> 1. **Get explicit user confirmation** before every step that creates, modifies, or deletes a resource.
> 2. **NEVER delete any resource directly.** For all deletion steps (old ACRE cache, old Private Endpoint, old DNS zone), present the exact command or portal instructions and **instruct the user to execute it themselves**.
> 3. **Present one step at a time.** Wait for the user to confirm completion before moving to the next step.

---

## ⚠️ PowerShell `az rest --body` Handling

Passing inline JSON via `--body` to `az rest` is **unreliable on PowerShell** — quotes get stripped or mangled, producing `UnsupportedMediaType`, `InvalidRequestContent`, or similar errors. This affects all `az rest` calls with a `--body` parameter throughout this procedure (in-place migration, database creation, geo-replication patching, force-unlink, etc.).

**Always use the temp-file pattern** when executing `az rest --body` commands:

```powershell
# 1. Build the JSON body as a PowerShell object and serialize it
$body = @{ sku = @{ name = "{targetAmrSku}" }; properties = @{ publicNetworkAccess = "{value}" } } | ConvertTo-Json -Compress -Depth 5

# 2. Write to a temp file (UTF-8)
$body | Out-File -FilePath "$env:TEMP\az-rest-body.json" -Encoding utf8

# 3. Reference the file with the @ prefix
az rest --method patch --url "{url}" --body "@$env:TEMP\az-rest-body.json" -o json
```

> The `@` prefix tells `az rest` to read the body from a file. This works identically on PowerShell and bash and avoids all escaping issues.
>
> The inline `--body '{"key":"value"}'` examples shown in later steps are for **documentation clarity only**. When the agent executes them, it MUST use the temp-file pattern above.

---

## Phase 1 — Discovery

1. **List all Redis Enterprise caches** in the subscription (including networking configuration):
   ```
   az redisenterprise list --query "[].{name:name, resourceGroup:resourceGroup, location:location, sku:sku.name, capacity:sku.capacity, zones:zones, publicNetworkAccess:publicNetworkAccess, privateEndpointConnections:privateEndpointConnections}" -o json
   ```

2. **Classify each cache** as ACRE (Gen1) or AMR (Gen2):
   - **ACRE (Gen1)**: SKU starts with `Enterprise_` or `EnterpriseFlash_` and `capacity` is non-null
   - **AMR (Gen2)**: SKU starts with `Balanced_`, `MemoryOptimized_`, `ComputeOptimized_`, or `FlashOptimized_` and `capacity` is null

3. **For each ACRE cache**, check geo-replication status:
   ```
   az rest --method get --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{cacheName}/databases/default?api-version=2025-07-01" --query "properties.geoReplication" -o json
   ```
   - If `geoReplication` is null or empty → **standalone cache** → use [Phase 2A — In-Place Migration](#phase-2a--in-place-migration-standalone-caches)
   - If `geoReplication.linkedDatabases` contains entries → **geo-replicated cache** → use [Phase 2B — Geo-Replicated Migration](#phase-2b--geo-replicated-migration)

4. **For each ACRE cache with Private Endpoint connections** (i.e., `privateEndpointConnections` is non-empty), retrieve PE details:
   ```
   az network private-endpoint show --name "{privateEndpointName}" --resource-group "{resourceGroup}" --query "{name:name, subnet:subnet.id, vnet:subnet.id, privateLinkServiceConnections:privateLinkServiceConnections[0].name}" -o json
   ```
   - Extract PE name from `privateEndpointConnections[].id` (last segment of the resource ID).
   - Parse VNet and subnet names from `subnet.id`.
   - Store for post-migration PE setup.

5. **For each ACRE cache**, call `listSkusForScaling` API to determine the target AMR SKU (see [sku-resolution.md](sku-resolution.md)).

6. **Present the migration plan** to the user as a summary table:
   - Cache name, resource group, location, current SKU + capacity, target AMR SKU, geo-replication status
   - **Private Link status**: "Yes (PE: `{peName}`, VNet: `{vnetName}`, Subnet: `{subnetName}`)" or "No"
   - **Public Network Access**: current value (`Enabled`, `Disabled`, or `not set`)
   - For standalone caches: note that `amr-migration-data-preserve` tag is mandatory; explain `False` (recommended, faster) vs `True` (preserves data)
   - Ask the user to confirm the plan, `publicNetworkAccess` settings, and `amr-migration-data-preserve` preference
   - **WAIT for user confirmation** before proceeding

For each step in Phase 2, **present the step**, explain what it does, show the exact command(s), and **WAIT for user confirmation** before executing.

---
## Phase 2A — In-Place Migration (Standalone Caches)

For **standalone (non-geo-replicated) ACRE caches**, the SKU can be updated in-place.

> **Prerequisites**: Target AMR SKU resolved via `listSkusForScaling` in Phase 1. The mandatory resource tag `amr-migration-data-preserve` must be set before migration.

### Step 1 — Pre-migration Checks

Present (using Phase 1 values) and get confirmation:
- Current cache: `{cacheName}` in `{resourceGroup}`, region `{location}`
- Current SKU: `{skuName}` capacity `{capacity}` → Target: `{targetAmrSku}`
- Database config (modules, persistence, clustering policy) will be preserved
- Hostname will change: `*.redisenterprise.cache.azure.net` → `*.redis.azure.net`
- **Private Link**: show PE details from Phase 1 if applicable; note new PE will be needed post-migration
- **Public Network Access**: show confirmed value from Phase 1

**Ask**: "Ready to proceed with migrating `{cacheName}` to `{targetAmrSku}`?"

### Step 1.5 — Set the Mandatory `amr-migration-data-preserve` Tag

- **`False` (recommended)** — Data cleaned up during migration; faster and more reliable.
- **`True`** — Data preserved during migration.

**Ask the user** which value, then apply:
```
az redisenterprise update --name {cacheName} --resource-group {resourceGroup} --tags amr-migration-data-preserve={True|False}
```

Verify:
```
az redisenterprise show --name {cacheName} --resource-group {resourceGroup} --query "tags" -o json
```

> The migration will fail without this tag. Do NOT proceed to Step 2 without it.

### Step 2 — Execute In-Place Migration

> **Connection impact**: During the in-place migration, applications will experience a brief **connection blip** similar to what occurs during regular Azure maintenance operations. Most Redis client libraries handle this automatically via built-in reconnect logic. No action is required — connections will re-establish on their own. **Recommendation**: Perform this operation during non-business hours or a scheduled maintenance window to minimize user impact.
>
> **⚠️ No rollback**: Once an in-place migration to AMR completes, it **cannot be rolled back** to ACRE. If you need **rollback flexibility and full control** over the migration process, consider creating a **separate new AMR cache** instead, switching application traffic to it, verifying behavior, and only then decommissioning the old ACRE cache. This alternative is recommended when rollback capability is a priority — it is NOT needed to avoid the brief connection blip, which is handled automatically by Redis client reconnect logic.

Use `az redisenterprise update` which is a long-running operation that waits for completion automatically:

```powershell
az redisenterprise update --name {cacheName} --resource-group {resourceGroup} --sku "{targetAmrSku}" -o json
```

> This command blocks until the migration completes (typically **15–20 minutes**, but can take **30+ minutes** in some scenarios). There is no need to manually poll — the CLI waits and returns the final state.

If you need to monitor progress separately (e.g., if using `--no-wait` or `az rest`), poll at **60-second intervals** and **do NOT stop** after a fixed number of attempts. If the migration is still in progress, ask the user whether to continue monitoring:

```powershell
while ($true) {
    $result = az redisenterprise show --name {cacheName} --resource-group {resourceGroup} `
        --query "{provisioningState:provisioningState, sku:sku.name, hostName:hostName}" -o json 2>&1 | ConvertFrom-Json
    Write-Host "SKU=$($result.sku), State=$($result.provisioningState)"
    if ($result.provisioningState -ne "Updating") { break }
    Start-Sleep -Seconds 60
}
```

> If the agent's polling loop times out while the state is still `Updating`, **do NOT treat it as a failure**. Inform the user of the current state and ask whether they want to continue monitoring.

**Alternative — `az rest`**: If `az redisenterprise update` does not support a required parameter, fall back to the REST API. Use the **temp-file pattern** (see [PowerShell `az rest --body` Handling](#%EF%B8%8F-powershell-az-rest---body-handling) above):

```powershell
$body = @{ sku = @{ name = "{targetAmrSku}" }; properties = @{ publicNetworkAccess = "{publicNetworkAccessValue}" } } | ConvertTo-Json -Compress -Depth 5
$body | Out-File -FilePath "$env:TEMP\migration-body.json" -Encoding utf8
az rest --method patch --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{cacheName}?api-version=2025-07-01" --body "@$env:TEMP\migration-body.json" -o json
```

Wait for `provisioningState: Succeeded`.

### Step 3 — Verify Migration

```
az redisenterprise show --name {cacheName} --resource-group {resourceGroup} --query "{name:name, sku:sku.name, hostName:hostName, provisioningState:provisioningState}" -o json
```

Confirm: SKU is target AMR SKU, hostname is `*.redis.azure.net`, state is `Succeeded`.

### Step 4 — Post-migration: Private Endpoint Update (if applicable)

If the cache had Private Link (detected in Phase 1), use the discovered PE details (VNet: `{vnetName}`, Subnet: `{subnetName}`):

1. Create new Private DNS zone `privatelink.redis.azure.net` if it doesn't exist
2. Create new PE linked to the new DNS zone, same VNet/subnet as original
3. Update application connection string to `*.redis.azure.net`
4. Verify connectivity through new PE
5. **Instruct the user** to delete the old PE (`{peName}`) and old DNS zone (`privatelink.redisenterprise.cache.azure.net`) themselves — provide the exact commands but do NOT execute deletions

Present exact commands for each sub-step and **get user confirmation** before each.

### Step 5 — Post-migration: Update Application

Remind the user to:
- **Switch to the new AMR endpoint**: Both old (`*.redisenterprise.cache.azure.net`) and new (`*.redis.azure.net`) endpoints work after in-place migration, but the new endpoint is recommended. See [breaking-changes.md — Post-Migration Dual Endpoints](breaking-changes.md#post-migration-dual-endpoints-in-place-migration-only) for details.
- If using access keys, verify `accessKeysAuthentication` is `Enabled`
- Update automation scripts per [checklists.md](checklists.md)

---
## Phase 2B — Geo-Replicated Migration

For **geo-replicated ACRE caches**, in-place SKU migration is **NOT supported**. Use a **create-new-and-swap** approach: create a new AMR cache with the target SKU, add it to the geo-replication group, switch application traffic, then remove the old ACRE cache. Repeat for each ACRE member until the entire group is migrated.

> **Why?** In-place SKU change on a geo-replicated cache member is blocked by the platform. The geo-replication group does support a temporary **mixed state** (both ACRE and AMR members), which enables a rolling migration one member at a time.

### Mixed-Group Constraints

While ACRE and AMR members coexist in the same geo-replication group, the following constraints apply:

| Constraint | Detail |
|-----------|--------|
| **Maximum members** | Normally a geo-replication group allows **max 5 caches**. During migration, the limit is temporarily raised to **max 6 caches** to accommodate the transitional member. |
| **No scaling** | **No scaling operations** are allowed on **any** cache in the group (ACRE or AMR) until **all** members have been migrated to AMR SKUs. |
| **AMR-only additions** | After the first AMR cache is added to an ACRE geo-replication group, **only AMR caches** can be added as new members. Adding more ACRE caches is blocked. |

> **Plan ahead**: Because scaling is blocked during the mixed period, ensure the target AMR SKU (from `listSkusForScaling`) is the right size for your workload **before** you start adding AMR members. Complete the migration for all members as promptly as practical to minimize time in the mixed state.

### Step 1 — Identify Group Members

Present the group information from Phase 1:
```
Geo-Replication Group: {groupNickname}
Members:
  1. {cache-A} ({region-A}) — SKU: {sku-A}, Capacity: {capacity-A} — State: {state-A}
  2. {cache-B} ({region-B}) — SKU: {sku-B}, Capacity: {capacity-B} — State: {state-B}
```

**Ask**: "Which ACRE cache would you like to migrate first? (Recommended: start with a non-primary/read replica)"

### Step 2 — Create New AMR Cache

Create a new AMR cache with the target SKU returned by `listSkusForScaling`. The cache must have a **different name** (e.g., `{oldName}-amr`). Use the `publicNetworkAccess` value confirmed in Phase 1.

```
az redisenterprise create \
  --name "{newCacheName}" \
  --resource-group "{resourceGroup}" \
  --location "{region}" \
  --sku "{targetAmrSku}" \
  --minimum-tls-version "1.2" \
  --public-network-access "{publicNetworkAccessValue}"
```

Wait for provisioning, then verify and get user confirmation.

### Step 3 — Create Database on New Cache

Retrieve existing database config:
```
az rest --method get --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{oldCacheName}/databases/default?api-version=2025-07-01" --query "properties" -o json
```

Create matching database **without** geoReplication (added next step). Include `accessKeysAuthentication: Enabled` if using access keys. Use the **temp-file pattern** (see [PowerShell `az rest --body` Handling](#%EF%B8%8F-powershell-az-rest---body-handling)):

```powershell
# Build body from retrieved database config (adjust properties as needed)
$body = @{
    properties = @{
        clientProtocol = "{clientProtocol}"
        clusteringPolicy = "{clusteringPolicy}"
        evictionPolicy = "{evictionPolicy}"
        port = 10000
        modules = @(...)
        accessKeysAuthentication = "Enabled"
    }
} | ConvertTo-Json -Compress -Depth 5
$body | Out-File -FilePath "$env:TEMP\db-body.json" -Encoding utf8

az rest --method put --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{newCacheName}/databases/default?api-version=2025-07-01" --body "@$env:TEMP\db-body.json" -o json
```

### Step 4 — Add New Cache to Geo-Replication Group

Get current geo-replication config from an existing member, then PATCH to add the new member. Use the **temp-file pattern** (see [PowerShell `az rest --body` Handling](#%EF%B8%8F-powershell-az-rest---body-handling)):
```powershell
# Build body with all existing members + the new member
$body = @{
    properties = @{
        geoReplication = @{
            groupNickname = "{groupNickname}"
            linkedDatabases = @(
                @{ id = "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{existingMember1}/databases/default" },
                @{ id = "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{newCacheName}/databases/default" }
            )
        }
    }
} | ConvertTo-Json -Compress -Depth 10
$body | Out-File -FilePath "$env:TEMP\geo-body.json" -Encoding utf8

az rest --method patch --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{existingMemberCacheName}/databases/default?api-version=2025-07-01" --body "@$env:TEMP\geo-body.json" -o json
```

> The `linkedDatabases` array must include **all existing members** plus the new member.
> **Reminder**: Adding this AMR member means the group is now in a **mixed state**. No scaling or ACRE additions are allowed until all members are AMR.

Monitor until all members show `Linked` state before proceeding. Linking can take **15–30+ minutes**. Poll at **60-second intervals** and **do NOT stop** after a fixed number of attempts — if still in progress, ask the user whether to continue monitoring:

```powershell
while ($true) {
    $result = az rest --method get --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{existingMemberCacheName}/databases/default?api-version=2025-07-01" --query "properties.geoReplication.linkedDatabases[].{id:id, state:state}" -o json 2>&1
    Write-Host $result
    if ($result -notmatch '"Linking"') { break }
    Start-Sleep -Seconds 60
}
```

### Step 5 — Set Up Private Endpoint (if applicable)

If the old cache used Private Link, create equivalent networking for the new AMR cache using discovered PE details (VNet: `{vnetName}`, Subnet: `{subnetName}`):

1. Create Private DNS zone `privatelink.redis.azure.net` (if needed)
2. Link DNS zone to VNet
3. Create PE for new AMR cache in same VNet/subnet
4. Create DNS zone group on PE

See [breaking-changes.md — Private Endpoint Migration Strategies](breaking-changes.md#private-endpoint-migration-strategies) for details.

Present each sub-step and wait for user confirmation.

### Step 6 — Update Application

Provide new cache connection details and instruct user to update connection strings to `{newCacheName}.{region}.redis.azure.net:10000`.

**Ask**: "Have you updated your application and verified it works with the new AMR cache? (yes/no)"

**WAIT for confirmation** before proceeding to removal.

### Step 7 — Remove Old ACRE Cache from Group

> **CRITICAL**: Only proceed after user confirms the application is working.

**Instruct the user** to force-unlink the old ACRE cache from a **different** group member. Provide the exact command but do NOT execute it — the user must run it themselves. Use the **temp-file pattern** (see [PowerShell `az rest --body` Handling](#%EF%B8%8F-powershell-az-rest---body-handling)):
```powershell
$body = @{ ids = @("/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{oldCacheName}/databases/default") } | ConvertTo-Json -Compress -Depth 5
$body | Out-File -FilePath "$env:TEMP\unlink-body.json" -Encoding utf8

az rest --method post --url "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Cache/redisEnterprise/{anotherMemberCacheName}/databases/default/forceUnlink?api-version=2025-07-01" --body "@$env:TEMP\unlink-body.json" -o json
```

**Ask**: "Have you executed the force-unlink command? Please confirm once complete."

### Step 8 — Delete Old ACRE Cache

**Instruct the user** to delete the old ACRE cache and clean up old PE/DNS resources. Provide the exact commands but do NOT execute them:

```
az redisenterprise delete --name "{oldCacheName}" --resource-group "{resourceGroup}" --yes
```

If the old cache had Private Link, also instruct the user to delete the old PE and DNS zone manually.

**Ask**: "Have you deleted the old ACRE cache (and old PE/DNS if applicable)? Please confirm once complete."

### Step 9 — Repeat for Remaining ACRE Members

Present progress summary:
```
Geo-Replication Group: {groupNickname}
Migration Progress:
  ✅ {cache-A} ({region-A}) — Migrated → {newCache-A} ({targetAmrSku})
  ⏳ {cache-B} ({region-B}) — Next to migrate
```

**Ask**: "Ready to proceed with migrating the next ACRE cache?"

Repeat Steps 2–8 for each remaining ACRE member until the entire group runs on AMR SKUs. Once all members are AMR, the mixed-group constraints (no scaling, AMR-only additions) are lifted.

### Important Notes

- **Data preserved** via geo-replication sync — data replicates to the new AMR member before the old member is removed.
- **Application cutover is per-region**: update each region's application independently.
- **Group remains functional** throughout (same or more members at all times).
- **Rollback**: If issues arise after adding the new AMR cache but before deleting the old, switch the app back to the old cache endpoint and force-unlink the new AMR cache from the group.
- **Order**: Migrate read replicas first, primary last.
- **Complete promptly**: Minimize time in the mixed ACRE+AMR state to avoid the scaling restriction.