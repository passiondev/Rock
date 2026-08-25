<#
    Get-PhoneShapedPredicate builds the residual-PII probes for phone numbers.

    Until 2026-08-24 every residual probe in the anonymizer was email-shaped
    except the address one, so the phone columns the run rewrites had no residual
    reporting at all. The report could show PhoneNumber swept clean while the same
    number sat in the note attached to the person.

    These exercise the builder rather than asserting against the text of the
    script, for the reason ComputedColumnGuard.Tests.ps1 exists: a text assertion
    establishes that a pattern is written down, not that it matches a phone
    number. The shapes are checked by running them.

    PowerShell's -like and T-SQL's LIKE agree on everything these patterns use:
    [0-9] is a range in both, and '.', '(' and ')' are literals in both. Only the
    any-length wildcard differs, % against *, so the translation below is one
    replace and the match it performs is the match SQL Server will perform.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AnonymizerScript = Get-RepositoryPath 'Deployment/Database/Invoke-StagingAnonymization.ps1'
    . (Import-ScriptFunction -Path $script:AnonymizerScript -Name 'Get-PhoneShapedPredicate')

    # Pull the individual LIKE literals back out of the assembled predicate so the
    # shapes are tested as the function actually emits them. Rewriting them by
    # hand here would test a copy that can drift from the original in silence.
    function script:Get-LikePattern {
        param([string]$Predicate)
        return @([regex]::Matches($Predicate, "LIKE '([^']*)'") | ForEach-Object { $_.Groups[1].Value })
    }

    function script:Test-AnyPattern {
        param([string[]]$Pattern, [string]$Value)
        foreach ($candidate in $Pattern) {
            if ($Value -like $candidate.Replace('%', '*')) { return $true }
        }
        return $false
    }
}

Describe 'Get-PhoneShapedPredicate' {

    Context 'the shapes people actually type' {
        BeforeAll {
            $script:Patterns = Get-LikePattern -Predicate (Get-PhoneShapedPredicate -Column 'Text')
        }

        It 'emits one LIKE per shape' {
            $script:Patterns.Count | Should -Be 3
        }

        It 'matches <Shape> embedded in prose' -ForEach @(
            @{ Shape = 'hyphenated';   Value = 'call her on 404-555-1234 before noon' }
            @{ Shape = 'parenthesized'; Value = 'mobile (404) 555-1234, home is different' }
            @{ Shape = 'dotted';       Value = 'left a message at 404.555.1234' }
        ) {
            Test-AnyPattern -Pattern $script:Patterns -Value $Value | Should -BeTrue
        }

        It 'matches a number that is the whole value, with nothing around it' {
            Test-AnyPattern -Pattern $script:Patterns -Value '404-555-1234' | Should -BeTrue
        }

        It 'does not fire on a row with no phone number in it' {
            Test-AnyPattern -Pattern $script:Patterns -Value 'no contact details here at all' | Should -BeFalse
        }
    }

    Context 'the tightness the probe trades accuracy for' {
        BeforeAll {
            $script:Patterns = Get-LikePattern -Predicate (Get-PhoneShapedPredicate -Column 'Value')
        }

        # These document the floor rather than a defect. A pattern loose enough to
        # catch them fires on most of the catalog, and a probe that reports every
        # row tells you nothing about whether phone PII survived.
        It 'misses an unseparated ten-digit number, which is the accepted cost' {
            Test-AnyPattern -Pattern $script:Patterns -Value 'reached them at 4045551234' | Should -BeFalse
        }

        It 'does not fire on a giving amount in cents' {
            Test-AnyPattern -Pattern $script:Patterns -Value 'amount 4045551234 cents' | Should -BeFalse
        }

        It 'does not fire on an ISO timestamp' {
            Test-AnyPattern -Pattern $script:Patterns -Value '2026-08-24T21:09:39.8981165Z' | Should -BeFalse
        }
    }

    Context 'the predicate it assembles' {
        It 'wraps the whole thing so it can be AND-ed into a WHERE clause safely' {
            $predicate = Get-PhoneShapedPredicate -Column 'Text'
            $predicate | Should -Match '^\('
            $predicate | Should -Match '\)$'
        }

        It 'covers every column in one predicate, so each table is scanned once' {
            $predicate = Get-PhoneShapedPredicate -Column 'OldValue', 'NewValue'

            # Three shapes per column, OR-ed: one scan, not one per shape.
            (Get-LikePattern -Predicate $predicate).Count | Should -Be 6
            $predicate | Should -Match 'OldValue LIKE'
            $predicate | Should -Match 'NewValue LIKE'
            $predicate | Should -Not -Match ' AND '
        }

        It 'reads, and never writes' {
            $predicate = Get-PhoneShapedPredicate -Column 'Text'
            $predicate | Should -Not -Match 'UPDATE|DELETE|INSERT'
        }
    }

    Context 'under the strict mode the script sets' {
        It 'builds a predicate without tripping Set-StrictMode -Version Latest' {
            Set-StrictMode -Version Latest
            try {
                { Get-PhoneShapedPredicate -Column 'Text' } | Should -Not -Throw
            }
            finally {
                Set-StrictMode -Off
            }
        }
    }
}
