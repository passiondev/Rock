<#
    .github/scripts/Test-ThemeCustomizationInput.ps1 is the ten-second failure that
    stands in front of a five-minute one.

    db-set-theme-customization.yml interpolates three dispatch inputs into a JSON
    document and drops it in a GCS queue. A quote or a backslash in any of them
    produces JSON the agent on the far side cannot parse, and the workflow learns
    about it by polling for a result that never arrives -- a timeout, with nothing in
    it that names the character responsible.

    That makes the validator the only place the mistake is legible, which makes an
    untested validator worth very little.

    The decision is lifted out with Import-ScriptFunction and called directly, the
    way every other suite here reaches into a script. Asserting on the source text
    instead -- "the file contains a backslash pattern" -- would pass just as happily
    if the pattern were never reached.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:ValidatorPath = Get-RepositoryPath '.github/scripts/Test-ThemeCustomizationInput.ps1'

    . (Import-ScriptFunction -Path $script:ValidatorPath -Name 'Test-ThemeCustomizationInputShape')

    function Test-Inputs {
        param(
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThemeName,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$VariableValues,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DbName
        )
        return Test-ThemeCustomizationInputShape -ThemeName $ThemeName -VariableValues $VariableValues -DbName $DbName
    }
}

Describe 'Test-ThemeCustomizationInputShape' {
    Context 'the inputs an operator is expected to type' {
        It 'accepts the values the dispatch form defaults to' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues 'base-primary=#00B8E4' -DbName 'RockStaging20260824'
            $verdict.Problem | Should -BeNullOrEmpty
            $verdict.VariableNames | Should -Be @('base-primary')
        }

        It 'accepts several assignments and tolerates spaces around the commas' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues 'base-primary=#00B8E4, link=#599AC2' -DbName 'RockStaging'
            $verdict.Problem | Should -BeNullOrEmpty
            $verdict.VariableNames | Should -Be @('base-primary', 'link')
        }

        It 'accepts an empty value, which is how one variable is cleared' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues 'base-primary=' -DbName 'RockStaging'
            $verdict.Problem | Should -BeNullOrEmpty
        }

        # A colour is one '=' and a hex string, but the parameter is general and a
        # value containing '=' is a shape the far side splits on the first one only.
        It 'accepts a value that itself contains an equals sign' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues 'font-stack=a=b' -DbName 'RockStaging'
            $verdict.Problem | Should -BeNullOrEmpty
            $verdict.VariableNames | Should -Be @('font-stack')
        }
    }

    Context 'characters that would break the queued JSON document' {
        # Each of the three is interpolated into the payload, so each is checked.
        It 'refuses a double quote in <Field>' -ForEach @(
            @{ Field = 'theme_name'; Theme = 'Rock"NextGen'; Variables = 'base-primary=#00B8E4'; Db = 'RockStaging' }
            @{ Field = 'variable_values'; Theme = 'RockNextGen'; Variables = 'base-primary="#00B8E4"'; Db = 'RockStaging' }
            @{ Field = 'db_name'; Theme = 'RockNextGen'; Variables = 'base-primary=#00B8E4'; Db = 'Rock"Staging' }
        ) {
            $verdict = Test-Inputs -ThemeName $Theme -VariableValues $Variables -DbName $Db
            $verdict.Problem | Should -Match ([regex]::Escape($Field))
        }

        It 'refuses a backslash in <Field>' -ForEach @(
            @{ Field = 'theme_name'; Theme = 'Rock\NextGen'; Variables = 'base-primary=#00B8E4'; Db = 'RockStaging' }
            @{ Field = 'variable_values'; Theme = 'RockNextGen'; Variables = 'base-primary=\00B8E4'; Db = 'RockStaging' }
            @{ Field = 'db_name'; Theme = 'RockNextGen'; Variables = 'base-primary=#00B8E4'; Db = 'Rock\Staging' }
        ) {
            $verdict = Test-Inputs -ThemeName $Theme -VariableValues $Variables -DbName $Db
            $verdict.Problem | Should -Match ([regex]::Escape($Field))
        }
    }

    Context 'a run that would report success having done nothing' {
        It 'refuses an empty variable list' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues '' -DbName 'RockStaging'
            $verdict.Problem | Should -Match 'would change nothing'
        }

        It 'refuses a list of nothing but commas' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues ',,' -DbName 'RockStaging'
            $verdict.Problem | Should -Match 'would change nothing'
        }
    }

    Context 'malformed assignments' {
        It 'refuses a bare name with no equals sign' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues 'base-primary' -DbName 'RockStaging'
            $verdict.Problem | Should -Match 'name=value'
        }

        It 'refuses an assignment with an empty name' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues '=#00B8E4' -DbName 'RockStaging'
            $verdict.Problem | Should -Match 'name=value'
        }

        It 'refuses the same variable named twice' {
            $verdict = Test-Inputs -ThemeName 'RockNextGen' -VariableValues 'base-primary=#00B8E4,base-primary=#FF0000' -DbName 'RockStaging'
            $verdict.Problem | Should -Match 'twice'
        }
    }

    Context 'the required inputs' {
        It 'refuses an empty <Field>' -ForEach @(
            @{ Field = 'theme_name'; Theme = ''; Db = 'RockStaging' }
            @{ Field = 'db_name'; Theme = 'RockNextGen'; Db = '' }
        ) {
            $verdict = Test-Inputs -ThemeName $Theme -VariableValues 'base-primary=#00B8E4' -DbName $Db
            $verdict.Problem | Should -Match ([regex]::Escape($Field))
        }
    }
}

Describe 'the validator script around it' {
    # The function decides; the body is what turns a decision into something the
    # workflow run displays. Both halves have to hold or the check is invisible.
    It 'reports a problem as a workflow error annotation' {
        $source = Get-Content -Path $script:ValidatorPath -Raw
        $source | Should -Match '::error::'
    }

    It 'exits non-zero when the function finds a problem' {
        $source = Get-Content -Path $script:ValidatorPath -Raw
        $source | Should -Match 'exit 1'
    }
}
