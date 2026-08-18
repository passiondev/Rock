import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
STOP_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Stop-PrEnvironment.ps1"
DESTROY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Destroy-PrEnvironment.ps1"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-lifecycle.yml"


class PrTestLifecycleTests(unittest.TestCase):
    def test_stop_and_destroy_scripts_are_pr_keyed_and_idempotent(self):
        stop = STOP_SCRIPT.read_text()
        destroy = DESTROY_SCRIPT.read_text()

        for text in [stop, destroy]:
            self.assertIn('$SiteName = "rock-pr-$PrNumber"', text)
            self.assertIn('$AppPoolName = "rock-pr-$PrNumber"', text)
            self.assertIn('Join-Path $EnvironmentRoot "pr-$PrNumber"', text)
            self.assertIn('Test-Path', text)

        self.assertIn('Stop-WebAppPool', stop)
        self.assertIn('Stop-Website', stop)
        self.assertIn('status = "stopped"', stop)
        self.assertNotIn('Remove-Item $EnvironmentPath', stop)

        self.assertIn('Remove-Website', destroy)
        self.assertIn('Remove-WebAppPool', destroy)
        self.assertIn('Remove-Item $EnvironmentPath', destroy)

    def test_lifecycle_workflow_handles_labels_and_pr_close_events(self):
        text = WORKFLOW.read_text()

        self.assertIn('types: [labeled, closed]', text)
        self.assertIn('rock:stop', text)
        self.assertIn('rock:destroy', text)
        self.assertIn('merged', text)
        self.assertIn('commands/pending', text)
        self.assertIn('commands/results', text)
        self.assertIn('Poll PR environment command result', text)
        self.assertIn('updatePrTestStatus', text)
        self.assertIn('removeLabel', text)

    def test_label_cleanup_cannot_abort_the_teardown_it_precedes(self):
        """Removing the command label is housekeeping. It ran before the queue step and
        rethrew everything except 404, so a failure to tidy a label stopped `stop` and
        `destroy` from ever being queued.

        403 is the case that matters, and it is permanent rather than transient: this
        repository has Issues disabled (`has_issues: false`), and PR labels live on the
        issues API, so the Actions token's `issues: write` scope is inert against them.
        A user PAT is unaffected, which is why the labels look editable right up until
        Actions tries it -- and then every teardown fails, by label and by dispatch
        alike, with "Resource not accessible by integration".

        Pinned as a behaviour rather than a string: whatever the catch looks like, a
        teardown must not be abandoned because a label could not be removed."""
        text = WORKFLOW.read_text()

        self.assertIn('removeLabel', text, "the label cleanup is gone entirely")

        # Match the line that decides to rethrow, not the shape of the catch around it --
        # this assertion first went in keyed to `catch` and `error.status` appearing
        # together on one line, and broke the moment the handler grew a log line and
        # wrapped onto three.
        guard = [line for line in text.splitlines() if 'error.status' in line and 'throw' in line]
        self.assertTrue(guard, "nothing guards the label-cleanup rethrow; a 403 aborts the teardown again")

        for line in guard:
            self.assertIn('403', line, f"label cleanup still aborts a teardown on 403: {line.strip()}")
            self.assertIn('404', line, f"label cleanup no longer tolerates a missing label: {line.strip()}")

    def test_destroy_waits_for_the_app_pool_to_release_its_files(self):
        """Stop-WebAppPool returns when the stop has been *requested*. w3wp.exe keeps its
        handles until it actually exits, and Rock's bin holds native DLLs the Google
        Cloud client libraries load -- grpc_csharp_ext.x64.dll cannot be deleted while it
        is still mapped into a live process.

        Deleting the directory immediately after therefore raced the shutdown and lost:
        on 2026-08-18 the destroy of pr-4 and pr-5 failed with "Access to the path
        'grpc_csharp_ext.x64.dll' is denied" *after* Remove-Website and Remove-WebAppPool
        had already run, leaving both environments half torn down -- no site, no app
        pool, but C:\\RockTestEnvs\\pr-N still on disk. Re-running a minute later worked,
        which is the tell that this is a race and not a permissions problem.

        Waiting for Stopped is necessary but not sufficient, because the pool reporting
        Stopped does not prove the worker process has exited, so the delete itself has to
        tolerate a transient lock and retry."""
        destroy = DESTROY_SCRIPT.read_text()

        self.assertIn('Get-WebAppPoolState', destroy)
        self.assertIn('Start-Sleep', destroy)
        self.assertRegex(
            destroy,
            r'while\s*\(',
            "the destroy never waits for anything; it still races the app pool shutdown",
        )
        self.assertIn(
            'try {',
            destroy,
            "the directory delete is unguarded, so a transient file lock still fails the destroy",
        )
        self.assertRegex(
            destroy,
            r'Remove-Item\s+\$EnvironmentPath',
            "the destroy no longer removes the environment directory",
        )

    def test_destroy_still_fails_when_the_directory_genuinely_cannot_be_removed(self):
        """The retry must give up and report. A destroy that swallows the error reports
        success while leaving the site directory on disk, and the next deploy for that PR
        then unpacks onto someone else's files.

        Anchored to a statement rather than the bare word. Written as `r'throw'` this
        passed against a script with the whole retry deleted, because the surviving
        comment above it contains "rethrow" -- the assertion was reading its own
        explanation and calling it an implementation."""
        destroy = DESTROY_SCRIPT.read_text()

        self.assertRegex(
            destroy,
            r'(?m)^\s*throw\s',
            "the delete retry never rethrows, so a permanently locked directory would be "
            "reported as a successful destroy",
        )


if __name__ == "__main__":
    unittest.main()
