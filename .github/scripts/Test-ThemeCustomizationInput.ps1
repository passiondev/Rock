<#
.SYNOPSIS
    Validates the dispatch inputs of db-set-theme-customization.yml before they are
    concatenated into a queued JSON command.

.DESCRIPTION
    Beside the workflow rather than inline in it, so the Pester suite can run it --
    see Tests/PrTestEnvironments/Pester/ThemeCustomizationInput.Tests.ps1. Both jobs
    of that workflow call it, which is the other half of the reason: the plan job and
    the apply job run on separate runners with no state between them, and a check
    written twice is a check that drifts.

    The judgement lives in Test-ThemeCustomizationInputShape and the script body only
    reports what it decided. That split is the same one ScriptFunctions.psm1 exists to
    serve: a function can be lifted out and called with arguments, while a script that
    ends in `exit 1` can only be tested by spawning a process and reading a number.

    Two things are being defended.

    The first is the queued document itself. queue-vm-command builds the command by
    interpolating these values into a JSON string, so a quote or a backslash in any
    of them produces JSON the agent on the far side cannot parse. The failure lands
    minutes later as a poll timeout with no useful message, which is a bad way to
    learn about a typo.

    The second is the shape of the variable list. Set-RockThemeCustomization.ps1
    rejects anything that is not name=value, and it does so before it opens a
    connection, so nothing unsafe reaches a query either way. This copy exists to
    turn a five-minute round trip into a ten-second failure that names the character
    responsible.

.PARAMETER ThemeName
    The theme_name input.

.PARAMETER VariableValues
    The variable_values input: comma-separated name=value pairs.

.PARAMETER DbName
    The db_name input.

.OUTPUTS
    Nothing on success. Writes one ::error:: annotation and exits 1 on the first
    problem, so the annotation lands on the workflow run rather than only in the log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]
    $ThemeName,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]
    $VariableValues,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]
    $DbName
)

$ErrorActionPreference = "Stop"

function Test-ThemeCustomizationInputShape {
    <#
        .SYNOPSIS
        Decides whether a set of dispatch inputs is safe to queue.

        .DESCRIPTION
        Returns an object with two properties:

            Problem       the first thing found wrong, or $null if nothing is
            VariableNames the variable names parsed out, in the order given

        One problem rather than all of them, on purpose. The checks are ordered from
        the ones that make later checks meaningless -- a quote breaks the document
        whatever else is true -- so the first is the one worth reading.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThemeName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$VariableValues,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DbName
    )

    function New-Verdict {
        param([AllowNull()][string]$Problem, [string[]]$VariableNames = @())
        return [pscustomobject]@{
            Problem       = $Problem
            VariableNames = $VariableNames
        }
    }

    # A quote closes the JSON string; a backslash starts an escape the agent will read
    # as something else. Checked on all three because all three are interpolated.
    $candidates = [ordered]@{
        "theme_name"      = $ThemeName
        "variable_values" = $VariableValues
        "db_name"         = $DbName
    }
    foreach ($inputName in $candidates.Keys) {
        if ($candidates[$inputName] -match '["\\]') {
            return New-Verdict -Problem "$inputName must not contain a quote or a backslash"
        }
    }

    foreach ($inputName in @("theme_name", "db_name")) {
        if ([string]::IsNullOrWhiteSpace($candidates[$inputName])) {
            return New-Verdict -Problem "$inputName is required"
        }
    }

    # An empty list is a run that would report success having changed nothing, which
    # reads as confirmation that the theme is already correct.
    if ([string]::IsNullOrWhiteSpace($VariableValues)) {
        return New-Verdict -Problem "variable_values is empty, so this run would change nothing"
    }

    # Split on commas, the same way the queue agent's arm does, then require each
    # piece to carry a non-empty name and a '='. The value may be empty: clearing one
    # variable back to the theme's default is a real thing to want.
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($pair in ($VariableValues -split ',')) {
        $candidate = $pair.Trim()
        if ($candidate -eq '') {
            continue
        }
        if ($candidate -notmatch '^[^=\s]+=') {
            return New-Verdict -Problem "variable_values must be name=value pairs separated by commas: '$pair' is not one"
        }
        $variableName = $candidate.Substring(0, $candidate.IndexOf('='))
        # The far side would take the last one silently. Two values for one variable
        # is a typo, not a preference, so it stops here where it is still readable.
        if ($names.Contains($variableName)) {
            return New-Verdict -Problem "variable_values names '$variableName' twice. Refusing to guess which value was meant."
        }
        $names.Add($variableName)
    }

    if ($names.Count -eq 0) {
        return New-Verdict -Problem "variable_values holds no assignments, so this run would change nothing"
    }

    return New-Verdict -Problem $null -VariableNames $names.ToArray()
}

$verdict = Test-ThemeCustomizationInputShape -ThemeName $ThemeName -VariableValues $VariableValues -DbName $DbName

if ($null -ne $verdict.Problem) {
    Write-Host "::error::$($verdict.Problem)"
    exit 1
}

Write-Host "Inputs look well formed: theme '$ThemeName', catalog '$DbName', $($verdict.VariableNames.Count) variable(s): $($verdict.VariableNames -join ', ')."
