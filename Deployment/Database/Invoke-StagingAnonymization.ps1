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

function ConvertTo-KeepDomain {
    <#
        .SYNOPSIS
            The -KeepEmailDomains allowlist as bare lowercase domains, or a
            terminating error if any entry is not shaped like one.

        .DESCRIPTION
            Every other value this script sends to SQL Server is a literal it
            wrote itself. These came from a dispatch box, and they are spliced
            into LIKE patterns rather than bound as parameters, because a pattern
            assembled per target is not a value a parameter can carry. So this is
            the boundary, and it runs before a connection exists: a refused
            domain never reaches a query, and never reaches a server either.

            Blank entries are dropped and repeats collapsed, so 'staff.example'
            and '@Staff.Example' are one domain and the per-domain report counts
            it once.

        .PARAMETER Domain
            The allowlist as the operator typed it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)][string[]] $Domain = @()
    )

    # Letters, digits, hyphens and dots in the shape of a hostname and nothing
    # else -- no quote, no semicolon, no comment marker, nothing that can close a
    # literal and start a statement.
    $domainPattern = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'

    $normalized = @()
    foreach ($candidateDomain in $Domain) {
        if ([string]::IsNullOrWhiteSpace($candidateDomain)) {
            continue
        }

        $candidate = $candidateDomain.Trim().TrimStart('@').ToLowerInvariant()
        if ($candidate -notmatch $domainPattern) {
            throw "Not a domain: '$candidateDomain'. Pass bare domains such as 'staff.example'. Only letters, digits, hyphens and dots are accepted, because these are concatenated into SQL."
        }
        if ($normalized -notcontains $candidate) {
            $normalized += $candidate
        }
    }

    # Leading comma so an empty list comes back as an empty array rather than as
    # nothing at all. The caller counts it, and under strict mode $null.Count is
    # an error rather than a zero.
    return ,$normalized
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

        .PARAMETER Sql
            The SQL adapter Invoke-StagingAnonymization was given. Only its Rows
            operation is used.

        .PARAMETER Connection
            Whatever the adapter's Open handed back. Untyped because the adapter,
            not this function, decides what a connection is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $true)][string] $Table,
        [Parameter(Mandatory = $true)][string] $SetClause,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    # $Table is a literal from Get-AnonymizationTarget, never an argument, so it is
    # not an injection path. Kept as interpolation to match the rest of the script.
    $computedColumns = & $Sql.Rows -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Query @"
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
        # failure no text assertion can see, which is why ComputedColumnGuard.Tests.ps1
        # runs this function against rows shaped the way Invoke-Rows shapes them.
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

function Get-PhoneShapedPredicate {
    <#
        .SYNOPSIS
            A predicate that matches a North-American phone number written into
            free text, across the three separators people actually type.

        .DESCRIPTION
            LIKE with [0-9] classes rather than a regex, because T-SQL has no
            regex operator and enabling the CLR one on a restored production
            catalog is a bigger change than a count is worth. The shapes are
            nnn-nnn-nnnn, (nnn) nnn-nnnn and nnn.nnn.nnnn.

            Deliberately tight, and it under-reports on purpose. Ten digits in
            any arrangement would also match order numbers, giving amounts in
            cents, and most of the timestamps in a serialized attribute value;
            a probe that fires on every row says nothing about whether phone PII
            survived. An unseparated 4045551234 is therefore missed. The count
            is a floor on the residue, not a census of it, and the report reads
            it as one.

            Every shape for every column is OR'd into one predicate so the
            caller scans each table once. These run against Note, History and
            AttributeValue, where a second full scan is not free.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $Column
    )

    # Parentheses and the literal dot need no escaping in LIKE. Only [ would,
    # and every [ below opens a character class on purpose. The dot matches a
    # literal dot here, not "any character" -- LIKE is not a regex, which is the
    # one way this pattern is easier to read than its regex equivalent.
    $shapes = @(
        "[0-9][0-9][0-9]-[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]",
        "([0-9][0-9][0-9]) [0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]",
        "[0-9][0-9][0-9].[0-9][0-9][0-9].[0-9][0-9][0-9][0-9]"
    )

    $clauses = @(
        foreach ($columnName in $Column) {
            foreach ($shape in $shapes) {
                "$columnName LIKE '%$shape%'"
            }
        }
    )
    return "(" + ($clauses -join " OR ") + ")"
}

