"""Static checks on Deployment/Database/Invoke-StagingAnonymization.ps1.

There is no SQL Server and no PowerShell in CI, so nothing here executes the
script -- these assert the properties that make it safe to point at a real
catalog. Same approach test_legacy_text_columns.py takes, and for a sharper
reason: the converter it guards rewrites column types, while this one destroys
every email address and phone number it can reach. Aimed at the wrong catalog it
is not a failed run, it is a restore.

The script exists because staging is seeded from a production backup. On the day
it is restored it holds every congregant's real contact details, on a box whose
whole purpose is that people try things on it -- including sending a
communication. Removing the ability to reach a real person is a stronger
guarantee than everyone remembering not to press send.
"""

import re
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
SCRIPT_DIR = REPO_ROOT / "Deployment" / "Database"
ANONYMIZER = SCRIPT_DIR / "Invoke-StagingAnonymization.ps1"
CONVERTER = SCRIPT_DIR / "Convert-LegacyTextColumns.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
ANONYMIZE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "db-anonymize-staging.yml"
QUEUE_AGENT = (
    REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
)
ANONYMIZE_COMMAND = "anonymize-staging"

# connect-prod. The script carries this so it can refuse before it does anything
# else; the test carries it so deleting it from the script is a failing test
# rather than a quiet loss of the only check that cannot be argued with.
PRODUCTION_DATA_SOURCE = "172.20.0.8"


def _strip_comments(text):
    """Drop block and line comments.

    Every claim this file makes is about what the script *does*, and the script
    explains all of it in prose -- it names the production instance, it says it
    writes no pre-image table, it describes the UPDATE it runs. A scan that could
    not tell an explanation from the thing explained would be satisfied by a
    script that only commented."""
    text = re.sub(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.DOTALL)
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class ScriptExistsTests(unittest.TestCase):
    def test_the_anonymizer_exists(self):
        self.assertTrue(ANONYMIZER.exists(), f"{ANONYMIZER} does not exist")


class RefusesProductionTests(unittest.TestCase):
    """The two gates, and the order they fire in.

    Neither is decoration. The sandbox instance hosts a catalog called
    RockConnectProd, character for character the name production uses, so a
    catalog-name check on its own is satisfied on either server. The address is
    what actually differs between them."""

    def test_the_production_instance_is_refused_by_address(self):
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn(
            PRODUCTION_DATA_SOURCE,
            body,
            "the script does not name the production instance, so nothing stops a "
            "connection string pointed at it",
        )
        self.assertRegex(
            body,
            r"if\s*\(\s*\$ProductionDataSources\s+-contains\s+\$dataSourceHost\s*\)",
            "the production address is named but not compared against the "
            "connection string's own host",
        )

    def test_the_refusal_happens_before_the_connection_is_opened(self):
        """A refusal that fires after the first query has already reached across to
        production is a log entry, not a guard."""
        body = _strip_comments(ANONYMIZER.read_text())

        refusal = body.index("$ProductionDataSources -contains $dataSourceHost")
        opened = body.index(".Open()")

        self.assertLess(
            refusal,
            opened,
            "the production check runs after the connection is opened",
        )

    def test_the_expected_catalog_is_mandatory(self):
        """Not defaulted, on purpose. A default would be this script guessing which
        catalog the operator meant, on the one question where guessing is the whole
        risk."""
        body = ANONYMIZER.read_text()

        match = re.search(
            r"\[Parameter\(Mandatory\s*=\s*\$true\)\]\s*\[string\]\s*\$ExpectedCatalog",
            body,
        )
        self.assertIsNotNone(
            match, "ExpectedCatalog is not a mandatory parameter"
        )

    def test_the_connected_catalog_must_match_what_was_asked_for(self):
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn("SELECT DB_NAME()", body)
        self.assertRegex(
            body,
            r"if\s*\(\s*\$actualCatalog\s+-ne\s+\$ExpectedCatalog\s*\)",
            "the catalog the connection actually landed on is never compared "
            "against the one the operator named",
        )

    def test_the_catalog_check_happens_before_any_write(self):
        body = _strip_comments(ANONYMIZER.read_text())

        check = body.index("$actualCatalog -ne $ExpectedCatalog")
        first_update = body.index("UPDATE TOP")

        self.assertLess(
            check, first_update, "the catalog check runs after the first UPDATE"
        )


