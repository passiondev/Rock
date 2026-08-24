import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
CERTIFICATE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-renew-certificates.yml"

# Every workflow that writes a .ps1 into bootstrap/latest. Both have to set a text
# content type; see ContentTypeOfPublishedScriptsTests for what happens when one does not.
SCRIPT_PUBLISHERS = (BOOTSTRAP_WORKFLOW, CERTIFICATE_WORKFLOW)

# The line the sync has to beat. Commands are dispatched from $DeployRoot and resolved at
# call time, so a refresh that lands before this line takes effect on the very command
# being processed -- and a refresh that lands after it is a full poll cycle late.
DISPATCH_ANCHOR = '$commands = Get-GcsObjectList -Prefix $PendingPrefix'


class CommandQueueSelfUpdateTests(unittest.TestCase):
    """Without this, a fix to any script in Deployment/PrTestEnvironments reaches the VM
    only when devops re-bootstraps it by hand. Three separate teardown bugs sat fixed in
    the repository and broken on the VM at the same time because of that gap, and nothing
    about the repository state made it visible -- the scripts looked deployed."""

    def setUp(self):
        self.text = QUEUE_SCRIPT.read_text()

    def test_the_dispatch_anchor_still_exists(self):
        """Every ordering assertion below is measured against this line. If it is renamed
        the assertions would silently compare -1 to -1 and pass."""
        self.assertIn(
            DISPATCH_ANCHOR,
            self.text,
            "the command-fetch line moved; the ordering assertions below are no longer "
            "measuring anything",
        )

    def test_the_agent_refreshes_its_scripts_from_the_bootstrap_prefix(self):
        self.assertIn(
            "pr-environments/bootstrap/latest/",
            self.text,
            "the agent never reads the bootstrap prefix, so it cannot pick up script fixes",
        )

    def test_the_refresh_runs_before_commands_are_dispatched(self):
        """A refresh after the fetch would still work eventually, but every fix would be
        one poll cycle late and the failure it fixed would be reported once more first."""
        self.assertIn("Sync-DeploymentScripts", self.text)

        called = [
            index
            for index, line in enumerate(self.text.splitlines())
            if "Sync-DeploymentScripts" in line and "function" not in line
        ]
        self.assertTrue(called, "Sync-DeploymentScripts is defined but never called")

        anchor = next(
            index
            for index, line in enumerate(self.text.splitlines())
            if DISPATCH_ANCHOR in line
        )
        self.assertLess(
            min(called),
            anchor,
            "the script refresh runs after commands are fetched, so a fix lands a full "
            "poll cycle late",
        )

    def test_a_broken_download_cannot_brick_the_agent(self):
        """The agent overwrites the very scripts it runs. Writing a file that does not
        parse would make every subsequent command fail, and the agent has no way back --
        the next sync would fetch the same broken file again. Parse before replacing."""
        self.assertIn(
            "[System.Management.Automation.Language.Parser]::ParseInput",
            self.text,
            "downloaded scripts are written without a parse check; one bad upload would "
            "brick the agent permanently",
        )

    def test_a_failed_refresh_does_not_stop_commands_from_running(self):
        """The refresh is an improvement to the agent, not a precondition for it. A GCS
        blip must not stop the queue draining -- that would turn a transient network
        error into a dead environment fleet, which is strictly worse than the stale
        scripts this feature exists to avoid."""
        start = self.text.index("function Sync-DeploymentScripts")
        end = self.text.index(DISPATCH_ANCHOR)
        body = self.text[start:end]

        self.assertIn("catch", body, "the refresh has no failure path")
        self.assertIn(
            "Write-Warning",
            body,
            "a failed refresh is swallowed silently, so stale scripts look like fresh ones",
        )

    def test_one_unreplaceable_file_does_not_abort_the_rest_of_the_refresh(self):
        """This script is itself in the list it syncs, and Windows may hold it open while
        it runs, so replacing it can fail. Handled at the loop level rather than per file,
        that failure would abandon the whole refresh -- and since names are processed in
        listing order, Invoke-PrEnvironmentCommandQueue sorts before Stop-PrEnvironment,
        so the file guaranteed to be skipped is one of the two the teardown depends on.

        Two handlers are required: one inside the per-file loop, one around the call."""
        start = self.text.index("function Sync-DeploymentScripts")
        end = self.text.index(DISPATCH_ANCHOR)
        region = self.text[start:end]

        self.assertGreaterEqual(
            region.count("catch"),
            2,
            "only one failure handler between the sync and the dispatch; a single "
            "locked file still aborts every remaining script",
        )

        loop = region.index("foreach ($object in $objects)")
        self.assertIn(
            "catch",
            region[loop:],
            "the per-file failure handler is outside the loop, so the first failure "
            "abandons every file after it",
        )

    def test_the_refresh_replaces_files_atomically(self):
        """A partial write leaves a truncated script on disk, which is the brick this
        whole guard exists to prevent."""
        self.assertIn(
            "Move-Item",
            self.text,
            "downloaded scripts are written in place rather than staged and moved",
        )

    def test_the_bootstrap_still_publishes_what_the_agent_reads(self):
        """The two halves are in different files and nothing else ties them together. If
        the upload prefix moves, the agent silently syncs an empty directory forever."""
        workflow = BOOTSTRAP_WORKFLOW.read_text()

        self.assertIn(
            "pr-environments/bootstrap/latest/",
            workflow,
            "the bootstrap no longer publishes to the prefix the agent reads",
        )


