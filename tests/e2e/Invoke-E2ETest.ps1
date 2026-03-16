<#
.SYNOPSIS
    End-to-end migration test: ACR template → Convert → AMR template → validate/deploy.

.DESCRIPTION
    Tests the full Convert-AcrToAmr.ps1 pipeline against real ARM/Bicep templates.
    Optionally validates both the source ACR and migrated AMR templates by running
    az deployment what-if or a full deploy+delete cycle.

    Single mode:  Supply -TemplatePath and -ParametersPath directly.
    Batch mode:   Supply -BatchDirectory to scan for template+param pairs.

    Batch directory convention:
      <dir>/
        acr-cache.json                    # shared ARM template
        acr-cache.bicep                   # shared Bicep template (optional)
        params/
          <name>.parameters.json          # ARM param files
          <name>.bicepparam               # Bicep param files

    For each param file found, the script:
      1. Validates/deploys the ACR source template + params  (optional)
      2. Runs Convert-AcrToAmr.ps1 to produce migrated output
      3. Validates/deploys the migrated AMR template + params (optional)
      4. Cleans up deployed resources

.PARAMETER TemplatePath
    Path to a single ACR source template (.json or .bicep).

.PARAMETER ParametersPath
    Path to the parameters file for the source template.

.PARAMETER BatchDirectory
    Directory to scan for template+param pairs. Mutually exclusive with TemplatePath.

.PARAMETER ResourceGroup
    Azure resource group for deployment validation. Required when DeployMode is set.

.PARAMETER Region
    Azure region for pricing lookup and deployment. Default: westus2.

.PARAMETER DeployMode
    Validation strategy. WhatIf = ARM what-if only (no cost, fast).
    Deploy = full deploy + verify + delete. Default: WhatIf.

.PARAMETER ClusteringPolicy
    AMR clustering policy passed to Convert-AcrToAmr.ps1. Default: OSSCluster.

.PARAMETER SkipSourceValidation
    Skip ACR source template validation/deployment (go straight to migration).

.PARAMETER OutputDirectory
    Where to write migrated files. Default: temp directory per test case.

.EXAMPLE
    # Single test with what-if validation
    .\Invoke-E2ETest.ps1 -TemplatePath ..\fixtures\arm\acr-cache.json `
        -ParametersPath ..\fixtures\arm\params\premium-p2-clustered.parameters.json `
        -ResourceGroup rg-amr-e2e -Region westus2

.EXAMPLE
    # Batch: scan ARM fixtures, full deploy validation
    .\Invoke-E2ETest.ps1 -BatchDirectory ..\fixtures\arm `
        -ResourceGroup rg-amr-e2e -Region westus2 -DeployMode Deploy

.EXAMPLE
    # Batch: scan Bicep fixtures, what-if only, skip source validation
    .\Invoke-E2ETest.ps1 -BatchDirectory ..\fixtures\bicep `
        -ResourceGroup rg-amr-e2e -SkipSourceValidation
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Single')]
    [string]$TemplatePath,

    [Parameter(ParameterSetName = 'Single')]
    [string]$ParametersPath,

    [Parameter(Mandatory, ParameterSetName = 'Batch')]
    [string]$BatchDirectory,

    [Parameter()]
    [string]$TestName,

    [Parameter()]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$Region = 'westus2',

    [Parameter()]
    [ValidateSet('WhatIf', 'Deploy')]
    [string]$DeployMode = 'WhatIf',

    [Parameter()]
    [ValidateSet('OSSCluster', 'EnterpriseCluster')]
    [string]$ClusteringPolicy = 'OSSCluster',

    [switch]$SkipSourceValidation,

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$script:ScriptDir = $PSScriptRoot
$script:ConvertScript = Join-Path $script:ScriptDir ".." ".." "iac" "Convert-AcrToAmr.ps1"
$script:TestResults = @()

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

function Write-Step  { param([string]$Msg) Write-Host "  ▶ $Msg" -ForegroundColor Cyan }
function Write-Pass  { param([string]$Msg) Write-Host "  ✅ $Msg" -ForegroundColor Green }
function Write-Fail  { param([string]$Msg) Write-Host "  ❌ $Msg" -ForegroundColor Red }
function Write-Skip  { param([string]$Msg) Write-Host "  ⏭️  $Msg" -ForegroundColor DarkGray }
function Write-Banner { param([string]$Msg) Write-Host "`n═══ $Msg ═══" -ForegroundColor Yellow }

