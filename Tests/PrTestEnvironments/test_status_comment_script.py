import json
import shutil
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

    def test_deploy_workflow_updates_sticky_comment_instead_of_creating_comment_spam(self):
        text = DEPLOY_WORKFLOW.read_text()

        self.assertIn("pr-test-status.js", text)
        self.assertIn("updatePrTestStatus", text)
        self.assertNotIn("github.rest.issues.createComment", text)


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class ReconcileLabelsTests(unittest.TestCase):
    """A pull request carries one state label at a time. The developer docs call the
    set a status light, and `pr-test-destroy-all.yml` reads any one of them as "this
    pull request may still have a site on the box".

    Every transition goes through `reconcilePrTestLabels`, so this is where that
    rule is held. Until the deploy workflow's two middle transitions came here too,
    each carried its own shorter list: building left `rock:stopped` and
    `rock:deploying` in place, and deploying left `rock:stopped`. A stop that
    finished between two jobs of a deploy left the pull request showing two states.

    These run the module under node rather than reading it. The test this replaced
    asserted that the six label names and the word `destroyed` appeared somewhere
    in the file, which stays true of a function that removes none of them.
    """

    # The status each caller passes, and the one label it leaves. `destroyed` leaves
    # none: the environment is gone, so nothing should advertise it.
    LABEL_FOR_STATUS = {
        "queued": "rock:queued",
        "building": "rock:building",
        "deploying": "rock:deploying",
        "deployed": "rock:deployed",
        "failed": "rock:failed",
        "stopped": "rock:stopped",
        "destroyed": None,
    }

    EVERY_STATE_LABEL = [
        "rock:queued",
        "rock:building",
        "rock:deploying",
        "rock:deployed",
        "rock:failed",
        "rock:stopped",
    ]

    def reconcile(self, held, status):
        """The labels pull request 42 holds after reconciling `held` to `status`."""
        body = (
            "const { reconcilePrTestLabels } = require('./.github/scripts/pr-test-status.js');\n"
            "await reconcilePrTestLabels({ github, owner: 'passiondev', repo: 'Rock', "
            f"issue_number: 42, status: {json.dumps(status)} }});\n"
        )
        return harness.run_github_script(body, labels={42: held})["labels"][42]

    def test_a_status_leaves_its_own_label_and_no_other_state(self):
        """From every state at once, and from none. The second is the path real runs
        take most -- the labels being removed are mostly not there -- and GitHub
        answers each of those with a 404 that has to be read as "already done".

        `rock:auto` stands for every label that is not a state. Those are the
        operator's, and reconciling a state must not touch them."""
        starts = {
            "every state label": self.EVERY_STATE_LABEL + ["rock:auto"],
            "no state label": ["rock:auto"],
        }
        for start, held in starts.items():
            for status, label in self.LABEL_FOR_STATUS.items():
                with self.subTest(start=start, status=status):
                    expected = sorted(["rock:auto"] + ([label] if label else []))
                    self.assertEqual(expected, self.reconcile(held, status))


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
