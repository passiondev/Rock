<#
.SYNOPSIS
    Repairs the five Tabler icon classes that Rock's own Font Awesome conversion
    wrote wrong. Dry run by default; writes only with -Apply.

.DESCRIPTION
    Rock 19's 202603271810501_ReplaceFontAwesomeWithTablerIcons migration rewrites
    every IconCssClass by joining it to the __IconTransition mapping table. Five
    rows of that table name a Tabler class that does not exist in the shipped font:

        fa fa-sync               -> ti ti-ti-refresh              (doubled prefix)
        fa fa-toggle-on          -> ti ti-toggle-righ             (truncated)
        fa fa-chalkboard-teacher -> ti ti-chaulkboard-teacher      (misspelled)
        fa fa-broadcast-tower    -> ti ti-building-broadcast       (wrong name)
        fa fa-fax                -> ti ti-landline                 (wrong name)

    Wherever those landed the icon renders as nothing at all. This is the only part
    of the half-finished Font Awesome conversion that is actually broken rather than
    merely inconsistent: a value the migration left on Font Awesome still renders,
    because v19 still ships and loads Font Awesome.

    The migration is not re-runnable, so correcting __IconTransition alone fixes no
    icon. This script corrects both: the mapping table, so the reference is right for
    anyone who reads it later, and the data the migration already wrote, which is
    where the visible fix happens.

    MATCHING IS EXACT, NEVER LIKE. The migration assigned whole values -- it joined
    target.IconCssClass = t.FontAwesomeFull and set the column to t.TablerFull -- so
    every value it broke is exactly one of the five strings above. Exact matching is
    therefore complete for what the migration did, and it is also the only safe form:
    'ti-building-broadcast' is a prefix of the correct 'ti-building-broadcast-tower',
    so a LIKE would rewrite rows that are already right. Values that contain a broken
    class alongside other classes are reported and not touched, because nothing in
    the migration could have produced one and a human should look at it.

    TABLE DISCOVERY MIRRORS THE MIGRATION. The same predicate: a user table, a column
    named IconCssClass, a character type. That is deliberate -- this script must reach
    exactly the set of tables the migration reached, no more. The character-type
    filter is the fork-local narrowing from Documentation/Fork-Local-Changes.md.

    ADDRESSED, NOT DISCOVERED. The five classes are a closed, hardcoded set, and
    -ExpectedCatalog is mandatory and compared against the catalog actually connected
    to. A run aimed at the wrong catalog stops before it reads anything else.

    ROCK CACHES THESE VALUES IN MEMORY. PageCache, BlockTypeCache, CategoryCache,
    DefinedValueCache and friends are plain in-process caches on an installation with
    no Redis, so a raw SQL write is invisible until the application domain recycles.
    Production recycles nightly. Nothing here recycles anything.

    Windows PowerShell 5.1 compatible: ADO.NET directly rather than Invoke-Sqlcmd,
    which needs the SqlServer module that is not installed on the deploy VM.

.PARAMETER ExpectedCatalog
    The catalog this run is meant for, compared against DB_NAME() after connecting.
    Mandatory, and there is deliberately no default.

.PARAMETER BrokenTablerClass
    Which of the five to repair. Defaults to all five. Constrained to the closed set,
    so this selects from the known-broken list and cannot introduce a new rewrite.

.PARAMETER ConnectionString
    Optional. Falls back to $env:ROCK_DB_CONNECTION_STRING, then to the
    connectionStrings entry in -WebConnectionStringsPath.

.PARAMETER WebConnectionStringsPath
    Optional path to web.ConnectionStrings.config, read only when no connection
    string is supplied any other way. Lets the script run on the web server without
    the credential ever being typed, logged or put in the process list.

.PARAMETER Apply
    Execute. Without it the script reports what it would do and changes nothing.

.PARAMETER RollbackScriptPath
    Where to write the generated rollback. Defaults to a timestamped file beside the
    script. Written in both modes, so the dry run also shows what the undo looks like.

