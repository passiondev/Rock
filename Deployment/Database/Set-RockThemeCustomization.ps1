<#
.SYNOPSIS
    Sets a Rock theme's customization settings (brand colours, custom CSS). Dry run
    by default; writes only with -Apply, and only to the theme named on the command
    line.

.DESCRIPTION
    Written for the RockNextGen theme, whose branding is the last piece of Passion's
    look that lives nowhere in this repository.

    Two halves make up the internal site's appearance, and they are stored in
    different places:

        Themes/Rock/Styles/_variable-overrides.less   on disk, in the artifact
        Theme.AdditionalSettingsJson                  in the database, per catalog

    The .less half is now committed and ships with every deploy. The database half
    was typed into Admin Tools > CMS Configuration > Themes by hand on staging, so
    it exists in exactly one catalog and no deploy reproduces it. This script is the
    reproducible form of that hand edit.

    It matters for the v19 cutover specifically. The v19 migration
    202508051740308_Rollup_20250805 repoints SystemGuid.Site.SITE_ROCK_INTERNAL at
    the RockNextGen theme unconditionally, so the day production upgrades it starts
    rendering from a theme row whose customization is empty. Staging shows what that
    looks like: correct fonts and icons, stock Rock blue. Running this against the
    production catalog after the migration puts Passion's blue back.

    How the value is stored, and why this script merges rather than overwrites.
    AdditionalSettingsJson is a JSON object keyed by settings-class name --
    Rock's SetAdditionalSettings uses typeof( TSettings ).Name -- so the theme's
    customization lives under "ThemeCustomizationSettings" beside whatever else a
    future Rock version puts in that column:

        {"ThemeCustomizationSettings":{"CustomOverrides":"","EnabledIconSets":3,
         "DefaultFontAwesomeWeight":0,"AdditionalFontAwesomeWeights":[],
         "VariableValues":{"base-primary":"#00B8E4"}}}

    Rock's own writer calls JObject.AddOrReplace on the root and leaves sibling keys
    alone. This does the same thing, one level further down: it replaces the variable
    values it is given, and leaves every other variable and every other settings key
    exactly as it found them. Passing one colour changes one colour.

    Effect is immediate-ish rather than immediate. ThemeService.GetThemeCssContent
    reads these settings and rewrites theme.css in memory on the way out, so nothing
    on disk has to be regenerated and a web farm picks the change up everywhere. Rock
    caches the result, so the new colour appears once that cache is cleared or the
    app pool recycles -- which a deploy does anyway.

    A theme whose PurposeValueId is neither the next-gen website purpose nor the
    check-in purpose ignores customization entirely: GetThemeCssContent returns the
    file unchanged before it ever reads these settings. Writing to such a theme
    succeeds and does nothing, which is the worst way to be wrong, so the purpose is
    read back and reported and a mismatch is a warning on every run.

    Follows Set-RockGlobalAttributeValue.ps1: no discovery mode, it is told which
    theme to change, it addresses the write by the explicit row Id it read back
    rather than by matching on Name again, and it writes the rollback before it
    writes anything else.

    Windows PowerShell 5.1 compatible: ADO.NET directly rather than Invoke-Sqlcmd,
    which needs the SqlServer module that is not installed on the deploy VM.

.PARAMETER ThemeName
    The Theme row's Name, e.g. RockNextGen. Required. Matched exactly; a name that
    matches no theme, or more than one, stops the script.

.PARAMETER VariableValues
    Theme variable assignments as name=value, one per array element, e.g.
    'base-primary=#00B8E4'. The name is a theme.json field key, not a LESS variable.
    Values are taken verbatim -- Rock's field logic formats them into CSS. Only the
    names given are touched.

.PARAMETER CustomOverrides
    The theme's custom CSS override block, the free-text box under the colour
    pickers. Only written when the parameter is supplied, so omitting it preserves
    whatever is there. Pass an empty string to deliberately clear it.

.PARAMETER Apply
    Execute. Without it the script reports what it would do and changes nothing.

.PARAMETER RollbackScriptPath
    Where to write the generated rollback. Defaults to a timestamped file in the
    working directory. Written in both dry-run and -Apply mode, so the dry run also
    shows what the undo would look like.

