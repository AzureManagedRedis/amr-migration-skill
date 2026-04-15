<#
.SYNOPSIS
    Script for migrating a cache from Azure Cache for Redis to Azure Managed Redis using ARM REST APIs.
.DESCRIPTION
    This script allows you to initiate, check the status of, or cancel a migration from an Azure Cache for Redis resource to Azure Managed Redis.
.PARAMETER Action
    The action to perform: "Validate", "Migrate", "Status", or "Cancel".
.PARAMETER SourceResourceId
    The resource ID of the source Azure Cache for Redis resource.
.PARAMETER TargetResourceId
    The resource ID of the target Azure Managed Redis resource.
.PARAMETER ForceMigrate
    If set to $true, migration proceeds even when source/target cache parity validation returns warnings.
    If set to $false (default), migration is blocked when validation returns any warning.
.PARAMETER TrackMigration
    If set, the script will wait for the migration operation to complete (default is $false).
.PARAMETER Help
    If set, displays help information about the script (default is $false).
.EXAMPLE
    .\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action Validate -SourceResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/Redis/redis1" -TargetResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1"
    Validates whether a migration can be performed between the source and target caches.
    .\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action Migrate -SourceResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/Redis/redis1" -TargetResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1" -TrackMigration
    Initiates a migration and tracks its progress.
    .\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action Migrate -SourceResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/Redis/redis1" -TargetResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1" -ForceMigrate $true
    Initiates a migration and forces migration when parity validation returns warnings.
    .\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action Status -TargetResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1"
    Checks the status of the migration.
    .\Azure-Redis-Migration-Arm-Rest-Api-Utility.ps1 -Action Cancel -TargetResourceId "/subscriptions/xxxxx/resourceGroups/rg1/providers/Microsoft.Cache/redisEnterprise/amr1"
    Cancels the migration.
.NOTES
    This script requires Azure CLI (az) logged in. Run 'az login' before use.
    PowerShell 7+ is required.
#>

[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter()]
    [ValidateSet("Validate", "Migrate", "Status", "Cancel")]
    [string] $Action,

    [Parameter()]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Cache/Redis/[^/]+$')]
    [string] $SourceResourceId,

    [Parameter()]
    [string] $TargetResourceId,

    [Parameter()]
    [bool] $ForceMigrate = $false,

    [Parameter()]
    [switch] $TrackMigration = $false,

    [Parameter()]
    [switch] $Help = $false
)

# ARM API version as internal constant (not user-configurable)
$ArmApiVersion = "2025-08-01-preview"
$ArmBaseUrl = "https://management.azure.com"

$ErrorActionPreference = "Stop"
$currentScript = $MyInvocation.MyCommand.Source

function Show-Help
{
    Get-Help -Name $currentScript -Full
}

if ($Help)
{
    Show-Help
    exit 0
}

# Parse the TargetResourceId (Azure Managed Redis resourceId)
$pattern = '(?i)^/subscriptions/(?<SubscriptionId>[^/]+)/resourceGroups/(?<ResourceGroupName>[^/]+)/providers/Microsoft\.Cache/redisEnterprise/(?<AmrCacheName>[^/]+)(?:/.*)?/?$'

if ($TargetResourceId -match $pattern) {
    $SubscriptionId = $Matches.SubscriptionId
    $ResourceGroupName = $Matches.ResourceGroupName
    $AmrCacheName = $Matches.AmrCacheName
} else {
    throw "TargetResourceId is not parsed correctly."
}

# Wrapper for Azure CLI calls — checks $LASTEXITCODE and throws on failure
function Invoke-AzCli
{
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        $errorMsg = ($output | Out-String).Trim()
        throw "Azure CLI command failed (exit code $LASTEXITCODE): $errorMsg"
    }
    return ($output | Out-String).Trim()
}

function Confirm-AzureLogin
{
    try {
        $accountJson = Invoke-AzCli -Arguments @("account", "show", "-o", "json")
        $account = $accountJson | ConvertFrom-Json
    } catch {
        throw "Not logged in to Azure CLI. Run 'az login' first."
    }

    if ($account.id -ne $SubscriptionId)
    {
        Invoke-AzCli -Arguments @("account", "set", "--subscription", $SubscriptionId) | Out-Null
        Write-Host "Switched Azure CLI subscription to '$SubscriptionId'."
    }

    Write-Host "Using subscription: $SubscriptionId"
    Write-Host
}

Confirm-AzureLogin

