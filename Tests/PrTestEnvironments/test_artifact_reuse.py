"""How pr-test-artifact.yml skips the build for a change that does not need one.

A full build is about half an hour on a Windows runner, and most changes to this
site are Lava, markup and theme assets the build copies into the artifact
untouched. The plan job asks whether an artifact already in the bucket differs
from this commit in such files alone; when one does, the repackage job swaps the
changed files into a copy of it instead of building.

What the two scripts decide is tested in Pester -- ArtifactPlan.Tests.ps1 and
ArtifactRepackage.Tests.ps1. What is tested here is the wiring, because every
piece of it fails quietly: a gate that lets both jobs run uploads two zips to one
folder, an output only one job sets leaves every deploy after a repackage with an
empty object path, and a label nothing reads looks exactly like a build that
ignored it.
"""

import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
PLAN_SCRIPT = REPO_ROOT / ".github" / "scripts" / "Get-ArtifactPlan.ps1"
REPACKAGE_SCRIPT = REPO_ROOT / ".github" / "scripts" / "New-RepackagedArtifact.ps1"

ARTIFACT_WORKFLOW = "pr-test-artifact.yml"


class ThePlanDecidesWhichJobPackagesTests(harness.HarnessAssertions, unittest.TestCase):
    """Exactly one of the two packaging jobs runs, and the plan says which."""

    def setUp(self):
        self.jobs = harness.workflow(ARTIFACT_WORKFLOW)["jobs"]

    def test_the_plan_job_runs_the_plan_script(self):
        plan = self.jobs.get("plan")
        self.assertIsNotNone(plan, "there is no plan job, so nothing decides whether to build")

        runs = "\n".join(step.get("run") or "" for step in plan.get("steps") or [])
        self.assertIn(".github/scripts/Get-ArtifactPlan.ps1", runs)
        self.assertTrue(PLAN_SCRIPT.is_file())
        self.assertIn("mode", plan.get("outputs") or {})

    def test_the_build_runs_unless_the_plan_said_repackage(self):
        """Not `mode == 'build'`: a plan that failed outright sets no mode at all,
        and that has to cost a build rather than a run with no artifact.

        The step's own continue-on-error covers the script. It does not cover the
        job around it -- a checkout, a sign-in or a hung `gsutil` that runs out the
        timeout -- and a failed job skips everything that needs it unless told
        otherwise. `!cancelled()` sends the build in anyway; continue-on-error on
        the job keeps the run green after it, because the caller's deploy needs
        this whole workflow to succeed, not only the job that packaged."""
        package = self.jobs["package"]
        self.assertIn("plan", self._needs(package))
        self.assertEqual("!cancelled() && needs.plan.outputs.mode != 'repackage'", self._condition(package))
        self.assertIs(True, self.jobs["plan"].get("continue-on-error"))

    def test_the_repackage_runs_only_when_the_plan_said_so(self):
        repackage = self.jobs.get("repackage")
        self.assertIsNotNone(repackage, "there is no repackage job, so every run builds")
        self.assertIn("plan", self._needs(repackage))
        self.assertEqual("needs.plan.outputs.mode == 'repackage'", self._condition(repackage))

        runs = "\n".join(step.get("run") or "" for step in repackage.get("steps") or [])
        self.assertIn(".github/scripts/New-RepackagedArtifact.ps1", runs)
        self.assertTrue(REPACKAGE_SCRIPT.is_file())

    def _needs(self, job):
        """A job's `needs:`, as a list whichever way it was written."""
        needs = job.get("needs") or []
        return [needs] if isinstance(needs, str) else needs

    def _condition(self, job):
        """A job's `if:`, without the optional `${{ }}` around it."""
        condition = str(job.get("if") or "").strip()
        unwrapped = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", condition)
        return unwrapped.group(1) if unwrapped else condition


