import json
import pathlib
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / ".github" / "pr-test-environments.json"
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
DEPLOY_WORKFLOW = WORKFLOW_DIR / "pr-test-deploy.yml"
STAGING_WORKFLOW = WORKFLOW_DIR / "staging-deploy.yml"
LIFECYCLE_WORKFLOW = WORKFLOW_DIR / "pr-test-lifecycle.yml"
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


def _triggers(workflow):
    """`on` is a YAML 1.1 boolean, so an unquoted key parses to True while a
    quoted one stays the string "on". Both spellings exist in this repo."""
    return workflow.get("on", workflow.get(True))


class StagingAndPrEnvironmentCouplingTests(unittest.TestCase):
    """PR environments follow staging -- same Rock version, same catalog. Decided
    2026-08-17. The version half is what makes the catalog half safe: Rock applies
    EF and plugin migrations at Application_Start, so one catalog shared across two
    Rock minors gets migrated out from under whichever site started first, which is
    what put pr-3 on a permanent HTTP 500 on 2026-08-11. Pinned to a single branch,
    everything on the catalog is the same minor and the shared schema is consistent."""

    def test_staging_tracks_the_same_branch_pr_environments_are_gated_to(self):
        """GitHub Actions cannot read a JSON file to build `on: push: branches:`,
        so the branch is necessarily a literal in the staging workflow and a value
        in the PR config -- there is no expression that could single-source them.
        Nothing but this test keeps the two in step, and drift is not visible in a
        deploy log: both environments succeed, they just migrate one catalog to two
        different Rock versions."""
        staging = yaml.safe_load(STAGING_WORKFLOW.read_text())
        triggers = _triggers(staging)

        self.assertEqual(
            triggers["push"]["branches"],
            [EXPECTED_BASE_BRANCH],
            "staging deploys from a branch other than the one PR environments are based on",
        )
        self.assertEqual(
            triggers["workflow_dispatch"]["inputs"]["ref"]["default"],
            EXPECTED_BASE_BRANCH,
            "a manual staging deploy defaults to a branch other than the trunk",
        )

    def test_staging_and_pr_environments_resolve_the_same_catalog(self):
        """Both sides must read the catalog the same way, fallback included. If one
        reads vars.STAGING_DB_NAME and the other pins secrets.DB_NAME, then setting
        the variable silently splits them onto different databases -- every deploy
        still reports success, so the split has no symptom until a migration or a
        missing row shows up somewhere unrelated."""
        staging_text = STAGING_WORKFLOW.read_text()
        deploy_text = DEPLOY_WORKFLOW.read_text()

        self.assertIn("db_name: ${{ vars.STAGING_DB_NAME }}", staging_text)
        self.assertIn(
            "Initial Catalog=${{ vars.STAGING_DB_NAME || secrets.DB_NAME }}",
            deploy_text,
            "pr-* sites no longer follow staging's catalog",
        )
        self.assertNotIn(
            "Initial Catalog=${{ secrets.DB_NAME }}",
            deploy_text,
            "pr-* sites still pin the prod-derived shared catalog directly",
        )


if __name__ == "__main__":
    unittest.main()
