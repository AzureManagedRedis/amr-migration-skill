#!/bin/bash
# Get Azure Redis pricing with monthly cost calculation
# Usage: ./get_redis_price.sh <SKU> <region> [tier] [options]
#
# For ACR C* SKUs, specify tier: basic or standard
# For AMR and ACR Premium, tier is auto-detected
#
# Options:
#   --no-ha       Non-HA deployment (AMR only, 50% savings)
#   --shards N    Number of shards (ACR Premium only, default: 1)
#   --replicas N  Replicas per primary (ACR Premium MRPP, default: 1)
#   --currency X  Currency code (default: USD)
#
# Examples:
#   ./get_redis_price.sh M10 westus2
#   ./get_redis_price.sh M10 westus2 --no-ha
#   ./get_redis_price.sh C3 westus2 standard
#   ./get_redis_price.sh P2 westus2 --shards 3
#   ./get_redis_price.sh P2 westus2 --shards 3 --replicas 2 --currency EUR

usage() {
    echo "Usage: ./get_redis_price.sh <SKU> <region> [tier] [options]"
    echo ""
    echo "For ACR C* SKUs, you MUST specify tier: basic or standard"
    echo "For AMR (M/B/X/A) and ACR Premium (P*), tier is auto-detected."
    echo ""
    echo "Options:"
    echo "  --no-ha       Non-HA deployment (AMR only, 50% savings)"
    echo "  --shards N    Number of shards (ACR Premium only, default: 1)"
    echo "  --replicas N  Replicas per primary (ACR Premium MRPP, default: 1)"
    echo "  --currency X  Currency code (default: USD)"
    echo ""
    echo "SKU Types:"
    echo "  ACR: C0-C6 (Basic/Standard), P1-P5 (Premium)"
    echo "  AMR: M10-M2000, B0-B1000, X3-X700, A250-A4500"
    echo ""
    echo "Examples:"
    echo "  ./get_redis_price.sh M10 westus2"
    echo "  ./get_redis_price.sh M10 westus2 --no-ha"
    echo "  ./get_redis_price.sh C3 westus2 standard"
    echo "  ./get_redis_price.sh C3 westus2 basic"
    echo "  ./get_redis_price.sh P2 westus2"
    echo "  ./get_redis_price.sh P2 westus2 --shards 3"
    echo "  ./get_redis_price.sh P2 westus2 --shards 3 --replicas 2"
    echo "  ./get_redis_price.sh P2 westus2 --shards 3 --currency EUR"
    echo ""
    echo "Common currencies: USD, EUR, GBP, AUD, CAD, JPY"
    exit 1
}

# Parse arguments
SKU="$1"
REGION="$2"
shift 2 2>/dev/null

if [ -z "$SKU" ] || [ -z "$REGION" ]; then
    usage
fi

# Check dependencies
for cmd in curl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

# Defaults
TIER=""
CURRENCY="USD"
HA=1
SHARDS=1
REPLICAS=1

# Parse optional arguments
while [ $# -gt 0 ]; do
    case "$1" in
        basic|Basic|BASIC)
            TIER="Basic"
            shift
            ;;
        standard|Standard|STANDARD)
            TIER="Standard"
            shift
            ;;
        --no-ha)
            HA=0
            shift
            ;;
        --shards)
            SHARDS="$2"
            shift 2
            ;;
        --replicas)
            REPLICAS="$2"
            shift 2
            ;;
        --currency)
            CURRENCY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# Determine product type and meter name from SKU prefix
FIRST_CHAR="${SKU:0:1}"
FIRST_CHAR_UPPER=$(echo "$FIRST_CHAR" | tr '[:lower:]' '[:upper:]')
METER_NAME="${SKU} Cache Instance"
PRODUCT="AMR"
NODES=2

