"""How pr-test-artifact.yml skips the build for a change that does not need one.

A full build is about half an hour on a Windows runner, and most changes to this
site are Lava, markup and theme assets the build copies into the artifact
untouched. The plan job asks whether an artifact already in the bucket differs
from this commit in such files alone; when one does, the repackage job swaps the
changed files into a copy of it instead of building.

What the two scripts decide is tested in Pester -- ArtifactPlan.Tests.ps1 and
ArtifactRepackage.Tests.ps1 run each one whole, against an artifact store held
in memory instead of the bucket -- and where every artifact goes and what its
record says is ArtifactRecord.psm1, tested in ArtifactRecord.Tests.ps1, which
both packaging jobs write through, along with the gsutil store the scripts are
handed in the workflow. What is tested here is the wiring, because every
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

    def test_a_target_that_cannot_name_its_upload_destination_builds(self):
        """The repackage job runs the target's own scripts. A commit from between
        artifact reuse and artifact_gcs_destination repackages a zip with no
        destination, so the plan has to send it to the build -- the way it
        already does a commit from before artifact reuse -- rather than hand
        the repackage job a run it can only fail.

        One check covers both, since -Bucket arrived after the plan script, and
        it exits before the plan script runs, so it cannot set mode=repackage."""
        step = harness.step(harness.workflow(ARTIFACT_WORKFLOW), "Look for an artifact to repackage", job="plan")
        run = step["run"]

        # With the ./ -- without it Import-Module reads the path as a module
        # name, fails, and the step's continue-on-error turns every run into a
        # build.
        self.assertIn("$record = './.github/scripts/ArtifactRecord.psm1'", run)
        self.assertIn("Import-Module $record", run)
        self.assertRegex(
            run,
            r"(?s)if \(-not \(\$writer -and \$writer\.Parameters\.ContainsKey\('Bucket'\)\)\) \{.*?exit 0\s*\}",
        )
        self.assertLess(
            run.index("exit 0"),
            run.index("./.github/scripts/Get-ArtifactPlan.ps1"),
            "the plan runs before anything has asked whether a repackage could upload",
        )

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

    def test_the_build_packages_with_the_scripts_its_workflow_came_with(self):
        """Both jobs name the zip and write its record and outputs through
        ArtifactRecord.psm1, and ArtifactRecord.Tests.ps1 holds what those say.
        The repackage runs its target's copy, which is safe: a target from
        before the module carries the older, self-contained repackage script,
        and one from before artifact reuse plans a build and never gets there.
        The build has no such escape -- it packages every target, including one
        with no New-PackagedArtifact.ps1 -- so it runs the copy from the commit
        this workflow was read from, checked out into a folder of its own so
        the build's tree is left as the build left it."""
        steps = self.jobs["package"]["steps"]
        package = next(s for s in steps if s.get("id") == "package-metadata")
        side = [
            s for s in steps
            if (s.get("uses") or "").startswith("actions/checkout@") and (s.get("with") or {}).get("path")
        ]
        self.assertEqual(1, len(side), "the package job runs whichever packaging script its target has, if any")
        checkout = side[0]["with"]

        self.assertEqual("${{ github.workflow_sha }}", checkout.get("ref"))
        self.assertIn(".github/scripts", str(checkout.get("sparse-checkout") or ".github/scripts").split())
        self.assertLess(steps.index(side[0]), steps.index(package), "the scripts arrive after the step that runs them")
        self.assertIn(f"./{checkout['path']}/.github/scripts/New-PackagedArtifact.ps1", package["run"])

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


