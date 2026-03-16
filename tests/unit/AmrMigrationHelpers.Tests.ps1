#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 tests for scripts/AmrMigrationHelpers.ps1 — the shared helpers module.
.DESCRIPTION
    Tests $script:AmrSkuSpecs integrity, Get-AmrSkuSizes, Get-RetailPrice,
    and Get-CacheNodeCount. Uses direct dot-sourcing since AmrMigrationHelpers.ps1 has
    no param() block or CLI-mode exit.
#>

BeforeAll {
    $script:SutPath = Join-Path $PSScriptRoot ".." ".." "scripts" "AmrMigrationHelpers.ps1"
    . $script:SutPath
}

# ─────────────────────────────────────────────────────────────
# $script:AmrSkuSpecs — Data Integrity
# ─────────────────────────────────────────────────────────────

Describe "`$AmrSkuSpecs Data Integrity" {
    BeforeAll {
        . $script:SutPath
    }

    It "contains exactly 44 SKU entries" {
        $script:AmrSkuSpecs.Count | Should -Be 44
    }

    It "has 12 MemoryOptimized SKUs" {
        $count = ($script:AmrSkuSpecs.Keys | Where-Object { $_ -like "MemoryOptimized_*" }).Count
        $count | Should -Be 12
    }

    It "has 14 Balanced SKUs" {
        $count = ($script:AmrSkuSpecs.Keys | Where-Object { $_ -like "Balanced_*" }).Count
        $count | Should -Be 14
    }

    It "has 11 ComputeOptimized SKUs" {
        $count = ($script:AmrSkuSpecs.Keys | Where-Object { $_ -like "ComputeOptimized_*" }).Count
        $count | Should -Be 11
    }

    It "has 7 FlashOptimized SKUs" {
        $count = ($script:AmrSkuSpecs.Keys | Where-Object { $_ -like "FlashOptimized_*" }).Count
        $count | Should -Be 7
    }

    It "every SKU has required keys: Advertised, Usable" {
        $requiredKeys = @("Advertised", "Usable")
        foreach ($skuName in $script:AmrSkuSpecs.Keys) {
            $spec = $script:AmrSkuSpecs[$skuName]
            foreach ($key in $requiredKeys) {
                $spec.ContainsKey($key) | Should -BeTrue -Because "$skuName should have key '$key'"
            }
        }
    }

    It "Usable is always 80% of Advertised" {
        foreach ($skuName in $script:AmrSkuSpecs.Keys) {
            $spec = $script:AmrSkuSpecs[$skuName]
            $expected = [math]::Round($spec.Advertised * 0.8, 2)
            [math]::Round($spec.Usable, 2) | Should -Be $expected -Because "$skuName Usable should be 80% of Advertised ($($spec.Advertised))"
        }
    }

    It "all Advertised values are positive numbers" {
        foreach ($skuName in $script:AmrSkuSpecs.Keys) {
            $script:AmrSkuSpecs[$skuName].Advertised | Should -BeGreaterThan 0 -Because "$skuName Advertised should be positive"
        }
    }

    It "spot-checks known SKU values: Balanced_B50" {
        $spec = $script:AmrSkuSpecs["Balanced_B50"]
        $spec.Advertised     | Should -Be 60
        $spec.Usable         | Should -Be 48
    }

    It "spot-checks known SKU values: FlashOptimized_A4500" {
        $spec = $script:AmrSkuSpecs["FlashOptimized_A4500"]
        $spec.Advertised     | Should -Be 4500
        $spec.Usable         | Should -Be 3600
    }

    It "spot-checks known SKU values: MemoryOptimized_M10" {
        $spec = $script:AmrSkuSpecs["MemoryOptimized_M10"]
        $spec.Advertised     | Should -Be 12
        $spec.Usable         | Should -Be 9.6
    }
}

# ─────────────────────────────────────────────────────────────
# Get-AmrSkuSizes
# ─────────────────────────────────────────────────────────────

