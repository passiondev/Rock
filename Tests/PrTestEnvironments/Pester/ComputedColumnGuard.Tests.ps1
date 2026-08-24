<#
    Get-ComputedColumnAssignment is the pre-flight that stops the anonymizer
    writing a computed column. It exists because SQL Server rejects such an UPDATE
    when it binds the statement, and the dry run only ever issues COUNT(*) against
    the predicate, so the dry run binds no SetClause and reports a clean plan. The
    failure then lands halfway through the apply with earlier targets committed.

    The Python suite asserts against the text of the script. That can establish
    that the guard is written and wired in ahead of the write loop. It cannot
    establish that the guard runs, and on 2026-08-24 it did not: the function read
    its rows with $row['ColumnName'], Invoke-Rows returns [pscustomobject], and a
    PSObject has no indexer. The guard threw the moment it reached the first table
    that actually had a computed column, which is the only case it exists for.

    So these exercise the function, against rows shaped exactly the way Invoke-Rows
    shapes them.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AnonymizerScript = Get-RepositoryPath 'Deployment/Database/Invoke-StagingAnonymization.ps1'
    . (Import-ScriptFunction -Path $script:AnonymizerScript -Name 'Get-ComputedColumnAssignment', 'Invoke-Rows')
    # Invoke-Rows is imported so Pester has something to mock, and so the import
    # fails loudly if the guard's collaborator is ever renamed out from under it.

    # Never opened. The parameter is typed, so the call needs one to exist.
    $script:Connection = New-Object System.Data.SqlClient.SqlConnection

    # Matches Invoke-Rows: a [pscustomobject] per row, one property per column.
    function script:New-ColumnRow {
        param([string[]]$Name)
        return ,@($Name | ForEach-Object { [pscustomobject][ordered]@{ ColumnName = $_ } })
    }
}

Describe 'Get-ComputedColumnAssignment' {
    It 'names a computed column the SetClause assigns' {
        Mock -CommandName Invoke-Rows -MockWith { New-ColumnRow -Name 'NumberReversed' }

        $offenders = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.PhoneNumber' -SetClause "Number = '5550000001',`n            NumberReversed = '1000000555'"

        $offenders | Should -Contain 'NumberReversed'
    }

    It 'reads a row without indexing into it, under the strict mode the script runs in' {
        # The regression, and the reason it needs its own strict mode. A PSObject
        # has no indexer. Left lax, $row['ColumnName'] quietly yields empty and the
        # guard reports no offenders -- so it approves every SetClause, which is
        # worse than throwing. Under Set-StrictMode -Version Latest, which the
        # script sets before it does anything, the same expression is a terminating
        # error, and that is what actually happened on the VM.
        #
        # Import-ScriptFunction lifts the function out without the script's
        # preamble, so this scope has to restate the mode or it tests semantics
        # production never runs under.
        Mock -CommandName Invoke-Rows -MockWith { New-ColumnRow -Name 'NumberReversed' }

        Set-StrictMode -Version Latest
        try {
            { Get-ComputedColumnAssignment -Connection $script:Connection `
                -Table 'dbo.PhoneNumber' -SetClause "Number = '5550000001'" } | Should -Not -Throw
        }
        finally {
            Set-StrictMode -Off
        }
    }

    It 'ignores a computed column that only appears on the right-hand side' {
        # FullNumber is built from CountryCode. Reading a column is fine; the guard
        # must only object to assigning one, or it blocks a correct SetClause.
        Mock -CommandName Invoke-Rows -MockWith { New-ColumnRow -Name 'CountryCode' }

        $offenders = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.PhoneNumber' -SetClause "FullNumber = ISNULL(CountryCode, '') + '5550000001'"

        $offenders | Should -BeNullOrEmpty
    }

    It 'passes a table that has no computed columns at all' {
        Mock -CommandName Invoke-Rows -MockWith { ,@() }

        $offenders = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.Person' -SetClause "Email = 'person' + CAST(Id AS varchar(10)) + '@example.invalid'"

        $offenders | Should -BeNullOrEmpty
    }

    It 'returns a collection even when a single column offends' {
        # The caller does $faults += $offenders and then counts. A bare string
        # would still count as one, but a caller that indexed it would walk
        # characters. Same unrolling trap Invoke-Rows guards with its leading comma.
        Mock -CommandName Invoke-Rows -MockWith { New-ColumnRow -Name 'NumberReversed' }

        $offenders = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.PhoneNumber' -SetClause "NumberReversed = 'x'"

        ,$offenders | Should -BeOfType [System.Object[]]
    }

    It 'finds an assignment wherever it sits in the clause' {
        Mock -CommandName Invoke-Rows -MockWith { New-ColumnRow -Name 'NumberReversed' }

        $head = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.PhoneNumber' -SetClause "NumberReversed = 'x', Number = 'y'"
        $tail = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.PhoneNumber' -SetClause "Number = 'y', NumberReversed = 'x'"
        $bracketed = Get-ComputedColumnAssignment -Connection $script:Connection `
            -Table 'dbo.PhoneNumber' -SetClause "Number = 'y',`n            [NumberReversed] = 'x'"

        $head | Should -Contain 'NumberReversed'
        $tail | Should -Contain 'NumberReversed'
        $bracketed | Should -Contain 'NumberReversed'
    }
}
