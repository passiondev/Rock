<#
.SYNOPSIS
    Reports columns still typed text, ntext or image, and how far the catalog has
    got through its migration set. Read-only.

.DESCRIPTION
    `text`, `ntext` and `image` were deprecated in SQL Server 2005 and removed in
    2016. Rock's own schema uses `nvarchar` and `varbinary`, so one of these in a
    Passion catalog is local drift -- a column added by a plugin, an import, or a
    hand-run script years ago.

    It matters at version-upgrade time because the old types have no equality
    operator against `nvarchar`. A migration that does `WHERE [Value] = @something`
    against a `text` column fails with

        The data types text and nvarchar are incompatible in the equal to operator

    and, because EF's DbMigrator commits each migration separately, the failure
    leaves the catalog on neither version: everything before the failing migration
    is committed, the failing one is rolled back, and nothing after it has run.
    That is what happened to the shared sandbox catalog on 2026-08-18. Run this
    before a version bump, not after one has failed.

    This script only reads. It is deliberately separate from
    Convert-LegacyTextColumns.ps1 so that it can be pointed at any catalog --
    including production -- without anyone having to audit it first.

    Windows PowerShell 5.1 compatible: ADO.NET directly rather than Invoke-Sqlcmd,
    which needs the SqlServer module that is not installed on the deploy VM.

.PARAMETER ConnectionString
    Full SQL Server connection string. Prefer the environment variable below --
    an argument lands in shell history, in the scrollback and in the process list.

.PARAMETER MeasureSizes
    Also report the largest value in each column found. This is a full scan of every
    affected table, so it is off by default; on a prod-derived catalog it can take a
    long time. The sizes are informational -- every legacy type converts to a `max`
    type of the same 2 GB capacity, so no value can be too large to convert.

.PARAMETER OutFile
    Write the findings as JSON as well as printing them. The converter takes column
    names, not this file: a human reads the list and decides.

.EXAMPLE
    $env:ROCK_DB_CONNECTION_STRING = "Server=...;Initial Catalog=RockStaging;..."
    ./Find-LegacyTextColumns.ps1 -OutFile legacy-columns.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $false)]
    [switch]
    $MeasureSizes,

    [Parameter(Mandatory = $false)]
    [string]
    $OutFile,

    [Parameter(Mandatory = $false)]
    [int]
    $CommandTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolved once and never written to output. Everything this script prints is
# derived from query results, not from the string that got it there.
$resolvedConnectionString = $ConnectionString
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    $resolvedConnectionString = [Environment]::GetEnvironmentVariable("ROCK_DB_CONNECTION_STRING")
}
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    throw "No connection string. Set ROCK_DB_CONNECTION_STRING, or pass -ConnectionString."
}

Add-Type -AssemblyName System.Data | Out-Null

function Invoke-ReadQuery {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Query,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 300
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds

        $table = New-Object System.Data.DataTable
        $reader = $command.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        return $table
    }
    finally {
        $command.Dispose()
    }
}

# is_ms_shipped excludes the system tables; the sys.partitions join is the cheap
# row estimate rather than COUNT(*), which on a prod-derived catalog is minutes.
$legacyColumnQuery = @"
SELECT
    s.name                              AS SchemaName,
    t.name                              AS TableName,
    c.name                              AS ColumnName,
    ty.name                             AS DataType,
    c.is_nullable                       AS IsNullable,
    ISNULL(c.collation_name, '')        AS CollationName,
    ISNULL(p.EstimatedRows, 0)          AS EstimatedRows,
    CASE WHEN fti.object_id IS NULL THEN 0 ELSE 1 END AS HasFullTextIndex
FROM sys.columns c
    INNER JOIN sys.tables t   ON t.object_id = c.object_id
    INNER JOIN sys.schemas s  ON s.schema_id = t.schema_id
    INNER JOIN sys.types ty   ON ty.user_type_id = c.user_type_id
    OUTER APPLY (
        SELECT MAX(rows) AS EstimatedRows
        FROM sys.partitions
        WHERE object_id = t.object_id AND index_id IN (0, 1)
    ) p
    LEFT JOIN sys.fulltext_index_columns fti
        ON fti.object_id = c.object_id AND fti.column_id = c.column_id
