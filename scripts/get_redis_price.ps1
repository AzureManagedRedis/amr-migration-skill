# Get Azure Redis pricing with monthly cost calculation
# Usage: .\get_redis_price.ps1 -SKU <sku> -Region <region> [-Tier <basic|standard>] [options]
#
# For ACR C* SKUs, specify -Tier: Basic or Standard
# For AMR and ACR Premium, tier is auto-detected
#
# Options:
#   -NoHA          Non-HA deployment (AMR only, 50% savings)
#   -Shards N      Number of shards (ACR Premium only, default: 1)
#   -Replicas N    Replicas per primary (ACR Premium MRPP, default: 1)
#   -Currency X    Currency code (default: USD)
#
# Examples:
#   .\get_redis_price.ps1 -SKU M10 -Region westus2
#   .\get_redis_price.ps1 -SKU M10 -Region westus2 -NoHA
#   .\get_redis_price.ps1 -SKU C3 -Region westus2 -Tier Standard
#   .\get_redis_price.ps1 -SKU P2 -Region westus2 -Shards 3
#   .\get_redis_price.ps1 -SKU P2 -Region westus2 -Shards 3 -Replicas 2 -Currency EUR

param(
    [Parameter(Mandatory=$true)]
    [string]$SKU,

    [Parameter(Mandatory=$true)]
    [string]$Region,

    [Parameter(Mandatory=$false)]
    [ValidateSet("Basic", "Standard", "Premium")]
    [string]$Tier,

    [Parameter(Mandatory=$false)]
    [switch]$NoHA,

    [Parameter(Mandatory=$false)]
    [int]$Shards = 1,

    [Parameter(Mandatory=$false)]
    [int]$Replicas = 1,

    [Parameter(Mandatory=$false)]
    [string]$Currency = "USD"
)

# Determine product type and meter name from SKU prefix
$firstChar = $SKU.Substring(0, 1).ToUpper()
$meterName = "$SKU Cache Instance"
$product = "AMR"
$nodes = 2

switch ($firstChar) {
    "C" {
        $product = "ACR"
        if (-not $Tier) {
            Write-Host "ERROR: For C* SKUs, specify -Tier: Basic or Standard" -ForegroundColor Red
            Write-Host "Example: .\get_redis_price.ps1 -SKU C3 -Region westus2 -Tier Standard"
            exit 1
        }
        if ($Tier -eq "Basic") {
            $nodes = 1
        } else {
            $nodes = 2
        }
    }
    "P" {
        $product = "ACR"
        $Tier = "Premium"
        # Premium: shards * (1 primary + replicas)
        $nodes = $Shards * (1 + $Replicas)
    }
    { $_ -in "M", "B", "X", "A" } {
        $product = "AMR"
        if ($NoHA) {
            $nodes = 1
        } else {
            $nodes = 2
        }
    }
    default {
        Write-Host "ERROR: Unknown SKU prefix '$firstChar'. Valid: C (Basic/Standard), P (Premium), M/B/X/A (AMR)" -ForegroundColor Red
        exit 1
    }
}

# Validate options
if ($NoHA -and $product -eq "ACR") {
    Write-Host "WARNING: -NoHA only applies to AMR SKUs. Ignored for ACR." -ForegroundColor Yellow
}
if ($Shards -gt 1 -and $Tier -ne "Premium") {
    Write-Host "WARNING: -Shards only applies to ACR Premium. Ignored." -ForegroundColor Yellow
}
if ($Replicas -gt 1 -and $Tier -ne "Premium") {
    Write-Host "WARNING: -Replicas only applies to ACR Premium. Ignored." -ForegroundColor Yellow
}

Write-Host "============================================================"
Write-Host "Azure Redis Pricing Query"
Write-Host "============================================================"
Write-Host "SKU:      $SKU"
Write-Host "Region:   $Region"
Write-Host "Product:  $product"
if ($Tier) { Write-Host "Tier:     $Tier" }
Write-Host "Currency: $Currency"
if ($product -eq "AMR") {
    if ($NoHA) {
        Write-Host "HA:       No (dev/test)"
    } else {
        Write-Host "HA:       Yes (production)"
    }
}
if ($product -eq "ACR" -and $Tier -eq "Premium") {
    Write-Host "Shards:   $Shards"
    Write-Host "Replicas: $Replicas per primary"
}
Write-Host "Nodes:    $nodes"
Write-Host ""

# Build API URL
$filter = "serviceName eq 'Redis Cache' and armRegionName eq '$Region' and type eq 'Consumption' and meterName eq '$meterName'"
$url = "https://prices.azure.com/api/retail/prices?currencyCode=%27${Currency}%27&`$filter=$filter"

Write-Host "Querying pricing API..."
Write-Host ""

try {
    $response = Invoke-RestMethod -Uri $url -Method Get
} catch {
    Write-Host "ERROR: API request failed" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

if ($response.Items.Count -eq 0) {
    Write-Host "ERROR: No pricing found for '$meterName' in $Region" -ForegroundColor Red
    Write-Host ""
    Write-Host "Debug URL: $url"
    exit 1
}

$hourly = $response.Items[0].retailPrice
$monthly = [math]::Round($hourly * 730 * $nodes, 2)

Write-Host "------------------------------------------------------------"
Write-Host "PRICING RESULTS"
Write-Host "------------------------------------------------------------"
Write-Host "Hourly (per node):  $Currency $hourly"
Write-Host "Monthly estimate:   $Currency $monthly"
Write-Host ""
Write-Host "Calculation: $hourly x 730 hours x $nodes nodes = $monthly"
Write-Host ""
Write-Host "Note: Prices are estimates. Use Azure Pricing Calculator for quotes."
Write-Host "https://azure.microsoft.com/en-us/pricing/calculator/?service=managed-redis"