case "$FIRST_CHAR_UPPER" in
    C)
        PRODUCT="ACR"
        if [ -z "$TIER" ]; then
            echo "ERROR: For C* SKUs, specify tier: basic or standard"
            echo "Example: ./get_redis_price.sh C3 westus2 standard"
            exit 1
        fi
        if [ "$TIER" = "Basic" ]; then
            NODES=1
        else
            NODES=2
        fi
        ;;
    P)
        PRODUCT="ACR"
        TIER="Premium"
        NODES=$((SHARDS * (1 + REPLICAS)))
        ;;
    M|B|X|A)
        PRODUCT="AMR"
        if [ "$HA" -eq 0 ]; then
            NODES=1
        else
            NODES=2
        fi
        ;;
    *)
        echo "ERROR: Unknown SKU prefix '${FIRST_CHAR_UPPER}'. Valid: C (Basic/Standard), P (Premium), M/B/X/A (AMR)"
        exit 1
        ;;
esac

# Validate options
if [ "$HA" -eq 0 ] && [ "$PRODUCT" = "ACR" ]; then
    echo "WARNING: --no-ha only applies to AMR SKUs. Ignored for ACR."
fi
if [ "$SHARDS" -gt 1 ] && [ "$TIER" != "Premium" ]; then
    echo "WARNING: --shards only applies to ACR Premium. Ignored."
fi
if [ "$REPLICAS" -gt 1 ] && [ "$TIER" != "Premium" ]; then
    echo "WARNING: --replicas only applies to ACR Premium. Ignored."
fi

# Display query info
echo "============================================================"
echo "Azure Redis Pricing Query"
echo "============================================================"
echo "SKU:      $SKU"
echo "Region:   $REGION"
echo "Product:  $PRODUCT"
[ -n "$TIER" ] && echo "Tier:     $TIER"
echo "Currency: $CURRENCY"
if [ "$PRODUCT" = "AMR" ]; then
    if [ "$HA" -eq 1 ]; then
        echo "HA:       Yes (production)"
    else
        echo "HA:       No (dev/test)"
    fi
fi
if [ "$PRODUCT" = "ACR" ] && [ "$TIER" = "Premium" ]; then
    echo "Shards:   $SHARDS"
    echo "Replicas: $REPLICAS per primary"
fi
echo "Nodes:    $NODES"
echo ""

# Build API URL
FILTER="serviceName eq 'Redis Cache' and armRegionName eq '${REGION}' and type eq 'Consumption' and meterName eq '${METER_NAME}'"
ENCODED_FILTER=$(echo "$FILTER" | sed "s/ /%20/g" | sed "s/'/%27/g")
URL="https://prices.azure.com/api/retail/prices?currencyCode=%27${CURRENCY}%27&\$filter=${ENCODED_FILTER}"

# Fetch price
RESULT=$(curl -s "$URL")

# Parse response and calculate monthly cost
PRICING=$(echo "$RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print('ERROR: Invalid JSON response from API', file=sys.stderr)
    sys.exit(1)
items = data.get('Items', [])
if not items:
    sys.exit(1)
hourly = items[0]['retailPrice']
monthly = round(hourly * 730 * $NODES, 2)
print(f'{hourly} {monthly}')
")

if [ $? -ne 0 ] || [ -z "$PRICING" ]; then
    echo "ERROR: No pricing found for '$METER_NAME' in $REGION"
    echo ""
    echo "Meter name queried: $METER_NAME"
    exit 1
fi

HOURLY=$(echo "$PRICING" | cut -d' ' -f1)
MONTHLY=$(echo "$PRICING" | cut -d' ' -f2)

echo "------------------------------------------------------------"
echo "PRICING RESULTS"
echo "------------------------------------------------------------"
echo "Hourly (per node):  $CURRENCY $HOURLY"
echo "Monthly estimate:   $CURRENCY $MONTHLY"
echo ""
echo "Calculation: $HOURLY x 730 hours x $NODES nodes = $MONTHLY"
echo ""
echo "Note: Prices are estimates. Use Azure Pricing Calculator for quotes."
echo "https://azure.microsoft.com/en-us/pricing/calculator/?service=managed-redis"
