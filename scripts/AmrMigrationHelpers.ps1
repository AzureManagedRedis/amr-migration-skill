# AMR SKU Data & Shared Helpers
# Canonical source of truth for AMR SKU specifications, pricing API, and node count logic.
#
# This module is dot-sourced by:
#   - Convert-AcrToAmr.ps1 (IaC migration)
#   - get_acr_metrics.ps1 (metrics-based SKU suggestion)
#   - get_redis_price.ps1 (pricing lookup)
#
# Usage:
#   . .\scripts\AmrMigrationHelpers.ps1
#   $specs = $script:AmrSkuSpecs["Balanced_B50"]
#   $sizes = Get-AmrSkuSizes -TierPrefix "Balanced"
#   $price = Get-RetailPrice -MeterName "B50 Cache Instance" -Region "westus2" -Currency "USD"
#   $nodes = Get-CacheNodeCount -Tier "Premium" -ShardCount 3 -ReplicasPerPrimary 2

# ═══════════════════════════════════════════════════════════════
# AMR SKU Specifications (canonical 44-entry table)
# ═══════════════════════════════════════════════════════════════

$script:AmrSkuSpecs = @{
    # Memory Optimized
    "MemoryOptimized_M10"   = @{ Advertised = 12;   Usable = 9.6; }
    "MemoryOptimized_M20"   = @{ Advertised = 24;   Usable = 19.2; }
    "MemoryOptimized_M50"   = @{ Advertised = 60;   Usable = 48; }
    "MemoryOptimized_M100"  = @{ Advertised = 120;  Usable = 96; }
    "MemoryOptimized_M150"  = @{ Advertised = 175;  Usable = 140; }
    "MemoryOptimized_M250"  = @{ Advertised = 235;  Usable = 188; }
    "MemoryOptimized_M350"  = @{ Advertised = 360;  Usable = 288; }
    "MemoryOptimized_M500"  = @{ Advertised = 480;  Usable = 384; }
    "MemoryOptimized_M700"  = @{ Advertised = 720;  Usable = 576; }
    "MemoryOptimized_M1000" = @{ Advertised = 960;  Usable = 768; }
    "MemoryOptimized_M1500" = @{ Advertised = 1440; Usable = 1152; }
    "MemoryOptimized_M2000" = @{ Advertised = 1920; Usable = 1536; }
    # Balanced
    "Balanced_B0"    = @{ Advertised = 0.5;  Usable = 0.4; }
    "Balanced_B1"    = @{ Advertised = 1;    Usable = 0.8; }
    "Balanced_B3"    = @{ Advertised = 3;    Usable = 2.4; }
    "Balanced_B5"    = @{ Advertised = 6;    Usable = 4.8; }
    "Balanced_B10"   = @{ Advertised = 12;   Usable = 9.6; }
    "Balanced_B20"   = @{ Advertised = 24;   Usable = 19.2; }
    "Balanced_B50"   = @{ Advertised = 60;   Usable = 48; }
    "Balanced_B100"  = @{ Advertised = 120;  Usable = 96; }
    "Balanced_B150"  = @{ Advertised = 180;  Usable = 144; }
    "Balanced_B250"  = @{ Advertised = 240;  Usable = 192; }
    "Balanced_B350"  = @{ Advertised = 360;  Usable = 288; }
    "Balanced_B500"  = @{ Advertised = 480;  Usable = 384; }
    "Balanced_B700"  = @{ Advertised = 720;  Usable = 576; }
    "Balanced_B1000" = @{ Advertised = 960;  Usable = 768; }
    # Compute Optimized
    "ComputeOptimized_X3"   = @{ Advertised = 3;    Usable = 2.4; }
    "ComputeOptimized_X5"   = @{ Advertised = 6;    Usable = 4.8; }
    "ComputeOptimized_X10"  = @{ Advertised = 12;   Usable = 9.6; }
    "ComputeOptimized_X20"  = @{ Advertised = 24;   Usable = 19.2; }
    "ComputeOptimized_X50"  = @{ Advertised = 60;   Usable = 48; }
    "ComputeOptimized_X100" = @{ Advertised = 120;  Usable = 96; }
    "ComputeOptimized_X150" = @{ Advertised = 180;  Usable = 144; }
    "ComputeOptimized_X250" = @{ Advertised = 240;  Usable = 192; }
    "ComputeOptimized_X350" = @{ Advertised = 360;  Usable = 288; }
    "ComputeOptimized_X500" = @{ Advertised = 480;  Usable = 384; }
    "ComputeOptimized_X700" = @{ Advertised = 720;  Usable = 576; }
    # Flash Optimized
    "FlashOptimized_A250"  = @{ Advertised = 250;  Usable = 200; }
    "FlashOptimized_A500"  = @{ Advertised = 500;  Usable = 400; }
    "FlashOptimized_A700"  = @{ Advertised = 750;  Usable = 600; }
    "FlashOptimized_A1000" = @{ Advertised = 1000; Usable = 800; }
    "FlashOptimized_A1500" = @{ Advertised = 1500; Usable = 1200; }
    "FlashOptimized_A2000" = @{ Advertised = 2000; Usable = 1600; }
    "FlashOptimized_A4500" = @{ Advertised = 4500; Usable = 3600; }
}