.EXAMPLE
    ./Repair-RockTablerIconClasses.ps1 -ExpectedCatalog RockConnectProd
    ./Repair-RockTablerIconClasses.ps1 -ExpectedCatalog RockConnectProd -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]
    $ExpectedCatalog,

    [Parameter(Mandatory = $false)]
    [ValidateSet(
        'ti ti-ti-refresh',
        'ti ti-toggle-righ',
        'ti ti-chaulkboard-teacher',
        'ti ti-building-broadcast',
        'ti ti-landline')]
    [string[]]
    $BrokenTablerClass = @(
        'ti ti-ti-refresh',
        'ti ti-toggle-righ',
        'ti ti-chaulkboard-teacher',
        'ti ti-building-broadcast',
        'ti ti-landline'),

    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $false)]
    [string]
    $WebConnectionStringsPath,

    [Parameter(Mandatory = $false)]
    [switch]
    $Apply,

    [Parameter(Mandatory = $false)]
    [string]
    $RollbackScriptPath,

    [Parameter(Mandatory = $false)]
    [int]
    $CommandTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The closed repair set. Key is the broken value the migration wrote, Source is the
# Font Awesome class it came from, Fixed is the class that exists in the font.
$repairSet = @{
    'ti ti-ti-refresh'          = @{ Fixed = 'ti ti-refresh';                  Source = 'fa fa-sync' }
    'ti ti-toggle-righ'         = @{ Fixed = 'ti ti-toggle-right';             Source = 'fa fa-toggle-on' }
    'ti ti-chaulkboard-teacher' = @{ Fixed = 'ti ti-chalkboard-teacher';       Source = 'fa fa-chalkboard-teacher' }
    'ti ti-building-broadcast'  = @{ Fixed = 'ti ti-building-broadcast-tower'; Source = 'fa fa-broadcast-tower' }
    'ti ti-landline'            = @{ Fixed = 'ti ti-device-landline-phone';    Source = 'fa fa-fax' }
}

$selected = @($BrokenTablerClass | Select-Object -Unique)

function Get-SqlIdentifier {
    <#
        .SYNOPSIS
            Quotes an identifier for interpolation into dynamic SQL. Table and column
            names cannot be parameterised, so they are escaped instead.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    return '[' + $Name.Replace(']', ']]') + ']'
}

function Resolve-RockConnectionString {
    <#
        .SYNOPSIS
            Finds a connection string without ever returning it through a log.
    #>
    param(
        [Parameter(Mandatory = $false)][string]$Supplied,
        [Parameter(Mandatory = $false)][string]$ConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($Supplied)) {
        return $Supplied
    }

    $fromEnvironment = [Environment]::GetEnvironmentVariable('ROCK_DB_CONNECTION_STRING')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) {
        return $fromEnvironment
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "No connection string. -WebConnectionStringsPath was given as '$ConfigPath' and there is no file there. Set `$env:ROCK_DB_CONNECTION_STRING instead."
        }

        [xml]$document = Get-Content -LiteralPath $ConfigPath -Raw
        $entry = $document.connectionStrings.add | Where-Object { $_.name -eq 'RockContext' } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "No connection string. '$ConfigPath' has no connectionStrings entry named RockContext. Set `$env:ROCK_DB_CONNECTION_STRING instead."
        }

        return $entry.connectionString
    }

    throw "No connection string. Set `$env:ROCK_DB_CONNECTION_STRING, or pass -ConnectionString, or point -WebConnectionStringsPath at a web.ConnectionStrings.config."
}

$resolvedConnectionString = Resolve-RockConnectionString -Supplied $ConnectionString -ConfigPath $WebConnectionStringsPath

