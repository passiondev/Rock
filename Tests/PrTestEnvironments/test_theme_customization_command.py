"""Static checks on the theme-customization path: script, queue arm, workflow.

Nothing here executes anything. There is no SQL Server in CI, no PowerShell job
that reaches a catalog, and no Rock instance to render against -- so these assert
the properties that make the path safe to point at production's catalog on
cutover day, and the properties that keep the three pieces pointing at each other.

WHAT THIS GUARDS

The internal site's branding is stored in two halves. The .less half is committed
and ships in every artifact. The other half is one column on one row --
Theme.AdditionalSettingsJson -- and it is per-catalog, so no deploy carries it
anywhere. It reached staging by somebody typing it into Admin Tools, which is
exactly the kind of value that exists in one place and is discovered missing by
looking at a stock-blue production site.

Set-RockThemeCustomization.ps1 is the reproducible form of that hand edit, and
the v19 cutover is when it gets used in anger: migration
202508051740308_Rollup_20250805 repoints the internal site at the RockNextGen
theme unconditionally, so production starts rendering from a row whose
customization column is empty.

WHY THE CROSS-LANGUAGE ASSERTIONS ARE HERE

Two values in the PowerShell script are copies of C# facts -- the settings key
and the two purposes that consume customization. Both fail silently when they
drift: a wrong key writes valid JSON to a property Rock never reads, and a wrong
purpose list downgrades a "this will not be visible" warning into silence. The
run reports success either way. So the tests read the C# and compare.
"""

import re
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
THEME_SCRIPT = REPO_ROOT / "Deployment" / "Database" / "Set-RockThemeCustomization.ps1"
THEME_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "db-set-theme-customization.yml"
VALIDATOR = REPO_ROOT / ".github" / "scripts" / "Test-ThemeCustomizationInput.ps1"
QUEUE_AGENT = (
    REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
)
THEME_COMMAND = "set-theme-customization"

# The C# this script is a copy of.
SETTINGS_CLASS = REPO_ROOT / "Rock" / "Cms" / "ThemeCustomizationSettings.cs"
SYSTEM_GUIDS = REPO_ROOT / "Rock" / "SystemGuid" / "DefinedValue.cs"
THEME_SERVICE = REPO_ROOT / "Rock" / "Model" / "CMS" / "Theme" / "ThemeService.cs"


def _strip_comments(text):
    """Drop block and line comments from PowerShell.

    Every claim here is about what the script does, and the script explains all of
    it in prose -- it names the settings key, it describes the merge, it says the
    rollback is written first. A scan that could not tell an explanation from the
    thing explained would be satisfied by a script that only commented."""
    text = re.sub(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.DOTALL)
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def _locate(case, text, needle, what):
    """Index of `needle`, or a failure naming what went missing.

    The ordering tests below are all `index(a) < index(b)`, and deleting either
    anchor is a real regression -- but through str.index it surfaces as
    "ValueError: substring not found" from inside the test, which says nothing
    about which of the two disappeared."""
    index = text.find(needle)
    case.assertNotEqual(index, -1, f"{what} is gone from the script")
    return index


def _agent_arm():
    """The switch arm for this command, comments removed."""
    agent = _strip_comments(QUEUE_AGENT.read_text())
    arm = agent[agent.index(f'"{THEME_COMMAND}" {{') :]
    return arm[: arm.index("default {")]


class ScriptExistsTests(unittest.TestCase):
    def test_the_script_exists(self):
        self.assertTrue(THEME_SCRIPT.exists(), f"{THEME_SCRIPT} does not exist")


