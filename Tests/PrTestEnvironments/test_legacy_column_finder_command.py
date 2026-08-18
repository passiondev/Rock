import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
AGENT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
FINDER = REPO_ROOT / "Deployment" / "Database" / "Find-LegacyTextColumns.ps1"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "db-find-legacy-text-columns.yml"

COMMAND = "find-legacy-text-columns"


class FinderIsReachableFromTheQueueTests(unittest.TestCase):
    """The finder shipped in PR #13 and reached the VM in PR #14, but nothing could
    *run* it. The catalog sits behind a Private Service Connect endpoint with no public
    IP, so no runner and no workstation can open it; and Cloud SQL will not let any
    login but the database's owner (`sqlserver`) into a database it owns, so a
    hand-made diagnostic login cannot substitute. The one process that already holds
    working credentials for that catalog is the deploy VM, which receives a connection
    string built from secrets.DB_USER/DB_PASSWORD on every deploy.

    So the finder runs where the credentials already are, through the queue that
    already carries them. That is what these tests pin."""

    def test_the_agent_dispatches_the_command_to_the_finder_script(self):
        agent = AGENT.read_text()

        self.assertIn(
            f'"{COMMAND}"',
            agent,
            "the queue agent has no branch for the finder, so a queued command hits "
            "the `default` arm and comes back as 'Unknown command'",
        )
        self.assertIn("Find-LegacyTextColumns.ps1", agent)

    def test_the_finder_branch_never_reaches_the_converter(self):
        """Find and Convert are separate scripts precisely so the read-only one can be
        pointed at any catalog without an audit. A dispatch that could reach the
        converter would erase that separation -- and this command is the one that will
        be aimed at production first.

        Comments are stripped before the check. Written against the raw text this
        failed on the branch's own comment explaining why the converter is absent --
        the same trap test_powershell_edition_compatibility.py grew _strip_comments
        for. An assertion that forbids naming the thing forbids documenting it."""
        offenders = [
            f"{lineno}: {line.strip()}"
            for lineno, line in enumerate(AGENT.read_text().splitlines(), start=1)
            if "Convert-LegacyTextColumns.ps1" in line.split("#", 1)[0]
        ]

        self.assertEqual(
            offenders,
            [],
            "the queue agent can invoke the -Apply-gated converter; only the read-only "
            "finder belongs on a path that a workflow_dispatch can trigger:\n  "
            + "\n  ".join(offenders),
        )

    def test_the_command_carries_its_connection_string_under_the_redacted_key(self):
        """Get-CommandSecrets only knows two property names. A command that spelled its
        credential anything else would hand a working production password to the
        uploaded log of a PUBLIC repository."""
        agent = AGENT.read_text()

        redacted_keys = re.search(
            r"foreach \(\$property in @\(([^)]*)\)\)", agent
        )
        self.assertIsNotNone(redacted_keys, "Get-CommandSecrets no longer lists the keys it redacts")
        self.assertIn("'connectionString'", redacted_keys.group(1))

        branch = _finder_branch(agent)
        self.assertIn(
            "$Command.connectionString",
            branch,
            "the finder branch reads its credential from a property Get-CommandSecrets "
            "does not redact",
        )

    def test_the_finder_branch_tolerates_a_command_with_no_optional_fields(self):
        """The runner body sets StrictMode. Reading a property that a queued command
        omitted is a terminating error there, not $null -- which is why every optional
        field in the deploy-environment branch is guarded by a Properties.Name check."""
        branch = _finder_branch(AGENT.read_text())

        self.assertIn(
            "PSObject.Properties.Name -contains 'measureSizes'",
            branch,
            "measureSizes is read unguarded; a command that omits it dies under StrictMode",
        )

    def test_the_agent_gives_the_command_its_own_timeout(self):
        """Without an entry the command falls back to 600s. The finder's own SQL
        timeout defaults to 300s and -MeasureSizes full-scans every affected table on a
        115 GB catalog, so the fallback would kill real work part-way and report it as
        a failure."""
        agent = AGENT.read_text()

        match = re.search(rf"'{COMMAND}'\s*=\s*(\d+)", agent)
        self.assertIsNotNone(match, f"no timeout entry for '{COMMAND}'")
        self.assertGreaterEqual(
            int(match.group(1)),
            900,
            "the finder's timeout is under 15 minutes; a sized scan of a prod-derived "
            "catalog will not finish in that",
        )


