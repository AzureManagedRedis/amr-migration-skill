# Threat Model: AMR Migration Skill Scripts

**Document Version**: 1.0
**Date**: April 7, 2026
**Scope**: All scripts in `scripts/` directory of the `amr-migration-skill` repository
**Methodology**: STRIDE-based analysis + defense-in-depth review

---

## 1. System Overview

### 1.1 Purpose

These scripts assist Azure customers in migrating from Azure Cache for Redis (ACR) Basic/Standard/Premium tiers to Azure Managed Redis (AMR). They are executed locally on the user's machine by an AI agent (GitHub Copilot) or directly by the user.

### 1.2 Scripts In Scope

| Script | Function | Auth Mechanism | External APIs Called |
|--------|----------|----------------|---------------------|
| `Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1` | Automated migration (Validate/Migrate/Status/Cancel) | Azure CLI (`az account show`) | ARM REST API (`management.azure.com`) |
| `azure-redis-migration-arm-rest-api-utility.sh` | Automated migration (Validate/Migrate/Status/Cancel) | Azure CLI (`az rest`) | ARM REST API (`management.azure.com`) |
| `get_acr_metrics.ps1` | Retrieve cache performance metrics | Azure CLI (`az rest`) | Azure Monitor Metrics API (`management.azure.com`) |
| `get_acr_metrics.sh` | Retrieve cache performance metrics | Azure CLI (`az rest`) | Azure Monitor Metrics API (`management.azure.com`) |
| `get_redis_price.ps1` | Look up Redis pricing | None (public API) | Azure Retail Prices API (`prices.azure.com`) |
| `get_redis_price.sh` | Look up Redis pricing | None (public API) | Azure Retail Prices API (`prices.azure.com`) |

### 1.3 Data Flow Diagram

```
┌──────────────┐      ┌─────────────────┐      ┌──────────────────────┐
│   User /     │─────▶│   Script        │─────▶│  Azure ARM API       │
│   AI Agent   │      │   (local exec)  │      │  management.azure.com│
└──────────────┘      └────────┬────────┘      └──────────────────────┘
                               │
                               │  (pricing only)
                               ▼
                      ┌──────────────────────┐
                      │  Azure Retail Prices │
                      │  prices.azure.com    │
                      │  (unauthenticated)   │
                      └──────────────────────┘
```

### 1.4 Trust Boundaries

| Boundary | Description |
|----------|-------------|
| **TB-1**: User machine ↔ Azure ARM API | Authenticated HTTPS calls to `management.azure.com` |
| **TB-2**: User machine ↔ Pricing API | Unauthenticated HTTPS calls to `prices.azure.com` |
| **TB-3**: AI Agent ↔ Script execution | Agent constructs parameters and invokes scripts on user's behalf |
| **TB-4**: Script ↔ Local filesystem | Local filesystem access during script execution |

---

## 2. Assets

| ID | Asset | Sensitivity | Location |
|----|-------|------------|----------|
| A-1 | Azure access tokens (Bearer tokens) | **Critical** — grants ARM API access to the user's subscription | Managed internally by Azure CLI (`az rest`); no direct handling in scripts |
| A-2 | Subscription IDs, resource group names, cache names | **Medium** — infrastructure metadata | Script parameters, console output |
| A-3 | Cache access keys | **High** — migrated as part of the DNS switch operation | Handled server-side by ARM API; not in script memory |
| A-4 | Cache metrics data | **Low** — performance telemetry | Console output only |
| A-5 | Azure resource IDs | **Medium** — can be used to target operations | Script parameters |
| A-6 | Pricing data | **Public** — no sensitivity | Console output |

---

## 3. Threat Analysis (STRIDE)

### 3.1 Spoofing

