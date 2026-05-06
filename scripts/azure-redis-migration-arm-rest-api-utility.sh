#!/usr/bin/env bash
#
# Script for migrating a cache from Azure Cache for Redis to Azure Managed Redis using ARM REST APIs.
#
# This script allows you to initiate, check the status of, or cancel a migration from an
# Azure Cache for Redis resource to Azure Managed Redis. It uses 'az rest' (Azure CLI) for
# ARM API calls, making it cross-platform (Linux, macOS, WSL).
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in (az login)
#   - jq installed for JSON processing
#
# Usage:
#   ./azure-redis-migration-arm-rest-api-utility.sh --action <Action> [options]
#
# Actions:
#   Validate  - Validate whether a migration can be performed
#   Migrate   - Initiate a migration from ACR to AMR
#   Status    - Check the status of an ongoing migration
#   Cancel    - Cancel/rollback a migration
#
# Options:
#   --action, -a          Action to perform: Validate, Migrate, Status, or Cancel (required)
#   --source, -s          Source ACR resource ID (required for Migrate, Validate)
#   --target, -t          Target AMR resource ID (required for all actions)
#   --force-migrate       Bypass validation warnings (default: false)
#   --track               Wait for long-running operation to complete (default: false)
#   --yes, -y             Skip confirmation prompt for destructive actions (Migrate, Cancel)
#   --api-version         ARM API version (default: 2025-08-01-preview)
#   --help, -h            Show this help message
#
# Examples:
#   # Validate migration
#   ./azure-redis-migration-arm-rest-api-utility.sh \
#     --action Validate \
#     --source "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/Redis/redis1" \
#     --target "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1"
#
#   # Migrate with tracking
#   ./azure-redis-migration-arm-rest-api-utility.sh \
#     --action Migrate \
#     --source "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/Redis/redis1" \
#     --target "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1" \
#     --track
#
#   # Force migrate (bypass warnings)
#   ./azure-redis-migration-arm-rest-api-utility.sh \
#     --action Migrate \
#     --source "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/Redis/redis1" \
#     --target "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1" \
#     --force-migrate
#
#   # Check status
#   ./azure-redis-migration-arm-rest-api-utility.sh \
#     --action Status \
#     --target "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1"
#
#   # Cancel migration
#   ./azure-redis-migration-arm-rest-api-utility.sh \
#     --action Cancel \
#     --target "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1" \
#     --track

set -euo pipefail

# Azure CLI appends AZURE_HTTP_USER_AGENT to its default User-Agent on every request made via 'az rest'.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_version="$(tr -d '[:space:]' < "${script_dir}/../VERSION")"
skill_ua="amr-migration-skill/${skill_version}"
export AZURE_HTTP_USER_AGENT="$(printf '%s %s' "$(printf '%s' "${AZURE_HTTP_USER_AGENT:-}" | sed -E 's/[[:space:]]*amr-migration-skill\/[^[:space:]]+([[:space:]]+\([^)]*\))?//g')" "${skill_ua}" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"

# --- Defaults ---
ACTION=""
SOURCE_RESOURCE_ID=""
TARGET_RESOURCE_ID=""
FORCE_MIGRATE="false"
TRACK_MIGRATION="false"
SKIP_CONFIRMATION="false"
API_VERSION="2025-08-01-preview"

# --- Colors (disabled when output is not a terminal) ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' CYAN='' NC=''
fi

# --- Functions ---

show_help() {
    sed -n '2,/^$/{ s/^# \?//; p }' "$0"
    exit 0
}

error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${CYAN}$1${NC}"
}

success() {
    echo -e "${GREEN}$1${NC}"
}

check_dependencies() {
    command -v az >/dev/null 2>&1 || error_exit "Azure CLI (az) is required but not installed. See https://learn.microsoft.com/cli/azure/install-azure-cli"
    command -v jq >/dev/null 2>&1 || error_exit "jq is required but not installed. See https://jqlang.github.io/jq/download/"
}

