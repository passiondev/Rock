<#
.SYNOPSIS
    Converts named text/ntext/image columns to their supported equivalents. Dry run
    by default; writes only with -Apply, and only to columns named on the command
    line.

.DESCRIPTION
    Companion to Find-LegacyTextColumns.ps1. The finder enumerates, a human reads
    the list and decides, and this is told what to change -- it has no discovery
    mode of its own on purpose, so it cannot convert a column nobody looked at.

        text   -> nvarchar(max)
        ntext  -> nvarchar(max)
        image  -> varbinary(max)

    Each conversion preserves the column's nullability and collation, and is a
    size-of-data operation: SQL Server rewrites every row and generates transaction
    log proportional to the column's contents. On a prod-derived catalog on a small
    instance that can take a long time and a lot of disk. Check free space first;
    the shared test instance has `storageAutoResize` disabled, and filling the disk
    mid-ALTER takes the instance read-only.

    A rollback .sql is generated before anything is executed, from the types read
    off the catalog rather than assumed. Read the note at the top of it -- the
    reverse of text -> nvarchar(max) is not lossless in general.

    Windows PowerShell 5.1 compatible: ADO.NET directly rather than Invoke-Sqlcmd,
    which needs the SqlServer module that is not installed on the deploy VM.

.PARAMETER Column
    One or more columns as Schema.Table.Column, e.g. dbo.AttributeValue.Value.
    Required. There is no "convert everything you find" mode.

.PARAMETER Apply
    Execute. Without it the script reports what it would do and changes nothing.

.PARAMETER RollbackScriptPath
    Where to write the generated rollback. Defaults to a timestamped file in the
    working directory. Written in both dry-run and -Apply mode, so the dry run also
    tells you what the undo would look like.

.EXAMPLE
    $env:ROCK_DB_CONNECTION_STRING = "Server=...;Initial Catalog=RockStaging;..."
    ./Convert-LegacyTextColumns.ps1 -Column dbo.AttributeValue.Value
    ./Convert-LegacyTextColumns.ps1 -Column dbo.AttributeValue.Value -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]
    $Column,

    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $false)]
    [switch]
    $Apply,

    [Parameter(Mandatory = $false)]
    [string]
    $RollbackScriptPath,

    # 0 is no timeout. An ALTER COLUMN on a large table routinely runs past any
    # finite default, and a client-side timeout does not cancel the server-side
    # rewrite -- it just stops you watching it.
    [Parameter(Mandatory = $false)]
    [int]
    $CommandTimeoutSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LegacyTypeMap = @{
    'text'  = 'nvarchar(max)'
    'ntext' = 'nvarchar(max)'
    'image' = 'varbinary(max)'
}

# Resolved once and never written to output.
$resolvedConnectionString = $ConnectionString
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    $resolvedConnectionString = [Environment]::GetEnvironmentVariable("ROCK_DB_CONNECTION_STRING")
}
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    throw "No connection string. Set ROCK_DB_CONNECTION_STRING, or pass -ConnectionString."
}

