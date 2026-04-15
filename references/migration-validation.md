# Automated Migration: Validation Errors & Warnings

This reference covers the validation errors and warnings returned by the automated migration API when running the `Validate` action.

## Validation Errors

These are **blocking** — migration cannot proceed until resolved:

| Error | Resolution |
|-------|------------|
| Source cache must be in Running state | Ensure the source ACR cache is in Running state (not creating, scaling, or failed). If stuck in a failed state, create a support request. |
| Target cluster must be in Running state | If the target AMR cluster is in a transient state (Creating, Scaling), wait for it to reach Running. If it's stuck in a failed or other non-transient state, create a support request. |
| Target resource must have at least one database | Create at least one database on the target AMR resource |
| Unsupported target SKU | Use a supported Azure Managed Redis SKU as the target |
| Source and target must be in the same region | Select a target in the same Azure region as the source |
| Source and target must be in the same subscription | Move or recreate the target AMR cache in the same subscription as the source |
| Geo-replication enabled on source | Disable geo-replication on the source before migration |
| Private endpoints on source | Remove private endpoints from the source before migration |
| VNet injection enabled on source | Automated migration is not supported for VNet-injected caches. Use an alternative migration strategy (see [Migration Overview](migration-overview.md)). |
| TLS mismatch (source TLS-only, target non-TLS) | Configure the target database to support TLS connections |

## Validation Warnings

These are **non-blocking** — can be bypassed with `-ForceMigrate $true` (PowerShell) or `--force-migrate` (Bash):

| Warning | Resolution |
|---------|------------|
| Data migration not currently supported | Plan for manual data migration or accept data loss |
| Source has multiple databases; only DB 0 migrated | Manually migrate data from other databases |
| System-assigned managed identity not copied | System-assigned identities are unique per resource and cannot be copied. If the source ACR used SAMI for import/export to a storage account, enable SAMI on the target AMR resource and grant it the required role (e.g., Storage Blob Data Contributor) on the storage account. Note: AMR persistence itself uses managed disks internally and does not require a user storage account. |
| User-assigned managed identities not copied | If the source ACR had user-assigned managed identities (e.g., for import/export to a storage account), assign them to the target AMR resource after migration and ensure their role assignments on the storage account are still valid. |
| Custom ACL roles not copied | Custom ACLs are not yet supported in AMR. AMR only has a built-in `default` access policy (equivalent to ACR's Data Owner with full data access). Evaluate whether the `default` policy is sufficient for your use case, or plan to adopt custom policies once AMR adds support. |
| Clustering policy mismatch | Clustering policy cannot be changed on an existing AMR cache. If the source is clustered and the target is not using OSSCluster mode (e.g., is using EnterpriseCluster or non-clustered), the client application may need to be updated. If the client is using StackExchange.Redis, no update is needed. If a different clustering policy is required, create a new AMR cache with the desired policy. |
| Public network access mismatch | Enable public access on target or configure private endpoints |
| Firewall rules not copied | Firewall rules are not supported in AMR. Use Private Endpoints with NSG rules on the subnet to control network access instead. |
| HA mismatch | Enable HA on target or accept lower SLA |
| RDB/AOF persistence not copied | Configure persistence on target after migration |
| Custom update schedule not copied | Configure update schedule on target after migration |
| Keyspace notifications not copied | Enable keyspace notifications on target after migration |
