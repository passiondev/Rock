<#
    Invoke-StagingAnonymization destroys contact data, and what keeps it pointed at
    the right catalog is the order it does things in: refuse the production
    address, connect, confirm the catalog by name, check every SET clause against
    the catalog's computed columns, and only then -- and only with -Apply -- write.
    Every gate is there to stop the step after it, so a gate that runs one step
    late is no gate.

    That order used to be held by the Python suite comparing character offsets:
    the refusal's line appears above the connection's line, the catalog check's
    above the first UPDATE's. That says how the source is laid out. It cannot say
    what runs first, and a refactor that moves a check into a function called
    from the wrong place keeps every offset and loses the property.

    The run now takes its SQL through an adapter, so these hand it one that
    records every call and answers the way a staging catalog would: the catalog
    name it was asked for, a computed column on PhoneNumber the way
    CreateDatabase declares one, and a few rows pending in every target. Each
    test then reads the recorded sequence. Nothing here connects to anything.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScriptFunctions.psm1') -Force

    $script:AnonymizerScript = Get-RepositoryPath 'Deployment/Database/Invoke-StagingAnonymization.ps1'
    . (Import-ScriptFunction -Path $script:AnonymizerScript -Name @(
            'Invoke-StagingAnonymization',
            'Get-DataSourceHost',
            'ConvertTo-KeepDomain',
            'Get-AnonymizationTarget',
            'Get-DomainExclusion',
            'Get-PersonDomainExclusion',
            'Get-ResidualPiiProbe',
            'Get-PhoneShapedPredicate',
            'Get-ComputedColumnAssignment',
            'Get-RowCount'
        ))

    function script:New-RecordingSqlAdapter {
        <#
            .SYNOPSIS
                A SQL adapter that answers like a staging catalog and keeps a list
                of every call made through it, in order.

            .DESCRIPTION
                Each operation appends { Kind; Query } to Calls before it answers,
                so a call that throws is still on the record.

                Counts and writes share one ledger, keyed by table and predicate.
                A COUNT reads the rows still pending for that key; an UPDATE TOP (n)
                takes up to n of them away and says how many it took. That is what
                lets the batching loop in the run terminate here the way it does
                against SQL Server: each pass shrinks its own predicate until a
                pass affects nothing.

                Anything the adapter does not recognise is a throw rather than a
                default. A new statement in the run should arrive here as a
                failing test, not as a zero nobody asked for.

                Closures, so each test states its own catalog. They can reach
                only what they captured, which is why every helper they need is a
                cmdlet or a .NET method.

            .PARAMETER Catalog
                What DB_NAME() answers.

            .PARAMETER ComputedColumnByTable
                Table -> computed column names, as sys.computed_columns would list
                them. The default is the one staging really has, and the run's
                SetClauses leave it alone, so the guard sees a computed column and
                must still pass.

            .PARAMETER PendingRows
                Rows still holding real data in every target and probe, until an
                UPDATE says otherwise.
        #>
        param(
            [string]$Catalog = 'RockStaging20260824',
            [hashtable]$ComputedColumnByTable = @{ 'dbo.PhoneNumber' = @('NumberReversed') },
            [int]$PendingRows = 3
        )

        # ::new() rather than New-Object, which hands the list back wrapped in a
        # PSObject. @() over that wrapper throws "Argument types do not match"
        # from pwsh 7.4's array binder once the list is a few dozen calls long.
        $calls = [System.Collections.Generic.List[object]]::new()
        $remaining = @{}
        # A hashtable rather than a bare counter so the closures share one: what a
        # closure captures is the value, and only a reference survives that.
        $statements = @{ Written = 0 }
        $census = @(
            [pscustomobject][ordered]@{ Domain = 'staging.invalid'; People = 5 },
            [pscustomobject][ordered]@{ Domain = 'staff.example'; People = 2 }
        )

        $open = {
            param($ConnectionString)

            $calls.Add([pscustomobject]@{ Kind = 'Open'; Query = '' })
            return [pscustomobject]@{ IsRecordingConnection = $true }
        }.GetNewClosure()

        $close = {
            param($Connection)

            $calls.Add([pscustomobject]@{ Kind = 'Close'; Query = '' })
        }.GetNewClosure()

        $scalar = {
            param($Connection, $Query, $TimeoutSeconds)

            $calls.Add([pscustomobject]@{ Kind = 'Scalar'; Query = $Query })
            if ($Query -match 'DB_NAME\(\)') {
                return $Catalog
            }
            if ($Query -match '(?s)^SELECT COUNT\(\*\) FROM (\S+) WHERE (.+)$') {
                $key = "$($Matches[1]) WHERE $($Matches[2])"
                if ($remaining.ContainsKey($key)) {
                    return $remaining[$key]
                }
                return $PendingRows
            }
            throw "The recording adapter has no answer for this Scalar: $Query"
        }.GetNewClosure()

        $nonQuery = {
            param($Connection, $Query, $TimeoutSeconds)

            $calls.Add([pscustomobject]@{ Kind = 'NonQuery'; Query = $Query })

            # A loop that never sees its predicate shrink would spin here forever
            # rather than fail. Far more writes than any test asks for.
            $statements.Written = $statements.Written + 1
            if ($statements.Written -gt 500) {
                throw 'The recording adapter stopped a runaway write loop after 500 statements.'
            }

            if ($Query -match '(?s)^UPDATE TOP \((\d+)\) (\S+)\r?\nSET .*\r?\nWHERE (.*);\s*$') {
                $batch = [int]$Matches[1]
                $key = "$($Matches[2]) WHERE $($Matches[3])"
                $left = $PendingRows
                if ($remaining.ContainsKey($key)) {
                    $left = $remaining[$key]
                }
                $affected = [Math]::Min($batch, $left)
                $remaining[$key] = $left - $affected
                return $affected
            }
            throw "The recording adapter has no answer for this NonQuery: $Query"
        }.GetNewClosure()

        $rowsOperation = {
            param($Connection, $Query, $TimeoutSeconds)

            $calls.Add([pscustomobject]@{ Kind = 'Rows'; Query = $Query })
            if ($Query -match 'sys\.computed_columns') {
                $table = ''
                if ($Query -match "OBJECT_ID\('([^']+)'\)") {
                    $table = $Matches[1]
                }
                $names = @()
                if ($ComputedColumnByTable.ContainsKey($table)) {
                    $names = @($ComputedColumnByTable[$table])
                }
                $columns = @($names | ForEach-Object { [pscustomobject][ordered]@{ ColumnName = $_ } })
                return ,$columns
            }
            if ($Query -match 'GROUP BY') {
                return ,$census
            }
            throw "The recording adapter has no answer for this Rows: $Query"
        }.GetNewClosure()

        return @{
            Open     = $open
            Close    = $close
            Scalar   = $scalar
            NonQuery = $nonQuery
            Rows     = $rowsOperation
            Calls    = $calls
        }
    }

    function script:Invoke-Anonymizer {
        <#
            .SYNOPSIS
                Runs Invoke-StagingAnonymization against a staging address and
                catalog unless the test says otherwise, under the strict mode the
                script sets for itself.

            .DESCRIPTION
                Import-ScriptFunction lifts the function without the script's
                preamble, so the mode is restated here. Without it, a read the
                script would stop on runs on quietly under test.
        #>
        param(
            [Parameter(Mandatory = $true)][hashtable]$Sql,
            [hashtable]$Parameter = @{}
        )

        $arguments = @{
            Sql              = $Sql
            ConnectionString = 'Data Source=172.20.0.2;Initial Catalog=RockStaging20260824;Integrated Security=true'
            ExpectedCatalog  = 'RockStaging20260824'
        }
        foreach ($name in $Parameter.Keys) {
            $arguments[$name] = $Parameter[$name]
        }

        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        return Invoke-StagingAnonymization @arguments
    }

    function script:Get-CallKind {
        # The recorded sequence reduced to which operation ran, for the tests where
        # the order of operations is the whole claim.
        param([Parameter(Mandatory = $true)]$Sql)

        return (@($Sql.Calls | ForEach-Object { $_.Kind }) -join ' -> ')
    }

    function script:Get-WriteCall {
        param([Parameter(Mandatory = $true)]$Sql)

        return ,@($Sql.Calls | Where-Object { $_.Kind -eq 'NonQuery' })
    }
}

