<#
.SYNOPSIS
    Load one function out of a deployment script without running the script.

.DESCRIPTION
    The deployment scripts are scripts, not modules: dot-sourcing one to reach a
    function would also run its body, which deploys a website. A module would
    solve that and cannot be used here -- the bootstrap ships this directory with
    `gsutil cp Deployment/PrTestEnvironments/*.ps1`, so a .psm1 would never reach
    the VM. That constraint is recorded at the top of Invoke-PrEnvironmentCleanup.ps1
    and it is why these tests read the functions out instead.

    The extent comes from the parser rather than from brace counting, so what runs
    under Pester is the exact source text that ships, character for character.

    This file is under Tests/ and is never copied to a VM.
#>

Set-StrictMode -Version Latest

function Import-ScriptFunction {
    <#
    .SYNOPSIS
        Return a scriptblock defining the named functions from a script file.

    .DESCRIPTION
        Dot-source the result to bring the functions into the caller's scope:

            . (Import-ScriptFunction -Path $script -Name 'Get-RedactedText')

        A name that is not in the file is a terminating error rather than a
        silent omission. Skipping it would leave the tests below asserting
        against functions that no longer exist, and they would report the same
        green they always did.

    .PARAMETER Path
        The script to read. Not executed.

    .PARAMETER Name
        The functions to lift out, in any order.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Name
    )

    $resolved = (Resolve-Path -Path $Path).Path

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
    # Wrapped because Set-StrictMode makes `.Count` on a scalar or `$null` an error,
    # and both are shapes the parser hands back.
    if (@($errors).Count -gt 0) {
        throw "$resolved does not parse: $($errors[0].Message)"
    }

    $definitions = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true)

    $parts = foreach ($wanted in $Name) {
        $match = @($definitions | Where-Object { $_.Name -eq $wanted })
        if ($match.Count -eq 0) {
            $available = ($definitions | ForEach-Object { $_.Name } | Sort-Object) -join ', '
            throw "$resolved defines no function '$wanted'. It defines: $available."
        }
        if ($match.Count -gt 1) {
            throw "$resolved defines '$wanted' more than once, so it is ambiguous which one ships."
        }
        $match[0].Extent.Text
    }

    return [scriptblock]::Create($parts -join "`n`n")
}

function Get-RepositoryPath {
    <#
    .SYNOPSIS
        Resolve a path from the repository root.

    .DESCRIPTION
        Every suite in this directory reaches back out of Tests/ to the scripts it
        loads, and each one used to spell that as `../../../`. Six copies of a
        relative hop is six things to fix the day this directory moves, and five of
        them would still resolve to somewhere -- just not to the repository root.

        A path that does not exist is a terminating error. The alternative is a
        string that fails later, inside whatever tried to read it, naming a
        directory nobody recognises.

    .PARAMETER Path
        Where to go, relative to the repository root. Forward slashes are fine on
        Windows; Join-Path normalises them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    # $PSScriptRoot inside a module function is the module's own directory, so the
    # hop is written once, here, and nowhere else.
    $root = (Resolve-Path -Path (Join-Path $PSScriptRoot '../../..')).Path

    $combined = Join-Path $root $Path
    if (-not (Test-Path -Path $combined)) {
        throw "The repository has no '$Path'. Looked under $root."
    }

    return (Resolve-Path -Path $combined).Path
}

Export-ModuleMember -Function Import-ScriptFunction, Get-RepositoryPath
