# Get Azure Cache for Redis metrics to help with AMR SKU selection
# Usage: .\get_acr_metrics.ps1 -SubscriptionId <id> -ResourceGroup <rg> -CacheName <name> [-Days <n>]
#
# Requires: Azure CLI logged in (az login)
#
# Retrieves max values for last N days (default 30):
#   - Used Memory RSS (bytes)
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
$interval = "PT1H"  # 1 hour intervals to reduce response size
$apiVersion = "2023-10-01"

$url = "https://management.azure.com${resourceUri}/providers/microsoft.insights/metrics?api-version=${apiVersion}&metricnames=${metrics}&timespan=${timespan}&interval=${interval}&aggregation=Maximum"

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

# Display results
Write-Host "------------------------------------------------------------"
Write-Host "METRICS RESULTS (Maximum values over last $Days days)"
Write-Host "------------------------------------------------------------"

foreach ($metric in $response.value) {
    $name = $metric.name.localizedValue
    $unit = $metric.unit
    $maxValue = ($metric.timeseries.data.maximum | Measure-Object -Maximum).Maximum
    
    if ($null -ne $maxValue) {
        switch ($name) {
            "Used Memory RSS" {
                $maxGB = [math]::Round($maxValue / 1GB, 2)
                Write-Host ("{0,-30} {1,15:N0} bytes ({2} GB)" -f $name, $maxValue, $maxGB)
            }
            { $unit -eq "Percent" } {
                Write-Host ("{0,-30} {1,15:N1} %" -f $name, $maxValue)
            }
            { $unit -eq "BytesPerSecond" } {
                $maxMBs = [math]::Round($maxValue / 1MB, 2)
                Write-Host ("{0,-30} {1,15:N0} bytes/sec ({2} MB/s)" -f $name, $maxValue, $maxMBs)
            }
            default {
                Write-Host ("{0,-30} {1,15:N0}" -f $name, $maxValue)
            }
        }
    } else {
        Write-Host ("{0,-30} No data" -f $name)
    }
}

Write-Host ""
Write-Host "Use these values to select an appropriate AMR SKU:"
Write-Host "  - Memory: Choose SKU with usable memory >= max used memory"
Write-Host "  - Server Load: High Server Load (>70%) with low memory suggests Compute Optimized (X-series)"
Write-Host "  - Connections: Check max connections supported by target SKU"
Write-Host ""
Write-Host "See references/sku-mapping.md for SKU selection guidance."