function Get-AnonymizationTarget {
    <#
        .SYNOPSIS
            Every table the run rewrites: the predicate that finds rows still
            holding real data, and the SET clause that replaces it.

        .DESCRIPTION
            Kept as data rather than as a run of hand-written blocks so the dry run
            and the apply path cannot drift apart -- both read this same list, and
            the dry run's count is literally the apply path's predicate.

            Every predicate excludes rows that already carry their substitute, so a
            rerun is a no-op and an interrupted run resumes where it stopped.

            Each predicate also carries the allowlist, spliced in as a fragment
            computed once here. It is the same fragment for the count and for the
            UPDATE because they read the same string, which is the property that
            keeps the number the approver saw and the number of rows destroyed the
            same number.

        .PARAMETER KeepDomain
            Domains already through ConvertTo-KeepDomain. Never raw input: these
            are spliced into the predicates as they stand.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory = $false)][string[]] $KeepDomain = @()
    )

    $personEmailKeep = Get-DomainExclusion -Column 'Email' -Domains $KeepDomain
    $searchValueKeep = Get-DomainExclusion -Column 'SearchValue' -Domains $KeepDomain
    $userNameKeep    = Get-DomainExclusion -Column 'UserName' -Domains $KeepDomain
    $phoneNumberKeep = Get-PersonDomainExclusion -PersonIdColumn 'dbo.PhoneNumber.PersonId' -Domains $KeepDomain

    # Communication is deliberately absent from that list. Those columns are the
    # record of mail already sent, not a way to reach anybody, and a tester reading
    # their own history wants to see that a message exists rather than who its
    # envelope named. It is anonymized whole.
    $targets = @(
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

    return ,$targets
}

function Get-ResidualPiiProbe {
    <#
        .SYNOPSIS
            Queries that count contact details held inside free text or serialized
            values. Counted and reported, never rewritten.

        .DESCRIPTION
            A regex sweep over these would be a guess dressed as a guarantee: it
            cannot tell a congregant's address in a note from one in a template's
            example block, and a partial scrub reads as a completed one. Naming them
            here, with counts, is more honest than a pass that half-works -- and the
            counts tell you whether the residue is a handful of rows or a real
            exposure.

            Both halves of the request get a probe. Until now every probe here was
            email-shaped except the address one, so the phone columns the run
            rewrites had no residual reporting at all: the report could show a clean
            sweep of PhoneNumber while a number sat in the note attached to it. The
            '(email-shaped)' and '(phone-shaped)' suffixes say which question a row
            answers, because 'Note.Text' appearing twice with different counts is
            otherwise unreadable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    $probes = @(
        @{ Name = 'Communication.Message (email-shaped)';      Query = "SELECT COUNT(*) FROM dbo.Communication WHERE Message LIKE '%@%'" },
        @{ Name = 'CommunicationTemplate.Message (email-shaped)'; Query = "SELECT COUNT(*) FROM dbo.CommunicationTemplate WHERE Message LIKE '%@%'" },
        @{ Name = 'Note.Text (email-shaped)';                  Query = "SELECT COUNT(*) FROM dbo.Note WHERE Text LIKE '%@%'" },
        @{ Name = 'History OldValue / NewValue (email-shaped)'; Query = "SELECT COUNT(*) FROM dbo.History WHERE OldValue LIKE '%@%' OR NewValue LIKE '%@%'" },
        @{ Name = 'AttributeValue.Value (email-shaped)';       Query = "SELECT COUNT(*) FROM dbo.AttributeValue WHERE Value LIKE '%@%'" },
        @{ Name = 'PhoneNumber.Description (phone-shaped)';    Query = "SELECT COUNT(*) FROM dbo.PhoneNumber WHERE $(Get-PhoneShapedPredicate -Column 'Description')" },
        @{ Name = 'Note.Text (phone-shaped)';                  Query = "SELECT COUNT(*) FROM dbo.Note WHERE $(Get-PhoneShapedPredicate -Column 'Text')" },
        @{ Name = 'History OldValue / NewValue (phone-shaped)'; Query = "SELECT COUNT(*) FROM dbo.History WHERE $(Get-PhoneShapedPredicate -Column 'OldValue', 'NewValue')" },
        @{ Name = 'AttributeValue.Value (phone-shaped)';       Query = "SELECT COUNT(*) FROM dbo.AttributeValue WHERE $(Get-PhoneShapedPredicate -Column 'Value')" },
        @{ Name = 'Location (street addresses present)';       Query = "SELECT COUNT(*) FROM dbo.Location WHERE Street1 IS NOT NULL AND Street1 <> ''" }
    )

    return ,$probes
}