.EXAMPLE
    $env:ROCK_DB_CONNECTION_STRING = "Server=...;Initial Catalog=RockStaging20260824;..."
    ./Set-RockThemeCustomization.ps1 -ThemeName RockNextGen -VariableValues 'base-primary=#00B8E4'
    ./Set-RockThemeCustomization.ps1 -ThemeName RockNextGen -VariableValues 'base-primary=#00B8E4' -Apply

.EXAMPLE
    # Several at once, plus the custom CSS block.
    ./Set-RockThemeCustomization.ps1 -ThemeName RockNextGen `
        -VariableValues 'base-primary=#00B8E4', 'link=#599AC2' `
        -CustomOverrides ":root { --logo-image: url('/Assets/Images/passion-logo.svg'); }" -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]
    $ThemeName,

    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]
    $VariableValues = @(),

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]
    $CustomOverrides,

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

# The settings key inside AdditionalSettingsJson. Rock derives it from the settings
# class name, so this string tracks Rock/Cms/ThemeCustomizationSettings.cs.
$SettingsKey = "ThemeCustomizationSettings"

# Theme purposes that consume customization. Anything else ignores it -- see
# ThemeService.GetThemeCssContent, which returns early before reading the settings.
$CustomizablePurposeGuids = @{
    "b177e07f-7e07-4d7b-afa7-9de163797659" = "Website (Next-Gen)"
    "2bbb1a44-708e-4469-80de-4aae6227bef8" = "Check-in"
}

$resolvedConnectionString = $ConnectionString
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    $resolvedConnectionString = [Environment]::GetEnvironmentVariable("ROCK_DB_CONNECTION_STRING")
}
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    throw "No connection string. Set ROCK_DB_CONNECTION_STRING, or pass -ConnectionString."
}

if ([string]::IsNullOrWhiteSpace($RollbackScriptPath)) {
    $RollbackScriptPath = "rollback-theme-{0}-{1}.sql" -f $ThemeName, (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
}

# Nothing to do is a usage error rather than a successful no-op. A run that names no
# variable and no override would report "already set to that value" and exit 0, which
# reads as confirmation that the theme is correct.
$isOverrideRequested = $PSBoundParameters.ContainsKey("CustomOverrides")
if ($VariableValues.Count -eq 0 -and -not $isOverrideRequested) {
    throw "Nothing to set. Pass -VariableValues, -CustomOverrides, or both."
}

# -- Parse the name=value pairs before opening a connection --------------------
# Split on the first '=' only: a value may contain one, and a CSS override certainly
# can. An empty name is rejected; an empty value is allowed, because clearing a
# single variable back to the theme's default is a real thing to want.
$requestedVariables = [ordered]@{}
foreach ($pair in $VariableValues) {
    $separatorIndex = $pair.IndexOf("=")
    if ($separatorIndex -lt 1) {
        throw "Variable '$pair' is not in name=value form. Expected something like base-primary=#00B8E4."
    }
    $variableName = $pair.Substring(0, $separatorIndex).Trim()
    $variableValue = $pair.Substring($separatorIndex + 1)
    if ([string]::IsNullOrWhiteSpace($variableName)) {
        throw "Variable '$pair' has an empty name."
    }
    if ($requestedVariables.Contains($variableName)) {
        throw "Variable '$variableName' was given twice. Refusing to guess which value was meant."
    }
    $requestedVariables[$variableName] = $variableValue
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

# Read a property off a PSCustomObject that may not have it. ConvertFrom-Json gives
# note properties, so a missing key is an absent property rather than a null value,
# and touching it under Set-StrictMode is an error.
function Get-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][AllowNull()] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )
    if ($null -eq $Object) {
        return $null
    }
    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        return $null
    }
    return $Object.$Name
}

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
$connection.Open()

