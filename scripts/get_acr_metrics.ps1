# Get Azure Cache for Redis metrics to help with AMR SKU selection
# Usage: .\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name> [-Days <n>]
#
# Requires: Azure CLI logged in (az login)
#
# Retrieves Peak, P95 and Average values for last N days (default 30):
#   - Used Memory RSS (bytes and GB)
#   - Server Load (%)
#   - Connected Clients
#   - Network Bandwidth Usage (bytes/sec)
#
# Examples:
#   .\get_acr_metrics.ps1 -SubscriptionId abc123 -ResourceGroup my-rg -CacheName my-cache
#   .\get_acr_metrics.ps1 -SubscriptionId abc123 -ResourceGroup my-rg -CacheName my-cache -Days 7

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [string]$CacheName,
    
    [Parameter(Mandatory=$false)]
    [int]$Days = 30
)

Write-Host "============================================================"
Write-Host "Azure Cache for Redis - Metrics Query"
Write-Host "============================================================"
Write-Host "Subscription:   $SubscriptionId"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Cache Name:     $CacheName"
Write-Host "Time Range:     Last $Days days"
Write-Host ""

# Get access token using Azure CLI
Write-Host "Fetching access token..."
try {
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "No token returned"
    }
} catch {
    Write-Host "ERROR: Failed to get access token. Please run 'az login' first." -ForegroundColor Red
    exit 1
}

Write-Host "Token acquired successfully."
Write-Host ""

# Build the metrics API URL
$resourceUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cache/Redis/$CacheName"
$metrics = "usedmemoryRss,serverLoad,connectedclients,cacheRead,cacheWrite"
$timespan = "P${Days}D"
$interval = "PT1H"  # 1 hour intervals for P95 calculation
$apiVersion = "2023-10-01"

$url = "https://management.azure.com${resourceUri}/providers/microsoft.insights/metrics?api-version=${apiVersion}&metricnames=${metrics}&timespan=${timespan}&interval=${interval}&aggregation=Maximum,Average"

Write-Host "Querying metrics..."
Write-Host ""

# Make the API call
$headers = @{
    "Authorization" = "Bearer $token"
}

try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
} catch {
    Write-Host "ERROR: API request failed" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Check for errors
if ($response.error) {
    Write-Host "ERROR: $($response.error.message)" -ForegroundColor Red
    exit 1
}

# Helper: compute P95 from a sorted array of values
function Get-Percentile95 {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
    return $sorted[$index]
}

# Helper: format a value based on metric name/unit
function Format-Value {
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

# Display results
Write-Host "------------------------------------------------------------"
Write-Host ("METRICS RESULTS (over last {0} days)" -f $Days)
Write-Host "------------------------------------------------------------"
Write-Host ""
Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f "Metric", "Peak", "P95", "Average")
Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f "------", "----", "---", "-------")

foreach ($metric in $response.value) {
    $name = $metric.name.localizedValue
    $unit = $metric.unit

    # Collect hourly data points
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

    $peakStr = Format-Value -Name $name -Unit $unit -Value $peak
    $p95Str  = Format-Value -Name $name -Unit $unit -Value $p95
    $avgStr  = Format-Value -Name $name -Unit $unit -Value $avg

    Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f $name, $peakStr, $p95Str, $avgStr)
}

Write-Host ""
Write-Host "Use these values to select an appropriate AMR SKU:"
Write-Host "  - Memory: Choose SKU with usable memory >= peak used memory"
Write-Host "  - Server Load: High Server Load (>70%) with low memory suggests Compute Optimized (X-series)"
Write-Host "  - Connections: Check max connections supported by target SKU"
Write-Host ""
Write-Host "See references/sku-mapping.md for SKU selection guidance."