Describe 'Invoke-StagingAnonymization' {

    BeforeEach {
        # What the operator reads, kept so a dry run can be held to reporting what
        # it found. The run writes nothing else to the host.
        $script:HostLines = New-Object 'System.Collections.Generic.List[string]'
        Mock Write-Host { $script:HostLines.Add("$Object") }
    }

    It 'refuses <DataSource> as production before it opens a connection' -ForEach @(
        @{ DataSource = '172.20.0.8' }
        @{ DataSource = 'tcp:172.20.0.8,1433' }
        @{ DataSource = '172.20.0.8\SQLEXPRESS' }
    ) {
        # The sandbox hosts a catalog named RockConnectProd too, so the catalog
        # check would pass on either server. This adapter answers RockConnectProd
        # and the operator asks for it, so only the address can stop the run --
        # and it has to before anything reaches across to that server.
        $sql = New-RecordingSqlAdapter -Catalog 'RockConnectProd'
        $parameter = @{
            ConnectionString = "Data Source=$DataSource;Initial Catalog=RockConnectProd;Integrated Security=true"
            ExpectedCatalog  = 'RockConnectProd'
            Apply            = $true
        }

        { Invoke-Anonymizer -Sql $sql -Parameter $parameter } | Should -Throw '*production instance*'

        $sql.Calls.Count | Should -Be 0 -Because 'the refusal has to come before the connection, not after it'
    }

    It 'refuses a keep domain that could close a SQL literal, before it opens a connection' {
        # The allowlist is spliced into LIKE patterns. A domain that would be
        # refused should never reach a server, not even to be counted.
        $sql = New-RecordingSqlAdapter

        { Invoke-Anonymizer -Sql $sql -Parameter @{ KeepEmailDomains = @("evil.com' OR '1'='1"); Apply = $true } } |
            Should -Throw 'Not a domain*'

        $sql.Calls.Count | Should -Be 0
    }

    It 'stops at a catalog other than the one named, having asked nothing else (<Mode>)' -ForEach @(
        @{ Mode = 'apply'; Apply = $true }
        @{ Mode = 'dry run'; Apply = $false }
    ) {
        $sql = New-RecordingSqlAdapter -Catalog 'RockConnectProd'

        { Invoke-Anonymizer -Sql $sql -Parameter @{ Apply = $Apply } } |
            Should -Throw "*-ExpectedCatalog said 'RockStaging20260824'*"

        # Connect, ask which catalog this is, let go. Not a count, not a check,
        # and not a write against a catalog nobody named.
        Get-CallKind -Sql $sql | Should -Be 'Open -> Scalar -> Close'
    }

    It 'stops at a SetClause that writes a computed column, before the first write (<Mode>)' -ForEach @(
        @{ Mode = 'apply'; Apply = $true }
        @{ Mode = 'dry run'; Apply = $false }
    ) {
        # On 2026-08-24 this fault surfaced between two targets, with Person.Email
        # already rewritten. Refused here, nothing has been. It refuses a dry run
        # too, because a plan that reports clean for a statement SQL Server will
        # reject is the failure.
        $sql = New-RecordingSqlAdapter -ComputedColumnByTable @{ 'dbo.Person' = @('Email') }

        { Invoke-Anonymizer -Sql $sql -Parameter @{ Apply = $Apply } } |
            Should -Throw '*computed columns*dbo.Person.Email*'

        $writeCalls = Get-WriteCall -Sql $sql
        $writeCalls.Count | Should -Be 0
        $sql.Calls[$sql.Calls.Count - 1].Kind | Should -Be 'Close' -Because 'a refused run still lets go of its connection'
    }

    It 'issues no write on a dry run, and counts every target the apply would write' {
        $sql = New-RecordingSqlAdapter

        $summary = Invoke-Anonymizer -Sql $sql

        $writeCalls = Get-WriteCall -Sql $sql
        $writeCalls.Count | Should -Be 0
        $summary.mode | Should -Be 'dry-run'
        $summary.catalog | Should -Be 'RockStaging20260824'

        $targets = Get-AnonymizationTarget
        $expectedNames = @($targets | ForEach-Object { $_.Name })
        $expectedNames.Count | Should -BeGreaterThan 0 -Because 'an empty target list would make the comparison below prove nothing'

        $reportedNames = @($summary.targets | ForEach-Object { $_.name })
        ($reportedNames -join ' | ') | Should -Be ($expectedNames -join ' | ')
        foreach ($target in $summary.targets) {
            $target.pending | Should -Be 3 -Because "the adapter holds three rows for $($target.name)"
            $target.updated | Should -Be 0
        }
    }

    It 'reports on a dry run what an apply would change and what it would leave' {
        $sql = New-RecordingSqlAdapter

        $summary = Invoke-Anonymizer -Sql $sql

        $probes = Get-ResidualPiiProbe
        $probes.Count | Should -BeGreaterThan 0
        @($summary.residualPii).Count | Should -Be $probes.Count
        foreach ($probe in $summary.residualPii) {
            $probe.rows | Should -Be 3 -Because "the adapter holds three rows for $($probe.name)"
        }

        (@($summary.emailDomains | ForEach-Object { "$($_.domain)=$($_.people)" }) -join ', ') |
            Should -Be 'staging.invalid=5, staff.example=2'

        # One line per target, and a total the approver can check against them.
        $targetCount = @($summary.targets).Count
        $perTarget = @($script:HostLines | Where-Object { $_ -like '*row(s) would change' })
        $perTarget.Count | Should -Be $targetCount

        $total = @($script:HostLines | Where-Object { $_ -like "Dry run. $(3 * $targetCount) row(s) would be rewritten*" })
        $total.Count | Should -Be 1
    }

    It 'writes only after the catalog and every computed-column check have passed' {
        # Batches of two against three pending rows, so each target takes more
        # than one UPDATE and the loop has to see its predicate shrink to stop.
        $sql = New-RecordingSqlAdapter

        $summary = Invoke-Anonymizer -Sql $sql -Parameter @{ Apply = $true; BatchSize = 2 }

        $calls = @($sql.Calls)
        $checks = @(for ($index = 0; $index -lt $calls.Count; $index++) {
                $isCatalogCheck = $calls[$index].Kind -eq 'Scalar' -and $calls[$index].Query -match 'DB_NAME\(\)'
                $isComputedCheck = $calls[$index].Kind -eq 'Rows' -and $calls[$index].Query -match 'sys\.computed_columns'
                if ($isCatalogCheck -or $isComputedCheck) {
                    $index
                }
            })
        $writes = @(for ($index = 0; $index -lt $calls.Count; $index++) {
                if ($calls[$index].Kind -eq 'NonQuery') {
                    $index
                }
            })

        $checks.Count | Should -BeGreaterThan 0
        $writes.Count | Should -BeGreaterThan 0 -Because 'an apply against pending rows has to write something'
        $writes[0] | Should -BeGreaterThan $checks[$checks.Count - 1] -Because 'every check has to finish before the first UPDATE'

        # The guard has to have asked about every table the run then wrote.
        $checkedTables = @($calls | Where-Object { $_.Kind -eq 'Rows' -and $_.Query -match "OBJECT_ID\('([^']+)'\)" } |
                ForEach-Object { $null = $_.Query -match "OBJECT_ID\('([^']+)'\)"; $Matches[1] })
        $writtenTables = @($calls | Where-Object { $_.Kind -eq 'NonQuery' } |
                ForEach-Object { $null = $_.Query -match '^UPDATE TOP \(\d+\) (\S+)'; $Matches[1] })
        foreach ($table in $writtenTables) {
            $checkedTables | Should -Contain $table
        }

        $summary.mode | Should -Be 'apply'
        foreach ($target in $summary.targets) {
            $target.updated | Should -Be 3 -Because "$($target.name) had three rows, taken two then one"
        }
    }

    It 'rewrites the rows it counted, with the allowlist in both' {
        # The number the approver read and the number of rows destroyed are the
        # same number only if the count and the UPDATE carry the same predicate.
        # The domain arrives the way an operator might type it.
        $sql = New-RecordingSqlAdapter

        $null = Invoke-Anonymizer -Sql $sql -Parameter @{ Apply = $true; KeepEmailDomains = @('@Staff.Example') }

        $counted = New-Object 'System.Collections.Generic.HashSet[string]'
        $writeCount = 0
        foreach ($call in $sql.Calls) {
            if ($call.Kind -eq 'Scalar' -and $call.Query -match '(?s)^SELECT COUNT\(\*\) FROM (\S+) WHERE (.+)$') {
                [void]$counted.Add("$($Matches[1]) WHERE $($Matches[2])")
                continue
            }
            if ($call.Kind -eq 'NonQuery' -and $call.Query -match '(?s)^UPDATE TOP \(\d+\) (\S+)\r?\nSET .*\r?\nWHERE (.*);\s*$') {
                $writeCount++
                $written = "$($Matches[1]) WHERE $($Matches[2])"
                $counted.Contains($written) | Should -BeTrue -Because "this UPDATE was never counted first: $written"
            }
        }
        $writeCount | Should -BeGreaterThan 0

        $personWrites = @($sql.Calls | Where-Object { $_.Kind -eq 'NonQuery' -and $_.Query -match '^UPDATE TOP \(\d+\) dbo\.Person\r?\n' })
        $personWrites.Count | Should -BeGreaterThan 0
        $personWrites[0].Query | Should -BeLike "*Email NOT LIKE '%@staff.example'*"
    }
}