if ([string]::IsNullOrWhiteSpace($RollbackScriptPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $RollbackScriptPath = Join-Path $PSScriptRoot "Rollback-RockTablerIconClasses-$stamp.sql"
}

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
$connection.Open()

function Invoke-Read {
    <#
        .SYNOPSIS
            Runs a reader and returns rows as hashtables. Reads only: this is the one
            execution path allowed before the -Apply gate.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $false)][hashtable]$Parameters = @{}
    )

    $command = $connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $CommandTimeoutSeconds
    foreach ($key in $Parameters.Keys) {
        [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
    }

    $rows = New-Object System.Collections.ArrayList
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
            }
            [void]$rows.Add($row)
        }
    }
    finally {
        $reader.Close()
        $command.Dispose()
    }

    return , $rows
}

# The catalog check comes before everything else. Refusing the wrong catalog has to
# happen before the script reads anything from it.
$catalogRows = Invoke-Read -Query 'SELECT DB_NAME() AS CatalogName;'
$actualCatalog = [string]$catalogRows[0]['CatalogName']
if ($actualCatalog -ne $ExpectedCatalog) {
    $connection.Close()
    throw "Refusing to continue. -ExpectedCatalog is '$ExpectedCatalog' and this connection is on '$actualCatalog'."
}

Write-Host "Catalog: $actualCatalog"
Write-Host "Mode:    $(if ($Apply) { 'APPLY' } else { 'dry run' })"
Write-Host ''

# Same predicate as the migration, so this reaches exactly the tables it reached.
$tableQuery = @'
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.columns ic
        WHERE ic.object_id = t.object_id AND ic.name = 'Id'
    ) THEN 1 ELSE 0 END AS HasId
FROM sys.columns c
JOIN sys.tables t ON c.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE c.name = 'IconCssClass'
  AND TYPE_NAME(c.system_type_id) IN ('nvarchar', 'varchar', 'nchar', 'char')
  AND t.is_ms_shipped = 0
ORDER BY s.name, t.name;
'@

$tables = Invoke-Read -Query $tableQuery
Write-Host ("Tables with a character-typed IconCssClass column: {0}" -f $tables.Count)

# Every unit of work found, so the plan, the rollback and the writes all read from
# one list rather than three separate discoveries that could disagree.
$plan = New-Object System.Collections.ArrayList
$notTouched = New-Object System.Collections.ArrayList

function Add-PlanEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][string]$BadValue,
        [Parameter(Mandatory = $true)][string]$GoodValue,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Ids,
        [Parameter(Mandatory = $true)][bool]$HasId,
        [Parameter(Mandatory = $false)][string]$KeyColumn,
        [Parameter(Mandatory = $false)][string]$KeyValue
    )

    if ($Ids.Count -eq 0 -and $HasId) {
        return
    }

    [void]$plan.Add([pscustomobject]@{
        Target    = $Target
        Column    = $Column
        BadValue  = $BadValue
        GoodValue = $GoodValue
        Ids       = $Ids
        HasId     = $HasId
        KeyColumn = $KeyColumn
        KeyValue  = $KeyValue
    })
}

foreach ($table in $tables) {
    $schemaName = [string]$table['SchemaName']
    $tableName = [string]$table['TableName']
    $hasId = ([int]$table['HasId']) -eq 1
    $qualified = (Get-SqlIdentifier $schemaName) + '.' + (Get-SqlIdentifier $tableName)

    foreach ($bad in $selected) {
        $good = $repairSet[$bad].Fixed

        if ($hasId) {
            $rows = Invoke-Read -Query "SELECT [Id] FROM $qualified WHERE [IconCssClass] = @bad;" -Parameters @{ '@bad' = $bad }
            $ids = @($rows | ForEach-Object { $_['Id'] })
            Add-PlanEntry -Target $qualified -Column 'IconCssClass' -BadValue $bad -GoodValue $good -Ids $ids -HasId $true
        }
        else {
            # No Id column, so the rollback cannot be row-scoped. Recorded anyway with
            # an empty Id list; the rollback falls back to a value-scoped statement.
            $rows = Invoke-Read -Query "SELECT COUNT(*) AS Affected FROM $qualified WHERE [IconCssClass] = @bad;" -Parameters @{ '@bad' = $bad }
            if ([int]$rows[0]['Affected'] -gt 0) {
                Add-PlanEntry -Target $qualified -Column 'IconCssClass' -BadValue $bad -GoodValue $good -Ids @() -HasId $false
            }
        }
    }

    # Values that contain a broken class among others. The migration assigned whole
    # values and so cannot have produced one of these, which is exactly why they are
    # reported rather than rewritten.
    $distinct = Invoke-Read -Query "SELECT DISTINCT [IconCssClass] AS Value FROM $qualified WHERE [IconCssClass] IS NOT NULL AND [IconCssClass] <> '';"
    foreach ($row in $distinct) {
        $value = [string]$row['Value']
        if ($selected -contains $value) {
            continue
        }

        $tokens = @($value -split '\s+' | Where-Object { $_ -ne '' })
        foreach ($bad in $selected) {
            $badToken = @($bad -split '\s+')[-1]
            if ($tokens -contains $badToken) {
                [void]$notTouched.Add([pscustomobject]@{ Target = $qualified; Value = $value; BadClass = $badToken })
            }
        }
    }
}