class EveryUploadGoesWhereTheModuleSaysTests(harness.HarnessAssertions, unittest.TestCase):
    """The four Cloud Storage uploads take their folder from Get-ArtifactAddress.

    ArtifactRecord.psm1 spells an artifact's address once, and the deploy's
    object path, both records and the plan's listing all come from it. The
    uploads used to spell the folder again from the job's env, so a change to
    the address would have moved where the deploy looks and left the zips where
    they were. Each packaging step now writes artifact_gcs_destination -- the
    bucket and folder, in the action's own `bucket/prefix` form -- and each
    upload takes it whole. ArtifactRecord.Tests.ps1 pins what that output says,
    down to the object names the action makes from it. What is held here is
    that the uploads read it and nothing else."""

    # Each packaging job, and the id of the step in it that writes the outputs.
    PACKAGING_STEP = {"package": "package-metadata", "repackage": "repackage"}

    ZIP_UPLOAD = "Upload package zip to Cloud Storage"
    RECORD_UPLOAD = "Upload package metadata to Cloud Storage"

    def setUp(self):
        self.parsed = harness.workflow(ARTIFACT_WORKFLOW)

    def _uploads(self, job):
        """The Cloud Storage uploads in one job, by step."""
        return [
            step for step in harness.steps(self.parsed, job)
            if (step.get("uses") or "").startswith("google-github-actions/upload-cloud-storage@")
        ]

    def _packaging_step(self, job):
        """The step that packaged the artifact, found by its id."""
        return next(s for s in harness.steps(self.parsed, job) if s.get("id") == self.PACKAGING_STEP[job])

    def test_no_upload_spells_the_folder_itself(self):
        uploads = [(job, step) for job in self.PACKAGING_STEP for step in self._uploads(job)]
        self.assertNotVacuous(uploads, "pr-test-artifact.yml no longer uploads to Cloud Storage")

        for job, step in uploads:
            with self.subTest(job=job, step=step.get("name")):
                self.assertNotIn(
                    "pr-environments",
                    str(step.get("with") or {}),
                    "this upload composes the artifact's folder itself rather than reading Get-ArtifactAddress's",
                )

    def test_each_upload_takes_its_destination_from_the_step_that_packaged(self):
        """Whole, with nothing composed around it. An output the packaging step
        never wrote is then an empty destination, which the action refuses;
        `${{ env.BUCKET }}/` in front of it would upload to the bucket's root."""
        for job, step_id in self.PACKAGING_STEP.items():
            with self.subTest(job=job):
                uploads = self._uploads(job)
                self.assertEqual(
                    sorted([self.ZIP_UPLOAD, self.RECORD_UPLOAD]),
                    sorted(step.get("name") for step in uploads),
                    f"the {job} job uploads something other than the zip and its record",
                )

                steps = harness.steps(self.parsed, job)
                packaged = steps.index(self._packaging_step(job))
                for step in uploads:
                    self.assertEqual(
                        f"${{{{ steps.{step_id}.outputs.artifact_gcs_destination }}}}",
                        step["with"]["destination"],
                    )
                    self.assertLess(packaged, steps.index(step), f"{step['name']} runs before the output it reads exists")

    def test_the_uploads_carry_the_zip_and_the_record_the_step_wrote(self):
        """The action names each object for the file it uploads, so these are
        the zip and record names Get-ArtifactAddress composed, under the folder
        it composed."""
        for job, step_id in self.PACKAGING_STEP.items():
            with self.subTest(job=job):
                zip_upload = harness.step(self.parsed, self.ZIP_UPLOAD, job=job)
                record_upload = harness.step(self.parsed, self.RECORD_UPLOAD, job=job)
                self.assertEqual(f"${{{{ steps.{step_id}.outputs.artifact_name }}}}", zip_upload["with"]["path"])
                self.assertEqual("pr-test-artifact.json", record_upload["with"]["path"])

    def test_both_packaging_steps_hand_the_module_what_the_folder_was_made_of(self):
        """The other half of keeping every object name what it was. The uploads
        were `${{ env.PR_TEST_GCS_BUCKET }}/pr-environments/${{ env.ARTIFACT_SLUG }}/${{ env.HEAD_SHA }}`;
        ArtifactRecord.Tests.ps1 shows the output is that bucket, slash, that
        folder, and this shows the module is handed those same three values,
        defined alike in both jobs so a repackage lands where a build would."""
        environments = []
        for job in self.PACKAGING_STEP:
            with self.subTest(job=job):
                run = self._packaging_step(job)["run"]
                self.assertIn("-Bucket $env:PR_TEST_GCS_BUCKET", run)
                self.assertIn("-ArtifactSlug $env:ARTIFACT_SLUG", run)
                self.assertIn("-TargetSha $env:HEAD_SHA", run)

                env = self.parsed["jobs"][job].get("env") or {}
                environments.append(
                    (job, repr({name: env.get(name) for name in ("PR_TEST_GCS_BUCKET", "ARTIFACT_SLUG", "HEAD_SHA")}))
                )

        self.assertOneShape(
            environments,
            "the bucket, slug and commit the two packaging jobs address their artifact by",
            "A repackaged artifact has to land in the folder a build of the same commit would fill.",
        )

    def test_a_repackage_that_names_no_destination_stops_before_uploading(self):
        """The repackage runs its target's own script, and a target from before
        artifact_gcs_destination writes the other five outputs and not this one.
        The action would refuse the empty destination anyway; this says why, and
        what to do, before anything is uploaded. Building instead is the way
        out, as it is for every repackage that fails."""
        guard = harness.step(self.parsed, "Refuse a repackage that names no upload destination", job="repackage")
        self.assertEqual("steps.repackage.outputs.artifact_gcs_destination == ''", guard.get("if"))
        self.assertIn("::error::", guard["run"])
        self.assertIn("force_build", guard["run"])
        self.assertIn("rock:full-build", guard["run"])
        self.assertRegex(guard["run"], r"(?m)^\s*exit 1\s*$")

        steps = harness.steps(self.parsed, "repackage")
        self.assertLess(steps.index(self._packaging_step("repackage")), steps.index(guard))
        self.assertLess(
            steps.index(guard),
            min(steps.index(step) for step in self._uploads("repackage")),
            "the guard runs after an upload has already been tried",
        )


class AFullBuildCanBeForcedTests(harness.HarnessAssertions, unittest.TestCase):
    """The way out when a repackage fails, or when its rules are wrong about a path."""

    def test_staging_and_production_can_force_one_when_dispatched(self):
        """Each in its own workflow's idiom. Staging also runs on push, where the
        `inputs` context does not exist and referencing it is a startup failure, so
        it reads github.event.inputs -- a string on dispatch, null on push, and
        false either way unless the box was ticked. Production is dispatch-only.

        Production's box starts ticked. A repackage base comes from a bucket the PR
        fleet can write, and the hash the deploy checks is taken after the base is
        copied, so it cannot tell a planted base from an honest one. A build reads
        nothing from the bucket. Production waits on a reviewer anyway, so the
        build's extra half hour costs little; unticking it promotes staging's zip."""
        passed = {
            "staging-deploy.yml": ("${{ github.event.inputs.force_build == 'true' }}", False),
            "production-deploy.yml": ("${{ inputs.force_build }}", True),
        }
        for name, (expression, default) in passed.items():
            with self.subTest(workflow=name):
                caller = harness.workflow(name)
                declared = (harness.triggers(caller)["workflow_dispatch"].get("inputs") or {}).get("force_build")
                self.assertIsNotNone(declared, f"{name} cannot be dispatched with a full build")
                self.assertEqual("boolean", declared.get("type"))
                self.assertIs(default, declared.get("default", False))
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
