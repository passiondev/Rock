import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
CERTIFICATE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-renew-certificates.yml"

# Every workflow that writes a .ps1 into bootstrap/latest. Both have to set a text
# content type; see ContentTypeOfPublishedScriptsTests for what happens when one does not.
SCRIPT_PUBLISHERS = (BOOTSTRAP_WORKFLOW, CERTIFICATE_WORKFLOW)


class CommandQueueSelfUpdateTests(unittest.TestCase):
    """Without this, a fix to any script in Deployment/PrTestEnvironments reaches the VM
    only when devops re-bootstraps it by hand. Three separate teardown bugs sat fixed in
    the repository and broken on the VM at the same time because of that gap, and nothing
    about the repository state made it visible -- the scripts looked deployed.

    This class used to hold five more tests, and each one matched source text. Two
    claimed the refresh runs before the queue is listed and that a refresh that throws
    still lets the queue drain; Pester/CommandQueuePass.Tests.ps1 now runs the poll pass
    against an in-memory queue and checks both. Two claimed a download that does not
    parse, or cannot be fetched, leaves the rest of the refresh alone;
    Pester/ScriptDelivery.Tests.ps1 runs both. The fifth checked that the line the
    ordering tests measured from still existed, and there is no longer a line to measure.

    What is left here is what Pester cannot observe: a prefix the two halves have to
    agree on, and a property of the write that a test cannot catch happening."""

    def setUp(self):
        self.text = QUEUE_SCRIPT.read_text()

    def test_the_agent_refreshes_its_scripts_from_the_bootstrap_prefix(self):
        """Kept beside the bootstrap test below because the two are one pairing, split
        across two files. test_production_bootstrap.py pins the same default for a
        different reason -- the installed task on the test VM relies on it."""
        self.assertIn(
            "pr-environments/bootstrap/latest/",
            self.text,
            "the agent never reads the bootstrap prefix, so it cannot pick up script fixes",
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
