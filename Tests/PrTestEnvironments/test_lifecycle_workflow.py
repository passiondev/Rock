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
        self.assertIn('rock-test:stop', text)
        self.assertIn('rock-test:destroy', text)
        self.assertIn('merged', text)
        self.assertIn('Stop-PrEnvironment.ps1', text)
        self.assertIn('Destroy-PrEnvironment.ps1', text)
        self.assertIn('updatePrTestStatus', text)
        self.assertIn('removeLabel', text)


if __name__ == "__main__":
    unittest.main()
