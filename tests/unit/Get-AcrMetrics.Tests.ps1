#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 tests for Get-Percentile95 and Get-AcrCacheMetrics from scripts/get_acr_metrics.ps1,
    plus Get-MetricsBasedSkuSuggestion from scripts/AmrMigrationHelpers.ps1.
.DESCRIPTION
    Uses AST-based extraction to load only the function definitions from
    the scripts, avoiding the param() block and CLI-mode exit.
#>

# File-level BeforeAll: parse the SUT once, extract function definitions via AST,
# and store the scriptblock for dot-sourcing inside each Describe.
BeforeAll {
    . (Join-Path $PSScriptRoot ".." "Helpers.ps1")

    # Parse get_acr_metrics.ps1 (ACR functions only)
    $script:SutPath = Join-Path $PSScriptRoot ".." ".." "scripts" "get_acr_metrics.ps1"
    $script:SutScriptBlock = Get-FunctionsScriptBlock -Path $script:SutPath

    # Parse AmrMigrationHelpers.ps1 (shared AMR functions + data)
    $script:SharedPath = Join-Path $PSScriptRoot ".." ".." "scripts" "AmrMigrationHelpers.ps1"
    $script:SharedScriptBlock = Get-SharedHelpersBlock
}

# ─────────────────────────────────────────────────────────────
# Get-Percentile95
# ─────────────────────────────────────────────────────────────
Describe "Get-Percentile95" {
    BeforeAll {
        . $script:SutScriptBlock
    }

    It "returns null for an empty array" {
        Get-Percentile95 -Values @() | Should -BeNullOrEmpty
    }

    It "returns the value itself for a single-element array" {
        Get-Percentile95 -Values @(42.0) | Should -Be 42.0
    }

    It "returns 19 for a 1..20 array (index Ceiling(0.95*20)-1 = 18)" {
        $values = @(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20)
        Get-Percentile95 -Values $values | Should -Be 19
    }

    It "returns 5 when all values are identical [5,5,5,5,5]" {
        Get-Percentile95 -Values @(5,5,5,5,5) | Should -Be 5
    }

    It "returns 20 for two-element array [10, 20]" {
        Get-Percentile95 -Values @(10, 20) | Should -Be 20
    }
}

