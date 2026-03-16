# Get Azure Cache for Redis metrics for SKU sizing
# Usage: .\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name> [-Days <n>] [-SourceSku <sku>] [-SourceTier <tier>]
#
# Requires: Azure CLI logged in (az login)
#
# Contains one reusable function (importable via dot-sourcing):
#   - Get-AcrCacheMetrics: Fetches metrics from Azure Monitor API, returns structured object
#
# When -SourceSku and -SourceTier are provided, automatically runs Get-MetricsBasedSkuSuggestion
# from AmrMigrationHelpers.ps1 and includes a concrete AMR SKU recommendation in the output.
#
# Standalone mode: displays formatted metrics table + SKU recommendation to console
# Library mode:    dot-source this file to import functions without running CLI display
#
# Examples:
#   # Standalone (metrics only)
#   .\get_acr_metrics.ps1 -SubscriptionId abc123 -ResourceGroup my-rg -CacheName my-cache
#
#   # Standalone with SKU recommendation
#   .\get_acr_metrics.ps1 -SubscriptionId abc123 -ResourceGroup my-rg -CacheName my-cache -SourceSku P2 -SourceTier Premium
#
#   # Library mode (dot-source)
#   . .\get_acr_metrics.ps1 -LibraryOnly
#   $metrics = Get-AcrCacheMetrics -SubscriptionId abc123 -ResourceGroup my-rg -CacheName my-cache

param(
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$false)]
    [string]$CacheName,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 90)]
    [int]$Days = 7,

    [Parameter(Mandatory=$false, HelpMessage = "Source ACR SKU (e.g., P2, C3) — enables metrics-based SKU recommendation")]
    [string]$SourceSku,

    [Parameter(Mandatory=$false, HelpMessage = "Source ACR tier (Basic, Standard, Premium) — required with -SourceSku")]
    [ValidateSet("Basic", "Standard", "Premium", "")]
    [string]$SourceTier,

    [Parameter(Mandatory=$false, HelpMessage = "Number of shards (Premium clustered only, default 1)")]
    [ValidateRange(1, 30)]
    [int]$ShardCount = 1,

    [Parameter(Mandatory=$false, HelpMessage = "Import functions only, do not run CLI display")]
    [switch]$LibraryOnly
)

# ═══════════════════════════════════════════════════════════════
# Reusable Functions
# ═══════════════════════════════════════════════════════════════

function Get-Percentile95 {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
    return $sorted[$index]
}