try {
    # -- Locate the theme -------------------------------------------------------
    # The purpose comes back as its DefinedValue Guid rather than the raw
    # PurposeValueId: the id is catalog-specific, the Guid is the thing
    # Rock's SystemGuid constants can be compared against.
    $themeCommand = New-Command -Connection $connection -Sql @"
SELECT t.[Id], t.[Name], t.[IsSystem], t.[AdditionalSettingsJson],
       dv.[Guid] AS [PurposeGuid], dv.[Value] AS [PurposeName]
FROM [dbo].[Theme] t
LEFT JOIN [dbo].[DefinedValue] dv ON dv.[Id] = t.[PurposeValueId]
WHERE t.[Name] = @themeName;
"@
    $themeCommand.Parameters.AddWithValue("@themeName", $ThemeName) | Out-Null

    $themeId = $null
    $isSystemTheme = $false
    $currentJson = $null
    $purposeGuid = $null
    $purposeName = $null
    $matchCount = 0

    $reader = $themeCommand.ExecuteReader()
    try {
        while ($reader.Read()) {
            $matchCount++
            $themeId = [int]$reader["Id"]
            $isSystemTheme = [bool]$reader["IsSystem"]
            $currentJson = if ($reader["AdditionalSettingsJson"] -is [DBNull]) { $null } else { [string]$reader["AdditionalSettingsJson"] }
            $purposeGuid = if ($reader["PurposeGuid"] -is [DBNull]) { $null } else { ([guid]$reader["PurposeGuid"]).ToString() }
            $purposeName = if ($reader["PurposeName"] -is [DBNull]) { $null } else { [string]$reader["PurposeName"] }
        }
    }
    finally {
        $reader.Close()
    }

    if ($matchCount -eq 0) {
        throw "No theme named '$ThemeName'. On a catalog that has not run the v19 migrations yet, RockNextGen does not exist. Nothing was changed."
    }
    if ($matchCount -gt 1) {
        throw "Name '$ThemeName' matches $matchCount themes. Refusing to guess which one. Nothing was changed."
    }

    Write-Host "Theme     : $ThemeName (Id=$themeId, IsSystem=$isSystemTheme)"
    if ($null -eq $purposeGuid) {
        Write-Warning "Theme '$ThemeName' has no purpose set. ThemeService.GetThemeCssContent ignores customization on such a theme, so this write would have no visible effect."
    }
    else {
        Write-Host "Purpose   : $purposeName ($purposeGuid)"
        if (-not $CustomizablePurposeGuids.ContainsKey($purposeGuid.ToLowerInvariant())) {
            Write-Warning "Purpose '$purposeName' does not consume theme customization. ThemeService.GetThemeCssContent returns the CSS unchanged for it, so this write would succeed and have no visible effect."
        }
    }

    # -- Merge the requested values into the existing settings ------------------
    # Mirrors Rock's SetAdditionalSettings: the root object keeps every key it
    # already had, and only the ThemeCustomizationSettings branch is rewritten.
    $root = $null
    if (-not [string]::IsNullOrWhiteSpace($currentJson)) {
        try {
            $root = $currentJson | ConvertFrom-Json
        }
        catch {
            throw "Theme Id $themeId has an AdditionalSettingsJson this script cannot parse: $($_.Exception.Message). Refusing to overwrite it. Nothing was changed."
        }
    }
    if ($null -eq $root) {
        $root = [pscustomobject]@{}
    }

    $settings = Get-JsonProperty -Object $root -Name $SettingsKey
    if ($null -eq $settings) {
        # First customization on this theme. Build the shape Rock's own serializer
        # produces for a default ThemeCustomizationSettings so the row looks the same
        # whether the admin UI or this script wrote it first.
        $settings = [pscustomobject]@{
            CustomOverrides              = ""
            EnabledIconSets              = $null
            DefaultFontAwesomeWeight     = 0
            AdditionalFontAwesomeWeights = @()
            VariableValues               = [pscustomobject]@{}
        }
    }

    $variableBag = Get-JsonProperty -Object $settings -Name "VariableValues"
    if ($null -eq $variableBag) {
        $variableBag = [pscustomobject]@{}
    }

    # Report and record every field this run touches, so the dry run is a diff rather
    # than a claim. Comparison is on the parsed values, not on the JSON text: Windows
    # PowerShell's ConvertTo-Json escapes characters Rock's serializer leaves alone
    # (an apostrophe in a CSS override comes back out as the escape \u0027), so two
    # semantically identical documents do not compare equal as strings.
    $changes = New-Object System.Collections.Generic.List[string]

    foreach ($variableName in $requestedVariables.Keys) {
        $newValue = $requestedVariables[$variableName]
        $oldValue = Get-JsonProperty -Object $variableBag -Name $variableName
        if ($null -eq $oldValue) {
            Write-Host "  $variableName : (unset) -> $newValue"
        }
        elseif ($oldValue -ceq $newValue) {
            Write-Host "  $variableName : $oldValue (unchanged)"
            continue
        }
        else {
            Write-Host "  $variableName : $oldValue -> $newValue"
        }
        $variableBag | Add-Member -NotePropertyName $variableName -NotePropertyValue $newValue -Force
        $changes.Add($variableName)
    }

    if ($isOverrideRequested) {
        $oldOverrides = Get-JsonProperty -Object $settings -Name "CustomOverrides"
        if ($oldOverrides -ceq $CustomOverrides) {
            Write-Host "  CustomOverrides : unchanged ($($CustomOverrides.Length) chars)"
        }
        else {
            $oldLength = if ($null -eq $oldOverrides) { 0 } else { $oldOverrides.Length }
            Write-Host "  CustomOverrides : $oldLength chars -> $($CustomOverrides.Length) chars"
            $settings | Add-Member -NotePropertyName "CustomOverrides" -NotePropertyValue $CustomOverrides -Force
            $changes.Add("CustomOverrides")
        }
    }

    if ($changes.Count -eq 0) {
        Write-Host ""
        Write-Host "Already set to those values. Nothing to do."
        @(
            "-- Rollback for theme $ThemeName on $(Get-Date -Format s)Z",
            "-- No change was needed; this file is a no-op."
        ) | Out-File -FilePath $RollbackScriptPath -Encoding utf8
        return
    }

    $settings | Add-Member -NotePropertyName "VariableValues" -NotePropertyValue $variableBag -Force
    $root | Add-Member -NotePropertyName $SettingsKey -NotePropertyValue $settings -Force

    # Depth 10 clears the deepest shape this column holds (root > settings >
    # VariableValues > value) with room for whatever Rock adds beside it. The default
    # of 2 would silently stringify the variable bag.
    $newJson = $root | ConvertTo-Json -Depth 10 -Compress

    # -- Build the rollback before any write ------------------------------------
    # Restores the column to the exact string that was read, escapes and all, rather
    # than to a re-serialized equivalent. If this run is wrong, the undo should not
    # also be a rewrite.
    $rollbackLines = New-Object System.Collections.Generic.List[string]
    $rollbackLines.Add("-- Rollback for theme $ThemeName on $(Get-Date -Format s)Z")
    $rollbackLines.Add("-- Generated before any write. Addresses the row by explicit Id.")
    $rollbackLines.Add("-- Restores AdditionalSettingsJson byte-for-byte as it was read.")
    $rollbackLines.Add("")
    if ($null -eq $currentJson) {
        $rollbackLines.Add("-- The column was NULL before this run.")
        $rollbackLines.Add("UPDATE [dbo].[Theme] SET [AdditionalSettingsJson] = NULL WHERE [Id] = $themeId;")
    }
    else {
        $rollbackLines.Add("UPDATE [dbo].[Theme] SET [AdditionalSettingsJson] = $(ConvertTo-SqlLiteral $currentJson) WHERE [Id] = $themeId;")
    }
    $rollbackLines | Out-File -FilePath $RollbackScriptPath -Encoding utf8

    Write-Host ""
    Write-Host "Changing  : $($changes -join ', ')"
    Write-Host "Rollback written to $RollbackScriptPath"

    if (-not $Apply) {
        Write-Host ""
        Write-Host "DRY RUN. Would: UPDATE Theme Id=$themeId"
        Write-Host "Re-run with -Apply to execute."
        return
    }

    # -- Write -------------------------------------------------------------------
    $writeCommand = New-Command -Connection $connection -Sql @"
UPDATE [dbo].[Theme]
SET [AdditionalSettingsJson] = @json, [ModifiedDateTime] = SYSDATETIME()
WHERE [Id] = @id;
"@
    $writeCommand.Parameters.AddWithValue("@json", $newJson) | Out-Null
    $writeCommand.Parameters.AddWithValue("@id", $themeId) | Out-Null

    $affected = $writeCommand.ExecuteNonQuery()
    if ($affected -ne 1) {
        throw "Expected to update exactly 1 row, updated $affected. Run the rollback and investigate."
    }
    Write-Host "Updated Theme Id=$themeId."

    Write-Host ""
    Write-Host "Rock caches the generated theme.css. The new values are not visible until"
    Write-Host "that cache is cleared or the app pool recycles."
}
finally {
    $connection.Close()
}
