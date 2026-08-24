import json
import re
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
PRODUCTION_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-deploy.yml"
CONFIG_PATH = REPO_ROOT / ".github" / "pr-test-environments.json"

REF_GUARD_STEP = "Refuse a ref that is not on the production branch"
VERSION_GUARD_STEP = "Refuse a ref from a different Rock version"


def _resolve_steps():
    workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
    return workflow["jobs"]["resolve"]["steps"]


def _step_named(name):
    for step in _resolve_steps():
        if step.get("name") == name:
            return step
    return None


def _without_comments(script):
    """Only the lines bash actually executes. A guard's comment naturally quotes
    the thing it is guarding against -- this one explains why it deliberately has
    no `acknowledge_version_change` escape -- and a test that reads the comment
    concludes the escape is present. Full-line comments only: a trailing `#` split
    would cut into the quoted text of the `echo` lines below."""
    return "\n".join(
        line for line in script.splitlines() if not line.lstrip().startswith("#")
    )


class ProductionRefGuardTests(unittest.TestCase):
    """`develop` is the 19.0 line and `staging` is 17.6.1 -- they are not points on
    one line with the trunk, they are different Rock majors. The last production
    *build* ran from `develop` on 2026-05-06; the only reason no v19 assembly is on
    the box is that the artifact was never installed. That was luck, not a control.

    The version guard already refuses a ref from another minor, but
    `acknowledge_version_change` is a single checkbox that turns it off, and it is
    there for a legitimate reason -- a real upgrade. So it cannot also be the thing
    standing between `develop` and production. This guard is the control."""

    def setUp(self):
        self.step = _step_named(REF_GUARD_STEP)
        self.assertIsNotNone(
            self.step,
            f"production-deploy.yml has no step named {REF_GUARD_STEP!r}; nothing stops a "
            f"deploy from a branch that is not the trunk",
        )
        self.script = _without_comments(self.step.get("run", ""))

    def test_the_guard_compares_against_the_production_branch_pin(self):
        """The same oracle the version guard uses, and NOT the repository's default
        branch.

        This test used to assert the opposite -- that the guard read the default
        branch -- on the reasoning that a pin is one more thing to flip at cutover
        and a missed one would refuse every legitimate deploy. The reasoning was
        sound and the premise was not: it assumed the default branch and the branch
        production runs are the same branch. On 2026-08-19 the trunk moved to
        passion-19.3.4 while production stayed on passion-18.4.1. The compare API
        calls those two `diverged`, the guard's catch-all refused it with "there is
        no override for this one", and production became undeployable -- including
        for a rollback. The test stayed green throughout, because it was asserting
        the mechanism rather than the outcome.

        Hence the pair: this names the oracle, and
        test_the_workflows_own_default_ref_is_one_the_guard_accepts below checks the
        outcome the oracle exists to produce."""
        # Matched as the jq extraction rather than as the bare word. The word also
        # appears in this step's fallback warning, so a guard that had been reverted
        # to the default-branch oracle but kept its warning text would still satisfy
        # `assertIn("productionBranch", ...)` -- the assertion would be reading the
        # error message rather than the code that produces it.
        self.assertRegex(
            self.script,
            r"jq -r '\.productionBranch",
            "the ref guard does not extract productionBranch from the config, so it "
            "will refuse every deploy whenever the trunk is ahead of production",
        )
        # And the extracted value has to be the one the compare actually uses.
        self.assertRegex(
            self.script,
            r"compare/\$production_branch\.\.\.",
            "the ref guard extracts the pin but compares against something else",
        )

    def test_the_guard_reads_the_pin_from_the_default_branch_not_the_checkout(self):
        """The job checks out `ref: inputs.ref` -- the ref being judged. Reading the
        pin off that checkout would let a branch ship a config naming itself and
        approve its own production deploy. That is the `pull.base.ref` mistake the PR
        gate already made, and the fix is the same: read config over the API from the
        branch nobody can push to without review."""
        self.assertRegex(
            self.script,
            r"contents/\$config_path\?ref=\$DEFAULT_BRANCH",
            "the ref guard does not fetch the pin from the default branch over the "
            "API, so the ref being judged may be supplying its own verdict",
        )

    def test_the_workflows_own_default_ref_is_one_the_guard_accepts(self):
        """The outcome, not the mechanism.

        `ref` defaults to the branch an operator deploying production will accept
        without thinking about it, and the guard decides whether that ref survives.
        If those two disagree, the workflow refuses its own default -- which is
        precisely what happened between the trunk cutover on 2026-08-19 and the pin
        landing: `ref` defaulted to passion-18.4.1, the guard measured against the
        default branch passion-19.3.4, and the compare API called them `diverged`.

        Asserted statically against the pin rather than by calling the compare API,
        so it holds with no network and no credentials. The pin is what the guard
        measures against, so ref-default == pin is exactly the condition under which
        the compare returns `identical`."""
        config = json.loads(CONFIG_PATH.read_text())
        pinned = config.get("productionBranch")
        self.assertIsNotNone(
            pinned,
            f"{CONFIG_PATH.name} has no 'productionBranch'; the guard falls back to "
            f"the default branch and will refuse every production deploy whenever "
            f"the trunk is ahead of production",
        )

        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        ref_default = workflow["on"]["workflow_dispatch"]["inputs"]["ref"]["default"]
        self.assertEqual(
            ref_default,
            pinned,
            f"production-deploy.yml defaults `ref` to {ref_default!r} but the guard "
            f"measures against {pinned!r}; the workflow would refuse its own default",
        )

    def test_the_guard_allows_a_rollback_to_an_earlier_trunk_commit(self):
        """The ref input's own description says to use the trunk 'unless you are
        rolling back'. A guard that demanded ref == trunk would break the one
        exception the workflow already documents, so it tests ancestry instead:
        anything in the trunk's history is fine, anything off it is not."""
        for allowed in ["identical", "behind"]:
            self.assertIn(
                allowed,
                self.script,
                f"the ref guard does not accept a '{allowed}' comparison, so rolling back "
                f"to an earlier trunk commit would be refused",
            )

    def test_the_guard_accepts_by_allow_list_and_refuses_everything_else(self):
        """`diverged` is develop and staging; `ahead` is a feature branch built on
        the trunk but not merged, and production deploys what was reviewed and
        merged, not what is about to be. Neither is named, and that is the stronger
        shape: the guard accepts two statuses and everything else falls to `*)`. A
        status GitHub has not invented yet is refused rather than waved through,
        which is the direction an unrecognized answer should fail."""
        arms = re.findall(r"^\s{2}([a-z*|]+)\)", self.script, re.MULTILINE)

        self.assertEqual(
            [arm for arm in arms if arm != "*"],
            ["identical", "behind"],
            "the ref guard accepts something other than an exact trunk tip or an earlier "
            f"trunk commit (arms found: {arms})",
        )
        self.assertIn("*", arms, "the ref guard has no catch-all, so an unrecognized comparison falls through")

        catch_all = self.script.split("*)", 1)[1]
        self.assertIn(
            "exit 1",
            catch_all,
            "the ref guard's catch-all does not fail the run, so an off-trunk ref would deploy",
        )

    def test_the_guard_has_no_acknowledge_style_bypass(self):
        """Deliberately unlike the version guard. That one has a checkbox because a
        real Rock upgrade is a real thing someone does. There is no legitimate
        reason to deploy `develop` to production, so there is no checkbox -- the
        path for an urgent fix is to merge it to the trunk first."""
        self.assertNotIn(
            "acknowledge",
            self.script,
            "the ref guard can be checkbox-bypassed, which makes it advisory rather "
            "than a control",
        )

    def test_the_ref_guard_runs_before_the_build(self):
        """Both guards live in `resolve`, which `build` and `approve` depend on. If
        the guard ran later, a refused deploy would still have spent a full Rock
        build, and an approver could be shown a commit that can never ship."""
        names = [step.get("name") for step in _resolve_steps()]
        self.assertIn(REF_GUARD_STEP, names)

    def test_the_version_guard_is_still_in_place(self):
        """The two guards answer different questions -- 'is this the trunk' and 'is
        this the expected Rock minor' -- and a rollback can satisfy the first while
        failing the second. Neither replaces the other."""
        self.assertIsNotNone(
            _step_named(VERSION_GUARD_STEP),
            "the Rock version guard is gone; a rollback to an older minor would now "
            "migrate the production database with nothing objecting",
        )


if __name__ == "__main__":
    unittest.main()