# AttributeValue.Value and Attribute.DefaultValue, the other two places the migration
# wrote. Both were whole-value assignments there too.
foreach ($bad in $selected) {
    $good = $repairSet[$bad].Fixed

    $attributeValueRows = Invoke-Read -Query 'SELECT [Id] FROM [dbo].[AttributeValue] WHERE [Value] = @bad;' -Parameters @{ '@bad' = $bad }
    Add-PlanEntry -Target '[dbo].[AttributeValue]' -Column 'Value' -BadValue $bad -GoodValue $good -Ids @($attributeValueRows | ForEach-Object { $_['Id'] }) -HasId $true

    $attributeRows = Invoke-Read -Query 'SELECT [Id] FROM [dbo].[Attribute] WHERE [DefaultValue] = @bad;' -Parameters @{ '@bad' = $bad }
    Add-PlanEntry -Target '[dbo].[Attribute]' -Column 'DefaultValue' -BadValue $bad -GoodValue $good -Ids @($attributeRows | ForEach-Object { $_['Id'] }) -HasId $true
}

# The mapping table itself. Correcting it fixes no icon on its own -- the migration
# does not run again -- but it stops the next reader of that table believing a class
# that does not exist.
$transitionExists = (Invoke-Read -Query "SELECT 1 AS Present FROM sys.tables WHERE name = '__IconTransition';").Count -gt 0
if ($transitionExists) {
    # The seed migration creates this table without an Id column, so the rollback for
    # it is value-scoped. Detected rather than assumed, because a later Rock version
    # adding one should not silently keep the weaker form.
    $transitionHasId = (Invoke-Read -Query "SELECT 1 AS Present FROM sys.columns WHERE object_id = OBJECT_ID('dbo.__IconTransition') AND name = 'Id';").Count -gt 0

    # Both columns carry the broken class: TablerFull as 'ti ti-landline' and
    # TablerClass as 'ti-landline'. Correcting one and not the other would leave the
    # mapping disagreeing with itself.
    foreach ($bad in $selected) {
        $good = $repairSet[$bad].Fixed
        $badClass = @($bad -split '\s+')[-1]
        $goodClass = @($good -split '\s+')[-1]

        $columnPairs = @(
            @{ Column = 'TablerFull';  Bad = $bad;      Good = $good },
            @{ Column = 'TablerClass'; Bad = $badClass; Good = $goodClass }
        )

        $source = $repairSet[$bad].Source

        foreach ($pair in $columnPairs) {
            $column = Get-SqlIdentifier $pair.Column
            if ($transitionHasId) {
                $rows = Invoke-Read -Query "SELECT [Id] FROM [dbo].[__IconTransition] WHERE [FontAwesomeFull] = @source AND $column = @bad;" -Parameters @{ '@source' = $source; '@bad' = $pair.Bad }
                Add-PlanEntry -Target '[dbo].[__IconTransition]' -Column $pair.Column -BadValue $pair.Bad -GoodValue $pair.Good -Ids @($rows | ForEach-Object { $_['Id'] }) -HasId $true
            }
            else {
                # FontAwesomeFull is the row's natural key and is unique across the
                # seeded table, so it scopes the write and the rollback to one row even
                # though there is no Id to address. That matters here: two other rows
                # already map to 'ti ti-refresh', so scoping the undo by the value
                # would revert rows that were always correct.
                $rows = Invoke-Read -Query "SELECT COUNT(*) AS Affected FROM [dbo].[__IconTransition] WHERE [FontAwesomeFull] = @source AND $column = @bad;" -Parameters @{ '@source' = $source; '@bad' = $pair.Bad }
                if ([int]$rows[0]['Affected'] -gt 0) {
                    Add-PlanEntry -Target '[dbo].[__IconTransition]' -Column $pair.Column -BadValue $pair.Bad -GoodValue $pair.Good -Ids @() -HasId $false -KeyColumn 'FontAwesomeFull' -KeyValue $source
                }
            }
        }
    }
}
else {
    Write-Host 'No __IconTransition table in this catalog, so the mapping rows are skipped.'
}