class DryRunByDefaultTests(unittest.TestCase):
    def test_apply_is_a_switch_and_not_a_default(self):
        body = ANONYMIZER.read_text()

        self.assertRegex(body, r"\[switch\]\s*\$Apply")
        self.assertNotRegex(
            body,
            r"\$Apply\s*=\s*\$true",
            "Apply is given a true default, which makes every run a write",
        )

    def test_no_update_runs_without_the_apply_gate(self):
        """The dry run and the apply path share one list of targets, so the count
        the dry run prints is produced by the same predicate the UPDATE uses. That
        is the property worth having: the two cannot drift into a dry run that
        reports one thing and an apply that does another."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn(
            "if (-not $Apply)",
            body,
            "there is no -Apply gate at all, so every run writes",
        )
        gate = body.index("if (-not $Apply)")
        update = body.index("UPDATE TOP")

        self.assertLess(
            gate, update, "the UPDATE is reachable before the -Apply gate"
        )

    def test_the_dry_run_and_the_apply_path_read_the_same_predicates(self):
        body = ANONYMIZER.read_text()

        self.assertEqual(
            1,
            len(re.findall(r"\$AnonymizationTargets\s*=\s*@\(", body)),
            "there is more than one list of targets, so the dry run can describe "
            "work the apply path does not do",
        )
        self.assertIn("foreach ($target in $AnonymizationTargets)", body)


class NoPreImageTests(unittest.TestCase):
    """The house rule for a write script is a generated row-by-row rollback. This
    is the one script where following it would undo the work.

    A table mapping every Id to its real email address and phone number is the
    same PII the run exists to remove, sitting in the same catalog under a
    different name. Reversal here is re-importing the .bak that seeded the
    catalog, which is already in GCS and is faithful by construction."""

    def test_no_pre_image_table_is_created(self):
        body = _strip_comments(ANONYMIZER.read_text())

        for pattern in [
            r"\bSELECT\b[^;]*\bINTO\b",
            r"\bCREATE\s+TABLE\b",
            r"\bINSERT\s+INTO\b",
        ]:
            self.assertIsNone(
                re.search(pattern, body, re.IGNORECASE),
                f"the script matches {pattern!r}, which would keep a copy of the "
                "contact details it is supposed to be removing",
            )

    def test_the_script_says_where_the_rollback_actually_is(self):
        """Absent a pre-image, an operator reading this at 2am needs to be told what
        reversal looks like, or they will assume there is none."""
        body = ANONYMIZER.read_text()

        self.assertIn(".bak", body)
        self.assertRegex(body, r"(?i)rollback")


class SubstitutesAreUnreachableTests(unittest.TestCase):
    """Blanking the columns would do for privacy and ruin the environment: Rock
    matches people on email during duplicate detection, so one shared value
    collapses merge review into nonsense. Deriving the substitute from the row's
    own Id keeps rows distinct, keeps reruns idempotent, and still cannot reach
    anybody."""

    def test_addresses_land_in_a_domain_that_cannot_resolve(self):
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn(
            "@staging.invalid",
            body,
            "substitute addresses are not in .invalid, the TLD RFC 2606 reserves "
            "precisely so it can never resolve",
        )
        self.assertNotRegex(
            body,
            r"@(example\.com|test\.com|passion\.team|268generation\.com)",
            "a substitute address is in a domain that resolves to somebody",
        )

    def test_phone_numbers_get_an_area_code_that_cannot_be_dialled(self):
        """555 as the area code, not the NANP's 555-01xx fiction range. That range
        is 100 numbers and lives in the subscriber number; using it would put the
        whole congregation in one bucket and collapse every phone lookup in Rock. An
        unassignable area code is equally undiallable and leaves the subscriber
        number free to keep rows distinct."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn(
            "'555'",
            body,
            "substitute numbers do not start with the unassignable 555 area code, "
            "so an anonymized number may still dial a real person",
        )
        self.assertIn(
            "Number = '555' + RIGHT(",
            body,
            "the 555 prefix is present but is not what Number is actually set to",
        )

    def test_every_substitute_is_derived_from_the_row_id(self):
        """Idempotence and distinctness come from the same property. A substitute
        that is a function of Id is stable across reruns, which is what lets the
        predicates below exclude rows already done."""
        body = ANONYMIZER.read_text()

        targets = re.findall(r"SetClause\s*=\s*(.*?)(?=\n\s*\}|\n\s*Name\s*=)", body, re.DOTALL)
        self.assertTrue(targets, "no SetClause entries found to check")

        id_derived = [t for t in targets if "Id AS varchar" in t]
        self.assertGreaterEqual(
            len(id_derived),
            3,
            "fewer than three targets derive their substitute from the row Id",
        )


