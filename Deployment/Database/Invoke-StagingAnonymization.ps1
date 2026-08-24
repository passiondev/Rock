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

    WHO IS LEFT ALONE

    A catalog where every address is undeliverable cannot be used to test the
    thing staging most needs testing: that mail goes out and arrives. It also
    locks out the people doing the testing, because Rock authenticates against
    UserLogin.UserName and most of those are addresses.

    -KeepEmailDomains names the domains that stay real. Rows whose address is on
    one of them are skipped -- the person keeps their email, their phone number,
    their alternate addresses and their login. Everybody else is anonymized,
    logins included.

    The allowlist makes the environment safer rather than less safe. After it
    runs, the only addresses staging can reach belong to the people who agreed to
    be reached, so the classic staging accident -- a test communication that goes
    to the real recipient list -- delivers to the testers instead of to the
    congregation.

    It is a domain match, not a person match, and that is the whole of its
    accuracy. A tester whose Rock login is a personal address is not on a staff
    domain, so it will be anonymized and they will not be able to sign in. Check
    the per-domain kept counts the dry run prints before approving the apply.

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

.PARAMETER KeepEmailDomains
    Email domains whose rows are left holding their real values, so the people who
    test on staging can still sign in, see themselves, and receive mail. Bare
    domains, no leading @ needed -- 'staff.example' and '@staff.example' are the
    same thing. Empty means anonymize everyone, which is the old behaviour and the
    safer default of the two.

    Validated against a domain pattern before use. These are concatenated into SQL
    and there is no parameter to bind them to, because a LIKE pattern assembled
    per target is not a value.

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