Describe "Get-AmrSkuSizes" {
    BeforeAll {
        . $script:SutPath
    }

    Context "returns ordered hashtable with correct structure" {
        It "returns an ordered hashtable" {
            $result = Get-AmrSkuSizes -TierPrefix "Balanced"
            $result | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        }

        It "contains unique size numbers sorted ascending" {
            $result = Get-AmrSkuSizes -TierPrefix "Balanced"
            $keys = @($result.Keys)
            $numericKeys = $keys | ForEach-Object { [int]$_ }
            $sorted = $numericKeys | Sort-Object
            $numericKeys | Should -Be $sorted
        }

        It "each entry has Advertised and Usable keys" {
            $result = Get-AmrSkuSizes -TierPrefix "Balanced"
            foreach ($size in $result.Keys) {
                $result[$size].ContainsKey("Advertised") | Should -BeTrue -Because "size $size needs Advertised"
                $result[$size].ContainsKey("Usable") | Should -BeTrue -Because "size $size needs Usable"
            }
        }
    }

    Context "With TierPrefix = 'Balanced'" {
        It "returns only Balanced-tier sizes" {
            $result = Get-AmrSkuSizes -TierPrefix "Balanced"
            # Balanced has B0, B1, B3, B5, B10, B20, B50, B100, B150, B250, B350, B500, B700, B1000
            $result.Count | Should -Be 14
        }

        It "includes B0 with 0.5 GB Advertised" {
            $result = Get-AmrSkuSizes -TierPrefix "Balanced"
            $result["0"].Advertised | Should -Be 0.5
        }

        It "includes B1000 with 960 GB Advertised" {
            $result = Get-AmrSkuSizes -TierPrefix "Balanced"
            $result["1000"].Advertised | Should -Be 960
        }
    }

    Context "With TierPrefix = 'FlashOptimized'" {
        It "returns only Flash-tier sizes" {
            $result = Get-AmrSkuSizes -TierPrefix "FlashOptimized"
            # Flash has A250, A500, A700, A1000, A1500, A2000, A4500
            $result.Count | Should -Be 7
        }

        It "smallest Flash size is 250" {
            $result = Get-AmrSkuSizes -TierPrefix "FlashOptimized"
            $firstKey = @($result.Keys)[0]
            $firstKey | Should -Be "250"
        }
    }

    Context "With TierPrefix = 'ComputeOptimized'" {
        It "returns 11 ComputeOptimized sizes" {
            $result = Get-AmrSkuSizes -TierPrefix "ComputeOptimized"
            $result.Count | Should -Be 11
        }
    }

    Context "With TierPrefix = 'MemoryOptimized'" {
        It "returns 12 MemoryOptimized sizes" {
            $result = Get-AmrSkuSizes -TierPrefix "MemoryOptimized"
            $result.Count | Should -Be 12
        }
    }

    Context "With non-existent TierPrefix" {
        It "throws validation error for unknown tier" {
            { Get-AmrSkuSizes -TierPrefix "DoesNotExist" } | Should -Throw "*does not belong to the set*"
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Get-CacheNodeCount
# ─────────────────────────────────────────────────────────────

Describe "Get-CacheNodeCount" {
    BeforeAll {
        . $script:SutPath
    }

    It "returns 1 for Basic tier" {
        Get-CacheNodeCount -Tier "Basic" | Should -Be 1
    }

    It "returns 2 for Standard tier" {
        Get-CacheNodeCount -Tier "Standard" | Should -Be 2
    }

    Context "Premium tier" {
        It "returns 2 for Premium with defaults (1 shard, 1 replica)" {
            Get-CacheNodeCount -Tier "Premium" | Should -Be 2
        }

        It "returns 6 for Premium with 3 shards and 1 replica" {
            Get-CacheNodeCount -Tier "Premium" -ShardCount 3 -ReplicasPerPrimary 1 | Should -Be 6
        }

        It "returns 9 for Premium with 3 shards and 2 replicas" {
            Get-CacheNodeCount -Tier "Premium" -ShardCount 3 -ReplicasPerPrimary 2 | Should -Be 9
        }

        It "returns 30 for Premium with 10 shards and 2 replicas" {
            Get-CacheNodeCount -Tier "Premium" -ShardCount 10 -ReplicasPerPrimary 2 | Should -Be 30
        }

        It "rejects ShardCount 0 with validation error" {
            { Get-CacheNodeCount -Tier "Premium" -ShardCount 0 -ReplicasPerPrimary 1 } | Should -Throw
        }

        It "rejects ReplicasPerPrimary 0 with validation error" {
            { Get-CacheNodeCount -Tier "Premium" -ShardCount 2 -ReplicasPerPrimary 0 } | Should -Throw
        }
    }

    Context "AMR tiers (default branch)" {
        It "returns 2 for any non-ACR tier with HA enabled (default)" {
            Get-CacheNodeCount -Tier "Balanced" | Should -Be 2
        }

        It "returns 1 for any non-ACR tier with HA disabled" {
            Get-CacheNodeCount -Tier "Balanced" -HA $false | Should -Be 1
        }

        It "returns 2 for AMR tier with HA enabled" {
            Get-CacheNodeCount -Tier "AMR" -HA $true | Should -Be 2
        }
    }

    Context "Edge cases" {
        It "handles max ACR shards (30) with max replicas (3)" {
            Get-CacheNodeCount -Tier "Premium" -ShardCount 30 -ReplicasPerPrimary 3 | Should -Be 120
        }

        It "rejects ShardCount above 30" {
            { Get-CacheNodeCount -Tier "Premium" -ShardCount 31 } | Should -Throw
        }

        It "rejects ReplicasPerPrimary above 3" {
            { Get-CacheNodeCount -Tier "Premium" -ReplicasPerPrimary 4 } | Should -Throw
        }
    }
}

# ─────────────────────────────────────────────────────────────
# Get-RetailPrice
# ─────────────────────────────────────────────────────────────

Describe "Get-RetailPrice" {
    BeforeAll {
        . $script:SutPath
    }

    Context "Successful API response" {
        It "returns the retail price when API returns items" {
            Mock Invoke-RestMethod {
                return @{ Items = @( @{ retailPrice = 123.45 } ) }
            }
            $result = Get-RetailPrice -MeterName "B50 Cache Instance" -Region "westus2"
            $result | Should -Be 123.45
        }

        It "builds correct filter with region and meter name" {
            Mock Invoke-RestMethod {
                param($Uri)
                # Verify filter contents via the URI
                $Uri | Should -BeLike "*armRegionName eq 'eastus'*"
                $Uri | Should -BeLike "*meterName eq 'P2 Cache Instance'*"
                return @{ Items = @( @{ retailPrice = 99.99 } ) }
            }
            Get-RetailPrice -MeterName "P2 Cache Instance" -Region "eastus" | Should -Be 99.99
        }

        It "uses USD currency by default" {
            Mock Invoke-RestMethod {
                param($Uri)
                $Uri | Should -BeLike "*currencyCode=%27USD%27*"
                return @{ Items = @( @{ retailPrice = 50.00 } ) }
            }
            Get-RetailPrice -MeterName "B10 Cache Instance" -Region "westus2" | Should -Be 50.00
        }

        It "supports custom currency" {
            Mock Invoke-RestMethod {
                param($Uri)
                $Uri | Should -BeLike "*currencyCode=%27EUR%27*"
                return @{ Items = @( @{ retailPrice = 42.00 } ) }
            }
            Get-RetailPrice -MeterName "B10 Cache Instance" -Region "westus2" -Currency "EUR" | Should -Be 42.00
        }
    }

    Context "No results" {
        It "returns null when API returns empty items" {
            Mock Invoke-RestMethod {
                return @{ Items = @() }
            }
            $result = Get-RetailPrice -MeterName "Nonexistent SKU" -Region "westus2"
            $result | Should -BeNullOrEmpty
        }
    }

    Context "API failure" {
        It "returns null and writes warning when Invoke-RestMethod throws" {
            Mock Invoke-RestMethod { throw "Network error" }
            $result = Get-RetailPrice -MeterName "B50 Cache Instance" -Region "westus2" -WarningVariable warn 3>$null
            $result | Should -BeNullOrEmpty
            $warn | Should -Not -BeNullOrEmpty
            $warn[0] | Should -BeLike "*Pricing API request failed*"
        }
    }
}
