<#
.SYNOPSIS
    Runs E2E migration tests in parallel across all param files in a fixtures directory.

.DESCRIPTION
    Wraps Invoke-E2ETest.ps1 to launch one test per param file concurrently using
    PowerShell 7 ForEach-Object -Parallel. Uses separate templates for Basic/Standard
    and Premium tiers:
      - acr-basic-standard.json + params/basic-standard/*.parameters.json
      - acr-premium.json        + params/premium/*.parameters.json

    Each test validates the ACR source template, runs migration via Convert-AcrToAmr.ps1,
    and validates the migrated AMR template.

.PARAMETER FixturesDirectory
    Path to the fixtures directory containing templates and a params/ subfolder.
    Default: ..\fixtures\arm (relative to this script).

.PARAMETER ResourceGroup
    Azure resource group for deployment validation.

.PARAMETER Region
    Azure region. Default: westus2.

.PARAMETER DeployMode
    WhatIf (default) or Deploy.

.PARAMETER ThrottleLimit
    Max concurrent tests. Default: 8.

.PARAMETER SkipSourceValidation
    Skip ACR source template validation (only test migration + AMR validation).

.EXAMPLE
    .\Invoke-ParallelE2ETest.ps1 -ResourceGroup rg-acrtoamr-e2etest

.EXAMPLE
    .\Invoke-ParallelE2ETest.ps1 -ResourceGroup rg-acrtoamr-e2etest -ThrottleLimit 4 -SkipSourceValidation
#>

[CmdletBinding()]
param(
    [string]$FixturesDirectory,

    [Parameter()]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$Region = 'westus2',

    [Parameter()]
    [ValidateSet('WhatIf', 'Deploy')]
    [string]$DeployMode = 'WhatIf',

    [Parameter()]
    [int]$ThrottleLimit = 8,

    [switch]$SkipSourceValidation
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$e2eScript = Join-Path $scriptDir "Invoke-E2ETest.ps1"

if (-not $FixturesDirectory) {
    $FixturesDirectory = Join-Path $scriptDir ".." "fixtures" "arm"
}
$FixturesDirectory = (Resolve-Path $FixturesDirectory).Path

# Validate prerequisites
if (-not (Test-Path $e2eScript)) {
    throw "Invoke-E2ETest.ps1 not found at: $e2eScript"
}

# Discover templates and param files by tier subfolder.
# Supports both ARM (.json / .parameters.json) and Bicep (.bicep / .bicepparam).
$basicStdTemplate = $null
$premiumTemplate  = $null

foreach ($ext in @('.bicep', '.json')) {
    if (-not $basicStdTemplate) {
        $candidate = Join-Path $FixturesDirectory "acr-basic-standard$ext"
        if (Test-Path $candidate) { $basicStdTemplate = $candidate }
    }
    if (-not $premiumTemplate) {
        $candidate = Join-Path $FixturesDirectory "acr-premium$ext"
        if (Test-Path $candidate) { $premiumTemplate = $candidate }
    }
}

# Determine param file filter based on detected template type
$isBicep = ($basicStdTemplate -and $basicStdTemplate.EndsWith('.bicep')) -or
           ($premiumTemplate -and $premiumTemplate.EndsWith('.bicep'))
$paramFilter = if ($isBicep) { "*.bicepparam" } else { "*.parameters.json" }

$basicStdParams = Join-Path $FixturesDirectory "params" "basic-standard"
$premiumParams  = Join-Path $FixturesDirectory "params" "premium"

# Build test cases: array of [template, paramFile] pairs
$testCases = @()

if ($basicStdTemplate) {
    if (Test-Path $basicStdParams) {
        Get-ChildItem $basicStdParams -Filter $paramFilter | ForEach-Object {
            $testCases += [PSCustomObject]@{ Template = $basicStdTemplate; ParamFile = $_ }
        }
    }
} else {
    Write-Warning "Basic/Standard template not found in: $FixturesDirectory"
}

if ($premiumTemplate) {
    if (Test-Path $premiumParams) {
        Get-ChildItem $premiumParams -Filter $paramFilter | ForEach-Object {
            $testCases += [PSCustomObject]@{ Template = $premiumTemplate; ParamFile = $_ }
        }
    }
} else {
    Write-Warning "Premium template not found in: $FixturesDirectory"
}

if ($testCases.Count -eq 0) {
    throw "No test cases found. Check that templates and param subfolders exist under $FixturesDirectory"
}

$testCases = $testCases | Sort-Object { $_.ParamFile.Name }

# ─────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────
Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host   "║   Parallel AMR Migration E2E Test Runner          ║" -ForegroundColor Yellow
Write-Host   "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host "  Templates:" -ForegroundColor DarkGray
if ($basicStdTemplate) { Write-Host "    Basic/Standard: $basicStdTemplate" -ForegroundColor DarkGray }
if ($premiumTemplate)  { Write-Host "    Premium:        $premiumTemplate" -ForegroundColor DarkGray }
Write-Host "  Format:         $(if ($isBicep) { 'Bicep' } else { 'ARM' })" -ForegroundColor DarkGray
Write-Host "  Test cases:     $($testCases.Count)" -ForegroundColor DarkGray
Write-Host "  ResourceGroup:  $(if ($ResourceGroup) { $ResourceGroup } else { '(none — skipping Azure validation)' })" -ForegroundColor DarkGray
Write-Host "  DeployMode:     $DeployMode" -ForegroundColor DarkGray
Write-Host "  Region:         $Region" -ForegroundColor DarkGray
Write-Host "  ThrottleLimit:  $ThrottleLimit" -ForegroundColor DarkGray
Write-Host "  SkipSource:     $SkipSourceValidation" -ForegroundColor DarkGray
Write-Host "  Started:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor DarkGray

# List all test cases grouped by tier
$bsCount = ($testCases | Where-Object { $_.Template -eq $basicStdTemplate }).Count
$pCount  = ($testCases | Where-Object { $_.Template -eq $premiumTemplate }).Count
if ($bsCount -gt 0) {
    Write-Host "  Basic/Standard ($bsCount):" -ForegroundColor Cyan
    $testCases | Where-Object { $_.Template -eq $basicStdTemplate } | ForEach-Object {
        $name = $_.ParamFile.BaseName -replace '\.parameters$', ''
        Write-Host "    • $name" -ForegroundColor DarkGray
    }
}
if ($pCount -gt 0) {
    Write-Host "  Premium ($pCount):" -ForegroundColor Cyan
    $testCases | Where-Object { $_.Template -eq $premiumTemplate } | ForEach-Object {
        $name = $_.ParamFile.BaseName -replace '\.parameters$', ''
        Write-Host "    • $name" -ForegroundColor DarkGray
    }
}
Write-Host ""

# ─────────────────────────────────────────────────────────────
# Run tests in parallel
# ─────────────────────────────────────────────────────────────
$startTime = Get-Date

$results = $testCases | ForEach-Object -Parallel {
    $tc = $_
    $pf = $tc.ParamFile
    $templatePath = $tc.Template
    $testName = $pf.BaseName -replace '\.parameters$', ''
    $testStart = Get-Date

    # Build args for Invoke-E2ETest.ps1
    $args = @{
        TemplatePath   = $templatePath
        ParametersPath = $pf.FullName
        TestName       = $testName
        Region         = $using:Region
        DeployMode     = $using:DeployMode
    }
    if ($using:ResourceGroup) { $args['ResourceGroup'] = $using:ResourceGroup }
    if ($using:SkipSourceValidation) { $args['SkipSourceValidation'] = $true }

    try {
        # Invoke-E2ETest returns a PSCustomObject with structured results.
        # Write-Host output goes to the console directly (information stream);
        # we only capture the returned object here.
        $resultObj = & $using:e2eScript @args
        $duration = (Get-Date) - $testStart

        # Serialize to JSON and back to avoid runspace deserialization issues
        # with nested PSCustomObject properties.
        $parsed = $resultObj | ConvertTo-Json -Depth 10 | ConvertFrom-Json

        $migrationOk = [bool]$parsed.MigrationSuccess

        # Source validation
        $sourceOk = if ($null -eq $parsed.SourceValidation) { 'Skipped' }
                    elseif ($parsed.SourceValidation.Success -eq $true) { 'Pass' }
                    else { 'Fail' }

        # AMR validation
        $amrOk = if ($null -eq $parsed.MigratedValidation) { 'Skipped' }
                 elseif ($parsed.MigratedValidation.Success -eq $true) { 'Pass' }
                 else { 'Fail' }

        # Extract SKU
        $skuLine = if ($parsed.PSObject.Properties['TargetSku']) { $parsed.TargetSku } else { '' }

        # Collect errors
        $errors = @()
        if ($parsed.Error) { $errors += $parsed.Error }
        if ($parsed.SourceValidation -and $sourceOk -eq 'Fail' -and $parsed.SourceValidation.Error) {
            $errors += "Source: $($parsed.SourceValidation.Error)"
        }
        if ($parsed.MigratedValidation -and $amrOk -eq 'Fail' -and $parsed.MigratedValidation.Error) {
            $errors += "AMR: $($parsed.MigratedValidation.Error)"
        }

        [PSCustomObject]@{
            TestName      = $testName
            Migration     = if ($migrationOk) { 'Pass' } else { 'Fail' }
            Source        = $sourceOk
            AMR           = $amrOk
            SKU           = $skuLine
            Duration      = $duration
            Errors        = ($errors -join "`n")
        }
    } catch {
        [PSCustomObject]@{
            TestName      = $testName
            Migration     = 'Error'
            Source        = 'Error'
            AMR           = 'Error'
            SKU           = ''
            Duration      = (Get-Date) - $testStart
            Errors        = $_.Exception.Message
        }
    }
} -ThrottleLimit $ThrottleLimit

$totalDuration = (Get-Date) - $startTime

# ─────────────────────────────────────────────────────────────
# Results Summary
# ─────────────────────────────────────────────────────────────
Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host   "║   Results Summary                                ║" -ForegroundColor Yellow
Write-Host   "╚══════════════════════════════════════════════════╝`n" -ForegroundColor Yellow

$statusIcon = @{ Pass = '✅'; Fail = '❌'; Skipped = '⏭️'; Unknown = '❓'; Error = '💥' }

# Table header
$fmt = "  {0,-40} {1,-10} {2,-10} {3,-10} {4,-10} {5}"
Write-Host ($fmt -f 'TEST', 'MIGRATE', 'SOURCE', 'AMR', 'DURATION', 'SKU') -ForegroundColor White
Write-Host ("  " + ("-" * 100)) -ForegroundColor DarkGray

$migPass = 0; $migFail = 0
foreach ($r in ($results | Sort-Object TestName)) {
    $mi = $statusIcon[$r.Migration]
    $si = $statusIcon[$r.Source]
    $ai = $statusIcon[$r.AMR]
    $dur = "{0:N1}s" -f $r.Duration.TotalSeconds

    $color = if ($r.Migration -eq 'Pass' -and $r.AMR -in @('Pass', 'Skipped')) { 'Green' } else { 'Red' }
    Write-Host ($fmt -f $r.TestName, $mi, $si, $ai, $dur, $r.SKU) -ForegroundColor $color

    if ($r.Migration -eq 'Pass') { $migPass++ } else { $migFail++ }
}

Write-Host ("`n  " + ("-" * 100)) -ForegroundColor DarkGray
Write-Host "  Migration: $migPass passed, $migFail failed out of $($results.Count)" -ForegroundColor $(if ($migFail -eq 0) { 'Green' } else { 'Red' })
Write-Host "  Total time: $("{0:N1}" -f $totalDuration.TotalSeconds)s (wall clock, $ThrottleLimit parallel)" -ForegroundColor DarkGray
Write-Host "  Finished:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────
# Show errors for failed tests
# ─────────────────────────────────────────────────────────────
$failedTests = $results | Where-Object { $_.Migration -ne 'Pass' -or $_.AMR -eq 'Fail' }
if ($failedTests) {
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║   Failed Test Details                             ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════╝`n" -ForegroundColor Red

    foreach ($f in $failedTests) {
        Write-Host "  ── $($f.TestName) ──" -ForegroundColor Red
        if ($f.Errors) {
            $f.Errors -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
        } else {
            Write-Host "    (no error details captured)" -ForegroundColor DarkRed
        }
        Write-Host ""
    }
}

# Return structured results for programmatic use (exclude large ResultObject from display)
$results | Sort-Object TestName | Select-Object TestName, Migration, Source, AMR, SKU, Duration, Errors
