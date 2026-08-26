import json
import pathlib
import re
import unittest
from typing import Callable, NamedTuple

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
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
EXPECTED_BASE_BRANCH = "passion-19.3.4"
EXPECTED_ENVIRONMENT_DOMAIN = "staging.connect.passion.team"

# Production is pinned separately, and during a Rock upgrade it deliberately lags.
#
# Staging goes first: it is the place a new minor is proven, so its trunk moves the
# moment the artifact is ready. Production keeps running the old minor until its own
# cutover, which is a separate decision with a separate catalog behind it. While that
# gap is open the two pins genuinely disagree, and folding production into
# BASE_BRANCH_PIN_SITES would force them level -- which in this direction means
# production-deploy.yml offering a v19 artifact as the default ref for a manual
# production deploy. Rock migrates at Application_Start, so accepting that default
# once migrates the production catalog with no way back.
#
# So it is pinned here rather than exempted. Both constants are asserted; neither can
# drift unnoticed. At production cutover, set this to EXPECTED_BASE_BRANCH's value.
EXPECTED_PRODUCTION_BRANCH = "passion-19.3.4"

# The trunk on the *old* side of the cutover that test_upgrade_diff.py examines. It is
# not a deploy pin -- nothing deploys from it any more -- but CI still has to fetch it,
# because those tests diff the real 18.4.1 -> 19.3.4 pair and assert on the incident
# that diff found.
#
# It earns a pin of its own because the two constants above stop disagreeing at
# cutover. Before v19 shipped, productionBranch was passion-18.4.1 and the fetch loop in
# deployment-pipeline-tests.yml picked the old trunk up for free. Repointing production
# to v19 took the last reference to 18.4.1 out of the config, the loop stopped fetching
# it, and both real-cutover classes died in setUpClass against a branch that was still
# sitting on origin. Retiring an old trunk means clearing this key on purpose.
EXPECTED_PREVIOUS_PRODUCTION_BRANCH = "passion-18.4.1"


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
        """These three docs name the current trunk *and* point at the config file, and
        both halves are deliberate.

        Naming the branch in prose looks like the un-evergreen thing to do, and the
        instinct is to strip it out. Don't: this assertion is what keeps the name from
        going stale, because a cutover that forgets these docs fails the suite. Remove
        the literal and the docs become quietly wrong instead of loudly wrong -- which
        is strictly worse for a runbook someone reads under pressure. The config-path
        assertion is the other half: the reader is told where the authority actually
        lives, so a doc that has somehow drifted still routes them to the right place.

        One caveat learned the hard way, and the reason PILOT_ISSUE now carries a
        frozen-history banner: a cutover must satisfy this by updating the doc's
        statement of the *current* pin, never by find-and-replacing the branch name
        through the whole file. The pilot doc records a PR that was based on
        develop-17.6.1, and successive bulk replacements had rewritten that history
        into whatever the trunk happened to be.
        """
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
    PinSite("deployment-pipeline-tests.yml: push branches", PIPELINE_TESTS_WORKFLOW, _push_branches),
    PinSite("test_environment_deploy.py: TRUNK_BRANCH", ENVIRONMENT_DEPLOY_TEST, _python_trunk_constants),
]

# Pinned to the production Rock line, not the trunk. Kept in the same shape as the
# list above so the completeness sweep below can cover both as one set.
PRODUCTION_PIN_SITES = [
    PinSite("production-deploy.yml: workflow_dispatch ref default", PRODUCTION_WORKFLOW, _dispatch_ref_defaults),
    PinSite("pr-test-environments.json: productionBranch", CONFIG_PATH, lambda p: [json.loads(p.read_text())["productionBranch"]]),
]