function Get-RowCount {
    <#
        .SYNOPSIS
            Runs a COUNT(*) through the SQL adapter and returns it as an [int64].

        .DESCRIPTION
            The adapter's Scalar returns what SQL Server sent, which for COUNT(*)
            is an Int32 and for a query that finds no row is nothing at all. Every
            count in the summary is read back by a person comparing two numbers,
            so they are one type and a missing one reads as zero.
    #>
    [CmdletBinding()]
    [OutputType([int64])]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $true)][string] $Query,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $value = & $Sql.Scalar -Connection $Connection -Query $Query -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $value -or $value -is [System.DBNull]) {
        return [int64]0
    }
    return [int64]$value
}

function Get-KeptDomainReport {
    <#
        .SYNOPSIS
            Prints how many people and logins each kept domain matches in the
            catalog, and returns those counts for the summary.

        .DESCRIPTION
            Restated against the catalog rather than against the argument. "I
            passed the domain" and "the domain matches somebody" are different
            claims, and only the second one keeps a tester able to sign in. A
            domain that matches nothing gets a line of its own, because that is a
            misspelling and the run would otherwise report success.

        .PARAMETER KeepDomain
            Domains already through ConvertTo-KeepDomain, spliced into the LIKE
            patterns as they stand.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $false)][string[]] $KeepDomain = @(),
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $keptByDomain = @()
    if ($KeepDomain.Count -eq 0) {
        Write-Host "Keep:     nothing -- every address, number and login in this catalog will be anonymized."
        return ,$keptByDomain
    }

    Write-Host "Keep:     $($KeepDomain -join ', ')"
    foreach ($domain in $KeepDomain) {
        $keptPeople = Get-RowCount -Sql $Sql -Connection $Connection -TimeoutSeconds $TimeoutSeconds `
            -Query "SELECT COUNT(*) FROM dbo.Person WHERE Email LIKE '%@$domain'"
        $keptLogins = Get-RowCount -Sql $Sql -Connection $Connection -TimeoutSeconds $TimeoutSeconds `
            -Query "SELECT COUNT(*) FROM dbo.UserLogin WHERE UserName LIKE '%@$domain'"

        Write-Host ("          {0,-40} {1,8:N0} person(s), {2,7:N0} login(s) kept" -f $domain, $keptPeople, $keptLogins)
        if ($keptPeople -eq 0 -and $keptLogins -eq 0) {
            Write-Host ("          {0,-40} >>> MATCHES NOTHING. Check the spelling before approving." -f "")
        }

        $keptByDomain += [ordered]@{ domain = $domain; people = $keptPeople; logins = $keptLogins }
    }

    # Leading comma for the same reason as ConvertTo-KeepDomain: an empty report
    # comes back as an empty array rather than as nothing.
    return ,$keptByDomain
}

