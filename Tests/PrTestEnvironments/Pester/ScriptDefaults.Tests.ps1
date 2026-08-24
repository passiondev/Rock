<#
    A default written down twice is a default that can drift.

    Deploy-RockEnvironment.ps1 declares $BackupRoot = "C:\RockBackups" in its
    script param block, and Resolve-DeploymentTarget declares it again. The
    script splats the value into the function on every real call, so the
    function's copy never runs -- which is exactly what makes it dangerous.
    Change the script's default to D:\RockBackups and the function still says
    C:\, nothing fails, and the two disagree in a file nobody re-reads.

    The copies stay rather than being deleted. A function that carries its own
    defaults is one that can be called on its own, and being callable on its own
    is what let DeploymentTarget.Tests.ps1 exist at all -- the site-selection
    logic was thirty lines of unreachable top-level script before it was a
    function. Keeping the defaults keeps that property. This keeps them honest.

    Only pairs where BOTH sides state a default are compared. A function that
    omits one is being stricter than the script, not drifting from it:
    Resolve-DeploymentTarget deliberately gives -Mode no default so a caller has
    to choose, while the script picks DedicatedSite for an operator who does not.
    That asymmetry is a decision and this leaves it alone.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    function Get-DefaultedParameters {
        <#
            .SYNOPSIS
            Parameter name -> default value text, for one param block.

            .DESCRIPTION
            Parameters with no default are left out, so a caller can treat a
            missing key and "no default" as the same thing.
        #>
        param($ParamBlock)

        $defaults = @{}
        if ($null -eq $ParamBlock) {
            return $defaults
        }
        foreach ($parameter in $ParamBlock.Parameters) {
            if ($null -eq $parameter.DefaultValue) {
                continue
            }
            $defaults[$parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.Extent.Text
        }
        return $defaults
    }
}

Describe 'Deployment script parameter defaults' {

    It 'states a shared default identically in the script and in the function' {
        $root = Get-RepositoryPath 'Deployment'
        $compared = @()
        $drifted = @()

        foreach ($file in Get-ChildItem -Path $root -Filter '*.ps1' -Recurse) {
            $errors = $null
            $tokens = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$errors)

            $scriptDefaults = Get-DefaultedParameters -ParamBlock $ast.ParamBlock
            if ($scriptDefaults.Count -eq 0) {
                continue
            }

            $functions = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            foreach ($function in $functions) {
                $functionDefaults = Get-DefaultedParameters -ParamBlock $function.Body.ParamBlock
                foreach ($name in $functionDefaults.Keys) {
                    if (-not $scriptDefaults.ContainsKey($name)) {
                        continue
                    }
                    $compared += "$($file.Name)/$($function.Name) -$name"
                    if ($scriptDefaults[$name] -ne $functionDefaults[$name]) {
                        $drifted += "$($file.Name), $($function.Name) -${name}: " +
                            "script says $($scriptDefaults[$name]), function says $($functionDefaults[$name])"
                    }
                }
            }
        }

        # Without this the whole check passes on an empty sweep -- a rename under
        # Deployment/, or a parse failure, and the loop finds nothing to compare.
        $compared.Count | Should -BeGreaterThan 0 -Because 'nothing was compared, so this proved nothing'
        $drifted | Should -BeNullOrEmpty -Because "a default is stated in two places and they disagree:`n  $($drifted -join "`n  ")"
    }
}
