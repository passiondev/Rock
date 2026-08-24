<#
.SYNOPSIS
    Replaces email addresses and phone numbers in a prod-derived staging catalog
    with deterministic, undeliverable substitutes. Dry run unless -Apply.

.DESCRIPTION
    Staging is seeded from a production backup, so on the day it is restored it
    holds every real congregant's email address and phone number. Rock is a system
    whose whole purpose is contacting those people, and a staging box is exactly
    where somebody tests a communication. This script removes the ability to reach
    a real person from staging, rather than relying on nobody pressing send.

    Substitutes are derived from the row's own Id, which buys three things:

      1. Reruns are idempotent. The same row always produces the same substitute,
         so a second pass changes nothing and the WHERE clauses below can exclude
         already-anonymized rows cheaply.
      2. Rows stay distinguishable. Blanking every address to one value collapses
         duplicate detection, merge review and any per-person grouping into
         nonsense, and staging stops resembling production in the ways that matter
         for testing.
      3. Nothing has to be stored to reverse it, which is the point -- see the
         rollback note below.

    Addresses land in `.invalid`, reserved by RFC 2606 precisely so it can never
    resolve. Phone numbers are given 555 as their area code, which the NANP does
    not assign and never will, so they cannot be dialled.

    Note that this is not the NANP's 555-01xx fiction range, which lives in the
    subscriber number rather than the area code. That range holds 100 numbers,
    and 100 numbers across a congregation would collapse every phone-based lookup
    in Rock into one bucket. An unassignable area code is equally undiallable and
    leaves the whole subscriber number free to keep rows distinct.

.NOTES
    ROLLBACK IS THE .bak, NOT A PRE-IMAGE TABLE.

    The house rule for a write script is a generated rollback that restores the
    previous values row by row. That rule is wrong here, and following it would
    defeat the operation: a pre-image table mapping every Id to its real email
    address and phone number is the same PII this script exists to remove, sitting
    in the same catalog, one SELECT away. It would leave staging holding the
    congregation's contact details under a different table name.

    So there is no pre-image. Reversal is re-importing the pristine `.bak` that
    seeded the catalog, which is already in GCS and is a faithful copy by
    construction. That is slower than an UPDATE but it is the only form of
    reversal that does not recreate the exposure.

    Do not add a pre-image table to this script.

.PARAMETER ConnectionString
    Full SQL Server connection string. Prefer the environment variable below -- an
    argument lands in shell history, in the scrollback and in the process list.

.PARAMETER ExpectedCatalog
    The catalog this is meant to run against. Compared against DB_NAME() and the
    run is refused if they differ. Mandatory, and deliberately not defaulted: the
    sandbox instance holds a catalog called RockConnectProd whose name is identical
    to production's, so the name alone cannot tell you which server you reached.
    Naming it is how the operator states intent.

.PARAMETER Apply
    Actually write. Without it the script reports what it would change and touches
    nothing.

.PARAMETER BatchSize
    Rows per UPDATE. The Person and PhoneNumber tables on a prod-derived catalog
    are large enough that one statement per table would hold a lock for minutes and
    grow the log by the size of the table. Batched, each transaction is small and
    the log can be reused between batches.

.PARAMETER OutFile
    Write the summary as JSON as well as printing it.

.EXAMPLE
    $env:ROCK_DB_CONNECTION_STRING = "Server=...;Initial Catalog=RockStaging20260824;..."
    ./Invoke-StagingAnonymization.ps1 -ExpectedCatalog RockStaging20260824
    # dry run: reports counts, changes nothing

.EXAMPLE
    ./Invoke-StagingAnonymization.ps1 -ExpectedCatalog RockStaging20260824 -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]
    $ConnectionString,

    [Parameter(Mandatory = $true)]
    [string]
    $ExpectedCatalog,

    [Parameter(Mandatory = $false)]
    [switch]
    $Apply,

    [Parameter(Mandatory = $false)]
    [int]
    $BatchSize = 25000,

    [Parameter(Mandatory = $false)]
    [string]
    $OutFile,

    [Parameter(Mandatory = $false)]
    [int]
    $CommandTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolved once and never written to output. Everything printed below is derived