# ─────────────────────────────────────────────────────────────
# Get-AcrCacheMetrics
# ─────────────────────────────────────────────────────────────
Describe "Get-AcrCacheMetrics" {
    BeforeAll {
        . $script:SutScriptBlock
        # Stub the az CLI as a global function so Pester can mock it
        function global:az { }
    }

    AfterAll {
        Remove-Item Function:\az -ErrorAction SilentlyContinue
    }

    Context "Successful API response" {
        BeforeAll {
            Mock az { return "fake-token" }

            $script:mockResponse = @{
                value = @(
                    @{
                        name = @{ value = "usedmemoryRss"; localizedValue = "Used Memory RSS" }
                        unit = "Bytes"
                        timeseries = @(@{ data = @(@{ maximum = 5368709120; average = 3221225472 }) })
                    },
                    @{
                        name = @{ value = "serverLoad"; localizedValue = "Server Load" }
                        unit = "Percent"
                        timeseries = @(@{ data = @(@{ maximum = 45.5; average = 22.3 }) })
                    },
                    @{
                        name = @{ value = "connectedclients"; localizedValue = "Connected Clients" }
                        unit = "Count"
                        timeseries = @(@{ data = @(@{ maximum = 150; average = 80 }) })
                    },
                    @{
                        name = @{ value = "cacheRead"; localizedValue = "Cache Read" }
                        unit = "BytesPerSecond"
                        timeseries = @(@{ data = @(@{ maximum = 10485760; average = 5242880 }) })
                    },
                    @{
                        name = @{ value = "cacheWrite"; localizedValue = "Cache Write" }
                        unit = "BytesPerSecond"
                        timeseries = @(@{ data = @(@{ maximum = 2097152; average = 1048576 }) })
                    }
                )
            }
            Mock Invoke-RestMethod { return $script:mockResponse }

            $script:result = Get-AcrCacheMetrics `
                -SubscriptionId "sub-1" -ResourceGroup "rg-1" -CacheName "cache-1"
        }

        It "returns object with CacheName and metric sub-objects" {
            $script:result              | Should -Not -BeNullOrEmpty
            $script:result.CacheName    | Should -Be "cache-1"
            $script:result.usedmemoryRss | Should -Not -BeNullOrEmpty
            $script:result.serverLoad    | Should -Not -BeNullOrEmpty
        }

        It "computes convenience properties correctly" {
            # UsedMemoryPeakGB = 5368709120 / 1 GB = 5.0
            $script:result.UsedMemoryPeakGB    | Should -Be 5.0
            # ServerLoadPeak = Round(45.5, 1) = 45.5
            $script:result.ServerLoadPeak       | Should -Be 45.5
            # ConnectedClientsPeak = [int]150
            $script:result.ConnectedClientsPeak | Should -Be 150
        }
    }

    Context "API failure" {
        BeforeAll {
            Mock az { return "fake-token" }
            Mock Invoke-RestMethod { throw "Network error" }
        }

        It "returns null when Invoke-RestMethod throws" {
            $r = Get-AcrCacheMetrics -SubscriptionId "s" -ResourceGroup "r" -CacheName "c"
            $r | Should -BeNullOrEmpty
        }
    }

    Context "Error response from API" {
        BeforeAll {
            Mock az { return "fake-token" }
            Mock Invoke-RestMethod { return @{ error = @{ message = "Not found" } } }
        }

        It "returns null when response contains error property" {
            $r = Get-AcrCacheMetrics -SubscriptionId "s" -ResourceGroup "r" -CacheName "c"
            $r | Should -BeNullOrEmpty
        }
    }

    Context "No access token" {
        BeforeAll {
            Mock az { return "" }
        }

        It "returns null when az returns empty token" {
            $r = Get-AcrCacheMetrics -SubscriptionId "s" -ResourceGroup "r" -CacheName "c"
            $r | Should -BeNullOrEmpty
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Format-MetricValue
# ─────────────────────────────────────────────────────────────
Describe "Format-MetricValue" {
    BeforeAll {
        . $script:SutScriptBlock
    }

    It "returns N/A for null value" {
        Format-MetricValue -Name "Any Metric" -Unit "Count" -Value $null | Should -Be "N/A"
    }

    It "formats Used Memory RSS as bytes and GB" {
        $result = Format-MetricValue -Name "Used Memory RSS" -Unit "Bytes" -Value 5368709120
        $result | Should -BeLike "*5,368,709,120 bytes*"
        $result | Should -BeLike "*5 GB*"
    }

    It "formats Percent unit with one decimal" {
        Format-MetricValue -Name "Server Load" -Unit "Percent" -Value 75.123 | Should -Be "75.1 %"
    }

    It "formats BytesPerSecond as bytes/sec and MB/s" {
        $result = Format-MetricValue -Name "Cache Read" -Unit "BytesPerSecond" -Value 10485760
        $result | Should -BeLike "*10,485,760 bytes/sec*"
        $result | Should -BeLike "*10 MB/s*"
    }

    It "formats default numeric value with no decimals" {
        Format-MetricValue -Name "Connected Clients" -Unit "Count" -Value 1234 | Should -Be "1,234"
    }
}

# ─────────────────────────────────────────────────────────────
# Get-MetricsBasedSkuSuggestion
# ─────────────────────────────────────────────────────────────
Describe "Get-MetricsBasedSkuSuggestion" {
    BeforeAll {
        . $script:SharedScriptBlock
        . $script:SutScriptBlock

        function New-MockMetrics {
            param(
                [object]$UsedMemoryPeakGB  = 5,
                [object]$ServerLoadPeak     = 25,
                [object]$ConnectedClientsPeak = 100,
                [object]$CacheReadPeakMBs  = 5,
                [object]$CacheWritePeakMBs = 1
            )
            return [PSCustomObject]@{
                UsedMemoryPeakGB     = $UsedMemoryPeakGB
                ServerLoadPeak       = $ServerLoadPeak
                ConnectedClientsPeak = $ConnectedClientsPeak
                CacheReadPeakMBs     = $CacheReadPeakMBs
                CacheWritePeakMBs    = $CacheWritePeakMBs
            }
        }

        function New-MockSourceConfig {
            param(
                [string]$Sku        = "P2",
                [int]$ShardCount    = 1,
                [string]$Tier       = "Premium"
            )
            return [PSCustomObject]@{
                Sku        = $Sku
                ShardCount = $ShardCount
                Tier       = $Tier
            }
        }
    }

    # 1. Null metrics → throws (Mandatory parameter rejects $null)
    It "throws when metrics object is null" {
        { Get-MetricsBasedSkuSuggestion -Metrics $null -SourceConfig (New-MockSourceConfig) } |
            Should -Throw
    }

    # 2. No memory data → Confidence None
    It "returns Confidence None when UsedMemoryPeakGB is null" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB $null
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig (New-MockSourceConfig)
        $r.Confidence | Should -Be "None"
        $r.SuggestedTier | Should -BeNullOrEmpty
    }

    # 3. High memory + low load → MemoryOptimized M
    #    P2 capacity = 13 GB, 11/13 = 84.6% > 70%, load 15 < 30
    It "suggests MemoryOptimized M for high memory and low load" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 11 -ServerLoadPeak 15
        $config  = New-MockSourceConfig -Sku "P2"
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "MemoryOptimized"
        $r.SuggestedSku  | Should -BeLike "M*"
        $r.Confidence    | Should -Be "High"
        # M10 usable=9.6 < 11, M20 usable=19.2 >= 11 → M20
        $r.SuggestedSku  | Should -Be "M20"
    }

    # 4. Low memory + high load → ComputeOptimized X
    #    3/13 = 23.1% < 40%, load 75 > 60
    It "suggests ComputeOptimized X for low memory and high load" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 3 -ServerLoadPeak 75
        $config  = New-MockSourceConfig -Sku "P2"
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "ComputeOptimized"
        $r.SuggestedSku  | Should -BeLike "X*"
        $r.Confidence    | Should -Be "High"
    }

    # 5. Moderate usage → Balanced B
    #    7/13 = 53.8% (40-70 range), load 45
    It "suggests Balanced B for moderate usage" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 7 -ServerLoadPeak 45
        $config  = New-MockSourceConfig -Sku "P2"
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "Balanced"
        $r.SuggestedSku  | Should -BeLike "B*"
        $r.Confidence    | Should -Be "Medium"
    }

    # 6. Very large dataset → Flash
    #    600 GB > 500 threshold → FlashOptimized tier
    #    Flash_A700: Usable=600 >= 600 GB peak → Flash700
    It "suggests FlashOptimized for very large dataset (600 GB)" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 600 -ServerLoadPeak 30
        $config  = New-MockSourceConfig -Sku "P5" -ShardCount 10
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "FlashOptimized"
        $r.SuggestedSku  | Should -BeLike "Flash*"
        $r.Confidence    | Should -Be "High"
        # Flash A700: Usable=600 >= 600 GB peak
        $r.SuggestedSku  | Should -Be "Flash700"
    }

    # 7. High connections → ComputeOptimized X
    #    60000 > 50000 threshold
    It "suggests ComputeOptimized X for very high connection count" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 2 -ServerLoadPeak 30 -ConnectedClientsPeak 60000
        $config  = New-MockSourceConfig -Sku "P2"
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "ComputeOptimized"
        $r.SuggestedSku  | Should -BeLike "X*"
    }

    # 8. Default fallback → Balanced B with Low confidence
    #    1/13 = 7.7% (below 40 range), load 10 (below 60) → no rule matches → default
    It "falls back to Balanced B with Low confidence for low utilization" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 1 -ServerLoadPeak 10
        $config  = New-MockSourceConfig -Sku "P2"
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "Balanced"
        $r.Confidence    | Should -Be "Low"
    }

    # 9. Correct SKU size selection
    #    5 GB peak, B series: B5 usable=4.8 < 5, so picks B10 usable=9.6
    It "selects B10 when 5 GB peak exceeds B5 usable capacity (4.8 GB)" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 5 -ServerLoadPeak 20
        $config  = New-MockSourceConfig -Sku "P2"
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedSku | Should -Be "B10"
    }

    # 10. Clustered capacity — P2 with 3 shards
    #     30 GB peak, low load → MemoryOptimized M
    It "suggests MemoryOptimized M for clustered P2 with large memory usage" {
        $metrics = New-MockMetrics -UsedMemoryPeakGB 30 -ServerLoadPeak 20
        $config  = New-MockSourceConfig -Sku "P2" -ShardCount 3
        $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config

        $r.SuggestedTier | Should -Be "MemoryOptimized"
        $r.SuggestedSku  | Should -BeLike "M*"
        # M10 usable=9.6 < 30, M20=19.2 < 30, M50 usable=48 >= 30
        $r.SuggestedSku  | Should -Be "M50"
    }

    # Edge cases — exact boundary values
    Context "Boundary values" {
        It "Flash threshold: 500 GB is NOT Flash (must exceed 500)" {
            $metrics = New-MockMetrics -UsedMemoryPeakGB 500 -ServerLoadPeak 20
            $config  = New-MockSourceConfig -Sku "P5" -ShardCount 10
            $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config
            $r.SuggestedTier | Should -Not -Be "FlashOptimized"
        }

        It "Flash threshold: 501 GB triggers Flash" {
            $metrics = New-MockMetrics -UsedMemoryPeakGB 501 -ServerLoadPeak 20
            $config  = New-MockSourceConfig -Sku "P5" -ShardCount 10
            $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config
            $r.SuggestedTier | Should -Be "FlashOptimized"
        }

        It "Connection threshold: 50000 is NOT high (must exceed 50000)" {
            $metrics = New-MockMetrics -UsedMemoryPeakGB 1 -ServerLoadPeak 10 -ConnectedClientsPeak 50000
            $config  = New-MockSourceConfig -Sku "P2"
            $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config
            $r.SuggestedTier | Should -Not -Be "ComputeOptimized"
        }

        It "Connection threshold: 50001 triggers ComputeOptimized" {
            $metrics = New-MockMetrics -UsedMemoryPeakGB 1 -ServerLoadPeak 10 -ConnectedClientsPeak 50001
            $config  = New-MockSourceConfig -Sku "P2"
            $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config
            $r.SuggestedTier | Should -Be "ComputeOptimized"
        }

        It "handles null ServerLoad for MemoryOptimized path" {
            # 11/13 = 84.6% > 70%, null load satisfies < 30 check
            $metrics = New-MockMetrics -UsedMemoryPeakGB 11 -ServerLoadPeak $null
            $config  = New-MockSourceConfig -Sku "P2"
            $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config
            $r.SuggestedTier | Should -Be "MemoryOptimized"
        }

        It "uses max shard count (30) for capacity calculation" {
            # P1 usable=4.8 GB per shard × 30 = 144 GB total. 80/144=55.6% → moderate (40-70) → Balanced Medium
            $metrics = New-MockMetrics -UsedMemoryPeakGB 80 -ServerLoadPeak 40
            $config  = New-MockSourceConfig -Sku "P1" -ShardCount 30
            $r = Get-MetricsBasedSkuSuggestion -Metrics $metrics -SourceConfig $config
            $r.SuggestedTier | Should -Be "Balanced"
            $r.Confidence | Should -Be "Medium"
        }
    }
}
