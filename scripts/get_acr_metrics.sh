#!/bin/bash
set -euo pipefail
# Get Azure Cache for Redis metrics to help with AMR SKU selection
# Usage: ./get_acr_metrics.sh <subscriptionId> <resourceGroup> <cacheName> [days]
#
# Requires: Azure CLI logged in (az login), python3
#
# Retrieves Peak, P95 and Average values for last N days (default 7):
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
    echo "  days            - Number of days to look back (default: 7)"
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
DAYS="${4:-7}"

if [ -z "$SUBSCRIPTION" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$CACHE_NAME" ]; then
    usage
fi

# Input validation
[[ "$SUBSCRIPTION" =~ ^[a-fA-F0-9-]+$ ]] || { echo "ERROR: Invalid subscription ID format."; exit 1; }
[[ "$RESOURCE_GROUP" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: Invalid resource group name format."; exit 1; }
[[ "$CACHE_NAME" =~ ^[a-zA-Z0-9-]+$ ]] || { echo "ERROR: Invalid cache name format."; exit 1; }
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "ERROR: Days must be a positive integer."; exit 1; }
[[ "$DAYS" -ge 1 && "$DAYS" -le 30 ]] || { echo "ERROR: Days must be between 1 and 30."; exit 1; }

echo "============================================================"
echo "Azure Cache for Redis - Metrics Query"
echo "============================================================"
echo "Subscription:   $SUBSCRIPTION"
echo "Resource Group: $RESOURCE_GROUP"
echo "Cache Name:     $CACHE_NAME"
echo "Time Range:     Last $DAYS days"
echo ""

# Detect shard count for clustered Premium caches
# Use -o json | tail -1 to handle noisy stdout from cross-platform az CLI (e.g., WSL proxying to Windows)
SHARD_COUNT=$(az redis show -n "$CACHE_NAME" -g "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION" --query "shardCount" -o json 2>/dev/null | tail -1 | tr -d '[:space:]')
if [ -z "$SHARD_COUNT" ] || [ "$SHARD_COUNT" = "null" ]; then
    SHARD_COUNT=0
fi

# Build the metrics API URL
RESOURCE_URI="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Cache/Redis/${CACHE_NAME}"
METRICS="usedmemoryRss,serverLoad,connectedclients,cacheRead,cacheWrite"
TIMESPAN="P${DAYS}D"
INTERVAL="PT1H"  # 1 hour intervals for P95 calculation
API_VERSION="2023-10-01"

URL="https://management.azure.com${RESOURCE_URI}/providers/microsoft.insights/metrics?api-version=${API_VERSION}&metricnames=${METRICS}&timespan=${TIMESPAN}&interval=${INTERVAL}&aggregation=Maximum,Average"

# For clustered caches, request per-shard metrics so we can aggregate correctly
if [ "$SHARD_COUNT" -gt 1 ] 2>/dev/null; then
    URL="${URL}&\$filter=ShardId%20eq%20'*'"
fi

echo "Querying metrics..."
echo ""

# Make the API call using az rest (handles authentication automatically)
RESPONSE=$(az rest --method GET --url "$URL" -o json 2>&1) || {
    echo "ERROR: API request failed. Check credentials and resource parameters."
    echo "Ensure you are logged in with 'az login' and have Reader access to the resource."
    exit 1
}

echo "------------------------------------------------------------"
echo "METRICS RESULTS (over last $DAYS days)"
echo "------------------------------------------------------------"

# Parse JSON using python3 (available on most Linux/Mac systems)
echo "$RESPONSE" | python3 -c "
import sys, json, math
from collections import defaultdict

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

# Metrics where per-shard values should be summed (additive).
# All others use max (bottleneck/per-shard value).
SUM_METRICS = {'usedmemoryRss', 'cacheRead', 'cacheWrite'}

def aggregate_shard_timeseries(timeseries_list, metric_id):
    \"\"\"Aggregate per-shard timeseries into combined data points.\"\"\"
    if len(timeseries_list) <= 1:
        if timeseries_list:
            return timeseries_list[0].get('data', [])
        return []

    use_sum = metric_id in SUM_METRICS
    by_ts = defaultdict(list)
    for ts in timeseries_list:
        for point in ts.get('data', []):
            by_ts[point.get('timeStamp', '')].append(point)

    aggregated = []
    for ts_key, points in by_ts.items():
        max_vals = [p['maximum'] for p in points if p.get('maximum') is not None]
        avg_vals = [p['average'] for p in points if p.get('average') is not None]
        if use_sum:
            agg_max = sum(max_vals) if max_vals else None
            agg_avg = sum(avg_vals) if avg_vals else None
        else:
            agg_max = max(max_vals) if max_vals else None
            agg_avg = max(avg_vals) if avg_vals else None
        aggregated.append({'maximum': agg_max, 'average': agg_avg})
    return aggregated

data = json.load(sys.stdin)

# Detect shard count
shard_count = 0
for metric in data.get('value', []):
    ts_count = len(metric.get('timeseries', []))
    if ts_count > 1:
        shard_count = ts_count
        break

print()
if shard_count > 1:
    print(f'Clustered Cache: {shard_count} shards detected - metrics aggregated across all shards')
print(f\"{'Metric':<30} {'Peak':>35} {'P95':>35} {'Average':>35}\")
print(f\"{'------':<30} {'----':>35} {'---':>35} {'-------':>35}\")

for metric in data.get('value', []):
    name = metric['name']['localizedValue']
    metric_id = metric['name']['value']
    unit = metric.get('unit', '')

    data_points = aggregate_shard_timeseries(metric.get('timeseries', []), metric_id)

    max_vals = [p['maximum'] for p in data_points if p.get('maximum') is not None]
    avg_vals = [p['average'] for p in data_points if p.get('average') is not None]

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