class ContentTypeOfPublishedScriptsTests(unittest.TestCase):
    """The refresh above was dead for its entire life, and every test in this file passed
    while it was.

    gsutil types a .ps1 as application/octet-stream. Invoke-WebRequest returns .Content as
    a byte[] for anything outside the text, JSON and XML families, so Read-GcsObjectText
    handed Sync-DeploymentScripts a byte array where it wanted text. The parse check saw
    "35 32 82 111 ...", rejected it, and kept the copy on disk -- per file, per poll,
    warning to a stream nothing collects. The command queue was never affected because
    command objects are written as application/json, which is why the box looked healthy.

    Measured 2026-08-24: a script published straight to bootstrap/latest failed to reach
    the VM across two dispatches 36 minutes apart, on an agent whose source contained the
    refresh and whose tests were green.

    The decode in Read-GcsObjectText is the real fix and is tested for behaviour in
    Pester/ScriptDelivery.Tests.ps1. These two assertions cover the other end, which
    Pester cannot see: publishing the scripts as text, so the byte path is not reached at
    all on a VM still running an older agent."""

    def test_every_publisher_sets_a_text_content_type(self):
        for workflow in SCRIPT_PUBLISHERS:
            with self.subTest(workflow=workflow.name):
                self.assertIn(
                    'gsutil -h "Content-Type:text/plain',
                    workflow.read_text(),
                    f"{workflow.name} publishes .ps1 files without a text content type, so "
                    "the agent fetches them as a byte[] and skips every one",
                )

    def test_no_publisher_uploads_scripts_untyped(self):
        """A second copy of the upload added later would default to octet-stream again and
        break the refresh for whichever files it touched, without failing the test above."""
        for workflow in SCRIPT_PUBLISHERS:
            for line in workflow.read_text().splitlines():
                stripped = line.strip()
                if not stripped.startswith("gsutil") or "bootstrap/latest" not in stripped:
                    continue
                with self.subTest(workflow=workflow.name, line=stripped[:60]):
                    self.assertIn(
                        "Content-Type:text/plain",
                        stripped,
                        f"{workflow.name} has a gsutil upload to bootstrap/latest that does "
                        f"not set a text content type: {stripped}",
                    )


class ScriptRefreshReadsTextTests(unittest.TestCase):
    """Guards the two lines that make the refresh able to deliver anything at all."""

    def setUp(self):
        self.text = QUEUE_SCRIPT.read_text()

    def test_the_reader_decodes_bytes_to_text(self):
        self.assertIn(
            "[System.Text.Encoding]::UTF8.GetString",
            self.text,
            "Read-GcsObjectText returns .Content unconverted, so an octet-stream object "
            "arrives as a byte[] and never parses",
        )

    def test_the_refresh_ignores_nested_objects(self):
        """bootstrap/latest/ also holds a PrTestEnvironments/ folder of April 2026
        scaffolding. Split-Path -Leaf flattens those onto the same destination names, so
        without this the refresh overwrites eight live scripts with four-month-old stubs
        the moment it starts working."""
        self.assertIn(
            "$_.Substring($Prefix.Length).Contains('/')",
            self.text,
            "Sync-DeploymentScripts takes objects from subdirectories of the prefix and "
            "flattens their names onto the top-level scripts",
        )


if __name__ == "__main__":
    unittest.main()