WHERE ty.name IN ('text', 'ntext', 'image')
    AND t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.name;
"@

# The high-water mark. A catalog stranded part-way through a migration set is
# indistinguishable from a healthy one until you read this, and after a failed
# deploy it names the last migration that committed -- which is the one before the
# one that failed.
$migrationHistoryQuery = @"
SELECT TOP 5 MigrationId, ContextKey
FROM dbo.__MigrationHistory
ORDER BY MigrationId DESC;
"@

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
try {
    $connection.Open()

    $context = Invoke-ReadQuery -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query @"
SELECT DB_NAME() AS CatalogName, CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS ProductVersion;
"@
    $catalogName = $context.Rows[0].CatalogName
    Write-Host "Catalog: $catalogName (SQL Server $($context.Rows[0].ProductVersion))"

    # A catalog with no __MigrationHistory is not an error -- it just is not a Rock
    # catalog, or is one that has never been migrated. Say so and carry on; the
    # legacy-column scan is still the answer the caller asked for.
    try {
        $history = Invoke-ReadQuery -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query $migrationHistoryQuery
        Write-Host ""
        Write-Host "Last 5 applied migrations (__MigrationHistory, newest first):"
        foreach ($row in $history.Rows) {
            Write-Host ("  {0}  [{1}]" -f $row.MigrationId, $row.ContextKey)
        }
    }
    catch {
        Write-Warning "Could not read dbo.__MigrationHistory: $($_.Exception.Message)"
    }

    $columns = Invoke-ReadQuery -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query $legacyColumnQuery

    $findings = @()
    foreach ($row in $columns.Rows) {
        $finding = [ordered]@{
            Schema           = [string]$row.SchemaName
            Table            = [string]$row.TableName
            Column           = [string]$row.ColumnName
            DataType         = [string]$row.DataType
            IsNullable       = [bool]$row.IsNullable
            Collation        = [string]$row.CollationName
            EstimatedRows    = [long]$row.EstimatedRows
            HasFullTextIndex = [bool]$row.HasFullTextIndex
            MaxValueBytes    = $null
        }

        if ($MeasureSizes) {
            $sizeQuery = "SELECT ISNULL(MAX(DATALENGTH([{0}])), 0) AS MaxBytes FROM [{1}].[{2}];" -f `
                $finding.Column.Replace("]", "]]"), $finding.Schema.Replace("]", "]]"), $finding.Table.Replace("]", "]]")
            $size = Invoke-ReadQuery -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query $sizeQuery
            $finding.MaxValueBytes = [long]$size.Rows[0].MaxBytes
        }

        $findings += [pscustomobject]$finding
    }

    Write-Host ""
    if ($findings.Count -eq 0) {
        Write-Host "No text, ntext or image columns. Nothing here will block a version upgrade."
    }
    else {
        Write-Host "$($findings.Count) legacy column(s) found:"
        $findings | Format-Table -AutoSize | Out-String | Write-Host

        $fullText = @($findings | Where-Object { $_.HasFullTextIndex })
        if ($fullText.Count -gt 0) {
            # ALTER COLUMN refuses while a full-text index covers the column, and the
            # error names the index rather than the fix. Surfacing it here is the
            # difference between one planned outage and two.
            Write-Warning ("$($fullText.Count) of these are covered by a full-text index; the index has to be dropped and recreated around the conversion: " +
                (($fullText | ForEach-Object { "$($_.Schema).$($_.Table).$($_.Column)" }) -join ", "))
        }

        Write-Host "Fix them with Convert-LegacyTextColumns.ps1, naming each column explicitly. Read its dry run before using -Apply."
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $report = [ordered]@{
            catalog     = $catalogName
            scannedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            findings    = $findings
        }
        $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutFile -Encoding utf8
        Write-Host "Wrote $OutFile"
    }
}
finally {
    $connection.Dispose()
}