if ([string]::IsNullOrWhiteSpace($RollbackScriptPath)) {
    $RollbackScriptPath = "rollback-legacy-text-columns-{0}.sql" -f (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

Add-Type -AssemblyName System.Data | Out-Null

function ConvertTo-ColumnReference {
    <#
        Parses Schema.Table.Column and refuses anything that is not three plain
        identifiers. The parts are interpolated into DDL, and DDL takes no
        parameters -- there is nowhere to bind these, so the only defence is
        refusing input that could close a bracket or a statement.
    #>
    param([Parameter(Mandatory = $true)][string] $Reference)

    $parts = $Reference.Split('.')
    if ($parts.Count -ne 3) {
        throw "Column '$Reference' is not in Schema.Table.Column form, e.g. dbo.AttributeValue.Value."
    }

    foreach ($part in $parts) {
        if ($part -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Column '$Reference' contains an identifier this script will not quote: '$part'. Rename it or change it by hand."
        }
    }

    return [pscustomobject]@{
        Reference = $Reference
        Schema    = $parts[0]
        Table     = $parts[1]
        Column    = $parts[2]
    }
}

function Invoke-ReadQuery {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Query,
        [Parameter(Mandatory = $false)][hashtable] $Parameters = @{}
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = 120
        foreach ($key in $Parameters.Keys) {
            [void]$command.Parameters.AddWithValue($key, $Parameters[$key])
        }

        $table = New-Object System.Data.DataTable
        $reader = $command.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        return $table
    }
    finally {
        $command.Dispose()
    }
}

$references = @($Column | ForEach-Object { ConvertTo-ColumnReference -Reference $_ })

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
try {
    $connection.Open()

    $catalogName = (Invoke-ReadQuery -Connection $connection -Query "SELECT DB_NAME() AS CatalogName;").Rows[0].CatalogName
    Write-Host "Catalog: $catalogName"
    Write-Host ""

    # Read every column's real type before planning anything. A typo that happens to
    # resolve to a real nvarchar column would otherwise trigger a size-of-data
    # rewrite of a table nobody meant to touch.
    $plan = @()
    foreach ($reference in $references) {
        $row = Invoke-ReadQuery -Connection $connection -Parameters @{
            '@schema' = $reference.Schema
            '@table'  = $reference.Table
            '@column' = $reference.Column
        } -Query @"
SELECT
    ty.name                       AS DataType,
    c.is_nullable                 AS IsNullable,
    ISNULL(c.collation_name, '')  AS CollationName,
    CASE WHEN fti.object_id IS NULL THEN 0 ELSE 1 END AS HasFullTextIndex
FROM sys.columns c
    INNER JOIN sys.tables t  ON t.object_id = c.object_id
    INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
    INNER JOIN sys.types ty  ON ty.user_type_id = c.user_type_id
    LEFT JOIN sys.fulltext_index_columns fti
        ON fti.object_id = c.object_id AND fti.column_id = c.column_id
WHERE s.name = @schema AND t.name = @table AND c.name = @column;
"@

        if ($row.Rows.Count -eq 0) {
            throw "Column $($reference.Reference) does not exist in $catalogName."
        }

        $dataType = [string]$row.Rows[0].DataType
        if (-not $LegacyTypeMap.ContainsKey($dataType)) {
            throw "Column $($reference.Reference) is a $dataType column, which is not a legacy type this script converts. Refusing rather than rewriting a table that does not need it."
        }

        if ([bool]$row.Rows[0].HasFullTextIndex) {
            throw "Column $($reference.Reference) is covered by a full-text index. ALTER COLUMN will not run while it is, and dropping and recreating that index is a bigger change than this script should make on its own."
        }

        $isNullable = [bool]$row.Rows[0].IsNullable
        $collation = [string]$row.Rows[0].CollationName
        $collateClause = ""
        if (-not [string]::IsNullOrWhiteSpace($collation)) {
            $collateClause = " COLLATE $collation"
        }
        $nullClause = if ($isNullable) { "NULL" } else { "NOT NULL" }

        $qualified = "[$($reference.Schema)].[$($reference.Table)]"
        $quotedColumn = "[$($reference.Column)]"
        $originalTypeDeclaration = "$dataType$collateClause $nullClause"
        $targetTypeDeclaration = "$($LegacyTypeMap[$dataType])$collateClause $nullClause"

        $plan += [pscustomobject]@{
            Reference = $reference.Reference
            Forward   = "ALTER TABLE $qualified ALTER COLUMN $quotedColumn $targetTypeDeclaration;"
            Rollback  = "ALTER TABLE $qualified ALTER COLUMN $quotedColumn $originalTypeDeclaration;"
            From      = $dataType
            To        = $LegacyTypeMap[$dataType]
        }
    }

    # Written before anything executes, and covering every column addressed rather
    # than every column reached. A run that dies part-way through the list would
    # otherwise leave a file describing the wrong half.
    $rollbackLines = @(
        "-- Rollback for Convert-LegacyTextColumns.ps1",
        "-- Catalog:   $catalogName",
        "-- Generated: $((Get-Date).ToUniversalTime().ToString('o')) UTC",
        "--",
        "-- Restores the column types read off this catalog immediately before the",
        "-- conversion. Safe to run whole: a statement for a column that was never",
        "-- converted restores the type it already has.",
        "--",
        "-- NOT LOSSLESS in one direction. nvarchar(max) -> text and nvarchar(max) ->",
        "-- ntext are Unicode-to-code-page conversions for text, and any character",
        "-- written after the forward conversion that the collation's code page cannot",
        "-- represent is replaced by '?' with no error. Data that was in the column",
        "-- before the conversion round-trips intact -- it was stored in that code page",
        "-- to begin with. Anything written while the column was nvarchar(max) may not.",
        "-- image <- varbinary(max) and ntext <- nvarchar(max) are byte-for-byte.",
        ""
    )
    foreach ($item in $plan) {
        $rollbackLines += "-- $($item.Reference): $($item.To) -> $($item.From)"
        $rollbackLines += $item.Rollback
        $rollbackLines += ""
    }
    $rollbackLines | Out-File -FilePath $RollbackScriptPath -Encoding utf8
    Write-Host "Rollback written to $RollbackScriptPath"
    Write-Host ""

    foreach ($item in $plan) {
        Write-Host "$($item.Reference): $($item.From) -> $($item.To)"
        Write-Host "  $($item.Forward)"
    }
    Write-Host ""

    if (-not $Apply) {
        Write-Host "Dry run. Nothing was changed. Re-run with -Apply to execute the $($plan.Count) statement(s) above."
        return
    }

    foreach ($item in $plan) {
        Write-Host "Applying $($item.Reference) ..."
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = $item.Forward
            $command.CommandTimeout = $CommandTimeoutSeconds
            [void]$command.ExecuteNonQuery()
        }
        finally {
            $command.Dispose()
        }
        Write-Host "  done."
    }

    Write-Host ""
    Write-Host "Converted $($plan.Count) column(s). Undo with: sqlcmd -i $RollbackScriptPath (read its header first)."
}
finally {
    $connection.Dispose()
}