function Assert-NoComputedColumnAssignment {
    <#
        .SYNOPSIS
            Throws, naming every offender, if any target's SET clause writes a
            computed column.

        .DESCRIPTION
            Bind-time check for every target before any of them runs. Whole-catalog,
            and ahead of the first write, because the point is to fail while nothing
            has been rewritten rather than between two targets. The caller runs it on
            a dry run too: a plan that reports clean for a statement SQL Server will
            reject is the failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $true)][hashtable[]] $Target,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $computedColumnFaults = @()
    foreach ($candidate in $Target) {
        $offenders = Get-ComputedColumnAssignment -Sql $Sql -Connection $Connection -TimeoutSeconds $TimeoutSeconds `
            -Table $candidate.Table -SetClause $candidate.SetClause
        foreach ($offender in $offenders) {
            $computedColumnFaults += "$($candidate.Table).$offender"
        }
    }

    if ($computedColumnFaults.Count -gt 0) {
        throw ("Refusing to run: these are computed columns and SQL Server will reject any UPDATE that writes them -- " +
            ($computedColumnFaults -join ', ') +
            ". Remove them from the SetClause; rewriting the column they are computed from is what clears them.")
    }
}

function Invoke-AnonymizationTarget {
    <#
        .SYNOPSIS
            Counts the rows one target would rewrite and, with -Apply, rewrites
            them in batches. Returns the target's entry for the summary.

        .DESCRIPTION
            A dry run stops at the count. An apply with nothing pending says so
            instead of sending an UPDATE that would match no row.

            The count and the UPDATE read the same predicate string, which is what
            keeps the number the approver saw and the number of rows rewritten the
            same number.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $true)][hashtable] $Target,
        [Parameter(Mandatory = $false)][switch] $Apply,
        [Parameter(Mandatory = $false)][int] $BatchSize = 25000,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $pending = Get-RowCount -Sql $Sql -Connection $Connection -TimeoutSeconds $TimeoutSeconds `
        -Query "SELECT COUNT(*) FROM $($Target.Table) WHERE $($Target.Predicate)"

    $entry = [ordered]@{
        name    = $Target.Name
        pending = $pending
        updated = 0
    }

    if (-not $Apply) {
        Write-Host ("  {0,-58} {1,12:N0} row(s) would change" -f $Target.Name, $pending)
        return $entry
    }

    if ($pending -eq 0) {
        Write-Host ("  {0,-58} {1,12} " -f $Target.Name, "already clean")
        return $entry
    }

    # TOP (n) with the same predicate the count used. Each pass removes rows
    # from its own predicate, so the loop terminates without a marker column
    # or a keyset to page through.
    $totalUpdated = 0
    do {
        $affected = & $Sql.NonQuery -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Query @"
UPDATE TOP ($BatchSize) $($Target.Table)
SET $($Target.SetClause)
WHERE $($Target.Predicate);
"@
        $totalUpdated += $affected
        if ($affected -gt 0) {
            Write-Host ("    {0,-56} {1,12:N0} / {2:N0}" -f $Target.Name, $totalUpdated, $pending)
        }
    } while ($affected -gt 0)

    $entry.updated = $totalUpdated

    # An ordered dictionary is not unrolled on the way out, so no leading comma.
    return $entry
}

function Get-EmailDomainCensus {
    <#
        .SYNOPSIS
            Prints the 25 most common email domains in dbo.Person, marking the
            kept ones, and returns them for the summary.

        .DESCRIPTION
            What the catalog actually holds, by domain. Printed so the allowlist can
            be checked against reality instead of against memory.

            A misspelled domain is the failure this catches, and it is a quiet one:
            the allowlist matches nothing, every row is anonymized, the run reports
            success, and the testers find out when they cannot sign in -- by which
            point the rollback is a 119 GiB restore. Read before the apply it is a
            spelling check; read after, it is the proof that only the allowlisted
            domains survived.

            Counts of domains, not addresses. Aggregate, so it is safe in a job
            summary.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $false)][string[]] $KeepDomain = @(),
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    $domainCensusQuery = @"
SELECT TOP 25
    LOWER(LTRIM(RTRIM(SUBSTRING(Email, CHARINDEX('@', Email) + 1, 255)))) AS Domain,
    COUNT(*) AS People
FROM dbo.Person
WHERE Email IS NOT NULL AND Email <> '' AND CHARINDEX('@', Email) > 0
GROUP BY LOWER(LTRIM(RTRIM(SUBSTRING(Email, CHARINDEX('@', Email) + 1, 255))))
ORDER BY COUNT(*) DESC;
"@

    Write-Host "Email domains in dbo.Person, top 25 by count:"
    $emailDomains = @()
    $census = & $Sql.Rows -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Query $domainCensusQuery
    foreach ($censusRow in $census) {
        $marker = ""
        if ($KeepDomain -contains $censusRow.Domain) {
            $marker = "<- kept"
        }
        Write-Host ("  {0,-50} {1,12:N0}  {2}" -f $censusRow.Domain, $censusRow.People, $marker)
        $emailDomains += [ordered]@{ domain = $censusRow.Domain; people = $censusRow.People }
    }

    return ,$emailDomains
}

function Get-ResidualPiiCount {
    <#
        .SYNOPSIS
            Prints and returns the row count of every Get-ResidualPiiProbe probe:
            contact data the run reports and does not rewrite.

        .DESCRIPTION
            A probe whose table is missing reports as "unavailable" with a null
            count rather than failing the run. Plugin tables come and go between
            Rock versions, and the probe list is deliberately broader than any one
            schema.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Sql,
        [Parameter(Mandatory = $true)] $Connection,
        [Parameter(Mandatory = $false)][int] $TimeoutSeconds = 600
    )

    Write-Host "Residual PII (reported, not rewritten -- see .NOTES):"
    $residualPii = @()
    foreach ($probe in (Get-ResidualPiiProbe)) {
        try {
            $count = Get-RowCount -Sql $Sql -Connection $Connection -TimeoutSeconds $TimeoutSeconds -Query $probe.Query
            Write-Host ("  {0,-58} {1,12:N0} row(s)" -f $probe.Name, $count)
            $residualPii += [ordered]@{ name = $probe.Name; rows = $count }
        }
        catch {
            Write-Host ("  {0,-58} {1,12}" -f $probe.Name, "unavailable")
            $residualPii += [ordered]@{ name = $probe.Name; rows = $null }
        }
    }

    return ,$residualPii
}