class IdempotenceTests(unittest.TestCase):
    def test_every_predicate_excludes_rows_already_done(self):
        """Each batch commits on its own, so a run killed by the agent's timeout
        leaves the catalog part-way through. The predicates are what make the next
        run resume instead of starting over -- and what make a second run a no-op
        rather than a second layer of substitution."""
        body = ANONYMIZER.read_text()

        predicates = re.findall(r"Predicate\s*=\s*\"(.*?)\"\n", body, re.DOTALL)
        self.assertGreaterEqual(
            len(predicates), 4, "expected a predicate per target; found too few"
        )

        for predicate in predicates:
            already_done = (
                "staging.invalid" in predicate
                or "555" in predicate
                or "CCEmails" in predicate
            )
            self.assertTrue(
                already_done,
                f"predicate does not exclude rows that already carry their "
                f"substitute, so a rerun rewrites them again: {predicate!r}",
            )


class ColumnCoverageTests(unittest.TestCase):
    def test_the_columns_the_boss_asked_for_are_covered(self):
        body = ANONYMIZER.read_text()

        for column in ["Email", "Number", "SearchValue", "FromEmail", "ReplyToEmail", "UserName"]:
            self.assertIn(column, body, f"{column} is not anonymized")

    def test_the_reversed_phone_number_is_covered(self):
        """The one that gets forgotten. Rock maintains NumberReversed so that "ends
        with" searches can use an index. Leaving it holding the reverse of the real
        number leaves the real number in the catalog, still searchable, under a
        column nobody thinks of as a phone number.

        It is cleared by rewriting Number, not by assigning it: the column is
        declared AS (reverse([Number])) PERSISTED, so SQL Server recomputes it and
        rejects any UPDATE that writes it directly. See ComputedColumnTests."""
        targets = _anonymization_targets(ANONYMIZER.read_text())
        phone = next(v for k, v in targets.items() if k.startswith("PhoneNumber"))

        self.assertRegex(
            phone,
            r"(^|[,\r\n])\s*\[?Number\]?\s*=",
            "Number is not rewritten, so the computed NumberReversed keeps the "
            "reverse of the real number",
        )

    def test_the_formatted_phone_number_is_covered(self):
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn("NumberFormatted", body)

    def test_free_text_holding_contact_details_is_reported_not_rewritten(self):
        """Notes, communication bodies and attribute values can hold an address in
        prose. A regex sweep over them would be a guess presented as a guarantee --
        it cannot tell a congregant's address in a note from one in a template's
        example block, and a partial scrub reads as a completed one. Counting them
        and saying so is the honest version."""
        body = ANONYMIZER.read_text()

        self.assertIn("$ResidualPiiProbes", body)
        probes = body[body.index("$ResidualPiiProbes") : body.index("$connection = New-Object")]

        for table in ["Note", "History", "AttributeValue"]:
            self.assertIn(table, probes, f"{table} is not reported as residual PII")

        self.assertNotIn(
            "UPDATE",
            probes,
            "a residual-PII probe writes, which is exactly the guess this section "
            "exists to avoid making",
        )


def _anonymization_targets(text):
    """Split the $AnonymizationTargets array into one chunk per target.

    Keyed on the Name field because that is the only line every target has, and
    the chunks are what let a test say "the allowlist reaches Person but not
    Communication" instead of "the allowlist appears somewhere in the file"."""
    block = text[text.index("$AnonymizationTargets = @(") : text.index("$ResidualPiiProbes")]
    chunks = re.split(r"\n    @\{", block)[1:]
    targets = {}
    for chunk in chunks:
        name = re.search(r"Name\s*=\s*'([^']+)'", chunk)
        if name:
            targets[name.group(1)] = chunk
    return targets


