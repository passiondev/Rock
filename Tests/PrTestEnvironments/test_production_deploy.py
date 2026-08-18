import pathlib
import re
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PRODUCTION_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-deploy.yml"

REF_GUARD_STEP = "Refuse a ref that is not on the trunk"
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

    def test_the_guard_compares_against_the_default_branch(self):
        """The same oracle the version guard uses. Branch names in this repository do
        not tell you the Rock version, so the trunk has to be read from the repo
        rather than hardcoded -- otherwise the guard is one more pin to flip at
        cutover, and a missed one would refuse every legitimate deploy."""
        self.assertIn(
            "default_branch",
            self.script,
            "the ref guard does not read the trunk from the default branch",
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