function Invoke-StagingAnonymization {
    <#
        .SYNOPSIS
            The run, in the order that makes it safe: refuse production, connect,
            confirm the catalog, check every SET clause against the catalog's
            computed columns, and only then -- and only with -Apply -- write.

        .DESCRIPTION
            The order is the safety property. Each gate exists to stop what the
            next step would do, so a gate that fires one step late is not a gate.
            A production refusal after the connection opens has already reached
            across to production. A catalog check after the first UPDATE is a log
            entry. A computed-column check between two targets leaves the catalog
            half rewritten, which is what happened to RockStaging20260824 on
            2026-08-24.

            Every statement goes through -Sql rather than through SqlClient, and
            that is what makes the order observable. While this sequence ran as
            top-level script, the only thing holding it in place was Python
            comparing the character offset of one line of source with another.
            That can say the refusal is written above the connection; it cannot
            say the refusal runs first. StagingAnonymization.Tests.ps1 runs this
            function against an adapter that records every call, and asserts on
            the sequence it records.

            In this script and not in a shared module, per ADR-0001: the VM gets
            .ps1 files, and the seam has to travel with the code it guards.

        .PARAMETER Sql
            The SQL adapter: a hashtable of five scriptblocks, each taking named
            parameters.

              Open     -ConnectionString                     an open connection, or a throw that leaves nothing open
              Close    -Connection                           nothing
              Scalar   -Connection -Query -TimeoutSeconds    the first column of the first row; $null for none or NULL
              NonQuery -Connection -Query -TimeoutSeconds    rows affected
              Rows     -Connection -Query -TimeoutSeconds    an array of [pscustomobject], one property per column

            New-SqlClientAdapter is the one that ships. Whatever Open returns is
            handed back to the others untouched; nothing here looks inside it.

        .PARAMETER ConnectionString
            Already resolved by the script body. Read here only for its host,
            which is how production is recognised, and passed to Open.

        .OUTPUTS
            The summary the script prints and writes to -OutFile.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Sql,

        [Parameter(Mandatory = $true)]
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
        [int]
        $CommandTimeoutSeconds = 600
    )

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
    $productionDataSources = @('172.20.0.8')

    $dataSourceHost = Get-DataSourceHost -ConnectionStringValue $ConnectionString
    if ($productionDataSources -contains $dataSourceHost) {
        throw "Refusing to run: $dataSourceHost is the production instance. This script destroys contact data."
    }

    # Before the connection, like the check above: a domain that would have been
    # refused should not cost a round trip to find out.
    $keepDomains = ConvertTo-KeepDomain -Domain $KeepEmailDomains

    $targets = Get-AnonymizationTarget -KeepDomain $keepDomains

    $summary = [ordered]@{
        catalog        = ""
        dataSourceHost = $dataSourceHost
        mode           = if ($Apply) { "apply" } else { "dry-run" }
        startedAtUtc   = (Get-Date).ToUniversalTime().ToString("o")
        keptDomains    = @($keepDomains)
        keptByDomain   = @()
        emailDomains   = @()
        targets        = @()
        residualPii    = @()
    }

    # Outside the try on purpose. The adapter's contract is that a failed Open
    # leaves nothing open, so there is nothing for the finally to close -- and a
    # Close handed a connection that never existed would throw over the real error.
    $connection = & $Sql.Open -ConnectionString $ConnectionString
    try {
        $actualCatalog = [string](& $Sql.Scalar -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds -Query "SELECT DB_NAME();")

        $summary.catalog = $actualCatalog

        # Second gate. The first was the instance address; this one is the operator
        # naming the catalog and being held to it.
        if ($actualCatalog -ne $ExpectedCatalog) {
            throw "Refusing to run: connected to '$actualCatalog' but -ExpectedCatalog said '$ExpectedCatalog'."
        }

        Write-Host "Catalog:  $actualCatalog"
        Write-Host "Instance: $dataSourceHost"
        Write-Host "Mode:     $($summary.mode)"

        $summary.keptByDomain = Get-KeptDomainReport -Sql $Sql -Connection $connection -KeepDomain $keepDomains `
            -TimeoutSeconds $CommandTimeoutSeconds
        Write-Host ""

        # Third gate, and the last before anything is written.
        Assert-NoComputedColumnAssignment -Sql $Sql -Connection $connection -Target $targets `
            -TimeoutSeconds $CommandTimeoutSeconds

        foreach ($target in $targets) {
            $summary.targets += Invoke-AnonymizationTarget -Sql $Sql -Connection $connection -Target $target `
                -Apply:$Apply -BatchSize $BatchSize -TimeoutSeconds $CommandTimeoutSeconds
        }

        Write-Host ""
        $summary.emailDomains = Get-EmailDomainCensus -Sql $Sql -Connection $connection -KeepDomain $keepDomains `
            -TimeoutSeconds $CommandTimeoutSeconds

        Write-Host ""
        $summary.residualPii = Get-ResidualPiiCount -Sql $Sql -Connection $connection -TimeoutSeconds $CommandTimeoutSeconds

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
        $null = & $Sql.Close -Connection $connection
    }

    $summary.completedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

    # An ordered dictionary is not unrolled on the way out, so no leading comma.
    return $summary
}

