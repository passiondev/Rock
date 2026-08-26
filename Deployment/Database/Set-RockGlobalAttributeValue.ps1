<#
.SYNOPSIS
    Sets a Rock global attribute value. Dry run by default; writes only with
    -Apply, and only to the attribute named on the command line.

.DESCRIPTION
    Written for PublicApplicationRoot, which the deploy cannot set. Both
    Deploy-RockEnvironment.ps1 and Set-PrEnvironmentRuntimeConfiguration.ps1 try to
    rewrite it in web.config:

        $webConfig -replace '(<attributeValue\s+attributeKey="PublicApplicationRoot"[^>]*value=")"', ...

    That element does not exist in RockWeb/web.config -- measured 0 occurrences --
    so both replacements are no-ops and always have been. Rock reads the value from
    the database, so the database is where it has to change. The host rename to
    staging.connect.passion.team is the first time that has mattered: the value is
    what Rock puts in generated links and emails, so a stale one sends people to
    the old name from inside a correctly-renamed site.

    Follows Convert-LegacyTextColumns.ps1: it has no discovery mode, it is told
    which attribute to change, and it addresses the write by the explicit row Id it
    read back rather than by matching on Key again.

    A global attribute is one with EntityTypeId IS NULL, and its value row is the
    one with EntityId IS NULL. Both are asserted rather than assumed -- a Key that
    matches several attributes stops the script instead of picking one.

    Two cases, and the rollback differs between them:

        value row exists  -> UPDATE by AttributeValue.Id; rollback restores the old value.
        no value row      -> INSERT (Rock was falling back to Attribute.DefaultValue);
                             rollback deletes the row this script created.

    Rock keeps persisted renderings of a value (PersistedTextValue and friends)
    alongside the raw Value. Writing Value without flagging IsPersistedValueDirty
    leaves Rock serving the old rendering, so every write here sets that flag to 1,
    the same thing AttributeValueCache does when a value changes under it. The
    column is a non-nullable bool with no default, so an INSERT has to supply it.

    Rock caches attribute values in memory. The new value is not live until the
    cache is cleared or the app pool recycles, which a deploy does anyway.

    Windows PowerShell 5.1 compatible: ADO.NET directly rather than Invoke-Sqlcmd,
    which needs the SqlServer module that is not installed on the deploy VM.

.PARAMETER Key
    The global attribute Key, e.g. PublicApplicationRoot. Required.

.PARAMETER Value
    The value to set. Required. For PublicApplicationRoot, Rock expects a trailing
    slash: https://staging.connect.passion.team/

.PARAMETER Apply
    Execute. Without it the script reports what it would do and changes nothing.

.PARAMETER RollbackScriptPath
    Where to write the generated rollback. Defaults to a timestamped file in the
    working directory. Written in both dry-run and -Apply mode, so the dry run also
    shows what the undo would look like.

.EXAMPLE
    $env:ROCK_DB_CONNECTION_STRING = "Server=...;Initial Catalog=RockStaging;..."
    ./Set-RockGlobalAttributeValue.ps1 -Key PublicApplicationRoot -Value "https://staging.connect.passion.team/"
    ./Set-RockGlobalAttributeValue.ps1 -Key PublicApplicationRoot -Value "https://staging.connect.passion.team/" -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]
    $Key,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]
    $Value,

    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $false)]
    [switch]
    $Apply,

    [Parameter(Mandatory = $false)]
    [string]
    $RollbackScriptPath,

    [Parameter(Mandatory = $false)]
    [int]
    $CommandTimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

$resolvedConnectionString = $ConnectionString
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    $resolvedConnectionString = [Environment]::GetEnvironmentVariable("ROCK_DB_CONNECTION_STRING")
}
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    throw "No connection string. Set ROCK_DB_CONNECTION_STRING, or pass -ConnectionString."
}

if ([string]::IsNullOrWhiteSpace($RollbackScriptPath)) {
    $RollbackScriptPath = "rollback-global-attribute-{0}-{1}.sql" -f $Key, (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

# Escape a string for a single-quoted T-SQL literal.
function ConvertTo-SqlLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string] $Text)
    if ($null -eq $Text) {
        return "NULL"
    }
    return "N'" + $Text.Replace("'", "''") + "'"
}

function New-Command {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Sql
    )
    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql
    $command.CommandTimeout = $CommandTimeoutSeconds
    return $command
}

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
$connection.Open()