# ═══════════════════════════════════════════════════════════════
# Shared Helper Functions
# ═══════════════════════════════════════════════════════════════

function Get-AmrSkuSizes {
    <#
    .SYNOPSIS
        Returns an ordered hashtable of AMR size numbers to Advertised/Usable memory,
        filtered by tier prefix.
    .DESCRIPTION
        Extracts size numbers from $script:AmrSkuSpecs for the specified tier
        (e.g., "Balanced" → B0-B1000).
    .PARAMETER TierPrefix
        Full tier prefix: "Balanced", "MemoryOptimized", "ComputeOptimized", "FlashOptimized".
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Balanced", "MemoryOptimized", "ComputeOptimized", "FlashOptimized")]
        [string]$TierPrefix
    )

    $sizeMap = [ordered]@{}

    foreach ($key in $script:AmrSkuSpecs.Keys) {
        if (-not $key.StartsWith($TierPrefix)) { continue }

        # Extract size number from key like "Balanced_B50" → "50", "FlashOptimized_A700" → "700"
        if ($key -match '_[A-Z](\d+)$') {
            $sizeNum = $Matches[1]
            if (-not $sizeMap.Contains($sizeNum)) {
                $spec = $script:AmrSkuSpecs[$key]
                $sizeMap[$sizeNum] = @{ Advertised = $spec.Advertised; Usable = $spec.Usable }
            }
        }
    }

    # Sort by numeric size value and rebuild ordered
    $sorted = [ordered]@{}
    foreach ($s in ($sizeMap.Keys | ForEach-Object { [int]$_ } | Sort-Object)) {
        $sorted["$s"] = $sizeMap["$s"]
    }
    return $sorted
}

function Get-RetailPrice {
    <#
    .SYNOPSIS
        Calls Azure Retail Prices API for a single meter name.
    .PARAMETER MeterName
        The meter name (e.g., "B50 Cache Instance", "P2 Cache Instance").
    .PARAMETER Region
        Azure region (e.g., "westus2").
    .PARAMETER Currency
        Currency code (default: "USD").
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$MeterName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Region,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$Currency = "USD"
    )

    $filter = "serviceName eq 'Redis Cache' and armRegionName eq '$Region' and type eq 'Consumption' and meterName eq '$MeterName'"
    $url = "https://prices.azure.com/api/retail/prices?currencyCode=%27${Currency}%27&`$filter=$filter"

    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -ErrorAction Stop
        if ($response.Items.Count -gt 0) {
            return $response.Items[0].retailPrice
        }
        return $null
    } catch {
        Write-Warning "Pricing API request failed for '$MeterName' in '$Region': $($_.Exception.Message)"
        return $null
    }
}

