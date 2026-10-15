import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
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


@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class ProductionVersionGuardRunTests(unittest.TestCase):
    """Run the version guard's own step text against a stubbed `gh`.

    The staging guard has been run by its tests since it was written; this one was
    only ever read as text. That was survivable while its comparison was a
    parameter expansion. It is now a call into .github/scripts/rock-version.sh,
    and a misspelt function name there fails the step under `bash -e` -- which
    refuses every production deploy, and no text match would notice.

    These pin the half of the comparison that is production's own: it compares
    the *minor*. 19.4.4 against 19.5.0 is one line, so the staging guard would
    let it through; production must not. The stub serves files per branch, so the
    expected version is only found where the guard should look for it -- on the
    branch `productionBranch` names, read from the default branch's config."""

    DEFAULT_BRANCH = "trunk"

    def _run(self, ref_version, production_version, acknowledged=False):
        """Returns `(exit code, stdout + stderr)` for one run of the guard."""
        script = _step_named(VERSION_GUARD_STEP)["run"]
        # What the runner substitutes before bash ever sees the text. Anything
        # left over would reach bash as a "bad substitution", so it is refused
        # here rather than passed through.
        expressions = {
            "${{ inputs.acknowledge_version_change }}": "true" if acknowledged else "false",
            "${{ github.actor }}": "deployer",
        }
        for expression, value in expressions.items():
            script = script.replace(expression, value)
        self.assertNotIn(
            "${{",
            script,
            "the version guard carries an expression this test does not substitute",
        )

        workdir = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        checkout = workdir / "checkout"
        checkout.mkdir()
        (checkout / "Directory.Build.props").write_text(
            f"<Project>\n  <PropertyGroup>\n    <Version>{ref_version}</Version>\n"
            "  </PropertyGroup>\n</Project>\n"
        )

        production_branch = f"passion-{production_version}"
        served = workdir / "served"
        config = served / self.DEFAULT_BRANCH / ".github" / "pr-test-environments.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"productionBranch": production_branch}))
        props = served / production_branch / "Directory.Build.props"
        props.parent.mkdir(parents=True)
        props.write_text(
            f"<Project>\n  <PropertyGroup>\n    <Version>{production_version}</Version>\n"
            "  </PropertyGroup>\n</Project>\n"
        )

        # `gh api repos/<owner>/<repo>/contents/<path>?ref=<branch> --jq .content`
        # answers with the file's base64, the way the contents API does; a path
        # the branch does not carry is a 404 and a non-zero exit.
        stub_dir = workdir / "bin"
        stub_dir.mkdir()
        stub = stub_dir / "gh"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'endpoint="$2"\n'
            'path="${endpoint#*/contents/}"\n'
            'path="${path%%\\?*}"\n'
            'ref="${endpoint##*\\?ref=}"\n'
            'served="$STUB_SERVED/$ref/$path"\n'
            'if [ ! -f "$served" ]; then echo "stub gh: 404 $ref:$path" >&2; exit 1; fi\n'
            'base64 < "$served"\n'
        )
        stub.chmod(0o755)

        env = dict(
            os.environ,
            PATH=f"{stub_dir}:{os.environ['PATH']}",
            STUB_SERVED=str(served),
            GITHUB_WORKSPACE=str(REPO_ROOT),
            GITHUB_STEP_SUMMARY=str(workdir / "summary.md"),
            GH_TOKEN="unused",
            REF="the-ref",
            REPOSITORY="passiondev/Rock",
            DEFAULT_BRANCH=self.DEFAULT_BRANCH,
        )
        # The flags the runner gives a `shell: bash` step.
        completed = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
            cwd=checkout,
            env=env,
            capture_output=True,
            text=True,
        )
        return completed.returncode, completed.stdout + completed.stderr

    def test_a_patch_change_within_the_production_minor_is_allowed(self):
        """A rollback, or a patch release on the minor production runs. Refusing
        this would make the checkbox routine, and a routine checkbox is ticked
        without being read."""
        code, output = self._run("19.4.1", "19.4.4")

        self.assertEqual(0, code, f"a same-minor production deploy was refused:\n{output}")

    def test_a_minor_change_within_the_line_is_refused(self):
        """The case that tells production's guard apart from staging's: one line,
        two minors. Staging lets this through; production compares the minor."""
        code, output = self._run("19.5.0", "19.4.4")

        self.assertNotEqual(0, code, f"a 19.5 ref was allowed onto a 19.4 production:\n{output}")
        self.assertIn("::error::", output, output)
        self.assertIn(
            "19.4",
            output,
            f"the refusal does not name the minor production expects:\n{output}",
        )

    def test_an_acknowledged_minor_change_is_allowed(self):
        """The upgrade path. The checkbox is what a deliberate upgrade ticks after
        taking a backup, so it has to let the same deploy through -- loudly."""
        code, output = self._run("19.5.0", "19.4.4", acknowledged=True)

        self.assertEqual(0, code, f"an acknowledged version change was still refused:\n{output}")
        self.assertIn("::warning::", output, output)


if __name__ == "__main__":
    unittest.main()
