#!/bin/bash
set -euo pipefail
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

# Input validation
[[ "$SKU" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] || { echo "ERROR: Invalid SKU format. Expected alphanumeric starting with a letter (e.g., M10, P2, C3)."; exit 1; }
[[ "$REGION" =~ ^[a-z0-9]+$ ]] || { echo "ERROR: Invalid region format. Expected lowercase alphanumeric (e.g., westus2)."; exit 1; }
[[ "$CURRENCY" =~ ^[A-Z]{3}$ ]] || { echo "ERROR: Invalid currency code. Expected 3 uppercase letters (e.g., USD, EUR)."; exit 1; }
[[ "$SHARDS" =~ ^[0-9]+$ ]] || { echo "ERROR: --shards must be a positive integer."; exit 1; }
[[ "$REPLICAS" =~ ^[0-9]+$ ]] || { echo "ERROR: --replicas must be a positive integer."; exit 1; }
[[ "$SHARDS" -ge 1 && "$SHARDS" -le 30 ]] || { echo "ERROR: --shards must be between 1 and 30."; exit 1; }
[[ "$REPLICAS" -ge 1 && "$REPLICAS" -le 3 ]] || { echo "ERROR: --replicas must be between 1 and 3."; exit 1; }

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

# Build API URL (use python3 for proper URL encoding)
FILTER="serviceName eq 'Redis Cache' and armRegionName eq '${REGION}' and type eq 'Consumption' and meterName eq '${METER_NAME}'"
ENCODED_FILTER=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$FILTER")
ENCODED_CURRENCY=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "'${CURRENCY}'")
URL="https://prices.azure.com/api/retail/prices?currencyCode=${ENCODED_CURRENCY}&\$filter=${ENCODED_FILTER}"

# Fetch price
RESULT=$(curl -s "$URL")

# Parse response and calculate monthly cost
export NODES
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
import os
nodes = int(os.environ['NODES'])
hourly = items[0]['retailPrice']
monthly = round(hourly * 730 * nodes, 2)
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
