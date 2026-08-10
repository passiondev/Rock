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

# The branch PR test environments deploy from. Declared once here so a version
# bump is a one-line change in this file plus the JSON config -- previously the
# branch name was repeated in five places and every one of them had to be found
# by hand. Bump this together with .github/pr-test-environments.json.
EXPECTED_BASE_BRANCH = "passion-18.4.1"
EXPECTED_ENVIRONMENT_DOMAIN = "rock-dev.connect.passion.team"


class BaseBranchConfigTests(unittest.TestCase):
    def test_pr_test_environment_base_branch_is_configured_for_current_rock_pin(self):
        config = json.loads(CONFIG_PATH.read_text())

        self.assertEqual(config["baseBranch"], EXPECTED_BASE_BRANCH)
        self.assertEqual(config["environmentDomain"], EXPECTED_ENVIRONMENT_DOMAIN)

    def test_workflows_gate_prs_to_configured_base_branch(self):
        deploy_text = DEPLOY_WORKFLOW.read_text()
        lifecycle_text = LIFECYCLE_WORKFLOW.read_text()

        for text in [deploy_text, lifecycle_text]:
            self.assertIn("pr-test-environments.json", text)
            self.assertIn("configuredBaseBranch", text)
            self.assertIn("pull.base.ref !== configuredBaseBranch", text)
            self.assertIn(EXPECTED_BASE_BRANCH, text)

    def test_runbooks_and_pilot_document_base_branch_config(self):
        for path in [DEV_RUNBOOK, OP_RUNBOOK, PILOT_ISSUE]:
            text = path.read_text()
            self.assertIn(EXPECTED_BASE_BRANCH, text)
            self.assertIn(".github/pr-test-environments.json", text)

    def test_no_stale_branch_names_remain_in_workflow_gates(self):
        """The gate fallbacks used to name a branch that no longer exists, so a
        missing config file silently routed deploys at a dead branch."""
        for path in [DEPLOY_WORKFLOW, LIFECYCLE_WORKFLOW]:
            text = path.read_text()
            self.assertNotIn("develop-17.6.1", text, f"{path.name} still references the retired 17.6.1 branch")
            self.assertIn(f"config.baseBranch || '{EXPECTED_BASE_BRANCH}'", text)


if __name__ == "__main__":
    unittest.main()