| ID | Threat | Scripts Affected | Severity | Likelihood | Existing Mitigations | Residual Risk |
|----|--------|-----------------|----------|------------|---------------------|---------------|
| S-1 | **Attacker replays or steals Azure access token** to perform unauthorized migration operations | All ARM-authenticated scripts | **High** | Low | Tokens are short-lived (default ~1 hr); Azure CLI manages token lifecycle internally via `az rest` — no scripts handle tokens directly | Token is managed by Azure CLI internals. If machine is compromised, attacker could use `az rest` directly. |
| S-2 | **Man-in-the-middle on ARM API calls** intercepts token or modifies payloads | All ARM-authenticated scripts | **High** | Very Low | All calls use HTTPS to `management.azure.com`; PS scripts enforce TLS 1.2+ (`[Net.ServicePointManager]::SecurityProtocol`); Azure CLI enforces TLS by default | Negligible with TLS. No certificate pinning, but standard for Azure SDK clients. |
| S-3 | **Spoofed pricing API response** returns misleading prices to influence SKU selection | `get_redis_price.ps1`, `get_redis_price.sh` | **Low** | Very Low | HTTPS to `prices.azure.com`; pricing is informational, not actionable | No authentication — response integrity depends on TLS only. |

### 3.2 Tampering

| ID | Threat | Scripts Affected | Severity | Likelihood | Existing Mitigations | Residual Risk |
|----|--------|-----------------|----------|------------|---------------------|---------------|
| T-1 | **Tampered script files** — attacker modifies scripts to alter migration parameters | All | **Critical** | Low | Scripts are source-controlled in Git; users can verify integrity via commit hashes | No code signing. If repo is compromised or user downloads from untrusted source, scripts could be backdoored. |
| T-2 | ~~**Temp file tampering** — attacker replaces response before script reads it~~ | ~~`get_acr_metrics.sh`~~ | N/A | N/A | ✅ **Eliminated.** Metrics scripts now use `az rest` which returns output directly — no temp files are created. | No residual risk. |
| T-3 | **Modified ARM API response** alters migration status, causing user to believe migration succeeded when it failed | Migration scripts | **Medium** | Very Low | HTTPS protects in transit; scripts display raw API response for user verification | Server-side trust — scripts trust ARM API responses as authoritative. |

### 3.3 Repudiation

| ID | Threat | Scripts Affected | Severity | Likelihood | Existing Mitigations | Residual Risk |
|----|--------|-----------------|----------|------------|---------------------|---------------|
| R-1 | **No audit trail** — migration actions performed via scripts lack local logging | Migration scripts | **Medium** | Medium | ARM API logs all operations in Azure Activity Log; PS script displays `x-ms-request-id` and `x-ms-correlation-request-id` headers for traceability | Bash script does not display correlation headers (`az rest` limitation). No local log file is written by any script. |
| R-2 | **AI agent-initiated operations** — unclear whether the user or agent triggered a destructive migration | Migration scripts | **Medium** | Medium | PS script uses `SupportsShouldProcess` (`-WhatIf`/`-Confirm` support); Bash script has interactive confirmation prompt (`--yes` to skip); SKILL.md mandates agent must use `ask_user` before executing destructive actions | When AI agent runs scripts, it passes `--yes` to bypass the terminal prompt — but only after obtaining user consent via `ask_user`. Residual risk is low. |

### 3.4 Information Disclosure

| ID | Threat | Scripts Affected | Severity | Likelihood | Existing Mitigations | Residual Risk |
|----|--------|-----------------|----------|------------|---------------------|---------------|
| I-1 | **Token exposure in process table** — Bearer token visible in `/proc/<pid>/cmdline` | ~~`get_acr_metrics.sh`~~ | **High** | ~~Medium~~ → **None** | ✅ **Eliminated.** All scripts now use `az rest` which handles tokens internally — no tokens appear in script variables or command-line arguments. | No residual risk. |
| I-2 | **Token in shell history** — if user manually exports or echoes the token | ~~All shell scripts~~ | **Low** | ~~Low~~ → **None** | ✅ **Eliminated.** No scripts call `az account get-access-token`. Tokens are never exposed to script variables or shell history. | No residual risk. |
| I-3 | **Subscription/resource IDs in console output** — visible to shoulder-surfing or screen recording | All | **Low** | Medium | Necessary for script functionality; no suppression | These are operational parameters, not secrets. Acceptable risk. |
| I-4 | **Verbose error output** may reveal internal ARM API details | Migration PS script | **Low** | Low | `Print-Response` limits output depth (`ConvertTo-Json -Depth 3`); raw response only shown with `-Verbose` flag | Controlled disclosure. |
| I-5 | **Metrics data exposure** — cache performance data displayed in terminal | Metrics scripts | **Low** | Low | Data is informational (memory, CPU, connections); not considered secret | Acceptable — this is the script's purpose. |