function Test-AzCliAvailable {
    try {
        $null = az account show 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Invoke-AzDeployment {
    <#
    .SYNOPSIS
        Validates or deploys a template+params to Azure.
    .OUTPUTS
        PSCustomObject with Success, Mode, Output, DeploymentName properties.
    #>
    param(
        [string]$Template,
        [string]$Parameters,
        [string]$RG,
        [string]$Mode,     # WhatIf or Deploy
        [string]$Label     # e.g., "ACR-source" or "AMR-migrated"
    )

    $deploymentName = "e2e-$Label-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $result = [PSCustomObject]@{
        Success        = $false
        Mode           = $Mode
        DeploymentName = $deploymentName
        Output         = ''
        Error          = ''
    }

    # Build command args
    $baseArgs = @(
        'deployment', 'group'
    )

    # Determine template type (Bicep or ARM)
    $templateExt = [System.IO.Path]::GetExtension($Template).ToLower()

    if ($Mode -eq 'WhatIf') {
        $baseArgs += 'what-if'
    } else {
        $baseArgs += 'create'
    }

    $baseArgs += '--resource-group', $RG
    $baseArgs += '--name', $deploymentName
    $baseArgs += '--template-file', $Template

    if ($Parameters) {
        $paramExt = [System.IO.Path]::GetExtension($Parameters).ToLower()
        if ($paramExt -eq '.bicepparam') {
            # Bicep params use --parameters directly
            $baseArgs += '--parameters', $Parameters
        } else {
            $baseArgs += '--parameters', "@$Parameters"
        }
    }

    if ($Mode -eq 'Deploy') {
        $baseArgs += '--mode', 'Incremental'
    }

    try {
        Write-Step "$Mode deployment: $Label ($deploymentName)"
        $output = & az @baseArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.Success = $true
            $result.Output = ($output | Out-String).Trim()
            Write-Pass "$Mode succeeded: $Label"
        } else {
            $result.Error = ($output | Out-String).Trim()
            Write-Fail "$Mode failed: $Label"
            Write-Host $result.Error -ForegroundColor DarkRed
        }
    } catch {
        $result.Error = $_.Exception.Message
        Write-Fail "$Mode error: $Label — $($_.Exception.Message)"
    }

    return $result
}

function Remove-Deployment {
    <#
    .SYNOPSIS
        Deletes resources created by a deployment.
    #>
    param(
        [string]$RG,
        [string]$DeploymentName
    )

    Write-Step "Cleaning up deployment: $DeploymentName"
    try {
        # Delete the deployment and its resources
        $null = az deployment group delete --resource-group $RG --name $DeploymentName 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Deployment delete only removes the deployment record.
            # We need to delete the actual resources. Get them from the deployment.
            $resources = az deployment group show --resource-group $RG --name $DeploymentName `
                --query 'properties.outputResources[].id' -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and $resources) {
                foreach ($resId in ($resources -split "`n" | Where-Object { $_ })) {
                    Write-Step "Deleting resource: $resId"
                    $null = az resource delete --ids $resId 2>&1
                }
            }
        }
        Write-Pass "Cleanup complete: $DeploymentName"
    } catch {
        Write-Fail "Cleanup error: $($_.Exception.Message)"
    }
}