function Get-CacheNodeCount {
    <#
    .SYNOPSIS
        Calculates node count for ACR/AMR based on tier and configuration.
    .PARAMETER Tier
        Cache tier: Basic, Standard, Premium (ACR) or AMR.
    .PARAMETER ShardCount
        Number of shards (Premium only, default 1).
    .PARAMETER ReplicasPerPrimary
        Replicas per primary (Premium MRPP, default 1).
    .PARAMETER HA
        Whether AMR cache has HA enabled (default $true).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Tier,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 30)]
        [int]$ShardCount = 1,

        [Parameter(Mandatory=$false)]
        [ValidateRange(1, 3)]
        [int]$ReplicasPerPrimary = 1,

        [Parameter(Mandatory=$false)]
        [bool]$HA = $true
    )

    switch ($Tier) {
        "Basic"    { return 1 }
        "Standard" { return 2 }
        "Premium"  {
            $shards = [Math]::Max($ShardCount, 1)
            $replicas = [Math]::Max($ReplicasPerPrimary, 1)
            return $shards * (1 + $replicas)
        }
        default {
            # AMR tiers
            return $(if ($HA) { 2 } else { 1 })
        }
    }
}

function Get-MetricsBasedSkuSuggestion {
    <#
    .SYNOPSIS
        Suggests an optimal AMR SKU based on actual cache metrics.
    .DESCRIPTION
        Applies the decision matrix from sku-mapping.md to recommend an AMR tier
        (M/B/X/Flash) and specific SKU based on memory usage, server load, connections,
        and bandwidth. Returns Confidence "None" if memory metrics are missing.
    .PARAMETER Metrics
        Structured metrics object from Get-AcrCacheMetrics.
    .PARAMETER SourceConfig
        Source ACR configuration (from Parse-AcrTemplate). Used for HA and capacity context.
    .PARAMETER AmrSkuSpecs
        AMR SKU specifications hashtable (optional, uses $script:AmrSkuSpecs).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Metrics,

        [Parameter(Mandatory=$true)]
        [PSCustomObject]$SourceConfig,

        [Parameter(Mandatory=$false)]
        [hashtable]$AmrSkuSpecs
    )

    $memPeakGB    = $Metrics.UsedMemoryPeakGB
    $serverLoad   = $Metrics.ServerLoadPeak
    $connPeak     = $Metrics.ConnectedClientsPeak
    $readMBs      = $Metrics.CacheReadPeakMBs
    $writeMBs     = $Metrics.CacheWritePeakMBs

    if ($null -eq $memPeakGB) {
        return [PSCustomObject]@{
            SuggestedTier = $null
            SuggestedSku  = $null
            Reason        = "Insufficient metrics data (no memory usage available)"
            Confidence    = "None"
            Dimensions    = $null
        }
    }

    # ACR usable memory per shard (~80% of advertised)
    # Per Learn docs, ACR defaults: maxmemory-reserved=10% + maxfragmentationmemory-reserved=10% = 20% reserved
    $acrCapacityMap = @{
        "C0" = 0.2; "C1" = 0.8; "C2" = 2; "C3" = 4.8; "C4" = 10.4; "C5" = 20.8; "C6" = 42.4
        "P1" = 4.8; "P2" = 10.4; "P3" = 20.8; "P4" = 42.4; "P5" = 96
    }
    $acrCapacity = $acrCapacityMap[$SourceConfig.Sku]
    if ($acrCapacity -and $SourceConfig.ShardCount -gt 1) {
        $acrCapacity = $acrCapacity * $SourceConfig.ShardCount
    }

    $memUtilPct = if ($acrCapacity -and $acrCapacity -gt 0) {
        [math]::Round(($memPeakGB / $acrCapacity) * 100, 1)
    } else { 50 }  # Default to moderate if we can't determine

    # Decision matrix (see references/sku-mapping.md "Migration Decision Matrix")
    # Implemented:
    #   - Memory usage > 70%, low server load → Memory Optimized (M)
    #   - Server load > 60%, low memory usage → Compute Optimized (X)
    #   - High connection count (>50K) → Compute Optimized (X)
    #   - Memory usage 40-70%, moderate server load → Balanced (B)
    #   - Very large dataset (>500 GB) → Flash Optimized
    #   - Default / unsure → Balanced (B)
    $tier = "Balanced"
    $tierCode = "B"
    $reason = ""
    $confidence = "Medium"

    if ($memPeakGB -gt 500) {
        # Very large dataset → Flash
        $tier = "FlashOptimized"
        $tierCode = "Flash"
        $reason = "Very large dataset (${memPeakGB} GB peak) — Flash Optimized is most cost-effective"
        $confidence = "High"
    } elseif ($memUtilPct -gt 70 -and ($null -eq $serverLoad -or $serverLoad -lt 30)) {
        # High memory, low compute → Memory Optimized
        $tier = "MemoryOptimized"
        $tierCode = "M"
        $reason = "High memory utilization (${memUtilPct}%) with low Server Load ($($serverLoad ?? 'N/A')%) — Memory Optimized"
        $confidence = "High"
    } elseif (($null -ne $serverLoad -and $serverLoad -gt 60) -and $memUtilPct -lt 40) {
        # Low memory, high compute → Compute Optimized
        $tier = "ComputeOptimized"
        $tierCode = "X"
        $reason = "Low memory utilization (${memUtilPct}%) with high Server Load (${serverLoad}%) — Compute Optimized"
        $confidence = "High"
    } elseif ($null -ne $connPeak -and $connPeak -gt 50000) {
        # Very high connections → Compute Optimized
        $tier = "ComputeOptimized"
        $tierCode = "X"
        $reason = "High connection count (${connPeak}) — Compute Optimized supports more connections per size"
        $confidence = "Medium"
    } elseif ($memUtilPct -ge 40 -and $memUtilPct -le 70) {
        # Moderate everything → Balanced
        $tier = "Balanced"
        $tierCode = "B"
        $loadStr = if ($null -ne $serverLoad) { "${serverLoad}%" } else { "N/A" }
        $reason = "Moderate memory utilization (${memUtilPct}%) and Server Load ($loadStr) — Balanced"
        $confidence = "Medium"
    } else {
        # Default fallback
        $tier = "Balanced"
        $tierCode = "B"
        $reason = "General-purpose workload — Balanced (default recommendation)"
        $confidence = "Low"
    }

    # Find the right SKU size using tier-specific size table
    $tierPrefixMap = @{ "M" = "MemoryOptimized"; "B" = "Balanced"; "X" = "ComputeOptimized"; "Flash" = "FlashOptimized" }
    $skuSizes = Get-AmrSkuSizes -TierPrefix $tierPrefixMap[$tierCode]

    $suggestedSku = $null
    foreach ($size in $skuSizes.Keys) {
        if ($skuSizes[$size].Usable -ge $memPeakGB) {
            $suggestedSku = "${tierCode}${size}"
            break
        }
    }

    # Fallback: if dataset too large for selected tier
    if (-not $suggestedSku) {
        $lastSize = ($skuSizes.Keys | Select-Object -Last 1)
        $suggestedSku = "${tierCode}${lastSize}"
        $reason += " (dataset exceeds standard sizes — largest SKU selected)"
    }

    return [PSCustomObject]@{
        SuggestedTier = $tier
        SuggestedSku  = $suggestedSku
        Reason        = $reason
        Confidence    = $confidence
        Dimensions    = [PSCustomObject]@{
            UsedMemoryPeakGB    = $memPeakGB
            MemoryUtilizationPct = $memUtilPct
            ServerLoadPeak       = $serverLoad
            ConnectedClientsPeak = $connPeak
            CacheReadPeakMBs     = $readMBs
            CacheWritePeakMBs    = $writeMBs
        }
    }
}
