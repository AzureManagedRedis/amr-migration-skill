# Get Azure Cache for Redis metrics to help with AMR SKU selection
# Usage: .\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name> [-Days <n>]
#
# Requires: Azure CLI logged in (az login) with 'az rest' support
#
# Retrieves Peak, P95 and Average values for last N days (default 7):
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
    [ValidatePattern('^[a-fA-F0-9-]+$')]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-zA-Z0-9._-]+$')]
    [string]$ResourceGroup,
    
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string]$CacheName,
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 30)]
    [int]$Days = 7
)

# Enforce TLS 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "============================================================"
Write-Host "Azure Cache for Redis - Metrics Query"
Write-Host "============================================================"
Write-Host "Subscription:   $SubscriptionId"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Cache Name:     $CacheName"
Write-Host "Time Range:     Last $Days days"
Write-Host ""

# Detect shard count for clustered Premium caches
$shardCount = 0
try {
    $shardInfo = az redis show -n $CacheName -g $ResourceGroup --subscription $SubscriptionId --query "shardCount" -o tsv 2>$null
    if ($shardInfo -and $shardInfo -ne "null" -and $shardInfo -ne "") {
        $shardCount = [int]$shardInfo
    }
} catch {
    Write-Warning "Could not detect shard count (non-clustered or access issue): $($_.Exception.Message)"
}

# Build the metrics API URL
$resourceUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Cache/Redis/$CacheName"
$metrics = "usedmemoryRss,serverLoad,connectedclients,cacheRead,cacheWrite"
$timespan = "P${Days}D"
$interval = "PT1H"  # 1 hour intervals for P95 calculation
$apiVersion = "2023-10-01"

$url = "https://management.azure.com${resourceUri}/providers/microsoft.insights/metrics?api-version=${apiVersion}&metricnames=${metrics}&timespan=${timespan}&interval=${interval}&aggregation=Maximum,Average"

# For clustered caches, request per-shard metrics so we can aggregate correctly
if ($shardCount -gt 1) {
    $url += "&`$filter=ShardId eq '*'"
}

Write-Host "Querying metrics..."
Write-Host ""

# Make the API call using az rest (handles authentication automatically)
try {
    $response = az rest --method GET --url $url -o json 2>$null | ConvertFrom-Json
    if (-not $response) {
        throw "No response returned"
    }
} catch {
    Write-Host "ERROR: API request failed. Check credentials and resource parameters." -ForegroundColor Red
    Write-Host "Ensure you are logged in with 'az login' and have Reader access to the resource." -ForegroundColor Red
    Write-Verbose $_.Exception.Message
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

# Helper: determine how to aggregate per-shard values for each metric
# Sum: total across shards (memory, bandwidth)
# Max: bottleneck/per-shard value (server load, connected clients)
function Get-ShardAggregation {
    param([string]$MetricId)
    switch ($MetricId) {
        "usedmemoryRss" { return "Sum" }
        "cacheRead"     { return "Sum" }
        "cacheWrite"    { return "Sum" }
        default         { return "Max" }
    }
}

# Helper: aggregate per-shard timeseries into a single set of data points
function Merge-ShardTimeseries {
    param(
        [array]$Timeseries,
        [string]$AggregationType
    )

    if ($Timeseries.Count -le 1) {
        if ($Timeseries.Count -eq 1) { return $Timeseries[0].data }
        return @()
    }

    # Group data points by timestamp across all shards
    $byTimestamp = @{}
    foreach ($ts in $Timeseries) {
        foreach ($point in $ts.data) {
            $key = $point.timeStamp
            if (-not $byTimestamp.ContainsKey($key)) {
                $byTimestamp[$key] = @()
            }
            $byTimestamp[$key] += $point
        }
    }

    # Aggregate per timestamp
    $aggregated = @()
    foreach ($key in $byTimestamp.Keys) {
        $points = $byTimestamp[$key]
        $maxVals = @($points | ForEach-Object { $_.maximum } | Where-Object { $null -ne $_ })
        $avgVals = @($points | ForEach-Object { $_.average } | Where-Object { $null -ne $_ })

        if ($AggregationType -eq "Sum") {
            $aggMax = if ($maxVals.Count -gt 0) { ($maxVals | Measure-Object -Sum).Sum } else { $null }
            $aggAvg = if ($avgVals.Count -gt 0) { ($avgVals | Measure-Object -Sum).Sum } else { $null }
        } else {
            $aggMax = if ($maxVals.Count -gt 0) { ($maxVals | Measure-Object -Maximum).Maximum } else { $null }
            $aggAvg = if ($avgVals.Count -gt 0) { ($avgVals | Measure-Object -Maximum).Maximum } else { $null }
        }

        $aggregated += [PSCustomObject]@{
            maximum = $aggMax
            average = $aggAvg
        }
    }

    return $aggregated
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

# Detect shard count from first metric with multiple timeseries
$shardCount = 0
foreach ($metric in $response.value) {
    if ($metric.timeseries.Count -gt 1) {
        $shardCount = $metric.timeseries.Count
        break
    }
}

# Display results
Write-Host "------------------------------------------------------------"
Write-Host ("METRICS RESULTS (over last {0} days)" -f $Days)
if ($shardCount -gt 1) {
    Write-Host ("Clustered Cache: {0} shards detected - metrics aggregated across all shards" -f $shardCount)
}
Write-Host "------------------------------------------------------------"
Write-Host ""
Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f "Metric", "Peak", "P95", "Average")
Write-Host ("{0,-30} {1,35} {2,35} {3,35}" -f "------", "----", "---", "-------")

foreach ($metric in $response.value) {
    $name = $metric.name.localizedValue
    $metricId = $metric.name.value
    $unit = $metric.unit

    # Aggregate per-shard timeseries into combined data points
    $aggType = Get-ShardAggregation -MetricId $metricId
    $dataPoints = Merge-ShardTimeseries -Timeseries $metric.timeseries -AggregationType $aggType

    # Collect aggregated hourly data points
    $maxValues = @()
    $avgValues = @()
    foreach ($point in $dataPoints) {
        if ($null -ne $point.maximum) { $maxValues += $point.maximum }
        if ($null -ne $point.average) { $avgValues += $point.average }
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
