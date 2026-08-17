import json
import pathlib
import re
import unittest
from typing import Callable, NamedTuple

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / ".github" / "pr-test-environments.json"
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
DEPLOY_WORKFLOW = WORKFLOW_DIR / "pr-test-deploy.yml"
STAGING_WORKFLOW = WORKFLOW_DIR / "staging-deploy.yml"
LIFECYCLE_WORKFLOW = WORKFLOW_DIR / "pr-test-lifecycle.yml"
PRODUCTION_WORKFLOW = WORKFLOW_DIR / "production-deploy.yml"
PIPELINE_TESTS_WORKFLOW = WORKFLOW_DIR / "deployment-pipeline-tests.yml"
ENVIRONMENT_DEPLOY_TEST = pathlib.Path(__file__).with_name("test_environment_deploy.py")
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


def _push_branches(path):
    return _triggers(yaml.safe_load(path.read_text()))["push"]["branches"]


def _dispatch_ref_defaults(path):
    inputs = _triggers(yaml.safe_load(path.read_text()))["workflow_dispatch"]["inputs"]
    return [inputs["ref"]["default"]]


def _js_gate_fallbacks(path):
    return re.findall(r"config\.baseBranch \|\| '([^']+)'", path.read_text())


def _python_trunk_constants(path):
    return re.findall(r'^TRUNK_BRANCH = "([^"]+)"', path.read_text(), re.MULTILINE)


class PinSite(NamedTuple):
    """One place a trunk branch name is written down, and how to read it back.
    `read_pins` returns a list because several sites hold more than one -- a
    `branches:` filter is a list by nature -- and a site that reads back empty
    means the file's shape moved out from under the guard."""

    label: str
    path: pathlib.Path
    read_pins: Callable[[pathlib.Path], list]


TRUNK_BRANCH_PATTERN = re.compile(r"passion-\d+\.\d+(?:\.\d+)?")


def _branch_names_in_values(path):
    """Trunk branch names that are *values*, not prose. Two layers of comment get
    stripped: yaml.safe_load discards YAML comments outright, and `#` to end of
    line is then removed from each remaining scalar, which is what a `run: |`
    block's embedded PowerShell comments look like. Without the second layer, a
    comment explaining why one branch differs from another reads as a pin -- which
    is exactly what the Rock.Mandrill note in pr-test-artifact.yml did."""
    found = set()

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(key)
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)
        elif isinstance(node, str):
            for line in node.splitlines():
                found.update(TRUNK_BRANCH_PATTERN.findall(line.split("#", 1)[0]))

    walk(yaml.safe_load(path.read_text()))
    return sorted(found)


# Every place the trunk branch name is written down. A workflow branch filter
# cannot be an expression and GitHub Actions cannot read pr-test-environments.json
# to build `on: push: branches:`, so the name is necessarily a literal in each of
# these files -- there is no single value they could all read. This list is the
# source of truth for humans instead: at cutover, bump EXPECTED_BASE_BRANCH and
# the test below names every file still on the old branch, which is what makes
# the flip mechanical rather than a hand search that missed
# production-deploy.yml the last two times.
#
# test_environment_deploy.py keeps its own TRUNK_BRANCH rather than importing
# this constant, and that duplication is deliberate. This suite is run both as
# `unittest discover -s Tests/PrTestEnvironments` (modules import as top-level
# names) and as `unittest Tests.PrTestEnvironments.<name>` (as a package), and a
# cross-module import between test files resolves under one of those and raises
# under the other. Two constants holding one value is the lesser problem, and the
# last entry below is what keeps them honest.
BASE_BRANCH_PIN_SITES = [
    PinSite("pr-test-environments.json: baseBranch", CONFIG_PATH, lambda p: [json.loads(p.read_text())["baseBranch"]]),
    PinSite("pr-test-deploy.yml: PR gate fallback", DEPLOY_WORKFLOW, _js_gate_fallbacks),
    PinSite("pr-test-lifecycle.yml: PR gate fallback", LIFECYCLE_WORKFLOW, _js_gate_fallbacks),
    PinSite("staging-deploy.yml: push branches", STAGING_WORKFLOW, _push_branches),
    PinSite("staging-deploy.yml: workflow_dispatch ref default", STAGING_WORKFLOW, _dispatch_ref_defaults),
    PinSite("production-deploy.yml: workflow_dispatch ref default", PRODUCTION_WORKFLOW, _dispatch_ref_defaults),
    PinSite("deployment-pipeline-tests.yml: push branches", PIPELINE_TESTS_WORKFLOW, _push_branches),
    PinSite("test_environment_deploy.py: TRUNK_BRANCH", ENVIRONMENT_DEPLOY_TEST, _python_trunk_constants),
]


class BaseBranchCutoverPinTests(unittest.TestCase):
    """Flipping the trunk branch is an eight-file edit with no compiler behind it.
    A pin left on the old branch does not fail a build -- production-deploy.yml
    would simply keep offering the retired branch as the default for a manual
    production deploy, and deployment-pipeline-tests.yml would stop running on
    pushes entirely, silently. These two tests make the miss loud."""

    def test_every_place_the_trunk_branch_is_written_down_names_the_same_branch(self):
        drifted = []
        for site in BASE_BRANCH_PIN_SITES:
            found = site.read_pins(site.path)
            self.assertTrue(
                found,
                f"{site.label}: no pin found -- the file's shape changed and this guard "
                f"is no longer reading it, so the cutover list is now silently short",
            )
            drifted.extend(f"{site.label} -> {value}" for value in found if value != EXPECTED_BASE_BRANCH)

        self.assertEqual(
            drifted,
            [],
            f"these pins disagree with EXPECTED_BASE_BRANCH ({EXPECTED_BASE_BRANCH}): " + "; ".join(drifted),
        )

    def test_no_workflow_pins_a_trunk_branch_the_cutover_list_does_not_cover(self):
        """The list above is only useful while it is complete. A new workflow that
        names the trunk branch has to join it, or the next cutover misses that file
        and nothing says so.

        Scope is deliberately the workflow directory only. A pin can also be added
        in a `.py`, `.ps1` or `.json` file, and this does not sweep those -- their
        prose is full of branch names that are not pins, so a text sweep there
        false-positives more than it catches. New workflows are the realistic
        source of a missed pin; everything else is caught by review."""
        covered = {site.path for site in BASE_BRANCH_PIN_SITES}
        stray = []
        for workflow in sorted([*WORKFLOW_DIR.glob("*.yml"), *WORKFLOW_DIR.glob("*.yaml")]):
            if workflow in covered:
                continue
            stray.extend(
                f"{workflow.name} -> {match}" for match in _branch_names_in_values(workflow)
            )

        self.assertEqual(
            stray,
            [],
            "these workflows name a trunk branch outside a comment but are not in "
            "BASE_BRANCH_PIN_SITES: " + "; ".join(stray),
        )


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