### 3.5 Denial of Service

| ID | Threat | Scripts Affected | Severity | Likelihood | Existing Mitigations | Residual Risk |
|----|--------|-----------------|----------|------------|---------------------|---------------|
| D-1 | **Accidental migration of production cache** — user targets wrong cache, causing service disruption | Migration scripts | **Critical** | Medium | PS script supports `-WhatIf`/`-Confirm` via `ShouldProcess`; Bash script has interactive confirmation prompt; Validate action exists as a pre-check; Cancel/Rollback operation available; SKILL.md mandates agent display resource IDs and confirm with user | AI agent may construct resource IDs incorrectly. No "dry run" beyond Validate. |
| D-2 | **ForceMigrate bypasses safety warnings** — user or agent sets `--force-migrate` without understanding implications | Migration scripts | **High** | Medium | Default is `false`; SKILL.md documents when to use it | Agent could set it based on user instruction without explaining the risk. |
| D-3 | **Polling loop resource consumption** — bash tracking mode polls indefinitely on network issues | `azure-redis-migration-arm-rest-api-utility.sh` | **Low** | Low | Hard cap at 60 iterations (30 minutes max) | Bounded. Acceptable. |

### 3.6 Elevation of Privilege

| ID | Threat | Scripts Affected | Severity | Likelihood | Existing Mitigations | Residual Risk |
|----|--------|-----------------|----------|------------|---------------------|---------------|
| E-1 | **Scripts execute with caller's full Azure permissions** — no principle of least privilege enforcement | All ARM-authenticated scripts | **Medium** | N/A (by design) | Scripts use whatever Azure context the user has logged in with; Azure RBAC controls actual permissions | If user has Owner/Contributor on the subscription, scripts can perform any supported operation. No scope-down mechanism. |
| E-2 | **AI agent has same permissions as user** — agent can perform destructive operations (Migrate, Cancel) without additional authorization | Migration scripts | **High** | Medium | PS script `ShouldProcess` provides confirmation gate for Migrate and Cancel | Agent typically auto-confirms prompts. No separate authorization mechanism for agent-driven vs. user-driven execution. |

---

## 4. Input Validation Review

### 4.1 Summary by Script

| Script | Input Validation | Assessment |
|--------|-----------------|------------|
| **Migration PS** | `ValidateSet` on Action; `ValidatePattern` regex on SourceResourceId; regex parsing on TargetResourceId | ✅ Strong — constrained parameter sets, regex validation |
| **Migration Bash** | Regex validation on SourceResourceId; regex parsing on TargetResourceId; API version format check | ✅ Strong — equivalent to PS version |
| **Metrics PS** | `ValidatePattern` on SubscriptionId (`^[a-fA-F0-9-]+$`), ResourceGroup (`^[a-zA-Z0-9._-]+$`), CacheName (`^[a-zA-Z0-9-]+$`); `ValidateRange(1,30)` on Days | ✅ Strong |
| **Metrics Bash** | Regex checks on all parameters; range check on Days (1–30) | ✅ Strong — mirrors PS validation |
| **Pricing PS** | `ValidatePattern` on SKU (`^[a-zA-Z][a-zA-Z0-9]*$`), Region (`^[a-z0-9]+$`), Currency (`^[A-Z]{3}$`); `ValidateRange` on Shards (1–30), Replicas (1–3); `ValidateSet` on Tier | ✅ Strong |
| **Pricing Bash** | Regex checks on SKU, Region, Currency, Shards, Replicas; range checks | ✅ Strong — mirrors PS validation |

### 4.2 OData / API Filter Injection

The pricing scripts construct OData `$filter` queries using user-supplied Region and SKU values:

- **PS (`get_redis_price.ps1`)**: Escapes single quotes in Region and MeterName (`-replace "'", "''"`) before embedding in the filter string, then URL-encodes via `[System.Uri]::EscapeDataString()`. ✅ **Mitigated.**
- **Bash (`get_redis_price.sh`)**: Uses `python3 urllib.parse.quote()` for URL encoding. Input validation regex (`^[a-z0-9]+$` for region, `^[a-zA-Z][a-zA-Z0-9]*$` for SKU) prevents special characters from reaching the filter. ✅ **Mitigated.**

### 4.3 Command Injection