function Invoke-Scalar {
    <#
        .SYNOPSIS
            Runs a query and returns the first column of its first row, as SQL
            Server sent it.

        .DESCRIPTION
            Not converted, because the run asks two kinds of question through it:
            DB_NAME(), which is a name, and COUNT(*), which is a number.
            Get-RowCount does the conversion for the second. NULL comes back as
            $null, the same as no row at all, so a caller tests for one thing.
    #>
    [CmdletBinding()]
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
        if ($value -is [System.DBNull]) {
            return $null
        }
        return $value
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-NonQuery {
    <#
        .SYNOPSIS
            Runs a statement and returns the number of rows it affected.
    #>
    [CmdletBinding()]
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
    [CmdletBinding()]
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

function New-SqlClientAdapter {
    <#
        .SYNOPSIS
            The SQL adapter that ships: the five operations
            Invoke-StagingAnonymization asks for, backed by System.Data.SqlClient.

        .DESCRIPTION
            Plain scriptblocks, deliberately not closures. GetNewClosure binds a
            block to a dynamic module of its own, and from inside that module the
            Invoke-* functions this script defines are out of reach -- the first
            Scalar would fail with "is not recognized". A plain block runs in the
            scope that invokes it, which is inside this script, so it finds them
            the way every other call here does.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        Open     = {
            param([string] $ConnectionString)

            $connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
            try {
                $connection.Open()
            }
            catch {
                # The caller never receives this connection, so the caller cannot
                # close it. Disposed here or not at all.
                $connection.Dispose()
                throw
            }
            return $connection
        }
        Close    = {
            param($Connection)

            $Connection.Dispose()
        }
        Scalar   = {
            param($Connection, [string] $Query, [int] $TimeoutSeconds)

            return Invoke-Scalar -Connection $Connection -Query $Query -TimeoutSeconds $TimeoutSeconds
        }
        NonQuery = {
            param($Connection, [string] $Query, [int] $TimeoutSeconds)

            return Invoke-NonQuery -Connection $Connection -Query $Query -TimeoutSeconds $TimeoutSeconds
        }
        Rows     = {
            param($Connection, [string] $Query, [int] $TimeoutSeconds)

            # Wrapped again on the way out, for the reason Invoke-Rows wraps it: one
            # row must still arrive as an array of one.
            $rows = Invoke-Rows -Connection $Connection -Query $Query -TimeoutSeconds $TimeoutSeconds
            return ,$rows
        }
    }
}

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

$summary = Invoke-StagingAnonymization -Sql (New-SqlClientAdapter) `
    -ConnectionString $resolvedConnectionString -ExpectedCatalog $ExpectedCatalog -Apply:$Apply `
    -KeepEmailDomains $KeepEmailDomains -BatchSize $BatchSize -CommandTimeoutSeconds $CommandTimeoutSeconds

if (![string]::IsNullOrWhiteSpace($OutFile)) {
    $summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutFile -Encoding UTF8 -Force
    Write-Host "Wrote $OutFile"
}