# Rock keeps persisted renderings of an attribute value beside the raw Value. Writing
# Value without flagging the row dirty leaves Rock serving the old rendering, which is
# what AttributeValueCache sets when a value changes under it.
$persistedDirtyPresent = (Invoke-Read -Query "SELECT 1 AS Present FROM sys.columns WHERE object_id = OBJECT_ID('dbo.AttributeValue') AND name = 'IsPersistedValueDirty';").Count -gt 0

Write-Host ''
Write-Host '--- Plan ---'
if ($plan.Count -eq 0) {
    Write-Host 'Nothing to repair. No row in this catalog holds any of the selected classes.'
}
else {
    foreach ($entry in $plan) {
        $scope = if ($entry.HasId) {
            "{0} row(s) by Id" -f $entry.Ids.Count
        }
        elseif (-not [string]::IsNullOrWhiteSpace($entry.KeyColumn)) {
            "scoped by {0} = '{1}'" -f $entry.KeyColumn, $entry.KeyValue
        }
        else {
            'scoped by value (no Id column and no key)'
        }
        Write-Host ("{0}.{1}: {2}  '{3}' -> '{4}'" -f $entry.Target, $entry.Column, $scope, $entry.BadValue, $entry.GoodValue)
    }
}

Write-Host ''
Write-Host '--- Reported, not changed ---'
if ($notTouched.Count -eq 0) {
    Write-Host 'No value holds a broken class alongside other classes.'
}
else {
    Write-Host 'These hold a broken class among others. Look at them by hand:'
    foreach ($entry in $notTouched) {
        Write-Host ("{0}: '{1}' (contains {2})" -f $entry.Target, $entry.Value, $entry.BadClass)
    }
}

# The rollback goes to disk before anything is written, so a run that dies part way
# through is still reversible. Row-scoped wherever the table has an Id.
$rollbackLines = New-Object System.Collections.ArrayList
[void]$rollbackLines.Add("-- Rollback for Repair-RockTablerIconClasses.ps1")
[void]$rollbackLines.Add("-- Catalog: $actualCatalog")
[void]$rollbackLines.Add("-- Generated: $(Get-Date -Format 's')")
[void]$rollbackLines.Add("-- Restores the broken classes this run replaced. Row-scoped where an Id exists.")
[void]$rollbackLines.Add('')
[void]$rollbackLines.Add('BEGIN TRANSACTION;')

