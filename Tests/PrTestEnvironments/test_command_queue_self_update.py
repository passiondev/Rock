import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"

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


if __name__ == "__main__":
    unittest.main()