- **Migration Bash**: Uses `jq -n` with `--arg` for JSON payload construction, avoiding shell interpolation of user values into JSON. ✅ **Mitigated.**
- **Metrics Bash**: User parameters are passed to `az redis show` and `az rest` as separate arguments (not shell-interpolated into commands). No direct token handling. ✅ **Mitigated.**
- **Pricing Bash**: User values passed to `python3 -c` via `sys.argv`, not via string interpolation. ✅ **Mitigated.**

---

## 5. Sensitive Data Handling

| Data | Script | Handling | Assessment |
|------|--------|----------|------------|
| **Bearer token** | `get_acr_metrics.ps1` | Managed internally by `az rest` (CLI handles token lifecycle) | ✅ Good — no direct token handling |
| **Bearer token** | `get_acr_metrics.sh` | Managed internally by `az rest` (CLI handles token lifecycle) | ✅ Good — no direct token handling |
| **Bearer token** | Migration PS | Managed internally by Azure CLI (`az rest` handles token lifecycle) | ✅ Good — no direct token handling |
| **Bearer token** | Migration Bash | Managed internally by `az rest` (CLI handles token lifecycle) | ✅ Good — no direct token handling |
| **API responses** | All | Printed to console (stdout) | ℹ️ By design — user needs to see results |

---

## 6. Identified Risks & Recommendations

### 6.1 High Priority

| ID | Risk | Recommendation | Effort |
|----|------|----------------|--------|
| **R-HIGH-1** | **Temp file in shared `/tmp`** (T-2): `get_acr_metrics.sh` uses a predictable filename `/tmp/acr_metrics_response.json`. On multi-user systems, another user could symlink-attack or read this file. | Use `mktemp` to create a unique temp file: `TMPFILE=$(mktemp /tmp/acr_metrics_XXXXXX.json)` and use a `trap` to clean it up on exit. | ✅ **Resolved** |
| **R-HIGH-2** | **No confirmation in Bash migration script** (D-1, R-2): The bash migration script performs Migrate and Cancel without any user confirmation, unlike the PS script which supports `ShouldProcess`. | Add a confirmation prompt for destructive actions (Migrate, Cancel) in the bash script, with a `--yes` flag to skip for automation. | ✅ **Resolved** |
| **R-HIGH-3** | **Agent-driven destructive operations** (E-2): AI agent can execute Migrate/Cancel on behalf of the user without explicit authorization beyond the initial conversation. | Document in SKILL.md that the agent must always display the full source and target resource IDs and request explicit user confirmation before executing Migrate or Cancel actions. | ✅ **Resolved** |

### 6.2 Medium Priority

| ID | Risk | Recommendation | Effort |
|----|------|----------------|--------|
| **R-MED-1** | **No local audit log** (R-1): Migration operations are not logged locally. If the user needs to reconstruct what happened, they must query Azure Activity Log. | Consider writing a local log entry (timestamp, action, source, target, result) to a file in the user's home directory or current directory for traceability. | Low |
| **R-MED-2** | **Bash migration script does not display correlation headers** (R-1): Makes troubleshooting harder since `az rest` doesn't expose response headers. | Add a note in script output recommending users check Azure Activity Log with the timestamp for the `x-ms-correlation-request-id`. | Low |
| **R-MED-3** | **`--api-version` is user-configurable in bash migration script**: While the format is validated (`YYYY-MM-DD(-preview)?`), allowing API version override could lead to unexpected behavior with untested API versions. | Consider removing the `--api-version` parameter or documenting it as advanced/unsupported. The PS script correctly hardcodes this as an internal constant. | Low |

### 6.3 Low Priority

| ID | Risk | Recommendation | Effort |
|----|------|----------------|--------|
| **R-LOW-1** | **No script integrity verification** (T-1): Users downloading or cloning scripts have no way to verify they haven't been tampered with. | Publish SHA-256 checksums of released script versions in the repository's `VERSION` file or releases page. | Low |
| **R-LOW-2** | **Pricing API responses not validated** (S-3): Scripts trust pricing API responses without schema validation. A malformed response could cause unexpected script behavior. | Add basic response structure validation (check for expected JSON keys) before processing. | Low |

---

## 7. Security Controls Summary

### 7.1 Controls Already In Place