class MirrorsRockTests(unittest.TestCase):
    """The two values copied out of C#."""

    def test_the_settings_key_is_the_name_of_rocks_settings_class(self):
        """AdditionalSettingsExtensions.SetAdditionalSettings<TSettings> keys the
        document by typeof( TSettings ).Name, so the key Rock reads is literally the
        class name. Write to any other key and the JSON is valid, the run reports
        success, and Rock reads straight past it."""
        source = SETTINGS_CLASS.read_text()
        match = re.search(r"\bclass\s+(ThemeCustomizationSettings)\b", source)
        self.assertIsNotNone(
            match,
            f"{SETTINGS_CLASS.name} no longer declares the class this key is copied "
            "from -- the script's key is now guessing",
        )

        script = _strip_comments(THEME_SCRIPT.read_text())
        self.assertRegex(
            script,
            rf'\$SettingsKey\s*=\s*"{match.group(1)}"',
            "the script writes to a key that is not the settings class's name",
        )

    def test_the_customizable_purposes_are_the_ones_rock_checks(self):
        """GetThemeCssContent returns the file unchanged unless the theme's purpose
        is one of these two. A theme with any other purpose accepts the write and
        renders none of it, so the script warns -- and can only warn about the
        purposes it knows."""
        guids = SYSTEM_GUIDS.read_text()

        expected = {}
        for constant in ("THEME_PURPOSE_WEBSITE_NEXTGEN", "THEME_PURPOSE_CHECKIN"):
            match = re.search(rf'{constant}\s*=\s*"([0-9A-Fa-f-]+)"', guids)
            self.assertIsNotNone(match, f"{constant} is gone from {SYSTEM_GUIDS.name}")
            expected[constant] = match.group(1).lower()

        script = _strip_comments(THEME_SCRIPT.read_text())
        declared = set(
            re.findall(
                r'"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"\s*=',
                script,
            )
        )

        self.assertEqual(
            declared,
            set(expected.values()),
            "the script's customizable-purpose list has drifted from "
            f"{SYSTEM_GUIDS.name}; a purpose missing here is a write that reports "
            "success and renders nothing, with no warning",
        )

    def test_rock_still_gates_on_exactly_those_two_purposes(self):
        """The pair above is only the right pair while GetThemeCssContent tests
        against both and nothing else. A third purpose added on the C# side would
        make the script's warning fire on a theme that does render."""
        source = THEME_SERVICE.read_text()
        body = source[source.index("string GetThemeCssContent(") :]
        body = body[: body.index("return fileContent;")]

        purposes = set(re.findall(r"DefinedValue\.(THEME_PURPOSE_\w+)", body))
        self.assertEqual(
            purposes,
            {"THEME_PURPOSE_WEBSITE_NEXTGEN", "THEME_PURPOSE_CHECKIN"},
            "GetThemeCssContent's purpose guard has changed shape; the script's "
            "warning is now judging against the wrong set",
        )


class MergesRatherThanOverwritesTests(unittest.TestCase):
    """The column holds more than this script sets.

    Rock's own writer does AddOrReplace on one key of the root document and leaves
    the siblings alone. Staging's row carries EnabledIconSets and
    AdditionalFontAwesomeWeights beside the colours; a writer that serialized only
    what it was given would take the icon sets out and report success."""

    def test_the_current_value_is_read_before_it_is_replaced(self):
        script = _strip_comments(THEME_SCRIPT.read_text())

        self.assertIn("AdditionalSettingsJson", script)
        self.assertRegex(
            script,
            r"SELECT[\s\S]{0,400}?\[AdditionalSettingsJson\][\s\S]{0,400}?FROM\s+\[dbo\]\.\[Theme\]",
            "the script never selects the column it is about to replace, so it "
            "cannot be merging into it",
        )

    def test_an_unparseable_value_stops_the_run(self):
        """Refusing is the only safe answer. The alternative -- treating a document
        this script cannot read as absent -- deletes whatever a later Rock version
        put there, and the run says it succeeded."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        self.assertRegex(
            script,
            r"throw\s+\"Theme Id \$themeId has an AdditionalSettingsJson this script cannot parse",
            "the script overwrites a document it failed to parse",
        )

    def test_a_missing_theme_stops_the_run(self):
        """Naming a theme that does not exist is the expected outcome of running
        this against a catalog still on 18.x, and it has to be an error rather than
        a no-op: the reason to run it at all is that the branding is missing."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        self.assertRegex(script, r"throw\s+\"No theme named")
        self.assertRegex(
            script,
            r"throw\s+\"Name '\$ThemeName' matches \$matchCount themes",
            "a name matching several themes picks one instead of refusing",
        )


