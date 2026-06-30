import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / ".github" / "pr-test-environments.json"
DEPLOY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"
LIFECYCLE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-lifecycle.yml"
DEV_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md"
OP_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"
PILOT_ISSUE = REPO_ROOT / "Documentation" / "Discussion Docs" / "PR-Test-Environments-Issues" / "12-pilot-rollout.md"


class BaseBranchConfigTests(unittest.TestCase):
    def test_pr_test_environment_base_branch_is_configured_for_current_rock_pin(self):
        config = json.loads(CONFIG_PATH.read_text())

        self.assertEqual(config["baseBranch"], "develop-17.6.1")
        self.assertEqual(config["environmentDomain"], "rock-dev.connect.passion.team")

    def test_workflows_gate_prs_to_configured_base_branch(self):
        deploy_text = DEPLOY_WORKFLOW.read_text()
        lifecycle_text = LIFECYCLE_WORKFLOW.read_text()

        for text in [deploy_text, lifecycle_text]:
            self.assertIn("pr-test-environments.json", text)
            self.assertIn("configuredBaseBranch", text)
            self.assertIn("pull.base.ref !== configuredBaseBranch", text)
            self.assertIn("develop-17.6.1", text)

    def test_runbooks_and_pilot_document_base_branch_config(self):
        for path in [DEV_RUNBOOK, OP_RUNBOOK, PILOT_ISSUE]:
            text = path.read_text()
            self.assertIn("develop-17.6.1", text)
            self.assertIn(".github/pr-test-environments.json", text)


if __name__ == "__main__":
    unittest.main()