class KeepListTests(unittest.TestCase):
    """Anonymizing every address makes the one thing staging most needs to prove
    -- that mail goes out and arrives -- untestable, and locks out the people
    doing the proving, because Rock authenticates against UserLogin.UserName and
    most of those are addresses.

    The allowlist is what reconciles that with the reason the script exists. It
    also tightens the environment rather than loosening it: afterwards the only
    addresses staging can reach belong to people who agreed to be reached, so the
    classic staging accident delivers to the testers rather than to the
    congregation."""

    def test_the_keep_list_is_a_parameter(self):
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn("$KeepEmailDomains", body)

    def test_keeping_nobody_is_the_default(self):
        """The old behaviour, and the stricter of the two. A caller that predates
        this parameter -- or an operator who leaves the box empty -- gets more
        anonymization, not less."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertRegex(
            body,
            r"\$KeepEmailDomains\s*=\s*@\(\)",
            "the keep list does not default to empty, so omitting it may preserve "
            "contact data the caller never asked to preserve",
        )

    def test_the_domains_are_validated_before_they_reach_a_query(self):
        """These arrive from a dispatch box and are concatenated into LIKE
        patterns, which is the one place in this script where a caller's string
        becomes SQL. There is no parameter to bind them to -- a pattern assembled
        per target is not a value -- so the pattern below is the whole boundary."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn("$DomainPattern", body)
        pattern = re.search(r"\$DomainPattern\s*=\s*'([^']+)'", body)
        self.assertIsNotNone(pattern, "the domain pattern is not a literal")

        compiled = re.compile(pattern.group(1), re.IGNORECASE)
        for hostile in [
            "evil.com' OR '1'='1",
            "a.com'; DROP TABLE Person--",
            "a.com%",
            "sp ace.com",
            "no-dot",
        ]:
            self.assertNotRegex(
                hostile.lower(),
                compiled,
                f"the domain pattern admits {hostile!r}, which becomes SQL",
            )

        for legitimate in ["staff.example", "a-b.example.org", "x1.y2.example"]:
            self.assertRegex(legitimate, compiled, f"{legitimate} should be allowed")

    def test_an_unvalidated_domain_stops_the_run(self):
        body = _strip_comments(ANONYMIZER.read_text())

        guard = body[body.index("$DomainPattern") : body.index("function Get-DomainExclusion")]
        self.assertIn(
            "throw",
            guard,
            "a domain that fails the pattern does not stop the run, so it reaches "
            "a query anyway",
        )

    def test_the_keep_list_reaches_every_column_a_tester_is_identified_by(self):
        """Email is what mail is sent to, UserName is what login checks, the phone
        number is what the tester sees on their own record, and PersonSearchKey is
        the alternate address duplicate detection matches on. Miss one and the
        tester is half-anonymized, which reads as a Rock bug rather than as this
        script's doing."""
        targets = _anonymization_targets(ANONYMIZER.read_text())

        expected = {
            "Person.Email": "$personEmailKeep",
            "PhoneNumber (Number, NumberFormatted, Extension)": "$phoneNumberKeep",
            "PersonSearchKey.SearchValue (email-shaped)": "$searchValueKeep",
            "UserLogin.UserName (email-shaped)": "$userNameKeep",
        }
        for name, fragment in expected.items():
            self.assertIn(name, targets, f"{name} is not a target any more")
            self.assertIn(
                fragment,
                targets[name],
                f"{name} ignores the keep list, so an allowlisted tester is "
                f"anonymized in that column anyway",
            )

    def test_sent_mail_is_anonymized_whole(self):
        """Communication holds the record of mail already sent. It is not a way to
        reach anybody and a tester reading their own history wants to see that a
        message exists, not who its envelope named. Exempting it would preserve
        real addresses for no testing benefit."""
        targets = _anonymization_targets(ANONYMIZER.read_text())

        for name, chunk in targets.items():
            if not name.startswith("Communication"):
                continue
            self.assertNotIn(
                "Keep",
                chunk,
                f"{name} honours the keep list, which preserves real addresses in "
                f"records that cannot be used for testing",
            )

    def test_the_phone_exclusion_resolves_through_the_person(self):
        """PhoneNumber holds no address, so whether a number belongs to a tester
        cannot be read off the row. NOT EXISTS rather than NOT IN: NOT IN against a
        subquery that ever yields NULL returns no rows at all, and that failure is
        silent -- it reads as "nothing left to anonymize"."""
        body = _strip_comments(ANONYMIZER.read_text())

        exclusion = body[
            body.index("function Get-PersonDomainExclusion") : body.index("function Invoke-Scalar")
        ]
        self.assertIn("NOT EXISTS", exclusion)
        self.assertNotIn("NOT IN", exclusion)

    def test_an_empty_keep_list_changes_no_sql(self):
        """The fragment builders return an empty string, so the predicates are
        character-for-character what they were before this parameter existed."""
        body = _strip_comments(ANONYMIZER.read_text())

        for function in ["Get-DomainExclusion", "Get-PersonDomainExclusion"]:
            start = body.index(f"function {function}")
            chunk = body[start : start + 900]
            self.assertRegex(
                chunk,
                r"Count\s*-eq\s*0\s*\)\s*\{\s*\n\s*return\s+\"\"",
                f"{function} does not return an empty fragment for an empty list",
            )

    def test_the_dry_run_says_how_many_rows_each_domain_keeps(self):
        """The failure this catches is a misspelled domain, and it is a quiet one:
        the allowlist matches nothing, everyone is anonymized, the run reports
        success, and the testers find out when they cannot sign in -- by which
        point the rollback is a full restore."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn("keptByDomain", body, "per-domain kept counts are not reported")
        self.assertIn(
            "$DomainCensusQuery",
            body,
            "the run does not report which domains the catalog actually holds, so "
            "the keep list cannot be checked against reality",
        )
        self.assertIn(
            "MATCHES NOTHING",
            ANONYMIZER.read_text(),
            "a keep-list domain that matches no row passes without comment",
        )

    def test_no_real_domain_is_baked_in(self):
        """Whose staging box this is should not be readable off the script, and a
        default here would silently preserve contact data on an install nobody
        checked the default against."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertNotRegex(
            body,
            r"KeepEmailDomains\s*=\s*@\(\s*['\"]",
            "a real domain is hard-coded as the default keep list",
        )

    def test_the_census_slices_the_domain_exactly(self):
        """The census is the only thing that shows what the catalog actually holds,
        so it is the check a misspelled keep list gets caught by. LEN() ignores
        trailing spaces and RIGHT() does not, so slicing with the two together
        reports a shifted domain for any address stored with a trailing space --
        and a garbled census reads as an unfamiliar domain, not as a bug."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertNotIn(
            "RIGHT(Email, LEN(Email)",
            body,
            "the census slices the domain with RIGHT/LEN, which disagree about "
            "trailing spaces; use SUBSTRING from CHARINDEX instead",
        )
        self.assertIn(
            "SUBSTRING(Email, CHARINDEX('@', Email) + 1",
            body,
            "the census does not slice the domain from the '@' onward",
        )


class LoginIsAnonymizedTests(unittest.TestCase):
    """UserLogin.UserName is what Rock authenticates against -- Person.Email is
    not a credential. Left alone, a staging box seeded from production is a second
    production login page: every congregant's username still works, against a
    catalog holding their real password hash."""

    def test_the_username_is_rewritten_and_not_merely_counted(self):
        body = ANONYMIZER.read_text()

        targets = _anonymization_targets(body)
        self.assertIn(
            "UserLogin.UserName (email-shaped)",
            targets,
            "UserLogin.UserName is not an anonymization target, so every "
            "congregant can still sign in to staging",
        )

        probes = body[body.index("$ResidualPiiProbes") : body.index("$DomainCensusQuery")]
        self.assertNotIn(
            "UserLogin",
            probes,
            "UserLogin is still listed as residual PII, which now reports a "
            "column the script actually rewrites",
        )

    def test_the_username_substitute_is_unique_per_row(self):
        """UserName carries a unique index, so the substitute has to be unique per
        row rather than per person. Id gives that; anything person-derived collides
        for anyone holding two logins."""
        targets = _anonymization_targets(ANONYMIZER.read_text())
        chunk = targets["UserLogin.UserName (email-shaped)"]

        self.assertIn("Id AS varchar", chunk)
        self.assertIn("@staging.invalid", chunk)

    def test_logins_that_are_not_addresses_are_left_alone(self):
        """Rock keeps every provider's logins in this one table and only some are
        addresses. A UserName with no @ is not contact data."""
        targets = _anonymization_targets(ANONYMIZER.read_text())
        chunk = targets["UserLogin.UserName (email-shaped)"]

        self.assertIn("UserName LIKE '%@%'", chunk)


class KeepListIsReachableTests(unittest.TestCase):
    """The parameter is worth nothing if the only two callers that can reach the
    script cannot pass it."""

    def test_the_queue_agent_forwards_the_keep_list(self):
        body = QUEUE_AGENT.read_text()

        arm = body[body.index(f'"{ANONYMIZE_COMMAND}"') :]
        arm = arm[: arm.index("default {")]
        self.assertIn("keepEmailDomains", arm)
        self.assertIn("KeepEmailDomains", arm, "the field is read but not passed on")

    def test_a_command_without_the_field_still_runs(self):
        """Commands are JSON documents that outlive the code that wrote them. One
        queued before this field existed must still run, and must err toward
        anonymizing more rather than fewer."""
        body = QUEUE_AGENT.read_text()

        arm = body[body.index(f'"{ANONYMIZE_COMMAND}"') :]
        arm = arm[: arm.index("default {")]
        self.assertIn(
            "PSObject.Properties.Name -contains 'keepEmailDomains'",
            arm,
            "the keep list is read without checking the field is there, so an "
            "older command throws under StrictMode instead of running",
        )

    def test_the_workflow_exposes_the_keep_list(self):
        spec = yaml.safe_load(ANONYMIZE_WORKFLOW.read_text())
        on_key = [key for key in spec if str(key).lower() == "on"][0]
        inputs = spec[on_key]["workflow_dispatch"]["inputs"]

        self.assertIn("keep_email_domains", inputs)
        self.assertEqual(
            inputs["keep_email_domains"].get("default"),
            "",
            "the workflow defaults to keeping somebody, which preserves contact "
            "data nobody asked to preserve",
        )

    def test_both_jobs_send_the_keep_list(self):
        """The dry run and the apply have to agree. A plan that counted rows with
        the keep list and an apply that wrote without it would destroy exactly the
        rows the approver was shown as safe."""
        spec = yaml.safe_load(ANONYMIZE_WORKFLOW.read_text())

        for job in ["plan", "apply"]:
            payloads = [
                step["with"]["payload"]
                for step in spec["jobs"][job]["steps"]
                if step.get("uses", "").endswith("queue-vm-command")
            ]
            self.assertTrue(payloads, f"{job} queues no command")
            for payload in payloads:
                self.assertIn(
                    "keepEmailDomains",
                    payload,
                    f"the {job} job does not forward the keep list",
                )

    def test_the_workflow_checks_the_keep_list_before_queueing(self):
        """It is concatenated into the queued JSON, so a quote produces a document
        the agent cannot parse -- which surfaces as a ten-minute poll timeout
        rather than as an error."""
        spec = yaml.safe_load(ANONYMIZE_WORKFLOW.read_text())

        for job in ["plan", "apply"]:
            names = [step.get("name", "") for step in spec["jobs"][job]["steps"]]
            self.assertIn(
                "Validate the keep list",
                names,
                f"the {job} job queues the keep list without checking its shape",
            )


class ComputedColumnTests(unittest.TestCase):
    """On 2026-08-24 an apply against RockStaging20260824 rewrote Person.Email in
    full and then died on PhoneNumber, because NumberReversed is declared
    AS (reverse([Number])) PERSISTED and SQL Server rejects an UPDATE that writes a
    computed column. Nothing spans the targets in one transaction, so the catalog
    was left half anonymized."""

    def test_the_phone_target_does_not_write_the_computed_column(self):
        targets = _anonymization_targets(ANONYMIZER.read_text())
        phone = next(v for k, v in targets.items() if k.startswith("PhoneNumber"))

        self.assertNotRegex(
            phone,
            r"(^|[,\r\n])\s*\[?NumberReversed\]?\s*=",
            "the SetClause assigns NumberReversed, which is computed; rewriting "
            "Number is what clears it",
        )

    def test_a_computed_column_is_refused_before_the_first_write(self):
        """The dry run only issues COUNT(*) against the predicate, so it never binds
        the SetClause. Without a check of its own it reports a clean plan for a
        statement SQL Server will reject."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn(
            "sys.computed_columns",
            body,
            "nothing asks the catalog which columns are computed",
        )

        guard = body.index("$computedColumnFaults")
        loop = body.index("foreach ($target in $AnonymizationTargets) {\n        $pending")
        self.assertLess(
            guard,
            loop,
            "the computed-column check runs after the loop that writes, so it "
            "cannot stop a half-finished apply",
        )

    def test_the_computed_column_check_throws(self):
        body = _strip_comments(ANONYMIZER.read_text())

        fault = body.index("$computedColumnFaults.Count -gt 0")
        following = body[fault : fault + 400]
        self.assertIn(
            "throw",
            following,
            "a computed column is reported but not refused, so the apply proceeds "
            "and fails partway",
        )