class DryRunByDefaultTests(unittest.TestCase):
    def test_apply_is_a_switch_and_not_a_default(self):
        script = THEME_SCRIPT.read_text()

        self.assertRegex(
            script,
            r"\[switch\]\s*\$Apply",
            "Apply is not a switch, so it may carry a default",
        )
        self.assertNotRegex(_strip_comments(script), r"\$Apply\s*=\s*\$true")

    def test_the_update_is_unreachable_without_the_apply_gate(self):
        """The dry run returns before the write rather than skipping past it, so
        there is one exit and not a second path that could be added below it."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        gate = _locate(self, script, "if (-not $Apply)", "the Apply gate")
        write = _locate(
            self,
            script,
            "UPDATE [dbo].[Theme]\nSET [AdditionalSettingsJson] = @json",
            "the UPDATE",
        )

        self.assertLess(gate, write, "the write is not behind the Apply gate")
        self.assertRegex(
            script[gate:write],
            r"return",
            "the Apply gate does not return, so the write runs anyway",
        )


class RollbackTests(unittest.TestCase):
    def test_the_rollback_is_written_before_the_write(self):
        script = _strip_comments(THEME_SCRIPT.read_text())

        rollback = _locate(self, script, "$rollbackLines | Out-File", "the rollback")
        write = _locate(
            self,
            script,
            "UPDATE [dbo].[Theme]\nSET [AdditionalSettingsJson] = @json",
            "the UPDATE",
        )

        self.assertLess(
            rollback,
            write,
            "the rollback is generated after the write, so a write that fails "
            "part-way leaves nothing to undo it with",
        )

    def test_the_dry_run_produces_the_same_rollback_the_apply_would(self):
        """Not decoration. The dry run's whole job is to be the rehearsal, and a
        rollback only the apply path writes is a rollback nobody has ever seen
        before the moment they need it."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        rollback = _locate(self, script, "$rollbackLines | Out-File", "the rollback")
        gate = _locate(self, script, "if (-not $Apply)", "the Apply gate")

        self.assertLess(
            rollback,
            gate,
            "the rollback is written inside the apply path, so a dry run never "
            "produces one",
        )

    def test_the_rollback_addresses_the_row_by_explicit_id(self):
        script = _strip_comments(THEME_SCRIPT.read_text())

        rollback_statements = re.findall(
            r"UPDATE \[dbo\]\.\[Theme\] SET \[AdditionalSettingsJson\] = .*?WHERE (.*?);",
            script,
        )
        self.assertTrue(rollback_statements, "no rollback UPDATE is generated")
        for predicate in rollback_statements:
            self.assertEqual(
                predicate.strip(),
                "[Id] = $themeId",
                "a rollback statement matches on something other than the row Id",
            )

    def test_the_rollback_restores_the_string_that_was_read(self):
        """Restoring a re-serialized equivalent would mean the undo is also an edit.
        Windows PowerShell escapes characters Rock's serializer leaves alone, so
        round-tripping the document changes its bytes even when nothing about it
        changed."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        self.assertIn("ConvertTo-SqlLiteral $currentJson", script)
        self.assertNotIn("ConvertTo-SqlLiteral $newJson", script)

    def test_the_write_asserts_it_touched_one_row(self):
        script = _strip_comments(THEME_SCRIPT.read_text())

        self.assertRegex(
            script,
            r"throw\s+\"Expected to update exactly 1 row",
            "the script does not check how many rows it changed",
        )


class ConnectionStringHandlingTests(unittest.TestCase):
    def test_the_connection_string_is_never_written_to_output(self):
        """It carries the SQL password. The queue agent writes this script's stdout
        to a GCS log the workflow then pastes into a job summary."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        for match in re.finditer(r"Write-(?:Host|Output|Warning|Error).*", script):
            self.assertNotIn(
                "$ConnectionString",
                match.group(0),
                f"the connection string reaches the log: {match.group(0).strip()}",
            )

    def test_the_connection_string_can_be_supplied_out_of_band(self):
        """The agent hands it over as a parameter, out of the queued document, so
        the document that lands in a bucket does not carry a password."""
        script = _strip_comments(THEME_SCRIPT.read_text())

        self.assertIn("ROCK_DB_CONNECTION_STRING", script)