confirm_action() {
    local action_desc="$1"
    if [[ "$SKIP_CONFIRMATION" == "true" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        error_exit "Destructive action requires confirmation. Run with --yes to skip, or run interactively."
    fi
    echo -e "${CYAN}You are about to: ${action_desc}${NC}"
    echo ""
    read -rp "Are you sure you want to proceed? [y/N] " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) echo "Aborted."; exit 0 ;;
    esac
}

parse_target_resource_id() {
    # Extract subscription, resource group, and cache name from the target resource ID
    local target="$1"
    local pattern='^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Cache/[rR]edis[eE]nterprise/([^/]+)'

    if [[ "$target" =~ $pattern ]]; then
        SUBSCRIPTION_ID="${BASH_REMATCH[1]}"
        RESOURCE_GROUP="${BASH_REMATCH[2]}"
        AMR_CACHE_NAME="${BASH_REMATCH[3]}"
    else
        error_exit "TargetResourceId could not be parsed. Expected format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Cache/redisEnterprise/<name>"
    fi
}

ensure_login() {
    local current_sub
    current_sub=$(az account show --query "id" -o tsv 2>/dev/null) || error_exit "Not logged in to Azure CLI. Run 'az login' first."

    if [[ "$current_sub" != "$SUBSCRIPTION_ID" ]]; then
        az account set --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1 || error_exit "Failed to set subscription to '$SUBSCRIPTION_ID'."
        echo "Switched Azure CLI subscription to '$SUBSCRIPTION_ID'."
    fi
    echo "Using subscription: $SUBSCRIPTION_ID"
    echo
}

get_base_url() {
    echo "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Cache/RedisEnterprise/${AMR_CACHE_NAME}/migrations/default"
}

# Make an ARM REST call and print the response
arm_rest() {
    local method="$1"
    local url="$2"
    local body="${3:-}"
    local response

    local args=(
        --method "$method"
        --url "${url}?api-version=${API_VERSION}"
        --headers "Content-Type=application/json"
        -o json
    )

    if [[ -n "$body" ]]; then
        args+=(--body "$body")
    fi

    if response=$(az rest "${args[@]}" 2>&1); then
        success "The request is successful."
        echo "$response" | jq .
        return 0
    else
        echo -e "${RED}The request encountered a failure.${NC}" >&2
        echo "$response" >&2
        return 1
    fi
}

# Poll migration status until terminal state
poll_status() {
    local url
    url="$(get_base_url)?api-version=${API_VERSION}"
    local state="InProgress"
    local attempt=0
    local max_attempts=60  # 30 minutes max (30s intervals)
    local response
    local details

    info "Tracking operation progress (polling every 30s)..."
    echo

    while [[ "$state" != "Succeeded" && "$state" != "Failed" && "$state" != "Canceled" && $attempt -lt $max_attempts ]]; do
        sleep 30
        attempt=$((attempt + 1))

        response=$(az rest --method GET --url "$url" -o json 2>&1) || true
        state=$(echo "$response" | jq -r '.properties.provisioningState // "Unknown"' 2>/dev/null || echo "Unknown")
        details=$(echo "$response" | jq -r '.properties.statusDetails // empty' 2>/dev/null || echo "")

        echo "  Poll $attempt: state=$state${details:+ details=$details}"
    done

    echo
    if [[ "$state" == "Succeeded" ]]; then
        success "Operation completed successfully."
    elif [[ "$state" == "Failed" ]]; then
        echo -e "${RED}Operation failed.${NC}"
    elif [[ "$state" == "Canceled" ]]; then
        echo "Operation was canceled."
    else
        echo -e "${RED}Timed out waiting for operation to complete (last state: $state).${NC}"
    fi

    # Print final status
    az rest --method GET --url "$url" -o json 2>/dev/null | jq . || true
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --action|-a)
            ACTION="$2"; shift 2 ;;
        --source|-s)
            SOURCE_RESOURCE_ID="$2"; shift 2 ;;
        --target|-t)
            TARGET_RESOURCE_ID="$2"; shift 2 ;;
        --force-migrate)
            FORCE_MIGRATE="true"; shift ;;
        --track)
            TRACK_MIGRATION="true"; shift ;;
        --api-version)
            API_VERSION="$2"
            [[ "$API_VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(-preview)?$ ]] || error_exit "Invalid API version format. Expected: YYYY-MM-DD or YYYY-MM-DD-preview"
            shift 2 ;;
        --yes|-y)
            SKIP_CONFIRMATION="true"; shift ;;
        --help|-h)
            show_help ;;
        *)
            error_exit "Unknown argument: $1. Use --help for usage." ;;
    esac