# Make an ARM REST call via az rest and return parsed JSON (or $null)
function Invoke-ArmRest
{
    param(
        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Body
    )

    $url = "${ArmBaseUrl}${Path}?api-version=${ArmApiVersion}"
    $args_ = @("rest", "--method", $Method, "--url", $url, "--headers", "Content-Type=application/json", "-o", "json")
    $tempFile = $null

    if ($Body)
    {
        # Write body to a temp file to avoid PowerShell argument quoting issues
        $tempFile = [System.IO.Path]::GetTempFileName()
        $Body | Set-Content -Path $tempFile -Encoding utf8NoBOM
        $args_ += @("--body", "@$tempFile")
    }

    try {
        $output = Invoke-AzCli -Arguments $args_
        Write-Host "The request is successful." -ForegroundColor Green

        if ($output) {
            try {
                $parsed = $output | ConvertFrom-Json
                $parsed | ConvertTo-Json -Depth 5 | Write-Host
                return $parsed
            } catch {
                Write-Verbose "Raw response: $output"
                Write-Host "(Response content available with -Verbose flag)"
            }
        }
    } catch {
        Write-Host "The request encountered a failure." -ForegroundColor Red
        Write-Host $_.Exception.Message
        throw
    } finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item $tempFile -Force
        }
    }

    return $null
}

# Poll migration status until terminal state (used with -TrackMigration)
function Wait-ForMigration
{
    $statusPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Cache/RedisEnterprise/$AmrCacheName/migrations/default"
    $state = "InProgress"
    $attempt = 0
    $maxAttempts = 60  # 30 minutes max (30s intervals)
    $transientErrors = 0
    $maxTransientErrors = 5

    Write-Host "Tracking operation progress (polling every 30s)..."
    Write-Host

    while ($state -notin @("Succeeded", "Failed", "Canceled") -and $attempt -lt $maxAttempts)
    {
        Start-Sleep -Seconds 30
        $attempt++

        try {
            $url = "${ArmBaseUrl}${statusPath}?api-version=${ArmApiVersion}"
            $output = Invoke-AzCli -Arguments @("rest", "--method", "GET", "--url", $url, "-o", "json")
            $status = $output | ConvertFrom-Json
            $state = $status.properties.provisioningState
            $details = $status.properties.statusDetails
            $transientErrors = 0

            $line = "  Poll ${attempt}: state=${state}"
            if ($details) { $line += " details=$details" }
            Write-Host $line
        } catch {
            $transientErrors++
            Write-Host "  Poll ${attempt}: transient error ($transientErrors/$maxTransientErrors) - $($_.Exception.Message)"
            if ($transientErrors -ge $maxTransientErrors) {
                Write-Host "Too many consecutive polling errors. Use -Action Status to check manually." -ForegroundColor Red
                return
            }
        }
    }

    Write-Host
    switch ($state)
    {
        "Succeeded" { Write-Host "Operation completed successfully." -ForegroundColor Green }
        "Failed"    { Write-Host "Operation failed." -ForegroundColor Red }
        "Canceled"  { Write-Host "Operation was canceled." }
        default     { Write-Host "Timed out waiting for operation to complete (last state: $state)." -ForegroundColor Red }
    }
}

$migrationPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Cache/RedisEnterprise/$AmrCacheName/migrations/default"

switch ($Action)
{
    "Migrate"
    {
        if (-not $PSCmdlet.ShouldProcess("$SourceResourceId -> $TargetResourceId", "Migrate Redis cache (DNS switch enabled)")) {
            return
        }
        $payload = @{
            properties = @{
                sourceResourceId  = $SourceResourceId;
                cacheResourceType = "AzureCacheForRedis";
                forceMigrate      = $ForceMigrate;
                switchDns         = $true;
                skipDataMigration = $true;
            };
        } | ConvertTo-Json -Depth 3

        if ($TrackMigration.IsPresent)
        {
            Write-Host "This command will trigger the migration and will track the long running operation until its completion."
        }
        else
        {
            Write-Host "This command will trigger the migration and will exit immediately. It will not track the long running migration operation until its completion. Please use the 'Status' action to check and track the migration completion status"
        }

        Invoke-ArmRest -Method PUT -Path $migrationPath -Body $payload | Out-Null

        if ($TrackMigration.IsPresent)
        {
            Wait-ForMigration
        }

        break
    }

    "Status"
    {
        Invoke-ArmRest -Method GET -Path $migrationPath | Out-Null

        break
    }

    "Cancel"
    {
        if (-not $PSCmdlet.ShouldProcess("$TargetResourceId", "Cancel Redis migration")) {
            return
        }

        if ($TrackMigration.IsPresent)
        {
            Write-Host "This command will trigger the cancellation and will track the long running operation until its completion."
        }
        else
        {
            Write-Host "This command will trigger the cancellation and will exit immediately. It will not track the long running operation until its completion. Use the 'Status' action to check and track migration cancellation status."
        }

        Invoke-ArmRest -Method POST -Path "${migrationPath}/cancel" | Out-Null

        if ($TrackMigration.IsPresent)
        {
            Wait-ForMigration
        }

        break
    }

    "Validate"
    {
        $payload = @{
            properties = @{
                sourceResourceId  = $SourceResourceId;
                skipDataMigration = $true;
            };
        } | ConvertTo-Json -Depth 3

        Write-Host "This command will validate whether a migration can be performed between the source and target caches."
        Invoke-ArmRest -Method POST -Path "${migrationPath}/validate" -Body $payload | Out-Null

        break
    }

    Default
    {
        throw "Invalid action specified. Please use one of the following: 'Migrate', 'Validate', 'Status', 'Cancel'."
    }
}