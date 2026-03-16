<#
.SYNOPSIS
    Shared test helper functions for Pester tests.
.DESCRIPTION
    Provides AST-based script extraction, shared module loading, and
    fixture path helpers to eliminate boilerplate across test files.
#>

function Get-FunctionsScriptBlock {
    <#
    .SYNOPSIS
        Parses a PowerShell script via AST and returns a scriptblock containing
        only function definitions (and optionally script-level variable assignments).
    .PARAMETER Path
        Path to the .ps1 file to parse.
    .PARAMETER IncludeScriptVariables
        Also extract $script:* variable assignments (e.g. $script:EvictionPolicyMap).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$IncludeScriptVariables
    )

    $content = Get-Content $Path -Raw
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)

    $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($func in $functions) { [void]$sb.AppendLine($func.Extent.Text) }

    if ($IncludeScriptVariables) {
        $assignments = $ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left.ToString() -match '^\$script:'
        }, $false)
        foreach ($assign in $assignments) { [void]$sb.AppendLine($assign.Extent.Text) }
    }

    return [scriptblock]::Create($sb.ToString())
}

function Get-SharedHelpersBlock {
    <#
    .SYNOPSIS
        Returns a scriptblock for AmrMigrationHelpers.ps1 (full content).
    .DESCRIPTION
        AmrMigrationHelpers.ps1 has no param() block or CLI-mode exit, so
        the entire file content is safe to load as a scriptblock.
    #>
    $path = Join-Path $PSScriptRoot ".." "scripts" "AmrMigrationHelpers.ps1"
    return [scriptblock]::Create((Get-Content $path -Raw))
}

function Get-FixturePath {
    <#
    .SYNOPSIS
        Returns the path to a test fixture directory.
    .PARAMETER SubPath
        Sub-path under tests/fixtures/. Defaults to "arm".
    #>
    param(
        [string]$SubPath = "arm"
    )
    return Join-Path $PSScriptRoot "fixtures" $SubPath
}
