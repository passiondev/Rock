import pathlib
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"


class LabelTriggeredDeployWorkflowTests(unittest.TestCase):
    def test_workflow_is_label_triggered_and_refuses_forks_before_building(self):
        text = WORKFLOW_PATH.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("pull_request_target", workflow["on"])
        self.assertIn("labeled", workflow["on"]["pull_request_target"]["types"])
        self.assertIn("rock-test:start", text)
        self.assertIn("head.repo.full_name !== context.payload.repository.full_name", text)
        self.assertIn("Skipping forked PR", text)

    def test_workflow_builds_artifact_then_invokes_windows_deploy_script_over_ssh(self):
        text = WORKFLOW_PATH.read_text()

        self.assertIn("./.github/workflows/pr-test-artifact.yml", text)
        self.assertIn("secrets: inherit", text)
        self.assertIn("sshpass", text)
        self.assertIn("GCP_VM_EXTERNAL_IP", text)
        self.assertIn("WINDOWS_USERNAME", text)
        self.assertIn("WINDOWS_PASSWORD", text)
        self.assertIn("Deploy-PrEnvironment.ps1", text)
        self.assertIn("rock-dev.connect.passion.team", text)

    def test_workflow_reconciles_command_and_state_labels(self):
        text = WORKFLOW_PATH.read_text()

        for label in [
            "rock-test:queued",
            "rock-test:building",
            "rock-test:deploying",
            "rock-test:deployed",
            "rock-test:failed",
        ]:
            self.assertIn(label, text)

        self.assertIn("removeLabel", text)
        self.assertIn("updatePrTestStatus", text)


if __name__ == "__main__":
    unittest.main()
