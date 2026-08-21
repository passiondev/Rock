import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
STATUS_SCRIPT = REPO_ROOT / ".github" / "scripts" / "pr-test-status.js"
DEPLOY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"


class PrTestStatusCommentScriptTests(unittest.TestCase):
    def test_status_script_uses_single_sticky_marker_and_documents_environment_contract(self):
        text = STATUS_SCRIPT.read_text()

        self.assertIn("<!-- rock-test-environment-status -->", text)

        # The comment used to claim VPN/office network access was required. It is
        # not: port 443 on the test VM is open to the internet via the
        # `https-from-world` rule, and the office-egress restriction covers only
        # RDP and SQL. Telling reviewers they need a VPN they don't have is how a
        # working environment gets reported as broken.
        self.assertIn("reachable from anywhere", text)
        self.assertNotIn("VPN/office network access is required", text)

        # A slow first request is migrations running, not a hang.
        self.assertIn("migrations", text)

        self.assertIn("shared sandbox database", text)

        # This comment described the catalog as a "shared sanitized sandbox
        # database" until 2026-08-19. No sanitization step exists or ever has --
        # the catalog is a straight copy of a production backup, served on a
        # world-open URL behind nothing but Rock's login (open item 24). The
        # assertion that used to live here pinned the literal phrase, so the test
        # defended the false claim for as long as it stood. Assert the claim the
        # reader needs instead, and fail if the reassuring word comes back.
        self.assertNotIn("sanitized sandbox", text)
        self.assertIn("not a sanitized one", text)
        self.assertIn("live congregant data", text)
        self.assertIn("rock:start", text)
        self.assertIn("rock:stop", text)
        self.assertIn("rock:destroy", text)
        self.assertIn("rock:auto", text)

    def test_status_script_reconciles_labels_for_deployed_failed_stopped_and_destroyed(self):
        text = STATUS_SCRIPT.read_text()

        self.assertIn("async function reconcilePrTestLabels", text)
        for state in ["deployed", "failed", "stopped", "destroyed"]:
            self.assertIn(state, text)
        for label in [
            "rock:queued",
            "rock:building",
            "rock:deploying",
            "rock:deployed",
            "rock:failed",
            "rock:stopped",
        ]:
            self.assertIn(label, text)

    def test_deploy_workflow_updates_sticky_comment_instead_of_creating_comment_spam(self):
        text = DEPLOY_WORKFLOW.read_text()

        self.assertIn("pr-test-status.js", text)
        self.assertIn("updatePrTestStatus", text)
        self.assertNotIn("github.rest.issues.createComment", text)


if __name__ == "__main__":
    unittest.main()