foreach ($entry in $plan) {
    $escapedBad = $entry.BadValue.Replace("'", "''")
    $column = Get-SqlIdentifier $entry.Column
    if ($entry.HasId -and $entry.Ids.Count -gt 0) {
        $idList = ($entry.Ids -join ', ')
        [void]$rollbackLines.Add("UPDATE $($entry.Target) SET $column = N'$escapedBad' WHERE [Id] IN ($idList);")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entry.KeyColumn)) {
        $keyColumn = Get-SqlIdentifier $entry.KeyColumn
        $escapedKey = $entry.KeyValue.Replace("'", "''")
        [void]$rollbackLines.Add("UPDATE $($entry.Target) SET $column = N'$escapedBad' WHERE $keyColumn = N'$escapedKey';")
    }
    else {
        $escapedGood = $entry.GoodValue.Replace("'", "''")
        [void]$rollbackLines.Add("-- No Id column and no natural key on this table, so this statement is")
        [void]$rollbackLines.Add("-- value-scoped and may revert rows that already held the corrected value.")
        [void]$rollbackLines.Add("UPDATE $($entry.Target) SET $column = N'$escapedBad' WHERE $column = N'$escapedGood';")
    }
}

[void]$rollbackLines.Add('COMMIT TRANSACTION;')
$rollbackLines | Out-File -FilePath $RollbackScriptPath -Encoding UTF8
Write-Host ''
Write-Host "Rollback written to: $RollbackScriptPath"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Dry run. Nothing was changed. Re-run with -Apply to write.'
    $connection.Close()
    return
}

Write-Host ''
Write-Host '--- Applying ---'

$transaction = $connection.BeginTransaction()
$totalAffected = 0
try {
    foreach ($entry in $plan) {
        $column = Get-SqlIdentifier $entry.Column
        $command = $connection.CreateCommand()
        $command.Transaction = $transaction
        $command.CommandTimeout = $CommandTimeoutSeconds

        if ($entry.HasId -and $entry.Ids.Count -gt 0) {
            $idList = ($entry.Ids -join ', ')
            $command.CommandText = "UPDATE $($entry.Target) SET $column = @good WHERE [Id] IN ($idList);"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($entry.KeyColumn)) {
            $keyColumn = Get-SqlIdentifier $entry.KeyColumn
            $command.CommandText = "UPDATE $($entry.Target) SET $column = @good WHERE $keyColumn = @key AND $column = @bad;"
            [void]$command.Parameters.AddWithValue('@key', $entry.KeyValue)
            [void]$command.Parameters.AddWithValue('@bad', $entry.BadValue)
        }
        else {
            $command.CommandText = "UPDATE $($entry.Target) SET $column = @good WHERE $column = @bad;"
            [void]$command.Parameters.AddWithValue('@bad', $entry.BadValue)
        }

        [void]$command.Parameters.AddWithValue('@good', $entry.GoodValue)
        $affected = $command.ExecuteNonQuery()
        $command.Dispose()
        $totalAffected += $affected
        Write-Host ("{0}.{1}: {2} row(s) updated" -f $entry.Target, $entry.Column, $affected)
    }

    # Flag the attribute value rows so Rock re-renders them rather than serving the
    # persisted rendering of the broken class.
    if ($persistedDirtyPresent) {
        $attributeValueIds = @($plan | Where-Object { $_.Target -eq '[dbo].[AttributeValue]' } | ForEach-Object { $_.Ids } | ForEach-Object { $_ })
        if ($attributeValueIds.Count -gt 0) {
            $dirtyCommand = $connection.CreateCommand()
            $dirtyCommand.Transaction = $transaction
            $dirtyCommand.CommandTimeout = $CommandTimeoutSeconds
            $dirtyCommand.CommandText = "UPDATE [dbo].[AttributeValue] SET [IsPersistedValueDirty] = 1 WHERE [Id] IN ($($attributeValueIds -join ', '));"
            $dirtyAffected = $dirtyCommand.ExecuteNonQuery()
            $dirtyCommand.Dispose()
            Write-Host ("[dbo].[AttributeValue].IsPersistedValueDirty: {0} row(s) flagged" -f $dirtyAffected)
        }
    }

    $transaction.Commit()
    Write-Host ''
    Write-Host ("Committed. {0} row(s) changed." -f $totalAffected)
    Write-Host 'Rock caches these values in memory, so the change is not visible until the application domain recycles.'
}
catch {
    $transaction.Rollback()
    Write-Host 'Failed. The transaction was rolled back and nothing was changed.'
    throw
}
finally {
    $connection.Close()
}