class FinderWorkflowTests(unittest.TestCase):
    def test_the_workflow_exists_and_is_manually_triggered(self):
        self.assertTrue(WORKFLOW.exists(), f"{WORKFLOW.relative_to(REPO_ROOT)} is missing")
        text = WORKFLOW.read_text()

        self.assertIn("workflow_dispatch", text)
        self.assertIn(COMMAND, text)

    def test_the_workflow_builds_the_connection_string_from_secrets(self):
        """The whole point of routing through the VM is that nobody has to hold this
        credential. It has to come from the same secrets the deploy uses."""
        text = WORKFLOW.read_text()

        for secret in ["secrets.DB_USER", "secrets.DB_PASSWORD"]:
            self.assertIn(secret, text, f"the workflow does not read {secret}")

    def test_the_workflow_never_echoes_the_command_it_queues(self):
        """env-deploy-command.yml rebuilds the command key by key before printing it,
        rather than regex-scrubbing, so a password containing a quote cannot leak a
        fragment. Anything that prints the raw command object undoes that."""
        text = WORKFLOW.read_text()

        # Line-based rather than one regex with a lookahead: the first attempt at this
        # put the lookahead after the newline, so it inspected the *following* line and
        # flagged the safe `| Out-File command.json` write.
        printed = [
            line.strip()
            for line in text.splitlines()
            if "$command" in line and "ConvertTo-Json" in line and "Out-File" not in line
        ]
        self.assertEqual(
            printed,
            [],
            "the workflow pipes the command object straight to output; the connection "
            "string goes with it:\n  " + "\n  ".join(printed),
        )
        self.assertIn("<redacted>", text)

    def test_the_workflow_outlasts_the_timeout_the_agent_enforces(self):
        """Stated as prose beside $CommandTimeoutsSeconds and never enforced: 'Defaults
        are kept comfortably under each workflow's own poll window so the workflow
        reports the failure rather than timing out first.' If the poll gives up first,
        the operator sees 'timed out waiting for a result' for a scan that was still
        running and would have succeeded."""
        agent = AGENT.read_text()
        text = WORKFLOW.read_text()

        agent_timeout = int(re.search(rf"'{COMMAND}'\s*=\s*(\d+)", agent).group(1))

        # Scoped to the poll_attempts input block -- its description is long enough
        # that a bounded [\s\S]{0,200} window stopped short of the default and made
        # this look like a missing input.
        block = re.search(r"\n      poll_attempts:\n(.*?)(?=\n      \w|\n\w)", text, re.DOTALL)
        self.assertIsNotNone(block, "the workflow does not declare a poll_attempts input")
        attempts = re.search(r"default:\s*(\d+)", block.group(1))
        self.assertIsNotNone(attempts, "the workflow does not declare poll_attempts")
        sleep = re.search(r"Start-Sleep -Seconds (\d+)", text)
        self.assertIsNotNone(sleep, "the workflow's poll loop does not sleep")

        window = int(attempts.group(1)) * int(sleep.group(1))
        self.assertGreater(
            window,
            agent_timeout,
            f"the poll window ({window}s) does not outlast the agent's timeout "
            f"({agent_timeout}s), so a slow scan is reported as a workflow timeout "
            f"rather than the real result",
        )


class FinderWorkflowInputsAreNotInterpolatedTests(unittest.TestCase):
    """The general rule -- no operator-typed input pasted into a script body -- lives in
    test_workflow_input_injection.py and covers every workflow at once. It did not
    catch this one, because it treated `number` as a constrained type; that scan has
    since been widened, and the duplicate copy of the rule that briefly lived here has
    been removed in favour of it.

    What stays here is what the repo-wide scan cannot know: the two specific shapes
    this workflow needs, and why."""

    def test_the_queue_name_is_validated_before_it_becomes_a_path(self):
        """queue_name is concatenated into a GCS object path. The agent validates its
        own QueueName against ^[a-z][a-z0-9-]{1,30}$ for the same reason; the workflow
        that writes the object should not be laxer than the one that reads it."""
        text = WORKFLOW.read_text()

        self.assertTrue(
            "a-z0-9-" in text,
            "the workflow builds a bucket path from queue_name without validating it",
        )

    def test_the_poll_count_is_read_as_a_number_not_pasted_as_code(self):
        text = WORKFLOW.read_text()

        self.assertFalse(
            "$attempts = ${{" in text,
            "the poll count is pasted into the script body as code",
        )
        self.assertTrue(
            "POLL_ATTEMPTS" in text,
            "the poll count no longer arrives through env:",
        )


class FinderReachesTheVmTests(unittest.TestCase):
    def test_the_finder_is_published_to_the_location_the_agent_syncs_from(self):
        """Belt and braces on PR #14. The dispatch above is worthless if the script is
        not on the box: the agent would report 'Unknown command'-adjacent failure --
        actually a missing-file error -- from a path nobody looks at."""
        publisher = (REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml").read_text()

        self.assertIn("Deployment/Database/*.ps1", publisher)
        self.assertTrue(FINDER.exists())


def _finder_branch(agent_text):
    """The body of the switch arm, from its label to the start of the next arm."""
    match = re.search(
        rf'"{COMMAND}"\s*\{{(.*?)\n        \}}',
        agent_text,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"no '{COMMAND}' switch arm found in the queue agent")
    return match.group(1)


if __name__ == "__main__":
    unittest.main()