function Get-AcrCacheMetrics {
    <#
    .SYNOPSIS
        Fetches Azure Cache for Redis metrics from Azure Monitor API.
    .DESCRIPTION
        Calls Azure Monitor REST API to retrieve Used Memory RSS, Server Load,
        Connected Clients, Cache Read, and Cache Write metrics. Returns a structured
        PSCustomObject with Peak, P95, and Average values for each metric.
        Returns $null if metrics cannot be fetched (no az CLI, auth failure, cache not found).
    .PARAMETER SubscriptionId
        Azure subscription ID (GUID).
    .PARAMETER ResourceGroup
        Azure resource group name containing the cache.
    .PARAMETER CacheName
        Name of the Azure Cache for Redis instance.
    .PARAMETER Days
        Number of days of metrics history to retrieve (default: 7).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroup,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$CacheName,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 90)]
        [int]$Days = 7
    )

    # Get access token using Azure CLI
    $token = $null
    try {
        $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
        if (-not $token) {
            Write-Warning "Azure CLI returned empty access token. Run 'az login' first."
            return $null
        }
    } catch {
        Write-Warning "Failed to get Azure access token: $($_.Exception.Message). Run 'az login' first."
        return $null
    }

    # Build the metrics API URL
    $resourceUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cache/Redis/$CacheName"
    $metricNames = "usedmemoryRss,serverLoad,connectedclients,cacheRead,cacheWrite"
    $timespan = "P${Days}D"
    $interval = "PT1H"
    $apiVersion = "2023-10-01"
    $url = "https://management.azure.com${resourceUri}/providers/microsoft.insights/metrics?api-version=${apiVersion}&metricnames=${metricNames}&timespan=${timespan}&interval=${interval}&aggregation=Maximum,Average"

    $headers = @{ "Authorization" = "Bearer $token" }

    $response = $null
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    } catch {
        Write-Warning "Metrics API request failed for cache '$CacheName': $($_.Exception.Message)"
        return $null
    }

    if ($response.error) {
        Write-Warning "Metrics API error for cache '$CacheName': $($response.error.message)"
        return $null
    }

    # Parse metrics into structured object
    $result = [ordered]@{
        CacheName  = $CacheName
        SubscriptionId = $SubscriptionId
        ResourceGroup = $ResourceGroup
        Days       = $Days
    }

    foreach ($metric in $response.value) {
        $name = $metric.name.value   # e.g., "usedmemoryRss"
        $localName = $metric.name.localizedValue
        $unit = $metric.unit

        $maxValues = @()
        $avgValues = @()
        foreach ($ts in $metric.timeseries) {
            foreach ($point in $ts.data) {
                if ($null -ne $point.maximum) { $maxValues += $point.maximum }
                if ($null -ne $point.average) { $avgValues += $point.average }
            }
        }

        $peak = if ($maxValues.Count -gt 0) { ($maxValues | Measure-Object -Maximum).Maximum } else { $null }
        $p95  = Get-Percentile95 -Values $maxValues
        $avg  = if ($avgValues.Count -gt 0) { ($avgValues | Measure-Object -Average).Average } else { $null }

        $result[$name] = [PSCustomObject]@{
            DisplayName = $localName
            Unit        = $unit
            Peak        = $peak
            P95         = $p95
            Average     = $avg
        }
    }

    # Add convenience properties in GB/MB/s
    if ($result["usedmemoryRss"] -and $null -ne $result["usedmemoryRss"].Peak) {
        $result["UsedMemoryPeakGB"] = [math]::Round($result["usedmemoryRss"].Peak / 1GB, 2)
        $result["UsedMemoryP95GB"]  = if ($result["usedmemoryRss"].P95) { [math]::Round($result["usedmemoryRss"].P95 / 1GB, 2) } else { $null }
        $result["UsedMemoryAvgGB"]  = if ($result["usedmemoryRss"].Average) { [math]::Round($result["usedmemoryRss"].Average / 1GB, 2) } else { $null }
    }
    if ($result["serverLoad"] -and $null -ne $result["serverLoad"].Peak) {
        $result["ServerLoadPeak"]  = [math]::Round($result["serverLoad"].Peak, 1)
        $result["ServerLoadP95"]   = if ($result["serverLoad"].P95) { [math]::Round($result["serverLoad"].P95, 1) } else { $null }
        $result["ServerLoadAvg"]   = if ($result["serverLoad"].Average) { [math]::Round($result["serverLoad"].Average, 1) } else { $null }
    }
    if ($result["connectedclients"] -and $null -ne $result["connectedclients"].Peak) {
        $result["ConnectedClientsPeak"] = [int]$result["connectedclients"].Peak
    }
    if ($result["cacheRead"] -and $null -ne $result["cacheRead"].Peak) {
        $result["CacheReadPeakMBs"] = [math]::Round($result["cacheRead"].Peak / 1MB, 2)
    }
    if ($result["cacheWrite"] -and $null -ne $result["cacheWrite"].Peak) {
        $result["CacheWritePeakMBs"] = [math]::Round($result["cacheWrite"].Peak / 1MB, 2)
    }

    return [PSCustomObject]$result
}

# ═══════════════════════════════════════════════════════════════
# CLI Display (standalone mode only)
# ═══════════════════════════════════════════════════════════════

if ($LibraryOnly) { return }

# Validate required params for standalone mode
if (-not $SubscriptionId -or -not $ResourceGroup -or -not $CacheName) {
    Write-Host "ERROR: -SubscriptionId, -ResourceGroup, and -CacheName are required in standalone mode." -ForegroundColor Red
    Write-Host "       Use -LibraryOnly to import functions without running." -ForegroundColor Yellow
    exit 1
}

# Helper: format a value based on metric name/unit
function Format-MetricValue {
    param([string]$Name, [string]$Unit, $Value)
    if ($null -eq $Value) { return "N/A" }
    switch ($Name) {
        "Used Memory RSS" {
            $gb = [math]::Round($Value / 1GB, 2)
            return "{0:N0} bytes ({1} GB)" -f $Value, $gb
        }
        default {
            if ($Unit -eq "Percent") {
                return "{0:N1} %" -f $Value
            } elseif ($Unit -eq "BytesPerSecond") {
                $mbs = [math]::Round($Value / 1MB, 2)
                return "{0:N0} bytes/sec ({1} MB/s)" -f $Value, $mbs
            } else {
                return "{0:N0}" -f $Value
            }
        }
    }
}

