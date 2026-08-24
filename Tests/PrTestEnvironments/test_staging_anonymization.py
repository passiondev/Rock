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

        for column in ["Email", "Number", "SearchValue", "FromEmail", "ReplyToEmail"]:
            self.assertIn(column, body, f"{column} is not anonymized")

    def test_the_reversed_phone_number_is_covered(self):
        """The one that gets forgotten. Rock maintains NumberReversed so that "ends
        with" searches can use an index. Rewriting Number and leaving it holding the
        reverse of the real number leaves the real number in the catalog, still
        searchable, under a column nobody thinks of as a phone number."""
        body = _strip_comments(ANONYMIZER.read_text())

        self.assertIn("NumberReversed", body)
        self.assertIn(
            "REVERSE(",
            body,
            "NumberReversed is named but not recomputed from the substitute",
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