class TheRepackageShipsWhatABuildWouldTests(harness.HarnessAssertions, unittest.TestCase):
    """Nothing downstream can tell a repackaged artifact from a built one."""

    def setUp(self):
        self.jobs = harness.workflow(ARTIFACT_WORKFLOW)["jobs"]
        self.steps = self.jobs["repackage"]["steps"]

    def test_text_files_carry_the_line_endings_a_build_ships(self):
        """The build checks out on a Windows runner, where Git for Windows turns
        autocrlf on system-wide -- not by its own "Setup Git CRLF" step, which
        comes after its checkout. So every Lava file in a built zip has CRLF
        endings. A Linux checkout without the setting ships LF, and a patched
        template then differs from its neighbours byte for byte. The setting is
        read at checkout, so after it is too late."""
        uses = [step.get("uses") or "" for step in self.steps]
        checkout = next(i for i, u in enumerate(uses) if u.startswith("actions/checkout"))
        before = [step.get("run") or "" for step in self.steps[:checkout]]
        self.assertTrue(
            any("git config --global core.autocrlf true" in run for run in before),
            "the repackage checks out before turning autocrlf on",
        )

    def test_the_zip_and_its_metadata_land_where_a_build_puts_them(self):
        """Compared against the package job rather than restated, so the two
        cannot drift: the deploy reads one folder, whichever job filled it."""
        def uploads(steps):
            return sorted(
                (step["with"]["path"].split(".")[-1], step["with"]["destination"])
                for step in steps
                if (step.get("uses") or "").startswith("google-github-actions/upload-cloud-storage@")
            )

        built = uploads(self.jobs["package"]["steps"])
        self.assertNotVacuous(built, "the package job no longer uploads to Cloud Storage")
        self.assertEqual(built, uploads(self.steps))

    def test_the_metadata_and_outputs_are_the_ones_a_build_writes(self):
        """The repackage writes them itself rather than sharing the package job's
        step, whose steps are held identical to the hand-deploy build's. So the
        build's step is the source of truth here: every field it records, in its
        order, then whatever only a repackage has; and the same outputs."""
        built = next(s for s in self.jobs["package"]["steps"] if s.get("id") == "package-metadata")["run"]
        repackaged = REPACKAGE_SCRIPT.read_text()

        def fields(script):
            block = re.search(r"\$metadata = \[ordered\]@\{(.*?)\n\s*\}", script, re.DOTALL)
            self.assertIsNotNone(block, "no [ordered] metadata block")
            return re.findall(r"^\s*(\w+)\s*=", block.group(1), re.MULTILINE)

        def outputs(script):
            return sorted(re.findall(r'"(\w+)=[^"]*" \| Out-File -FilePath \$env:GITHUB_OUTPUT', script))

        built_fields = fields(built)
        self.assertNotVacuous(built_fields, "the package job records no metadata fields")
        self.assertEqual(built_fields, fields(repackaged)[: len(built_fields)])

        self.assertNotVacuous(outputs(built), "the package job writes no outputs")
        self.assertEqual(outputs(built), outputs(repackaged))

    def test_the_run_keeps_the_zip_as_a_build_does(self):
        kept = [
            step for step in self.steps
            if (step.get("uses") or "").startswith("actions/upload-artifact@")
        ]
        self.assertEqual(1, len(kept), "the repackaged zip is not kept with the run")
        self.assertIn("pr-test-artifact.json", kept[0]["with"]["path"])

    def test_every_output_the_callers_read_comes_from_whichever_job_ran(self):
        """The skipped job's outputs are empty strings, so `||` picks the one that
        ran. An output only the package job sets would hand every deploy after a
        repackage an empty object path -- `gs:///` -- and the deploy would fail on
        the VM, minutes later, far from the cause."""
        outputs = harness.triggers(harness.workflow(ARTIFACT_WORKFLOW))["workflow_call"]["outputs"]
        self.assertNotVacuous(outputs, "the workflow declares no outputs")

        for name, output in outputs.items():
            self.assertEqual(
                f"${{{{ jobs.package.outputs.{name} || jobs.repackage.outputs.{name} }}}}",
                output["value"],
                f"the {name} output reads one packaging job only",
            )
            self.assertIn(name, self.jobs["repackage"].get("outputs") or {}, f"the repackage job never sets {name}")