class ConnectionStringHandlingTests(unittest.TestCase):
    def test_the_connection_string_is_never_written_to_output(self):
        body = _strip_comments(ANONYMIZER.read_text())

        for match in re.finditer(r"Write-(Host|Output|Warning)[^\n]*", body):
            self.assertNotIn(
                "ConnectionString",
                match.group(0),
                f"the connection string reaches output: {match.group(0)!r}",
            )
            self.assertNotIn("$resolvedConnectionString", match.group(0))

    def test_the_connection_string_can_be_supplied_out_of_band(self):
        """An argument lands in shell history, in the scrollback and in the process
        list. The finder takes the same route for the same reason."""
        body = ANONYMIZER.read_text()

        self.assertIn("ROCK_DB_CONNECTION_STRING", body)

    def test_the_catalog_that_was_rewritten_is_reported(self):
        """The connection string is redacted in the log, so the catalog name is the
        one fact the log cannot otherwise show -- and a row count attributed to the
        wrong catalog is worse than no row count."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertRegex(body, r"Write-Host\s+\"Catalog:")


class TheAnonymizerCanActuallyBeRunTests(unittest.TestCase):
    """Four pieces are load-bearing -- the script, the bootstrap that publishes it,
    the agent command that invokes it, and the workflow that queues that command.
    test_legacy_text_columns.py records what happens when they drift: the v19
    cutover carried the finder and its runbook forward and left the other three
    behind, and every test stayed green because losing the ability to run it was
    not one of the things anything was looking at."""

    def test_the_bootstrap_publishes_the_anonymizer_to_the_vm(self):
        published_from = re.findall(
            r"(Deployment/[A-Za-z]+)/\*\.ps1", BOOTSTRAP_WORKFLOW.read_text()
        )

        self.assertIn(
            "Deployment/Database",
            published_from,
            "the bootstrap does not publish Deployment/Database, so the anonymizer "
            "cannot reach the VM that is the only place it can run",
        )

    def test_the_queue_agent_has_a_command_that_runs_the_anonymizer(self):
        agent = QUEUE_AGENT.read_text()

        self.assertIn(f'"{ANONYMIZE_COMMAND}" {{', agent)
        self.assertIn(ANONYMIZER.name, agent)
        self.assertIn(f"'{ANONYMIZE_COMMAND}' = ", agent)

    def test_the_agent_refuses_the_command_without_an_expected_catalog(self):
        """Every other optional field on every other command degrades to something
        sensible when it is missing. This one must not: the value it carries is the
        operator stating which catalog they mean, and absent means unstated."""
        agent = _strip_comments(QUEUE_AGENT.read_text())

        arm = agent[agent.index(f'"{ANONYMIZE_COMMAND}" {{') :]
        arm = arm[: arm.index("default {")]

        self.assertIn("expectedCatalog", arm)
        self.assertRegex(
            arm,
            r"throw\s+\"anonymize-staging requires an expectedCatalog",
            "the agent forwards a missing expectedCatalog instead of refusing it",
        )

    def test_the_agent_defaults_the_command_to_a_dry_run(self):
        agent = _strip_comments(QUEUE_AGENT.read_text())

        arm = agent[agent.index(f'"{ANONYMIZE_COMMAND}" {{') :]
        arm = arm[: arm.index("default {")]

        self.assertRegex(
            arm,
            r"-contains 'apply'\)\s*-and\s*\$Command\.apply\)",
            "the agent does not gate Apply on the command explicitly asking for it",
        )

    def test_the_command_has_a_timeout_that_outlasts_a_real_run(self):
        """The fallback is 600s. Batched UPDATEs over every Person and PhoneNumber
        row in a prod-derived catalog run longer than that, and a run killed part-way
        is reported as a failure -- which invites the reading that it did nothing and
        leaves real addresses in place."""
        agent = QUEUE_AGENT.read_text()

        match = re.search(rf"'{ANONYMIZE_COMMAND}'\s*=\s*(\d+)", agent)
        self.assertIsNotNone(match, "no timeout is declared for the command")
        self.assertGreaterEqual(int(match.group(1)), 1800)

    def test_a_workflow_exists_to_dispatch_that_command(self):
        self.assertTrue(
            ANONYMIZE_WORKFLOW.exists(),
            f"{ANONYMIZE_WORKFLOW.name} does not exist, so the command cannot be "
            "dispatched at all",
        )

        workflow = yaml.safe_load(ANONYMIZE_WORKFLOW.read_text())
        self.assertIn("workflow_dispatch", workflow["on"])

    def test_the_workflow_requires_the_catalog_and_defaults_to_a_dry_run(self):
        workflow = yaml.safe_load(ANONYMIZE_WORKFLOW.read_text())
        inputs = workflow["on"]["workflow_dispatch"]["inputs"]

        self.assertTrue(
            inputs["db_name"]["required"],
            "db_name is optional, so a dispatch with the box left empty falls back "
            "to some other catalog -- and the fallback elsewhere in this repository "
            "is the catalog the whole pr-* fleet shares",
        )
        self.assertTrue(inputs["expected_catalog"]["required"])
        self.assertIs(
            inputs["apply"]["default"],
            False,
            "the workflow defaults to writing",
        )

    def test_the_workflow_has_no_fallback_catalog(self):
        """db-find-legacy-text-columns.yml falls back to secrets.DB_NAME when its
        db_name box is empty, which is right for a read. Here the same fallback would
        aim a destructive write at the shared sandbox catalog because somebody left a
        field blank."""
        text = ANONYMIZE_WORKFLOW.read_text()

        self.assertNotIn(
            "inputs.db_name || secrets.DB_NAME",
            text,
            "the workflow falls back to the shared sandbox catalog",
        )

    def test_apply_runs_behind_an_environment_approval(self):
        """The same gate production-deploy.yml puts in front of a production deploy.
        A dry run needs no approval; a write that cannot be undone without a 40-minute
        re-import gets a second person."""
        workflow = yaml.safe_load(ANONYMIZE_WORKFLOW.read_text())

        environments = [
            job.get("environment")
            for job in workflow["jobs"].values()
            if job.get("environment")
        ]
        self.assertTrue(
            environments,
            "no job declares an environment, so -Apply is one dispatch box away "
            "from rewriting a catalog with nobody else in the loop",
        )


class AsymmetryWithTheConverterTests(unittest.TestCase):
    def test_the_converter_is_still_not_reachable_from_the_queue(self):
        """Adding a second Deployment/Database script to the agent must not quietly
        add the first one too. The converter stays a by-hand script.

        The asymmetry is not squeamishness about writes -- this script writes. It is
        that this one cannot be aimed at production: it refuses that instance by
        address before it opens a connection, and refuses any catalog but the one
        named on the command. The converter has neither check, so what protects it is
        a human choosing the catalog, and a dispatch box removes exactly that."""
        agent = _strip_comments(QUEUE_AGENT.read_text())

        self.assertIn(ANONYMIZER.name, agent)
        self.assertNotIn(CONVERTER.name, agent)


if __name__ == "__main__":
    unittest.main()