.EXAMPLE
    # Leave the staff domain reachable so testers can sign in and receive mail.
    ./Invoke-StagingAnonymization.ps1 -ExpectedCatalog RockStaging20260824 `
        -KeepEmailDomains 'staff.example', 'staff.example.org' -Apply
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
    [string[]]
    $KeepEmailDomains = @(),

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

# The allowlist, normalized and checked before a single character of it reaches a
# query. Every other value this script sends to SQL Server is a literal it wrote
# itself; these came from a dispatch box, and they are spliced into LIKE patterns
# rather than bound as parameters, because a pattern assembled per target is not a
# value a parameter can carry.
#
# So the pattern below is the boundary. It admits letters, digits, hyphens and dots
# in the shape of a hostname and nothing else -- no quote, no semicolon, no comment
# marker, nothing that can close a literal and start a statement.
$DomainPattern = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'

$normalizedKeepDomains = @()
foreach ($keepDomain in $KeepEmailDomains) {
    if ([string]::IsNullOrWhiteSpace($keepDomain)) {
        continue
    }

    $candidate = $keepDomain.Trim().TrimStart('@').ToLowerInvariant()
    if ($candidate -notmatch $DomainPattern) {
        throw "Not a domain: '$keepDomain'. Pass bare domains such as 'staff.example'. Only letters, digits, hyphens and dots are accepted, because these are concatenated into SQL."
    }
    if ($normalizedKeepDomains -notcontains $candidate) {
        $normalizedKeepDomains += $candidate
    }
}

function Get-ComputedColumnAssignment {
    <#
        .SYNOPSIS
            Names any computed column a SetClause tries to write.

        .DESCRIPTION
            SQL Server rejects "UPDATE ... SET <computed> = ..." when it binds the
            statement, before it touches a row. That timing is the problem: the dry
            run only ever issues COUNT(*) against the predicate, so it never binds
            the SetClause and reports a clean plan. The failure then surfaces
            halfway through the apply, with every earlier target already committed
            and no transaction spanning them.

            That is exactly how RockStaging20260824 ended up with Person.Email
            rewritten and nothing else, on 2026-08-24: PhoneNumber.NumberReversed is
            declared AS (reverse([Number])) PERSISTED.

            Ask the catalog rather than parsing the SQL. sys.computed_columns is
            authoritative and per-catalog, so this also catches local drift where a
            column is computed here but not in CreateDatabase.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Table,
        [Parameter(Mandatory = $true)][string] $SetClause,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    # $Table is a literal from $AnonymizationTargets, never an argument, so it is
    # not an injection path. Kept as interpolation to match the rest of the script.
    $computedColumns = Invoke-Rows -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Query @"
SELECT c.[name] AS ColumnName
FROM sys.computed_columns c
WHERE c.[object_id] = OBJECT_ID('$Table');
"@

    $offenders = @()
    foreach ($computedColumn in $computedColumns) {
        # Property access, not an indexer. Invoke-Rows hands back [pscustomobject]
        # rows, and those have no indexer, so $row['ColumnName'] throws "Unable to
        # index into an object of type System.Management.Automation.PSObject" the
        # moment a table actually has a computed column. That is a live-connection
        # failure the text assertions in the Python suite cannot see, which is why
        # ComputedColumnGuard.Tests.ps1 exercises this function for real.
        $columnName = [string]$computedColumn.ColumnName
        if ([string]::IsNullOrWhiteSpace($columnName)) {
            continue
        }

        # Match "Name =" only where Name starts an assignment: at the head of the
        # clause, or after a comma or newline. Without that anchor, a column named
        # in an expression on the right-hand side reads as an assignment to it.
        $escapedName = [regex]::Escape($columnName)
        if ($SetClause -match "(?im)(^|[,\r\n])\s*\[?$escapedName\]?\s*=") {
            $offenders += $columnName
        }
    }

    return ,$offenders
}


function Get-DomainExclusion {
    <#
        .SYNOPSIS
            A predicate fragment that skips rows whose address column ends in one
            of the allowlisted domains.

        .DESCRIPTION
            Returns an empty string when the allowlist is empty, so the predicates
            it is spliced into are character-for-character what they were before
            this parameter existed. An allowlist nobody uses changes no SQL.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Column,
        [Parameter(Mandatory = $false)][string[]] $Domains = @()
    )

    if ($null -eq $Domains -or $Domains.Count -eq 0) {
        return ""
    }

    $clauses = @( $Domains | ForEach-Object { "$Column NOT LIKE '%@$_'" } )
    return " AND (" + ($clauses -join " AND ") + ")"
}

function Get-PersonDomainExclusion {
    <#
        .SYNOPSIS
            The same exclusion for a table that has no address of its own, resolved
            through the person the row belongs to.

        .DESCRIPTION
            PhoneNumber holds no email, so whether a number is a tester's cannot be
            read off the row. NOT EXISTS rather than NOT IN: PersonId is not
            nullable today, but NOT IN against a subquery that ever yields a NULL
            returns no rows at all, and that failure mode is silent -- it would read
            as "nothing left to anonymize".
    #>
    param(
        [Parameter(Mandatory = $true)][string] $PersonIdColumn,
        [Parameter(Mandatory = $false)][string[]] $Domains = @()
    )

    if ($null -eq $Domains -or $Domains.Count -eq 0) {
        return ""
    }

    $clauses = @( $Domains | ForEach-Object { "keepPerson.Email LIKE '%@$_'" } )
    return " AND NOT EXISTS (SELECT 1 FROM dbo.Person keepPerson WHERE keepPerson.Id = $PersonIdColumn AND (" + ($clauses -join " OR ") + "))"
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

function Invoke-Rows {
    <#
        .SYNOPSIS
            Runs a query and returns its rows as objects.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection] $Connection,
        [Parameter(Mandatory = $true)][string] $Query,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds

        $rows = @()
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                    $value = $reader.GetValue($index)
                    if ($value -is [System.DBNull]) {
                        $value = $null
                    }
                    $row[$reader.GetName($index)] = $value
                }
                $rows += [pscustomobject]$row
            }
        }
        finally {
            $reader.Dispose()
        }

        # Leading comma on purpose. PowerShell unrolls a returned collection, so a
        # single-row result would come back as a bare object and a caller iterating
        # it would walk its properties instead of its rows. Same trap
        # Find-LegacyTextColumns.ps1 fell into.
        return ,$rows
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
#
# Each predicate also carries the allowlist, spliced in as a fragment computed
# once here. It is the same fragment for the count and for the UPDATE because they
# read the same string, which is the property that keeps the number the approver
# saw and the number of rows destroyed the same number.
$personEmailKeep = Get-DomainExclusion -Column 'Email' -Domains $normalizedKeepDomains
$searchValueKeep = Get-DomainExclusion -Column 'SearchValue' -Domains $normalizedKeepDomains
$userNameKeep    = Get-DomainExclusion -Column 'UserName' -Domains $normalizedKeepDomains
$phoneNumberKeep = Get-PersonDomainExclusion -PersonIdColumn 'dbo.PhoneNumber.PersonId' -Domains $normalizedKeepDomains

# Communication is deliberately absent from that list. Those columns are the record
# of mail already sent, not a way to reach anybody, and a tester reading their own
# history wants to see that a message exists rather than who its envelope named. It
# is anonymized whole.
$AnonymizationTargets = @(
    @{
        Name      = 'Person.Email'
        Table     = 'dbo.Person'
        # Rock indexes Email (IX_Email) and matches on it during duplicate
        # detection, so the substitute has to stay unique per person.
        Predicate = "Email IS NOT NULL AND Email <> '' AND Email NOT LIKE '%@staging.invalid'$personEmailKeep"
        SetClause = "Email = 'person' + CAST(Id AS varchar(12)) + '@staging.invalid'"
    },
    @{
        Name      = 'PhoneNumber (Number, NumberFormatted, FullNumber, Extension)'
        Table     = 'dbo.PhoneNumber'
        # Two columns here hold the real number without looking like phone number
        # columns, and they have to be handled in opposite ways.
        #
        # NumberReversed exists so that "ends with" searches can use an index. It is
        # not assigned here because it cannot be: CreateDatabase declares it
        # [NumberReversed] AS (reverse([Number])) PERSISTED, and SQL Server rejects
        # an UPDATE that writes a computed column. Rewriting Number is what clears
        # it -- the engine recomputes the reverse from the new value, which is both
        # correct and impossible to get out of step. Get-ComputedColumnAssignment
        # enforces that this stays true.
        #
        # FullNumber is the opposite trap, and the more dangerous one, because it
        # reads as computed and is not. The column is a plain [nvarchar](23) NOT
        # NULL; only the C# property computes it, as CountryCode + Number behind a
        # private setter that EF fills on save. Raw SQL never runs that, so an
        # UPDATE that rewrites Number alone leaves FullNumber holding the real
        # number -- indexed by IX_FullNumber, and matched directly by
        # PersonService.GetPersonFromMobilePhoneNumber and the SMS action pipeline.
        # Staging would still resolve a real number to the right person. So it is
        # assigned, reproducing the C# concatenation exactly: a null CountryCode
        # concatenates as empty in C# but poisons the whole expression in SQL,
        # hence ISNULL.
        #
        # The predicate carries a second arm for the same reason. Keying only on
        # Number would make a row whose Number is already a substitute invisible to
        # a later run, stranding whatever FullNumber still holds. The second arm
        # asks the leak question directly -- FullNumber disagrees with the number it
        # is supposed to mirror -- so the target repairs drift instead of skipping
        # it, and still settles to zero rows once everything agrees.
        Predicate = "((Number IS NOT NULL AND Number <> '' AND Number <> ('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7))) OR (FullNumber <> '' AND FullNumber <> ISNULL(CountryCode, '') + ISNULL(Number, '')))$phoneNumberKeep"
        SetClause = @"
Number = '555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7),
            NumberFormatted = '(555) ' + SUBSTRING('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7), 4, 3) + '-' + RIGHT('555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7), 4),
            FullNumber = ISNULL(CountryCode, '') + '555' + RIGHT('0000000' + CAST(Id AS varchar(10)), 7),
            Extension = NULL
"@
    },
    @{
        Name      = 'PersonSearchKey.SearchValue (email-shaped)'
        Table     = 'dbo.PersonSearchKey'
        # Alternate addresses recorded for search. The type is a DefinedValue and
        # the ids differ per install, so this matches on shape instead: anything
        # containing an @ is treated as an address.
        Predicate = "SearchValue IS NOT NULL AND SearchValue LIKE '%@%' AND SearchValue NOT LIKE '%@staging.invalid'$searchValueKeep"
        SetClause = "SearchValue = 'search' + CAST(Id AS varchar(12)) + '@staging.invalid'"
    },
    @{
        Name      = 'UserLogin.UserName (email-shaped)'
        Table     = 'dbo.UserLogin'
        # This is what Rock authenticates against -- Person.Email is not a
        # credential, UserName is -- so it is the column that decides who can sign
        # in to staging. Anonymizing it locks out everybody it touches, which is the
        # intent: a staging box that the whole congregation can still sign in to
        # with their production password is a second production login page.
        #
        # Shape-matched rather than type-matched. Rock stores every provider's
        # logins in this one table and only some of them are addresses; a UserName
        # with no @ is not contact data and is left alone.
        #
        # UserName carries a unique index, so the substitute has to be unique per
        # row and not merely unique per person. Id gives that for free.
        Predicate = "UserName IS NOT NULL AND UserName LIKE '%@%' AND UserName NOT LIKE '%@staging.invalid'$userNameKeep"
        SetClause = "UserName = 'user' + CAST(Id AS varchar(12)) + '@staging.invalid'"
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
    @{ Name = 'Location (street addresses present)';   Query = "SELECT COUNT(*) FROM dbo.Location WHERE Street1 IS NOT NULL AND Street1 <> ''" }
)

# What the catalog actually holds, by domain. Printed so the allowlist can be
# checked against reality instead of against memory.
#
# A misspelled domain is the failure this catches, and it is a quiet one: the
# allowlist matches nothing, every row is anonymized, the run reports success, and
# the testers find out when they cannot sign in -- by which point the rollback is a
# 119 GiB restore. Read before the apply it is a spelling check; read after, it is
# the proof that only the allowlisted domains survived.
#
# Counts of domains, not addresses. Aggregate, so it is safe in a job summary.
$DomainCensusQuery = @"
SELECT TOP 25
    LOWER(LTRIM(RTRIM(SUBSTRING(Email, CHARINDEX('@', Email) + 1, 255)))) AS Domain,
    COUNT(*) AS People
FROM dbo.Person
WHERE Email IS NOT NULL AND Email <> '' AND CHARINDEX('@', Email) > 0
GROUP BY LOWER(LTRIM(RTRIM(SUBSTRING(Email, CHARINDEX('@', Email) + 1, 255))))
ORDER BY COUNT(*) DESC;
"@

$connection = New-Object System.Data.SqlClient.SqlConnection $resolvedConnectionString
$summary = [ordered]@{
    catalog        = ""
    dataSourceHost = $dataSourceHost
    mode           = if ($Apply) { "apply" } else { "dry-run" }
    startedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
    keptDomains    = @($normalizedKeepDomains)
    keptByDomain   = @()
    emailDomains   = @()
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

    # Restated against the catalog rather than against the argument. "I passed the
    # domain" and "the domain matches somebody" are different claims, and only the
    # second one keeps a tester able to sign in.
    if ($normalizedKeepDomains.Count -eq 0) {
        Write-Host "Keep:     nothing -- every address, number and login in this catalog will be anonymized."
    }
    else {
        Write-Host "Keep:     $($normalizedKeepDomains -join ', ')"
        foreach ($keepDomain in $normalizedKeepDomains) {
            $keptPeople = Invoke-Scalar -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds `
                -Query "SELECT COUNT(*) FROM dbo.Person WHERE Email LIKE '%@$keepDomain'"
            $keptLogins = Invoke-Scalar -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds `
                -Query "SELECT COUNT(*) FROM dbo.UserLogin WHERE UserName LIKE '%@$keepDomain'"

            Write-Host ("          {0,-40} {1,8:N0} person(s), {2,7:N0} login(s) kept" -f $keepDomain, $keptPeople, $keptLogins)
            if ($keptPeople -eq 0 -and $keptLogins -eq 0) {
                Write-Host ("          {0,-40} >>> MATCHES NOTHING. Check the spelling before approving." -f "")
            }

            $summary.keptByDomain += [ordered]@{ domain = $keepDomain; people = $keptPeople; logins = $keptLogins }
        }
    }
    Write-Host ""

    # Bind-time check for every target before any of them runs. Whole-catalog, and
    # ahead of the first write, because the point is to fail while nothing has been
    # rewritten rather than between two targets.
    $computedColumnFaults = @()
    foreach ($target in $AnonymizationTargets) {
        $offenders = Get-ComputedColumnAssignment -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds `
            -Table $target.Table -SetClause $target.SetClause
        foreach ($offender in $offenders) {
            $computedColumnFaults += "$($target.Table).$offender"
        }
    }

    if ($computedColumnFaults.Count -gt 0) {
        throw ("Refusing to run: these are computed columns and SQL Server will reject any UPDATE that writes them -- " +
            ($computedColumnFaults -join ', ') +
            ". Remove them from the SetClause; rewriting the column they are computed from is what clears them.")
    }

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
    Write-Host "Email domains in dbo.Person, top 25 by count:"
    $census = Invoke-Rows -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query $DomainCensusQuery
    foreach ($censusRow in $census) {
        $marker = ""
        if ($normalizedKeepDomains -contains $censusRow.Domain) {
            $marker = "<- kept"
        }
        Write-Host ("  {0,-50} {1,12:N0}  {2}" -f $censusRow.Domain, $censusRow.People, $marker)
        $summary.emailDomains += [ordered]@{ domain = $censusRow.Domain; people = $censusRow.People }
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