done

# --- Validation ---
check_dependencies

[[ -z "$ACTION" ]] && error_exit "Action is required. Use --action <Migrate|Validate|Status|Cancel>."
[[ -z "$TARGET_RESOURCE_ID" ]] && error_exit "Target resource ID is required. Use --target <resourceId>."

# Normalize action to lowercase for matching
ACTION_LOWER="${ACTION,,}"

if [[ "$ACTION_LOWER" == "migrate" || "$ACTION_LOWER" == "validate" ]]; then
    [[ -z "$SOURCE_RESOURCE_ID" ]] && error_exit "Source resource ID is required for '$ACTION'. Use --source <resourceId>."
    # Validate source resource ID format
    local_pattern='^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Cache/Redis/[^/]+$'
    [[ "$SOURCE_RESOURCE_ID" =~ $local_pattern ]] || error_exit "SourceResourceId format is invalid. Expected: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Cache/Redis/<name>"
fi

parse_target_resource_id "$TARGET_RESOURCE_ID"
ensure_login

BASE_URL=$(get_base_url)

# --- Execute Action ---
case "$ACTION_LOWER" in
    validate)
        info "Validating whether migration can be performed between source and target caches..."
        echo

        payload=$(jq -n \
            --arg sourceId "$SOURCE_RESOURCE_ID" \
            '{properties: {sourceResourceId: $sourceId, skipDataMigration: true}}')

        arm_rest POST "${BASE_URL}/validate" "$payload"
        ;;

    migrate)
        confirm_action "Migrate cache (DNS switch): ${SOURCE_RESOURCE_ID} -> ${TARGET_RESOURCE_ID}"

        if [[ "$TRACK_MIGRATION" == "true" ]]; then
            info "Triggering migration and tracking until completion..."
        else
            info "Triggering migration (fire-and-forget). Use --action Status to track progress."
        fi
        echo

        payload=$(jq -n \
            --arg sourceId "$SOURCE_RESOURCE_ID" \
            --argjson force "$FORCE_MIGRATE" \
            '{properties: {sourceResourceId: $sourceId, cacheResourceType: "AzureCacheForRedis", forceMigrate: $force, switchDns: true, skipDataMigration: true}}')

        arm_rest PUT "$BASE_URL" "$payload"

        if [[ "$TRACK_MIGRATION" == "true" ]]; then
            poll_status
        fi
        ;;

    status)
        info "Checking migration status..."
        echo
        arm_rest GET "$BASE_URL"
        ;;

    cancel)
        confirm_action "Cancel migration on: ${TARGET_RESOURCE_ID}"

        if [[ "$TRACK_MIGRATION" == "true" ]]; then
            info "Triggering migration cancellation and tracking until completion..."
        else
            info "Triggering migration cancellation (fire-and-forget). Use --action Status to track."
        fi
        echo

        arm_rest POST "${BASE_URL}/cancel"

        if [[ "$TRACK_MIGRATION" == "true" ]]; then
            poll_status
        fi
        ;;

    *)
        error_exit "Invalid action '$ACTION'. Use one of: Migrate, Validate, Status, Cancel."
        ;;
esac
