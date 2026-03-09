# Automated Migration: Validation Errors & Warnings

This reference covers the validation errors and warnings returned by the automated migration API when running the `Validate` action.

## Validation Errors

These are **blocking** — migration cannot proceed until resolved:

| Error | Resolution |
|-------|------------|
| Target cluster must be in Running state | Wait for the target AMR cluster to reach Running state |
| Target resource must have at least one database | Create at least one database on the target AMR resource |
| Unsupported target SKU | Use an Azure Managed Redis (Gen2) SKU as the target |
| Source and target must be in the same region | Select a target in the same Azure region as the source |
| Source and target must be in the same subscription | Move or recreate the target AMR cache in the same subscription as the source |
| Geo-replication enabled on source | Disable geo-replication on the source before migration |
| Private endpoints on source | Remove private endpoints from the source before migration |
| VNet injection enabled on source | Use a non-VNet injected source cache |
| TLS mismatch (source TLS-only, target non-TLS) | Configure the target database to support TLS connections |

## Validation Warnings

These are **non-blocking** — can be bypassed with `-ForceMigrate $true` (PowerShell) or `--force-migrate` (Bash):

| Warning | Resolution |
|---------|------------|
| Data migration not currently supported | Plan for manual data migration or accept data loss |
| Source has multiple databases; only DB 0 migrated | Manually migrate data from other databases |
| Missing identities on target | Add missing identities to target's access policy assignments |
| System-assigned managed identity not copied | Configure managed identity on target after migration |
| User-assigned managed identities not copied | Assign required managed identities to target after migration |
| Custom ACL roles not copied | Manually recreate custom ACL roles on target |
| Clustering policy mismatch (target clustered, source not) | Ensure client is cluster-aware or use non-clustered target |
| OSS clustering policy mismatch | Configure OSSCluster policy on target or update application |
| Public network access mismatch | Enable public access on target or configure private endpoints |
| Firewall rules not copied | Document and re-create firewall rules on target |
| TLS mode mismatch | Update client applications to use the correct TLS mode |
| HA mismatch | Enable HA on target or accept lower SLA |
| RDB/AOF persistence not copied | Configure persistence on target after migration |
| Custom update schedule not copied | Configure update schedule on target after migration |
| Keyspace notifications not copied | Enable keyspace notifications on target after migration |