Write-Host "============================================================"
Write-Host "Azure Cache for Redis - Metrics Query"
Write-Host "============================================================"
Write-Host "Subscription:   $SubscriptionId"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Cache Name:     $CacheName"
Write-Host "Time Range:     Last $Days days"
Write-Host ""

$metrics = Get-AcrCacheMetrics -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -CacheName $CacheName -Days $Days

if (-not $metrics) {
    Write-Host "ERROR: Failed to retrieve metrics. Check parameters and ensure 'az login' has been run." -ForegroundColor Red
    exit 1
}

Write-Host "------------------------------------------------------------"
Write-Host ("METRICS RESULTS (over last {0} days)" -f $Days)
Write-Host "------------------------------------------------------------"
Write-Host ""
Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f "Metric", "Peak", "P95", "Average")
Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f "------", "----", "---", "-------")

foreach ($metricName in @("usedmemoryRss", "serverLoad", "connectedclients", "cacheRead", "cacheWrite")) {
    $m = $metrics.$metricName
    if (-not $m) { continue }

    $peakStr = Format-MetricValue -Name $m.DisplayName -Unit $m.Unit -Value $m.Peak
    $p95Str  = Format-MetricValue -Name $m.DisplayName -Unit $m.Unit -Value $m.P95
    $avgStr  = Format-MetricValue -Name $m.DisplayName -Unit $m.Unit -Value $m.Average

    Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f $m.DisplayName, $peakStr, $p95Str, $avgStr)
}

Write-Host ""
Write-Host "Use these values to select an appropriate AMR SKU:"
Write-Host "  - Memory: Choose SKU with usable memory >= peak used memory"
Write-Host "  - Server Load: High Server Load (>70%) with low memory suggests Compute Optimized (X-series)"
Write-Host "  - Connections: Check max connections supported by target SKU"

# ── Metrics-based SKU Recommendation ──
if ($SourceSku -and $SourceTier) {
    $sharedPath = Join-Path $PSScriptRoot "AmrMigrationHelpers.ps1"
    if (Test-Path $sharedPath) {
        . $sharedPath

        $sourceConfig = [PSCustomObject]@{
            Sku        = $SourceSku
            Tier       = $SourceTier
            ShardCount = $ShardCount
        }

        $suggestion = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $sourceConfig
        if ($suggestion) {
            Write-Host ""
            Write-Host "============================================================"
            Write-Host "AMR SKU RECOMMENDATION (metrics-based)"
            Write-Host "============================================================"
            Write-Host "  Suggested Tier: $($suggestion.SuggestedTier)"
            Write-Host "  Suggested SKU:  $($suggestion.SuggestedSku)"
            Write-Host "  Confidence:     $($suggestion.Confidence)"
            Write-Host "  Reason:         $($suggestion.Reason)"
            if ($suggestion.Dimensions) {
                Write-Host ""
                Write-Host "  Decision inputs:"
                Write-Host "    Used Memory Peak:     $($suggestion.Dimensions.UsedMemoryPeakGB) GB"
                Write-Host "    Memory Utilization:   $($suggestion.Dimensions.MemoryUtilizationPct)%"
                Write-Host "    Server Load Peak:     $(if ($null -ne $suggestion.Dimensions.ServerLoadPeak) { "$($suggestion.Dimensions.ServerLoadPeak)%" } else { 'N/A' })"
                Write-Host "    Connected Clients:    $(if ($null -ne $suggestion.Dimensions.ConnectedClientsPeak) { $suggestion.Dimensions.ConnectedClientsPeak } else { 'N/A' })"
            }
        }
    } else {
        Write-Host ""
        Write-Warning "AmrMigrationHelpers.ps1 not found at $sharedPath — SKU recommendation skipped."
    }
} else {
    Write-Host ""
    Write-Host "TIP: Add -SourceSku <sku> -SourceTier <tier> to get an automated AMR SKU recommendation."
    Write-Host "     Example: .\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name> -SourceSku P2 -SourceTier Premium"
}

Write-Host ""
Write-Host "See references/sku-mapping.md for SKU selection guidance."