function Invoke-SingleTest {
    <#
    .SYNOPSIS
        Runs one E2E test case: validate source → migrate → validate migrated → cleanup.
    #>
    param(
        [string]$Template,
        [string]$Params,
        [string]$TestName
    )

    Write-Banner "Test: $TestName"
    $testResult = [PSCustomObject]@{
        Name              = $TestName
        Template          = $Template
        Parameters        = $Params
        SourceValidation  = $null
        MigrationSuccess  = $false
        MigratedTemplate  = ''
        MigratedParams    = ''
        MigratedValidation = $null
        CleanupDone       = $false
        Error             = ''
    }

    # ── Step 1: Validate ACR source ──
    if (-not $SkipSourceValidation -and $ResourceGroup) {
        $testResult.SourceValidation = Invoke-AzDeployment `
            -Template $Template -Parameters $Params `
            -RG $ResourceGroup -Mode $DeployMode -Label "ACR-$TestName"

        if ($DeployMode -eq 'Deploy' -and $testResult.SourceValidation.Success) {
            Remove-Deployment -RG $ResourceGroup -DeploymentName $testResult.SourceValidation.DeploymentName
        }
    } elseif ($SkipSourceValidation) {
        Write-Skip "Source validation skipped"
    } else {
        Write-Skip "Source validation skipped (no -ResourceGroup)"
    }

    # ── Step 2: Run migration ──
    Write-Step "Running Convert-AcrToAmr.ps1..."
    $tempOut = if ($OutputDirectory) { $OutputDirectory } else {
        $td = Join-Path ([System.IO.Path]::GetTempPath()) "amr-e2e-$TestName-$(Get-Date -Format 'HHmmss')"
        New-Item -ItemType Directory -Path $td -Force | Out-Null
        $td
    }

    try {
        $migrateArgs = @{
            TemplatePath     = $Template
            Region           = $Region
            ClusteringPolicy = $ClusteringPolicy
            OutputDirectory  = $tempOut
            Force            = $true
            ReturnObject     = $true
            SkipPricing      = $true
        }
        if ($Params) { $migrateArgs['ParametersPath'] = $Params }

        $result = & $script:ConvertScript @migrateArgs

        if ($result -and $result.OutputFiles) {
            $testResult.MigrationSuccess = $true
            $templateFile = $result.OutputFiles | Where-Object { $_.Type -eq 'Template' } | Select-Object -First 1
            $paramsFile = $result.OutputFiles | Where-Object { $_.Type -match 'Parameters' } | Select-Object -First 1
            $testResult.MigratedTemplate = if ($templateFile) { $templateFile.Path } else { '' }
            $testResult.MigratedParams = if ($paramsFile) { $paramsFile.Path } else { '' }
            Write-Pass "Migration succeeded → $($testResult.MigratedTemplate)"

            # Show SKU mapping
            if ($result.TargetSku) {
                Write-Step "SKU: $($result.SourceConfig.SkuName) → $($result.TargetSku.Name)"
            }
        } else {
            $testResult.Error = "Migration returned no output"
            Write-Fail "Migration produced no output"
        }
    } catch {
        $testResult.Error = $_.Exception.Message
        Write-Fail "Migration error: $($_.Exception.Message)"
    }

    # ── Step 3: Validate AMR migrated template ──
    if ($testResult.MigrationSuccess -and $ResourceGroup) {
        $migratedParams = $testResult.MigratedParams
        $testResult.MigratedValidation = Invoke-AzDeployment `
            -Template $testResult.MigratedTemplate -Parameters $migratedParams `
            -RG $ResourceGroup -Mode $DeployMode -Label "AMR-$TestName"

        if ($DeployMode -eq 'Deploy' -and $testResult.MigratedValidation.Success) {
            Remove-Deployment -RG $ResourceGroup -DeploymentName $testResult.MigratedValidation.DeploymentName
            $testResult.CleanupDone = $true
        }
    } elseif (-not $testResult.MigrationSuccess) {
        Write-Skip "Migrated validation skipped (migration failed)"
    } else {
        Write-Skip "Migrated validation skipped (no -ResourceGroup)"
    }

    # ── Cleanup temp output ──
    if (-not $OutputDirectory -and $tempOut -and (Test-Path $tempOut)) {
        Remove-Item $tempOut -Recurse -Force -ErrorAction SilentlyContinue
    }

    $script:TestResults += $testResult
    return $testResult
}