class CutoverGateFailClosedTests(unittest.TestCase):
    """Which ref the gate reads its config from decides whether a cutover shuts
    the old fleet off or leaves it running. Read from `pull.base.ref` and a PR
    on the retired branch reads *that branch's* config, which still names
    itself, so the comparison passes and the site keeps deploying old-minor
    artifacts onto the migrated catalog -- pr-3 again, once per environment.
    Read from the default branch and the same flip rejects it immediately."""

    def assertContains(self, path, needle, why):
        """assertIn dumps the entire file into the failure when the haystack is a
        workflow, which buries the one line that matters. These are the failures a
        cutover reads under time pressure, so they stay one line."""
        self.assertTrue(needle in path.read_text(), f"{path.name}: {why} (looked for {needle!r})")

    def assertLacks(self, path, needle, why):
        self.assertFalse(needle in path.read_text(), f"{path.name}: {why} (found {needle!r})")

    def test_the_deploy_gate_reads_its_config_from_the_default_branch(self):
        self.assertContains(
            DEPLOY_WORKFLOW,
            "ref: context.payload.repository.default_branch",
            "the deploy gate reads config from somewhere other than the default branch, "
            "so flipping the trunk pin will not stop the retired fleet",
        )
        self.assertLacks(
            DEPLOY_WORKFLOW,
            "ref: pull.base.ref",
            "the deploy gate still reads the retired branch's own config, which always "
            "names itself -- the gate can never reject it",
        )

    def test_the_lifecycle_gate_still_reads_the_pull_request_base_branch(self):
        """Deliberately the opposite of the deploy gate, and the asymmetry is the
        whole point. Lifecycle only ever runs `stop` and `destroy`. If it also read
        the default branch, then the moment the pin flipped, the retired fleet would
        become undestroyable through the pipeline -- exactly when the runbook needs
        `rock:destroy` to work on every one of those PRs. Deploy fails closed;
        teardown stays open."""
        self.assertContains(
            LIFECYCLE_WORKFLOW,
            "ref: pull.base.ref",
            "the lifecycle gate no longer reads the PR's own base branch, so rock:destroy "
            "stops working on retired PRs -- the fleet cannot be cleaned up after a cutover",
        )


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

    def test_production_pins_the_production_rock_line_not_the_trunk(self):
        """The one pin that does not follow staging. Asserted rather than skipped,
        so "production still points at the old branch" stays a deliberate statement
        in this file instead of something a cutover forgot."""
        drifted = []
        for site in PRODUCTION_PIN_SITES:
            found = site.read_pins(site.path)
            self.assertTrue(
                found,
                f"{site.label}: no pin found -- the file's shape changed and this guard "
                f"is no longer reading it",
            )
            drifted.extend(
                f"{site.label} -> {value}" for value in found if value != EXPECTED_PRODUCTION_BRANCH
            )

        self.assertEqual(
            drifted,
            [],
            f"these pins disagree with EXPECTED_PRODUCTION_BRANCH ({EXPECTED_PRODUCTION_BRANCH}): "
            + "; ".join(drifted),
        )

    def test_ci_fetches_the_old_trunk_the_upgrade_diff_tests_diff_against(self):
        """test_upgrade_diff.py names origin/passion-18.4.1 directly, and a name in a
        test file cannot make CI fetch anything. The fetch step reads the config, so the
        config has to carry the old trunk or those tests fail in setUpClass on a branch
        that exists perfectly well on origin.

        Both ends are asserted here because either one alone is satisfiable while the
        suite stays broken: a config key nothing reads, or a fetch loop naming a key that
        is absent.
        """
        config = json.loads(CONFIG_PATH.read_text())
        self.assertEqual(
            config.get("previousProductionBranch"),
            EXPECTED_PREVIOUS_PRODUCTION_BRANCH,
            "the config must name the old trunk so the upgrade-diff fetch step can "
            "fetch it",
        )

        workflow = PIPELINE_TESTS_WORKFLOW.read_text()
        self.assertIn(
            "previousProductionBranch",
            workflow,
            "deployment-pipeline-tests.yml must fetch previousProductionBranch, or the "
            "config key is decoration",
        )

        upgrade_diff_tests = pathlib.Path(__file__).with_name("test_upgrade_diff.py").read_text()
        self.assertIn(
            f"origin/{EXPECTED_PREVIOUS_PRODUCTION_BRANCH}",
            upgrade_diff_tests,
            "test_upgrade_diff.py no longer diffs against "
            f"{EXPECTED_PREVIOUS_PRODUCTION_BRANCH} -- if the cutover pair moved, move "
            "EXPECTED_PREVIOUS_PRODUCTION_BRANCH and the config with it",
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
        covered = {site.path for site in [*BASE_BRANCH_PIN_SITES, *PRODUCTION_PIN_SITES]}
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
    """One Rock minor per catalog.

    Decided 2026-08-17 as "PR environments follow staging: same Rock version, same
    catalog". Narrowed 2026-08-18 to the half that was actually load-bearing. Rock
    applies EF and plugin migrations at Application_Start, so a catalog shared
    across two Rock minors gets migrated out from under whichever site started
    first -- that is what put pr-3 on a permanent HTTP 500 on 2026-08-11, and what
    stranded the sandbox catalog part-way through v19 on 2026-08-18. Sharing a
    catalog was never the safety property. Sharing a *minor* was, and requiring the
    catalog to be shared as well is what made staging unusable as the place to find
    out whether the next minor migrates cleanly.

    So staging and the fleet now name separate variables and fall back to the same
    catalog. Unset, they resolve identically and the 2026-08-17 arrangement holds
    unchanged; set one and exactly one environment moves. What keeps two minors off
    one catalog is no longer the wiring but the guard in staging-deploy.yml, which
    refuses a minor change while staging's variable is unset -- a rule that reads
    the variable at deploy time instead of inferring it from the file."""

    def test_staging_tracks_the_same_branch_pr_environments_are_gated_to(self):
        """GitHub Actions cannot read a JSON file to build `on: push: branches:`,
        so the branch is necessarily a literal in the staging workflow and a value
        in the PR config -- there is no expression that could single-source them.
        Nothing but this test keeps the two in step, and drift is not visible in a
        deploy log: both environments succeed, they just migrate one catalog to two
        different Rock versions.

        Still asserted after the catalog split, because the split does not by itself
        give staging a database -- it only makes one possible. Moving staging to the
        next minor is `vars.STAGING_DB_NAME` and this literal, in that order, and
        the guard in staging-deploy.yml fails the deploy if the literal moves first."""
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

    def test_staging_and_the_pr_fleet_name_separate_catalog_variables(self):
        """`vars.STAGING_DB_NAME` reads like staging's variable and was documented as
        staging's variable, but pr-test-deploy.yml read it too -- so setting it moved
        the whole fleet. Staging is the environment a version bump is supposed to be
        tried on first; a variable that cannot be set without taking every pr-* site
        with it means there is nowhere to try it."""
        staging_text = STAGING_WORKFLOW.read_text()
        deploy_text = DEPLOY_WORKFLOW.read_text()

        self.assertIn("db_name: ${{ vars.STAGING_DB_NAME }}", staging_text)
        self.assertIn(
            "Initial Catalog=${{ vars.PR_TEST_DB_NAME || secrets.DB_NAME }}",
            deploy_text,
            "the pr-* fleet does not name its own catalog variable",
        )

        # Comments may still discuss it -- the reason the fleet has its own variable
        # cannot be written down without naming the one it used to share.
        code = "\n".join(
            line.split("#", 1)[0] for line in deploy_text.splitlines()
        )
        self.assertNotIn(
            "STAGING_DB_NAME",
            code,
            "pr-* sites still read staging's catalog variable, so setting it moves the fleet too",
        )

    def test_the_catalog_split_is_inert_until_a_variable_is_set(self):
        """Neither variable is set today and both environments sit on the
        prod-derived sandbox catalog. The split has to preserve that exactly: an
        unset variable interpolates to the empty string, and `|| secrets.DB_NAME`
        is the only thing standing between that and a deploy whose connection
        string names no database at all.

        Asserted as the operand order rather than the presence of the fallback,
        because reversed it still parses, still deploys, and still reports success
        -- it just pins every environment to the shared catalog forever and makes
        both variables dead config."""
        for path in [DEPLOY_WORKFLOW, STAGING_WORKFLOW, WORKFLOW_DIR / "env-deploy-command.yml"]:
            text = path.read_text()
            self.assertNotIn(
                "secrets.DB_NAME ||",
                text,
                f"{path.name} prefers the shared catalog over the environment's own variable",
            )

        self.assertIn(
            "vars.PR_TEST_DB_NAME || secrets.DB_NAME",
            DEPLOY_WORKFLOW.read_text(),
            "the fleet no longer falls back to the shared catalog, so an unset variable "
            "would deploy a connection string with an empty Initial Catalog",
        )

    def test_the_operator_runbook_does_not_still_promise_one_variable_moves_both(self):
        """The runbook told operators that setting the catalog variable moves staging
        and every pr-* site together, and that was true when it was written. Left
        standing it is worse than no note at all: it describes a blast radius large
        enough to talk someone out of the move this change exists to make safe."""
        runbook = OP_RUNBOOK.read_text()

        self.assertNotIn(
            "moves **staging and every `pr-*` site**",
            runbook,
            "the runbook still describes the pre-split blast radius",
        )

        # Anchored to the step that carried the wrong claim, not to the document.
        # `assertIn("PR_TEST_DB_NAME", runbook)` is satisfied by any passing mention
        # elsewhere, which leaves the one paragraph an operator actually reads before
        # setting the variable free to go on saying nothing about the other one.
        step = next(
            (line for line in runbook.splitlines() if "**Set the repository variable**" in line),
            None,
        )
        self.assertIsNotNone(step, "the provisioning step that sets the catalog variable is gone")
        self.assertIn("PR_TEST_DB_NAME", step, "the step that sets STAGING_DB_NAME does not say what it does not move")
        self.assertIn("staging only", step, "the step does not state the blast radius at all")


if __name__ == "__main__":
    unittest.main()