class AFullBuildCanBeForcedTests(harness.HarnessAssertions, unittest.TestCase):
    """The way out when a repackage fails, or when its rules are wrong about a path."""

    def test_staging_and_production_can_force_one_when_dispatched(self):
        """Each in its own workflow's idiom. Staging also runs on push, where the
        `inputs` context does not exist and referencing it is a startup failure, so
        it reads github.event.inputs -- a string on dispatch, null on push, and
        false either way unless the box was ticked. Production is dispatch-only."""
        passed = {
            "staging-deploy.yml": "${{ github.event.inputs.force_build == 'true' }}",
            "production-deploy.yml": "${{ inputs.force_build }}",
        }
        for name, expression in passed.items():
            with self.subTest(workflow=name):
                caller = harness.workflow(name)
                declared = (harness.triggers(caller)["workflow_dispatch"].get("inputs") or {}).get("force_build")
                self.assertIsNotNone(declared, f"{name} cannot be dispatched with a full build")
                self.assertEqual("boolean", declared.get("type"))
                self.assertIs(False, declared.get("default", False))
                self.assertEqual(expression, (caller["jobs"]["build"].get("with") or {}).get("force_build"))

    def test_both_triggers_take_force_build(self):
        on = harness.triggers(harness.workflow(ARTIFACT_WORKFLOW))
        for trigger in ("workflow_call", "workflow_dispatch"):
            declared = (on[trigger].get("inputs") or {}).get("force_build")
            self.assertIsNotNone(declared, f"{trigger} has no force_build input")
            self.assertEqual("boolean", declared.get("type"), trigger)
            self.assertIs(False, declared.get("default", False), f"{trigger} builds every time unless told not to")

    def test_the_plan_hands_force_build_to_the_script(self):
        """Read from `env:`, because the syntax job parses every block with the
        `${{ }}` already substituted, and a bare one is not PowerShell."""
        plan = harness.workflow(ARTIFACT_WORKFLOW)["jobs"]["plan"]
        step = next(s for s in plan["steps"] if "Get-ArtifactPlan.ps1" in (s.get("run") or ""))
        self.assertEqual("${{ inputs.force_build }}", (step.get("env") or {}).get("FORCE_BUILD"))
        self.assertIn("-ForceBuild:($env:FORCE_BUILD -eq 'true')", step["run"])

    def test_the_full_build_label_reaches_the_build(self):
        """Read from the pull request the prepare job already fetched, not from
        `github.event`: a manual redeploy is a workflow_dispatch, whose event
        carries no pull request, and the label would be silently ignored there."""
        jobs = harness.workflow("pr-test-deploy.yml")["jobs"]

        prepare = jobs["prepare"]
        self.assertEqual("${{ steps.prepare.outputs.force_build }}", (prepare.get("outputs") or {}).get("force_build"))
        script = next(s for s in prepare["steps"] if s.get("id") == "prepare")["with"]["script"]
        self.assertIn("'rock:full-build'", script)
        self.assertRegex(script, r"core\.setOutput\('force_build'")

        self.assertEqual(
            "${{ needs.prepare.outputs.force_build == 'true' }}",
            (jobs["build"].get("with") or {}).get("force_build"),
        )


class ThePlanCanAskWhereACommitCameFromTests(harness.HarnessAssertions, unittest.TestCase):
    def test_the_token_can_read_pull_requests(self):
        """A merge to the trunk carries the code its pull request last deployed,
        so that pull request's artifact is the natural base for staging. GitHub
        answers "which pull requests is this commit in" only to a token that can
        read pull requests; without it the lookup fails, the plan carries on
        without that tier, and staging builds after every merge.

        The callers have to grant it too -- ReusableWorkflowPermissionTests in
        test_environment_deploy.py holds them to that."""
        permissions = harness.workflow(ARTIFACT_WORKFLOW).get("permissions") or {}
        self.assertEqual("read", permissions.get("pull-requests"))


if __name__ == "__main__":
    unittest.main()
