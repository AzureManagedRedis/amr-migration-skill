#!/bin/bash
# Get Azure Cache for Redis metrics to help with AMR SKU selection
# Usage: ./get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName> [days]
#
# Requires: Azure CLI logged in (az login), python3, curl
#
# Retrieves Peak, P95 and Average values for last N days (default 30):
#   - Used Memory RSS (bytes and GB)
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
    echo "Output includes (Peak, P95, Average for each):"
    echo "  - Used Memory (bytes and GB)"
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
INTERVAL="PT1H"  # 1 hour intervals for P95 calculation
API_VERSION="2023-10-01"

URL="https://management.azure.com${RESOURCE_URI}/providers/microsoft.insights/metrics?api-version=${API_VERSION}&metricnames=${METRICS}&timespan=${TIMESPAN}&interval=${INTERVAL}&aggregation=Maximum,Average"

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
echo "METRICS RESULTS (over last $DAYS days)"
echo "------------------------------------------------------------"

# Parse JSON using python3 (available on most Linux/Mac systems)
echo "$RESPONSE" | python3 -c "
import sys, json, math

def percentile95(values):
    if not values:
        return None
    s = sorted(values)
    idx = math.ceil(0.95 * len(s)) - 1
    return s[idx]

def format_value(name, unit, val):
    if val is None:
        return 'N/A'
    if name == 'Used Memory RSS':
        gb = round(val / (1024**3), 2)
        return f'{val:,.0f} bytes ({gb} GB)'
    elif unit == 'Percent':
        return f'{val:.1f} %'
    elif unit == 'BytesPerSecond':
        mbs = round(val / (1024**2), 2)
        return f'{val:,.0f} bytes/sec ({mbs} MB/s)'
    else:
        return f'{val:,.0f}'

data = json.load(sys.stdin)

print()
print(f\"{'Metric':<30} {'Peak':>35} {'P95':>35} {'Average':>35}\")
print(f\"{'------':<30} {'----':>35} {'---':>35} {'-------':>35}\")

for metric in data.get('value', []):
    name = metric['name']['localizedValue']
    unit = metric.get('unit', '')

    max_vals = []
    avg_vals = []
    for ts in metric.get('timeseries', []):
        for point in ts.get('data', []):
            v = point.get('maximum')
            if v is not None:
                max_vals.append(v)
            v = point.get('average')
            if v is not None:
                avg_vals.append(v)

    peak = max(max_vals) if max_vals else None
    p95 = percentile95(max_vals)
    avg = sum(avg_vals) / len(avg_vals) if avg_vals else None

    peak_s = format_value(name, unit, peak)
    p95_s = format_value(name, unit, p95)
    avg_s = format_value(name, unit, avg)

    print(f'{name:<30} {peak_s:>35} {p95_s:>35} {avg_s:>35}')
"

echo ""
echo "Use these values to select an appropriate AMR SKU:"
echo "  - Memory: Choose SKU with usable memory >= peak used memory"
echo "  - Server Load: High Server Load (>70%) with low memory suggests Compute Optimized (X-series)"
echo "  - Connections: Check max connections supported by target SKU"
echo ""
echo "See references/sku-mapping.md for SKU selection guidance."
