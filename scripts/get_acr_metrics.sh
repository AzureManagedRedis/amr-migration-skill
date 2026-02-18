#!/bin/bash
# Get Azure Cache for Redis metrics to help with AMR SKU selection
# Usage: ./get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName> [days]
#
# Requires: Azure CLI logged in (az login), python3, curl
#
# Retrieves max values for last N days (default 30):
#   - Used Memory RSS (bytes)
#   - Server Load (%)
#   - Connected Clients
#   - Network Bandwidth Usage (bytes/sec)
#
# Examples:
#   ./get_acr_metrics.sh abc123-def456 my-rg my-redis-cache
#   ./get_acr_metrics.sh abc123-def456 my-rg my-redis-cache 7

usage() {
    echo "Usage: ./get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName> [days]"
    echo ""
    echo "Requires Azure CLI to be logged in (run 'az login' first)."
    echo ""
    echo "Arguments:"
    echo "  subscriptionId  - Azure subscription ID"
    echo "  resourceGroup   - Resource group containing the cache"
    echo "  cacheName       - Name of the Azure Cache for Redis instance"
    echo "  days            - Number of days to look back (default: 30)"
    echo ""
    echo "Examples:"
    echo "  ./get_acr_metrics.sh abc123-def456 my-rg my-redis-cache"
    echo "  ./get_acr_metrics.sh abc123-def456 my-rg my-redis-cache 7"
    echo ""
    echo "Output includes:"
    echo "  - Used Memory (bytes and GB)"
    echo "  - Used Memory Percentage"
    echo "  - Server Load (%)"
    echo "  - Connected Clients"
    echo "  - Network Bandwidth (bytes/sec)"
    exit 1
}

SUBSCRIPTION="$1"
RESOURCE_GROUP="$2"
CACHE_NAME="$3"
DAYS="${4:-30}"

if [ -z "$SUBSCRIPTION" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$CACHE_NAME" ]; then
    usage
fi

echo "============================================================"
echo "Azure Cache for Redis - Metrics Query"
echo "============================================================"
echo "Subscription:   $SUBSCRIPTION"
echo "Resource Group: $RESOURCE_GROUP"
echo "Cache Name:     $CACHE_NAME"
echo "Time Range:     Last $DAYS days"
echo ""

# Get access token using Azure CLI
echo "Fetching access token..."
TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to get access token. Please run 'az login' first."
    exit 1
fi

echo "Token acquired successfully."
echo ""

# Build the metrics API URL
RESOURCE_URI="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Cache/Redis/${CACHE_NAME}"
METRICS="usedmemoryRss,serverLoad,connectedclients,cacheRead,cacheWrite"
TIMESPAN="P${DAYS}D"
INTERVAL="PT1H"  # 1 hour intervals to reduce response size
API_VERSION="2023-10-01"

URL="https://management.azure.com${RESOURCE_URI}/providers/microsoft.insights/metrics?api-version=${API_VERSION}&metricnames=${METRICS}&timespan=${TIMESPAN}&interval=${INTERVAL}&aggregation=Maximum"

echo "Querying metrics..."
echo ""

# Make the API call
RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$URL")

# Check for errors
if echo "$RESPONSE" | grep -q '"code":'; then
    echo "ERROR: API request failed"
    echo "$RESPONSE" | grep -o '"message":"[^"]*"'
    exit 1
fi

echo "------------------------------------------------------------"
echo "METRICS RESULTS (Maximum values over last $DAYS days)"
echo "------------------------------------------------------------"

# Parse JSON using python3 (available on most Linux/Mac systems)
echo "$RESPONSE" | python3 -c "
import sys, json

data = json.load(sys.stdin)
for metric in data.get('value', []):
    name = metric['name']['localizedValue']
    unit = metric.get('unit', '')
    # Get max of all maximum values across all timeseries
    max_val = None
    for ts in metric.get('timeseries', []):
        for point in ts.get('data', []):
            v = point.get('maximum')
            if v is not None and (max_val is None or v > max_val):
                max_val = v

    if max_val is not None:
        if name == 'Used Memory RSS':
            gb = round(max_val / (1024**3), 2)
            print(f'{name:<30} {max_val:>15,.0f} bytes ({gb} GB)')
        elif unit == 'Percent':
            print(f'{name:<30} {max_val:>15.1f} %')
        elif unit == 'BytesPerSecond':
            mbs = round(max_val / (1024**2), 2)
            print(f'{name:<30} {max_val:>15,.0f} bytes/sec ({mbs} MB/s)')
        else:
            print(f'{name:<30} {max_val:>15,.0f}')
    else:
        print(f'{name:<30} No data')
"

echo ""
echo "Use these values to select an appropriate AMR SKU:"
echo "  - Memory: Choose SKU with usable memory >= max used memory"
echo "  - Server Load: High Server Load (>70%) with low memory suggests Compute Optimized (X-series)"
echo "  - Connections: Check max connections supported by target SKU"
echo ""
echo "See references/sku-mapping.md for SKU selection guidance."