# from query results, not from the string that got us there.
$resolvedConnectionString = $ConnectionString
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    $resolvedConnectionString = [Environment]::GetEnvironmentVariable("ROCK_DB_CONNECTION_STRING")
}
if ([string]::IsNullOrWhiteSpace($resolvedConnectionString)) {
    throw "No connection string. Set ROCK_DB_CONNECTION_STRING, or pass -ConnectionString."
}

Add-Type -AssemblyName System.Data | Out-Null

# The production instance, by address. Checked before anything else runs.
#
# The catalog-name check further down cannot do this job on its own: the sandbox
# instance hosts a catalog called RockConnectProd, character for character the same
# name production uses, so -ExpectedCatalog RockConnectProd is satisfied on either
# server. The addresses are what actually differ. 172.20.0.8 is connect-prod;
# 172.20.0.2 is connect-restore-test.
#
# A denylist rather than an allowlist on purpose. An allowlist fails closed when a
# legitimate new sandbox appears, and the predictable response to that is someone
# editing this constant under time pressure -- which is exactly when you want the
# production entry to still be here.
$ProductionDataSources = @('172.20.0.8')

function Get-DataSourceHost {
    <#
        .SYNOPSIS
            Pulls the host out of a connection string's Data Source, without the
            protocol prefix, instance name or port.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $ConnectionStringValue
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder $ConnectionStringValue
    $dataSource = $builder.DataSource
    if ([string]::IsNullOrWhiteSpace($dataSource)) {
        return ""
    }

    # "tcp:172.20.0.8,1433\INSTANCE" -> "172.20.0.8"
    $value = $dataSource
    if ($value.Contains(':')) {
        $value = $value.Substring($value.IndexOf(':') + 1)
    }
    foreach ($separator in @(',', '\')) {
        if ($value.Contains($separator)) {
            $value = $value.Substring(0, $value.IndexOf($separator))
        }
    }

    return $value.Trim()
}

$dataSourceHost = Get-DataSourceHost -ConnectionStringValue $resolvedConnectionString
if ($ProductionDataSources -contains $dataSourceHost) {
    throw "Refusing to run: $dataSourceHost is the production instance. This script destroys contact data."
}

function Invoke-Scalar {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Query,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds
        $value = $command.ExecuteScalar()
        if ($null -eq $value -or $value -is [System.DBNull]) {
            return 0
        }
        return [int64]$value
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-NonQuery {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Query,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds
        return $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

# Each target is a table, the predicate that finds rows still holding real data,
# and the SET clause that replaces it. Kept as data rather than as a run of
# hand-written blocks so the dry run and the apply path cannot drift apart -- both
# read this same list, and the dry run's count is literally the apply path's
# predicate.
#
# Every predicate excludes rows that already carry their substitute, so a rerun is
# a no-op and an interrupted run resumes where it stopped.
$AnonymizationTargets = @(
    @{
        Name      = 'Person.Email'
        Table     = 'dbo.Person'
        # Rock indexes Email (IX_Email) and matches on it during duplicate
        # detection, so the substitute has to stay unique per person.
        Predicate = "Email IS NOT NULL AND Email <> '' AND Email NOT LIKE '%@staging.invalid'"
        SetClause = "Email = 'person' + CAST(Id AS varchar(12)) + '@staging.invalid'"
    },
    @{
        Name      = 'PhoneNumber (Number, NumberFormatted, NumberReversed, Extension)'
        Table     = 'dbo.PhoneNumber'
        # NumberReversed is the one that gets forgotten. Rock maintains it to make
        # "ends with" searches indexable, so leaving it holding the reverse of the
        # real number leaves the real number in the catalog, searchable, under a
        # column nobody thinks of as a phone number.
        Predicate = "Number IS NOT NULL AND Number <> '' AND Number <> ('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7))"
        SetClause = @"
Number = '555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7),
            NumberFormatted = '(555) ' + SUBSTRING('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7), 4, 3) + '-' + RIGHT('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7), 4),
            NumberReversed = REVERSE('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7)),
            Extension = NULL
"@
    },
    @{
        Name      = 'PersonSearchKey.SearchValue (email-shaped)'
        Table     = 'dbo.PersonSearchKey'
        # Alternate addresses recorded for search. The type is a DefinedValue and
        # the ids differ per install, so this matches on shape instead: anything
        # containing an @ is treated as an address.
        Predicate = "SearchValue IS NOT NULL AND SearchValue LIKE '%@%' AND SearchValue NOT LIKE '%@staging.invalid'"
        SetClause = "SearchValue = 'search' + CAST(Id AS varchar(12)) + '@staging.invalid'"
    },
    @{
        Name      = 'Communication.FromEmail / ReplyToEmail'
        Table     = 'dbo.Communication'
        Predicate = "(FromEmail IS NOT NULL AND FromEmail <> '' AND FromEmail NOT LIKE '%@staging.invalid') OR (ReplyToEmail IS NOT NULL AND ReplyToEmail <> '' AND ReplyToEmail NOT LIKE '%@staging.invalid')"
        SetClause = @"
FromEmail = CASE WHEN FromEmail IS NOT NULL AND FromEmail <> '' THEN 'noreply@staging.invalid' ELSE FromEmail END,
            ReplyToEmail = CASE WHEN ReplyToEmail IS NOT NULL AND ReplyToEmail <> '' THEN 'noreply@staging.invalid' ELSE ReplyToEmail END
"@
    },
    @{
        Name      = 'Communication.CCEmails / BCCEmails'
        Table     = 'dbo.Communication'
        # Lists rather than single addresses, so there is no per-row substitute
        # that keeps their shape meaningful. Emptied instead.
        Predicate = "(CCEmails IS NOT NULL AND CCEmails <> '') OR (BCCEmails IS NOT NULL AND BCCEmails <> '')"
        SetClause = "CCEmails = '', BCCEmails = ''"
    }
)

# Columns that hold contact details inside free text or serialized values. Counted
# and reported, never rewritten.
#
# A regex sweep over these would be a guess dressed as a guarantee: it cannot tell
# a congregant's address in a note from one in a template's example block, and a
# partial scrub reads as a completed one. Naming them here, with counts, is more
# honest than a pass that half-works -- and the counts tell you whether the
# residue is a handful of rows or a real exposure.
$ResidualPiiProbes = @(
    @{ Name = 'Communication.Message (body text)';     Query = "SELECT COUNT(*) FROM dbo.Communication WHERE Message LIKE '%@%'" },
    @{ Name = 'CommunicationTemplate.Message';         Query = "SELECT COUNT(*) FROM dbo.CommunicationTemplate WHERE Message LIKE '%@%'" },
    @{ Name = 'Note.Text';                             Query = "SELECT COUNT(*) FROM dbo.Note WHERE Text LIKE '%@%'" },
    @{ Name = 'History (OldValue / NewValue)';         Query = "SELECT COUNT(*) FROM dbo.History WHERE OldValue LIKE '%@%' OR NewValue LIKE '%@%'" },
    @{ Name = 'AttributeValue.Value';                  Query = "SELECT COUNT(*) FROM dbo.AttributeValue WHERE Value LIKE '%@%'" },
    @{ Name = 'Location (street addresses present)';   Query = "SELECT COUNT(*) FROM dbo.Location WHERE Street1 IS NOT NULL AND Street1 <> ''" },
    @{ Name = 'UserLogin.UserName (email-shaped)';     Query = "SELECT COUNT(*) FROM dbo.UserLogin WHERE UserName LIKE '%@%'" }
)

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
$summary = [ordered]@{
    catalog        = ""
    dataSourceHost = $dataSourceHost
    mode           = if ($Apply) { "apply" } else { "dry-run" }
    startedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
    targets        = @()
    residualPii    = @()
}

try {
    $connection.Open()

    $catalogCommand = $connection.CreateCommand()
    try {
        $catalogCommand.CommandText = "SELECT DB_NAME();"
        $actualCatalog = [string]$catalogCommand.ExecuteScalar()
    }
    finally {
        $catalogCommand.Dispose()
    }

    $summary.catalog = $actualCatalog

    # Second gate. The first was the instance address; this one is the operator
    # naming the catalog and being held to it.
    if ($actualCatalog -ne $ExpectedCatalog) {
        throw "Refusing to run: connected to '$actualCatalog' but -ExpectedCatalog said '$ExpectedCatalog'."
    }

    Write-Host "Catalog:  $actualCatalog"
    Write-Host "Instance: $dataSourceHost"
    Write-Host "Mode:     $($summary.mode)"
    Write-Host ""

    foreach ($target in $AnonymizationTargets) {
        $pending = Invoke-Scalar -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds `
            -Query "SELECT COUNT(*) FROM $($target.Table) WHERE $($target.Predicate)"

        $entry = [ordered]@{
            name    = $target.Name
            pending = $pending
            updated = 0
        }

        if (-not $Apply) {
            Write-Host ("  {0,-58} {1,12:N0} row(s) would change" -f $target.Name, $pending)
            $summary.targets += $entry
            continue
        }

        if ($pending -eq 0) {
            Write-Host ("  {0,-58} {1,12} " -f $target.Name, "already clean")
            $summary.targets += $entry
            continue
        }

        # TOP (n) with the same predicate the count used. Each pass removes rows
        # from its own predicate, so the loop terminates without a marker column
        # or a keyset to page through.
        $totalUpdated = 0
        do {
            $affected = Invoke-NonQuery -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query @"
UPDATE TOP ($BatchSize) $($target.Table)
SET $($target.SetClause)
WHERE $($target.Predicate);
"@
            $totalUpdated += $affected
            if ($affected -gt 0) {
                Write-Host ("    {0,-56} {1,12:N0} / {2:N0}" -f $target.Name, $totalUpdated, $pending)
            }
        } while ($affected -gt 0)

        $entry.updated = $totalUpdated
        $summary.targets += $entry
    }

    Write-Host ""
    Write-Host "Residual PII (reported, not rewritten -- see .NOTES):"
    foreach ($probe in $ResidualPiiProbes) {
        # A missing table is not a failure. Plugin tables come and go between Rock
        # versions and the probe list is deliberately broader than any one schema.
        try {
            $count = Invoke-Scalar -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query $probe.Query
            Write-Host ("  {0,-58} {1,12:N0} row(s)" -f $probe.Name, $count)
            $summary.residualPii += [ordered]@{ name = $probe.Name; rows = $count }
        }
        catch {
            Write-Host ("  {0,-58} {1,12}" -f $probe.Name, "unavailable")
            $summary.residualPii += [ordered]@{ name = $probe.Name; rows = $null }
        }
    }

    Write-Host ""
    if ($Apply) {
        $changed = ($summary.targets | ForEach-Object { $_.updated } | Measure-Object -Sum).Sum
        Write-Host "Applied. $changed row(s) rewritten."
    }
    else {
        $would = ($summary.targets | ForEach-Object { $_.pending } | Measure-Object -Sum).Sum
        Write-Host "Dry run. $would row(s) would be rewritten. Re-run with -Apply to write."
    }
}
finally {
    $connection.Dispose()
}

$summary.completedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

if (![string]::IsNullOrWhiteSpace($OutFile)) {
    $summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutFile -Encoding UTF8 -Force
    Write-Host "Wrote $OutFile"
}
