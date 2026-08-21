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


class StatusScriptPermissionTests(harness.HarnessAssertions, unittest.TestCase):
    """Every workflow that writes a sticky status needs `pull-requests: write`.

    The module reaches the label through `github.rest.issues.addLabels`, so the
    natural reading is that `issues: write` covers it. It does not. A pull request
    is not a plain issue, and GitHub bills its label writes against the
    `pull-requests` scope -- so a workflow declaring `issues: write` and
    `pull-requests: read` gets a 403 on exactly one step, the last one.

    That is the worst shape a permission bug can take here. On 2026-08-21 a
    destroy-all run tore down three environments, polled three successful results,
    and then failed all three legs on the bookkeeping step. The environments were
    gone; their pull requests still carried `rock:deployed` and a sticky comment
    pointing at a hostname that no longer answered. The run went red for a reason
    that had nothing to do with the teardown, which is the kind of red that trains
    people to skim the summary.
    """

    def workflows_requiring_the_status_script(self):
        """Every workflow whose steps require pr-test-status.js, by file name."""
        found = []
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            if "pr-test-status.js" in path.read_text(encoding="utf-8"):
                found.append(path.name)
        return found

    def test_every_workflow_using_the_status_script_can_write_pull_requests(self):
        names = self.workflows_requiring_the_status_script()
        self.assertNotVacuous(names, "no workflow requires pr-test-status.js")

        wrong = []
        for name in names:
            permissions = harness.workflow(name).get("permissions") or {}
            if permissions.get("pull-requests") != "write":
                wrong.append(f"{name}: pull-requests={permissions.get('pull-requests')!r}")

        self.assertEqual(
            [],
            wrong,
            "pr-test-status.js sets a label on a pull request, which needs "
            "pull-requests: write. These declare something else, so their sticky "
            "update will 403 after the real work has already succeeded: "
            + "; ".join(wrong),
        )


if __name__ == "__main__":
    unittest.main()