class TheCommandCanActuallyBeRunTests(unittest.TestCase):
    """The three pieces that have to agree, and the ways they drift apart.

    test_legacy_text_columns.py records what happens when they do: the v19 cutover
    carried a script and its runbook forward and left the bootstrap, the command
    and the workflow behind, and every test stayed green because losing the
    ability to run it was not one of the things anything was looking at."""

    def test_the_queue_agent_invokes_the_script_by_the_name_it_has(self):
        arm = _agent_arm()

        self.assertIn(
            THEME_SCRIPT.name,
            arm,
            "the arm does not name the script -- renaming the file left the arm "
            "pointing at a path that does not exist",
        )

    def test_the_workflow_queues_the_command_the_agent_answers_to(self):
        """Both jobs. The plan job matching and the apply job not would mean the
        approval gate opens onto an unknown-command error."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        queued = [
            step["with"]["command"]
            for job in workflow["jobs"].values()
            for step in job["steps"]
            if str(step.get("uses", "")).endswith("queue-vm-command")
        ]

        self.assertEqual(len(queued), 2, "expected one queued command per job")
        for command in queued:
            self.assertEqual(command, THEME_COMMAND)

        self.assertIn(f'"{THEME_COMMAND}" {{', _strip_comments(QUEUE_AGENT.read_text()))

    def test_the_agent_requires_a_theme_name(self):
        """Defaulting it would pick a theme on the operator's behalf, against a
        catalog they named explicitly."""
        arm = _agent_arm()

        self.assertRegex(arm, r"throw\s+\"set-theme-customization requires a themeName")
        self.assertRegex(
            arm, r"throw\s+\"set-theme-customization requires a connectionString"
        )

    def test_the_agent_defaults_the_command_to_a_dry_run(self):
        arm = _agent_arm()

        self.assertRegex(
            arm,
            r"-contains 'apply'\)\s*-and\s*\$Command\.apply\)",
            "the agent does not gate Apply on the command explicitly asking for it",
        )

    def test_the_agent_decides_the_override_block_on_presence(self):
        """Every other optional field here degrades on whitespace. This one must
        not: an empty string is how an operator clears the block, and reading that
        as absent makes clearing it impossible."""
        arm = _agent_arm()

        match = re.search(r".*contains 'customOverrides'.*", arm)
        self.assertIsNotNone(match, "the arm does not forward customOverrides at all")
        self.assertNotIn(
            "IsNullOrWhiteSpace",
            match.group(0),
            "an empty override block is treated as absent, so it can never be cleared",
        )

    def test_the_command_has_a_timeout(self):
        """One SELECT and one UPDATE against a table with a handful of rows. Short
        on purpose, unlike the anonymizer's hour: nothing here can legitimately take
        minutes, so a run that hangs is a lock, and failing fast says so."""
        agent = QUEUE_AGENT.read_text()

        match = re.search(rf"'{THEME_COMMAND}'\s*=\s*(\d+)", agent)
        self.assertIsNotNone(match, "no timeout is declared for the command")
        self.assertLessEqual(
            int(match.group(1)),
            600,
            "the timeout is at or above the fallback, so declaring it buys nothing",
        )


class WorkflowGatesTests(unittest.TestCase):
    def test_the_workflow_exists_and_is_dispatchable(self):
        self.assertTrue(THEME_WORKFLOW.exists(), f"{THEME_WORKFLOW.name} does not exist")

        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())
        self.assertIn("workflow_dispatch", workflow["on"])

    def test_the_catalog_is_required_and_has_no_fallback(self):
        """db-find-legacy-text-columns.yml falls back to secrets.DB_NAME when its
        box is empty, which is right for a read. The same fallback here aims a write
        at the catalog the whole pr-* fleet shares because somebody tabbed past a
        field."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        self.assertTrue(
            workflow["on"]["workflow_dispatch"]["inputs"]["db_name"]["required"],
            "db_name is optional",
        )
        self.assertNotIn("inputs.db_name || secrets.DB_NAME", THEME_WORKFLOW.read_text())

    def test_the_dispatch_defaults_to_a_dry_run(self):
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        self.assertIs(
            workflow["on"]["workflow_dispatch"]["inputs"]["apply"]["default"],
            False,
            "the workflow defaults to writing",
        )

    def test_the_two_jobs_queue_opposite_apply_flags(self):
        """The plan job's payload saying apply true would make the dry run the
        write, and the gate below it theatre."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        payloads = {
            name: [
                step["with"]["payload"]
                for step in job["steps"]
                if str(step.get("uses", "")).endswith("queue-vm-command")
            ][0]
            for name, job in workflow["jobs"].items()
        }

        self.assertIn('"apply": false', payloads["plan"])
        self.assertIn('"apply": true', payloads["apply"])

    def test_the_write_waits_for_the_dry_run_and_for_a_person(self):
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())
        apply_job = workflow["jobs"]["apply"]

        self.assertEqual(apply_job["needs"], "plan", "the write does not wait for the plan")
        # Normalised, because `if: inputs.apply` and `if: ${{ inputs.apply }}` are
        # the same job-level condition. Compared whole rather than searched for, so
        # that `inputs.apply == false` is a failure and not a match.
        self.assertIn(
            "if",
            apply_job,
            "the write job carries no condition at all, so it runs on every dispatch",
        )
        condition = re.sub(r"^\$\{\{|\}\}$", "", str(apply_job["if"])).strip()
        self.assertEqual(
            condition,
            "inputs.apply",
            "the write job runs on every dispatch, dry run or not",
        )
        self.assertTrue(
            apply_job.get("environment"),
            "no environment on the write job, so -Apply is one dispatch box away "
            "from a catalog with nobody else in the loop",
        )

    def test_both_jobs_validate_what_the_operator_typed(self):
        """Separate runners with no state between them. The plan job validating and
        the apply job not would mean the checked input is not the applied input."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        for name, job in workflow["jobs"].items():
            validating = [
                step for step in job["steps"] if VALIDATOR.name in str(step.get("run", ""))
            ]
            self.assertTrue(validating, f"the {name} job does not run {VALIDATOR.name}")

    def test_the_validator_is_checked_out_where_the_jobs_run_it(self):
        """A sparse checkout that omits .github/scripts leaves both jobs failing on
        a missing file, and the failure looks like a broken path rather than a
        missing directory."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        for name, job in workflow["jobs"].items():
            checkouts = [
                step["with"]["sparse-checkout"]
                for step in job["steps"]
                if str(step.get("uses", "")).startswith("actions/checkout")
            ]
            self.assertTrue(checkouts, f"the {name} job never checks anything out")
            self.assertIn(
                ".github/scripts",
                checkouts[0],
                f"the {name} job runs the validator without checking it out",
            )

    def test_the_dispatch_boxes_never_reach_the_shell_as_script(self):
        """The step holding a live connection string is a step whose text a
        dispatch box should not be able to change. The values go in through env:
        and are read as $env: -- the reason db-find-legacy-text-columns.yml gives
        for the same shape."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        for name, job in workflow["jobs"].items():
            for step in job["steps"]:
                script = str(step.get("run", ""))
                self.assertNotIn(
                    "${{ inputs.",
                    script,
                    f"a dispatch value is interpolated into a run: block in the "
                    f"{name} job",
                )


class SerialisedWithItselfTests(unittest.TestCase):
    def test_two_runs_cannot_race_on_the_same_column(self):
        """The loser's rollback restores a value the winner already replaced, so
        the undo silently reverts somebody else's write."""
        workflow = yaml.safe_load(THEME_WORKFLOW.read_text())

        self.assertIn("concurrency", workflow)
        self.assertIs(
            workflow["concurrency"]["cancel-in-progress"],
            False,
            "an in-flight write is cancelled part-way by the next dispatch",
        )


if __name__ == "__main__":
    unittest.main()