try {
    # -- Locate the global attribute -------------------------------------------
    $attributeCommand = New-Command -Connection $connection -Sql @"
SELECT [Id], [Name], [DefaultValue]
FROM [dbo].[Attribute]
WHERE [Key] = @key AND [EntityTypeId] IS NULL;
"@
    $attributeCommand.Parameters.AddWithValue("@key", $Key) | Out-Null

    $attributeId = $null
    $attributeName = $null
    $defaultValue = $null
    $matchCount = 0

    $reader = $attributeCommand.ExecuteReader()
    try {
        while ($reader.Read()) {
            $matchCount++
            $attributeId = [int]$reader["Id"]
            $attributeName = [string]$reader["Name"]
            $defaultValue = if ($reader["DefaultValue"] -is [DBNull]) { $null } else { [string]$reader["DefaultValue"] }
        }
    }
    finally {
        $reader.Close()
    }

    if ($matchCount -eq 0) {
        throw "No global attribute with Key '$Key' (EntityTypeId IS NULL). Nothing was changed."
    }
    if ($matchCount -gt 1) {
        throw "Key '$Key' matches $matchCount global attributes. Refusing to guess which one. Nothing was changed."
    }

    Write-Host "Attribute : $attributeName (Key=$Key, Id=$attributeId)"
    Write-Host "Default   : $defaultValue"

    # -- Locate its value row ---------------------------------------------------
    $valueCommand = New-Command -Connection $connection -Sql @"
SELECT [Id], [Value]
FROM [dbo].[AttributeValue]
WHERE [AttributeId] = @attributeId AND [EntityId] IS NULL;
"@
    $valueCommand.Parameters.AddWithValue("@attributeId", $attributeId) | Out-Null

    $valueRowId = $null
    $currentValue = $null
    $valueRowCount = 0

    $reader = $valueCommand.ExecuteReader()
    try {
        while ($reader.Read()) {
            $valueRowCount++
            $valueRowId = [int]$reader["Id"]
            $currentValue = if ($reader["Value"] -is [DBNull]) { $null } else { [string]$reader["Value"] }
        }
    }
    finally {
        $reader.Close()
    }

    if ($valueRowCount -gt 1) {
        throw "Attribute Id $attributeId has $valueRowCount global value rows (EntityId IS NULL). Refusing to guess which one. Nothing was changed."
    }

    # -- Report and build the rollback -----------------------------------------
    $rollbackLines = New-Object System.Collections.Generic.List[string]
    $rollbackLines.Add("-- Rollback for $Key on $(Get-Date -Format s)Z")
    $rollbackLines.Add("-- Generated before any write. Addresses rows by explicit Id.")
    $rollbackLines.Add("")

    if ($valueRowCount -eq 1) {
        Write-Host "Current   : $currentValue"
        Write-Host "New       : $Value"
        if ($currentValue -ceq $Value) {
            Write-Host ""
            Write-Host "Already set to that value. Nothing to do."
            $rollbackLines.Add("-- No change was needed; this file is a no-op.")
            $rollbackLines | Out-File -FilePath $RollbackScriptPath -Encoding utf8
            return
        }
        $action = "UPDATE AttributeValue Id=$valueRowId"
        $writeSql = "UPDATE [dbo].[AttributeValue] SET [Value] = @value, [IsPersistedValueDirty] = 1, [ModifiedDateTime] = SYSDATETIME() WHERE [Id] = @id;"
        $rollbackLines.Add("UPDATE [dbo].[AttributeValue] SET [Value] = $(ConvertTo-SqlLiteral $currentValue), [IsPersistedValueDirty] = 1 WHERE [Id] = $valueRowId;")
    }
    else {
        Write-Host "Current   : (no value row -- Rock is falling back to the default above)"
        Write-Host "New       : $Value"
        $action = "INSERT AttributeValue for AttributeId=$attributeId"
        $writeSql = @"
INSERT INTO [dbo].[AttributeValue] ([IsSystem], [AttributeId], [EntityId], [Value], [IsPersistedValueDirty], [Guid], [CreatedDateTime], [ModifiedDateTime])
VALUES (0, @attributeId, NULL, @value, 1, NEWID(), SYSDATETIME(), SYSDATETIME());
SELECT CAST(SCOPE_IDENTITY() AS int);
"@
        $rollbackLines.Add("-- This run created the value row; the undo is to remove it so Rock")
        $rollbackLines.Add("-- falls back to Attribute.DefaultValue again.")
        $rollbackLines.Add("DELETE FROM [dbo].[AttributeValue] WHERE [AttributeId] = $attributeId AND [EntityId] IS NULL;")
    }

    $rollbackLines | Out-File -FilePath $RollbackScriptPath -Encoding utf8
    Write-Host ""
    Write-Host "Rollback written to $RollbackScriptPath"

    if (-not $Apply) {
        Write-Host ""
        Write-Host "DRY RUN. Would: $action"
        Write-Host "Re-run with -Apply to execute."
        return
    }

    # -- Write ------------------------------------------------------------------
    $writeCommand = New-Command -Connection $connection -Sql $writeSql
    $writeCommand.Parameters.AddWithValue("@value", $Value) | Out-Null
    if ($valueRowCount -eq 1) {
        $writeCommand.Parameters.AddWithValue("@id", $valueRowId) | Out-Null
        $affected = $writeCommand.ExecuteNonQuery()
        if ($affected -ne 1) {
            throw "Expected to update exactly 1 row, updated $affected. Run the rollback and investigate."
        }
        Write-Host "Updated AttributeValue Id=$valueRowId."
    }
    else {
        $writeCommand.Parameters.AddWithValue("@attributeId", $attributeId) | Out-Null
        $newId = $writeCommand.ExecuteScalar()
        Write-Host "Inserted AttributeValue Id=$newId."
    }

    Write-Host ""
    Write-Host "Rock caches attribute values. This is not live until the cache is cleared"
    Write-Host "or the app pool recycles."
}
finally {
    $connection.Close()
}