function Find-TemplatePairs {
    <#
    .SYNOPSIS
        Scans a directory for template + param file pairs.
    .DESCRIPTION
        Looks for a shared template (acr-cache.json or acr-cache.bicep) and
        pairs it with each param file in the params/ subfolder.
    #>
    param([string]$Dir)

    $pairs = @()

    # Find the shared template
    $armTemplate = Get-ChildItem $Dir -Filter "acr-cache.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $bicepTemplate = Get-ChildItem $Dir -Filter "acr-cache.bicep" -File -ErrorAction SilentlyContinue | Select-Object -First 1

    $template = if ($bicepTemplate) { $bicepTemplate } elseif ($armTemplate) { $armTemplate } else { $null }

    if (-not $template) {
        Write-Warning "No acr-cache.json or acr-cache.bicep found in $Dir"
        return $pairs
    }

    # Find param files in params/ subfolder
    $paramsDir = Join-Path $Dir "params"
    if (Test-Path $paramsDir) {
        $paramFiles = Get-ChildItem $paramsDir -File | Where-Object {
            $_.Extension -in '.json', '.bicepparam'
        }
        foreach ($pf in $paramFiles) {
            $testName = [System.IO.Path]::GetFileNameWithoutExtension($pf.Name) -replace '\.parameters$', '' -replace '\.bicepparam$', ''
            $pairs += [PSCustomObject]@{
                Template   = $template.FullName
                Parameters = $pf.FullName
                TestName   = $testName
            }
        }
    }

    # Also pair with the root-level param file if it exists
    $rootParams = Get-ChildItem $Dir -File | Where-Object {
        $_.Name -match '\.parameters\.json$' -or ($_.Name -match '\.bicepparam$' -and $_.Name -ne $template.Name)
    }
    foreach ($rp in $rootParams) {
        $testName = "root-$([System.IO.Path]::GetFileNameWithoutExtension($rp.Name) -replace '\.parameters$', '')"
        $pairs += [PSCustomObject]@{
            Template   = $template.FullName
            Parameters = $rp.FullName
            TestName   = $testName
        }
    }

    return $pairs
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host   "║   AMR Migration E2E Test Runner                  ║" -ForegroundColor Yellow
Write-Host   "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow

# Validate prerequisites
if (-not (Test-Path $script:ConvertScript)) {
    throw "Convert-AcrToAmr.ps1 not found at: $script:ConvertScript"
}

if ($ResourceGroup) {
    if (-not (Test-AzCliAvailable)) {
        throw "Azure CLI not logged in. Run 'az login' first."
    }
    Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor DarkGray
}

Write-Host "  Deploy Mode:    $DeployMode" -ForegroundColor DarkGray
Write-Host "  Region:         $Region" -ForegroundColor DarkGray
Write-Host "  Clustering:     $ClusteringPolicy" -ForegroundColor DarkGray

# Run tests
if ($PSCmdlet.ParameterSetName -eq 'Batch') {
    if (-not (Test-Path $BatchDirectory)) {
        throw "Batch directory not found: $BatchDirectory"
    }

    $pairs = Find-TemplatePairs -Dir (Resolve-Path $BatchDirectory).Path
    if ($pairs.Count -eq 0) {
        Write-Warning "No template+param pairs found in $BatchDirectory"
        exit 1
    }

    Write-Host "`n  Found $($pairs.Count) test case(s)" -ForegroundColor DarkGray
    foreach ($pair in $pairs) {
        Invoke-SingleTest -Template $pair.Template -Params $pair.Parameters -TestName $pair.TestName
    }
} else {
    # Single mode
    $resolvedTemplate = (Resolve-Path $TemplatePath).Path
    $resolvedParams = if ($ParametersPath) { (Resolve-Path $ParametersPath).Path } else { '' }
    $singleTestName = if ($TestName) { $TestName }
                      elseif ($ParametersPath) {
                          [System.IO.Path]::GetFileNameWithoutExtension($ParametersPath) -replace '\.parameters$', ''
                      } else {
                          [System.IO.Path]::GetFileNameWithoutExtension($resolvedTemplate)
                      }

    Invoke-SingleTest -Template $resolvedTemplate -Params $resolvedParams -TestName $singleTestName
}

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host   "║   Results Summary                                ║" -ForegroundColor Yellow
Write-Host   "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow

$passed = 0
$failed = 0
foreach ($tr in $script:TestResults) {
    $migStatus = if ($tr.MigrationSuccess) { "✅" } else { "❌" }
    $srcStatus = if ($null -eq $tr.SourceValidation) { "⏭️" }
                 elseif ($tr.SourceValidation.Success) { "✅" } else { "❌" }
    $amrStatus = if ($null -eq $tr.MigratedValidation) { "⏭️" }
                 elseif ($tr.MigratedValidation.Success) { "✅" } else { "❌" }

    $line = "  {0,-35} Migrate:{1}  Source:{2}  AMR:{3}" -f $tr.Name, $migStatus, $srcStatus, $amrStatus
    Write-Host $line

    if ($tr.MigrationSuccess) { $passed++ } else { $failed++ }
    if ($tr.Error) { Write-Host "    Error: $($tr.Error)" -ForegroundColor DarkRed }
}

Write-Host "`n  Total: $($script:TestResults.Count)  Passed: $passed  Failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })

# Return results for programmatic use
if ($script:TestResults.Count -eq 1) {
    $script:TestResults[0]
} else {
    $script:TestResults
}
