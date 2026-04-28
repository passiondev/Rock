import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
STATUS_SCRIPT = REPO_ROOT / ".github" / "scripts" / "pr-test-status.js"
DEPLOY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"


class PrTestStatusCommentScriptTests(unittest.TestCase):
    def test_status_script_uses_single_sticky_marker_and_documents_environment_contract(self):
        text = STATUS_SCRIPT.read_text()

        self.assertIn("<!-- rock-test-environment-status -->", text)
        self.assertIn("VPN/office network access is required", text)
        self.assertIn("shared sanitized sandbox database", text)
        self.assertIn("rock-test:start", text)
        self.assertIn("rock-test:stop", text)
        self.assertIn("rock-test:destroy", text)
        self.assertIn("rock-test:auto", text)

    def test_status_script_reconciles_labels_for_deployed_failed_stopped_and_destroyed(self):
        text = STATUS_SCRIPT.read_text()

        self.assertIn("async function reconcilePrTestLabels", text)
        for state in ["deployed", "failed", "stopped", "destroyed"]:
            self.assertIn(state, text)
        for label in [
            "rock-test:queued",
            "rock-test:building",
            "rock-test:deploying",
            "rock-test:deployed",
            "rock-test:failed",
            "rock-test:stopped",
        ]:
            self.assertIn(label, text)

    def test_deploy_workflow_updates_sticky_comment_instead_of_creating_comment_spam(self):
        text = DEPLOY_WORKFLOW.read_text()

        self.assertIn("pr-test-status.js", text)
        self.assertIn("updatePrTestStatus", text)
        self.assertNotIn("github.rest.issues.createComment", text)


if __name__ == "__main__":
    unittest.main()