| Control | Implementation | Coverage |
|---------|---------------|----------|
| **Input validation** | Regex patterns on all user-supplied parameters (PS `ValidatePattern`/`ValidateSet`/`ValidateRange`; Bash regex checks) | All scripts ✅ |
| **TLS enforcement** | `[Net.ServicePointManager]::SecurityProtocol = Tls12` (PS); HTTPS URLs (all) | All scripts ✅ |
| **Token delegation** | All scripts delegate token handling to Azure CLI (`az rest`) — no direct token acquisition or storage | All ARM-authenticated scripts ✅ |
| **OData injection prevention** | Single-quote escaping + URL encoding (PS pricing); input charset restriction (Bash pricing) | Pricing scripts ✅ |
| **Command injection prevention** | `jq --arg` for JSON construction; `sys.argv` for Python parameter passing | Bash scripts ✅ |
| **Destructive action confirmation** | `SupportsShouldProcess` on PS migration script (supports `-WhatIf`/`-Confirm`); interactive confirmation prompt on Bash migration script (`--yes` to skip) | Migration scripts ✅ |
| **Agent confirmation mandate** | SKILL.md requires agent to display resource IDs and use `ask_user` for explicit confirmation before Migrate/Cancel | SKILL.md ✅ |
| **API version pinning** | Hardcoded as internal constant (PS migration) | PS migration ✅ |
| **Bounded polling** | 60-iteration cap (30 min) on tracking loop | Bash migration ✅ |
| **Error handling** | `$ErrorActionPreference = "Stop"` (PS); `set -euo pipefail` (Bash) | All scripts ✅ |

### 7.2 STRIDE Residual Risk Heat Map

| Category | Risk Level | Key Concern |
|----------|-----------|-------------|
| **Spoofing** | 🟢 Low | Tokens are short-lived; TLS enforced; no custom auth flows; no direct token handling |
| **Tampering** | 🟢 Low | No script signing; no temp files used |
| **Repudiation** | 🟡 Medium | No local logging; bash migration lacks correlation headers |
| **Information Disclosure** | 🟢 Low | No direct token handling; no secrets in output |
| **Denial of Service** | 🟠 Medium-High | Accidental migration of wrong cache; no confirmation in bash |
| **Elevation of Privilege** | 🟡 Medium | Scripts run with caller's full Azure permissions (by design) |

---

## 8. Deployment Context & Assumptions

1. **Scripts run on the user's local machine** — not in a shared server or CI/CD pipeline. Threats assume a workstation attack surface.
2. **Azure authentication is pre-established** — scripts rely on existing `az login` sessions. They do not handle or store long-lived credentials.
3. **AI agent orchestration** — scripts may be invoked by an AI agent (GitHub Copilot) that constructs parameters from user conversation. The agent is trusted to the same level as the user.
4. **Public preview API** — the migration ARM API (`2025-08-01-preview`) is in preview. Behavior may change, and the API version will need to be updated.
5. **No customer data in scripts** — cache data itself is never read, stored, or transmitted by these scripts. Migration with `skipDataMigration: true` only switches DNS and port forwarding.

---

## 9. Appendix: Script-by-Script Security Profile

### A. Migration Scripts (PS + Bash)

- **Impact**: **Critical** — can initiate irreversible DNS switches on production caches
- **Authentication**: Azure AD via Azure CLI (both PS and Bash)
- **Destructive operations**: Migrate (DNS switch), Cancel (rollback)
- **Safety mechanisms**: Validate pre-check; `ShouldProcess` (PS only); Cancel/Rollback available
- **ARM API scope**: `Microsoft.Cache/redisEnterprise/migrations` — requires Contributor or specific RBAC on the target AMR resource

### B. Metrics Scripts (PS + Bash)

- **Impact**: **Low** — read-only; retrieves performance telemetry
- **Authentication**: Azure CLI (`az rest`) — token managed internally by CLI
- **API scope**: `microsoft.insights/metrics` — read-only, requires Monitoring Reader or equivalent
- **Sensitive data**: No direct token handling; metrics data (non-sensitive)

### C. Pricing Scripts (PS + Bash)

- **Impact**: **None** — read-only; queries public API
- **Authentication**: None required
- **API scope**: Azure Retail Prices API (public, unauthenticated)
- **Sensitive data**: None

---

*This threat model should be reviewed whenever scripts are modified, new scripts are added, or the ARM API moves from preview to GA.*
