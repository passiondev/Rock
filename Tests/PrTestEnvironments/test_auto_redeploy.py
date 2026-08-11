import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPLOY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-PrEnvironment.ps1"


class AutoRedeployConcurrencyTests(unittest.TestCase):
    def test_deploy_workflow_supports_auto_label_on_push_and_latest_commit_wins(self):
        text = DEPLOY_WORKFLOW.read_text()

        self.assertIn("types: [labeled, synchronize]", text)
        self.assertIn("rock:auto", text)
        self.assertIn("PR does not have rock:auto", text)
        self.assertIn("cancel-in-progress: true", text)
        self.assertIn("group: pr-test-deploy-${{ github.event.pull_request.number || inputs.pr_number }}", text)

    def test_deploy_script_uses_per_pr_mutex_while_mutating_iis_and_files(self):
        text = DEPLOY_SCRIPT.read_text()

        self.assertIn("Global\\RockPrEnvironment-$PrNumber", text)
        self.assertIn("System.Threading.Mutex", text)
        self.assertIn("WaitOne", text)
        self.assertIn("ReleaseMutex", text)


if __name__ == "__main__":
    unittest.main()
