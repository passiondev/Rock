"""Tests for the long-lived environment (staging / production) deploy path.

These environments reuse the PR test environment control plane -- the same GCS
command queue and the same Windows build -- but they differ in ways that are easy
to get wrong and expensive to get wrong on production. The tests below pin the
properties that make the production path safe.
"""

import pathlib
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-RockEnvironment.ps1"
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
TASK_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Install-PrEnvironmentCommandQueueTask.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
ARTIFACT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-artifact.yml"
COMMAND_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "env-deploy-command.yml"
STAGING_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "staging-deploy.yml"
PRODUCTION_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-deploy.yml"

TRUNK_BRANCH = "passion-18.4.1"
STAGING_HOST = "staging.rock-dev.connect.passion.team"


class EnvironmentDeployScriptTests(unittest.TestCase):
    def test_script_supports_both_dedicated_site_and_in_place_modes(self):
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("[ValidateSet('DedicatedSite', 'InPlace')]", text)
        self.assertIn("$EnvironmentName", text)

    def test_in_place_deploy_is_a_dry_run_unless_apply_is_passed(self):
        """A production overwrite should never be one mistyped argument away. The
        script reports its plan and returns unless -Apply is explicitly given."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("$Apply", text)
        self.assertIn("if ($Mode -eq 'InPlace' -and -not $Apply)", text)
        self.assertIn("DRY RUN", text)

    def test_in_place_deploy_backs_up_before_touching_the_live_site(self):
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("$BackupRoot", text)
        self.assertIn("refusing to deploy", text)
        # The backup must happen before the copy that overwrites the site.
        self.assertLess(
            text.index("Backing up $SitePath"),
            text.index("Deploy copy failed"),
            "backup must run before the artifact is copied over the live site",
        )

    def test_in_place_deploy_never_purges_server_owned_data(self):
        """robocopy /MIR or /PURGE against a live Rock webroot deletes uploaded
        Content and App_Data -- user data that exists nowhere else. Every copy in
        this script must be additive."""
        text = DEPLOY_SCRIPT.read_text()

        robocopy_lines = [line for line in text.splitlines() if line.lstrip().startswith("& robocopy")]
        self.assertGreaterEqual(len(robocopy_lines), 3)
        for line in robocopy_lines:
            self.assertNotIn("/MIR", line)
            self.assertNotIn("/PURGE", line)

        for preserved in ["'Content'", "'App_Data'", "'Logs'", "'Uploads'"]:
            self.assertIn(preserved, text)
        self.assertIn("'web.ConnectionStrings.config'", text)
        self.assertIn("$PreservedDirectories", text)
        self.assertIn("$PreservedFiles", text)

    def test_production_connection_string_on_disk_is_left_alone_when_none_supplied(self):
        """CI has no production database credentials by design. With no connection
        string in the command, the deploy must keep the file already on the box
        rather than writing an empty one and taking the site down."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("if (![string]::IsNullOrWhiteSpace($Connection))", text)
        self.assertIn("leaving the existing web.ConnectionStrings.config in place", text)

    def test_dedicated_site_manifest_lands_where_certificate_renewal_finds_it(self):
        """Invoke-PrEnvironmentCertificateRenewal.ps1 walks $EnvironmentRoot for
        env.json files with status 'deployed' and keys off hostName/siteName, not
        PR numbers -- so staging gets Let's Encrypt renewal for free, but only if
        its manifest is written under that root."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn('$EnvironmentRoot = "C:\\RockTestEnvs"', text)
        self.assertIn('$ManifestPath = Join-Path $EnvironmentPath "env.json"', text)
        self.assertIn('status = "deployed"', text)
        self.assertIn("hostName = $HostName", text)
        self.assertIn("siteName = $SiteName", text)

    def test_in_place_manifest_is_kept_out_of_the_renewal_search_path(self):
        """The renewal job stops and starts every site it finds a manifest for. A
        production manifest under C:\\RockTestEnvs would put production in the blast
        radius of a certificate job running on the test VM."""
        text = DEPLOY_SCRIPT.read_text()
        in_place_manifest = "$ManifestPath = Join-Path (Join-Path $BackupRoot $EnvironmentName) \"env.json\""
        self.assertIn(in_place_manifest, text)

    def test_deploy_waits_for_the_site_to_answer_before_reporting_success(self):
        """Rock runs EF and plugin migrations on the first request after a deploy,
        so a deploy that only checks 'did the files copy' reports success on a site
        that is about to throw a yellow screen."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("Test-EnvironmentHealth", text)
        self.assertIn("$HealthCheckTimeoutSeconds", text)
        self.assertIn("did not become healthy", text)

    def test_app_pool_is_stopped_and_drained_before_files_are_replaced(self):
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("Stop-EnvironmentAppPool", text)
        self.assertIn("Get-WebAppPoolState", text)
        self.assertNotIn("Restart-Computer", text)
        self.assertNotIn("iisreset", text.lower())


class CommandQueueTests(unittest.TestCase):
    def test_queue_dispatches_deploy_environment_to_the_new_script(self):
        text = QUEUE_SCRIPT.read_text()
        self.assertIn('"deploy-environment"', text)
        self.assertIn("Deploy-RockEnvironment.ps1", text)
        self.assertIn("'deploy-environment' = 1800", text)

    def test_each_vm_polls_its_own_queue_prefix(self):
        """The deployment bucket is shared. If the test VM and the production VM
        both polled pr-environments/commands/pending, they would race for every
        command and each would win about half -- a staging deploy could execute on
        production. The prefix is therefore per-VM, defaulting to the existing
        test-VM queue so nothing already installed moves."""
        text = QUEUE_SCRIPT.read_text()
        self.assertIn("$QueueName", text)
        self.assertIn('$QueueName = "commands"', text)
        self.assertIn('$PendingPrefix = "pr-environments/$QueueName/pending/"', text)
        self.assertIn('$ResultsPrefix = "pr-environments/$QueueName/results/"', text)

        installer = TASK_SCRIPT.read_text()
        self.assertIn("-QueueName", installer)

    def test_optional_command_fields_are_only_forwarded_when_present(self):
        """Production omits connectionString so the box keeps its own. Passing an
        empty string instead would overwrite it with nothing."""
        text = QUEUE_SCRIPT.read_text()
        self.assertIn("IsNullOrWhiteSpace([string]$Command.$optional)", text)
        self.assertIn("'connectionString'", text)

    def test_bootstrap_ships_the_environment_deploy_script_to_the_vm(self):
        """Scripts are only re-downloaded by the startup script, so a script the
        bootstrap list does not name never reaches the VM and the command fails
        with 'file not found' minutes later."""
        self.assertIn("Deploy-RockEnvironment.ps1", BOOTSTRAP_WORKFLOW.read_text())


class ArtifactReuseTests(unittest.TestCase):
    def test_one_build_serves_pr_staging_and_production(self):
        """Staging and production must be built by the same workflow as PR
        environments. A second copy of the build is how build-develop.yml drifted
        away from reality and stayed broken without anyone noticing."""
        workflow = yaml.safe_load(ARTIFACT_WORKFLOW.read_text())
        call_inputs = workflow["on"]["workflow_call"]["inputs"]

        self.assertIn("artifact_slug", call_inputs)
        self.assertFalse(call_inputs["pr_number"].get("required", False))

        text = ARTIFACT_WORKFLOW.read_text()
        self.assertIn("ARTIFACT_SLUG", text)
        self.assertNotIn("pr-environments/pr-${{ env.PR_NUMBER }}", text)

        for caller in [STAGING_WORKFLOW, PRODUCTION_WORKFLOW]:
            self.assertIn("uses: ./.github/workflows/pr-test-artifact.yml", caller.read_text())

    def test_environment_artifacts_do_not_collide(self):
        staging = yaml.safe_load(STAGING_WORKFLOW.read_text())
        production = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        self.assertEqual(staging["jobs"]["build"]["with"]["artifact_slug"], "staging")
        self.assertEqual(production["jobs"]["build"]["with"]["artifact_slug"], "production")


class CommandWorkflowTests(unittest.TestCase):
    def test_command_workflow_fails_fast_when_the_artifact_is_missing(self):
        text = COMMAND_WORKFLOW.read_text()
        self.assertIn("gsutil -q stat", text)
        self.assertIn("::error::Artifact not found", text)

    def test_timeout_message_names_the_actual_cause(self):
        """A missing result object means the queue worker never ran. 'Timed out'
        alone sent three months of failures to the wrong place."""
        text = COMMAND_WORKFLOW.read_text()
        self.assertIn("scheduled task is running on the target VM", text)

    def test_connection_string_is_redacted_from_logs(self):
        """The repo is public and these logs get screenshotted in training."""
        text = COMMAND_WORKFLOW.read_text()
        self.assertIn("<redacted>", text)


class StagingWorkflowTests(unittest.TestCase):
    def test_staging_tracks_the_trunk_branch(self):
        workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())
        self.assertEqual(workflow["on"]["push"]["branches"], [TRUNK_BRANCH])
        self.assertIn("workflow_dispatch", workflow["on"])

    def test_staging_deploys_its_own_site_against_the_sandbox_database(self):
        workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())
        deploy = workflow["jobs"]["deploy"]["with"]

        self.assertEqual(deploy["environment_name"], "staging")
        self.assertEqual(deploy["host_name"], STAGING_HOST)
        self.assertEqual(deploy["mode"], "DedicatedSite")
        self.assertEqual(deploy["queue_name"], "commands")
        self.assertTrue(deploy["write_connection_string"])

    def test_dual_trigger_workflow_does_not_use_the_inputs_context(self):
        """The `inputs` context does not exist on a push event. Referencing it in a
        workflow that has both push and workflow_dispatch triggers fails the entire
        run as a startup_failure -- no jobs, no logs, and actionlint does not catch
        it. github.event.inputs is null on push instead of undefined."""
        text = STAGING_WORKFLOW.read_text()
        body = text.split("jobs:", 1)[1]

        self.assertNotIn("${{ inputs.", body)
        self.assertIn("${{ github.event.inputs.ref || github.sha }}", body)

    def test_documentation_only_commits_do_not_trigger_a_thirty_minute_build(self):
        workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())
        ignored = workflow["on"]["push"]["paths-ignore"]
        self.assertIn("**/*.md", ignored)
        self.assertIn("Documentation/**", ignored)


class ProductionWorkflowTests(unittest.TestCase):
    def test_production_never_fires_automatically(self):
        """No push, schedule, or pull_request trigger may reach production."""
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        self.assertEqual(list(workflow["on"]), ["workflow_dispatch"])

    def test_production_deploy_requires_environment_approval_after_a_green_build(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())

        approve = workflow["jobs"]["approve"]
        self.assertEqual(approve["environment"]["name"], "production")
        # Approval gate must sit after the build: nobody should be asked to approve
        # a commit that does not compile.
        self.assertIn("build", approve["needs"])
        self.assertIn("approve", workflow["jobs"]["deploy"]["needs"])

    def test_production_defaults_to_a_dry_run(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        apply_input = workflow["on"]["workflow_dispatch"]["inputs"]["apply"]
        self.assertFalse(apply_input["default"])
        self.assertEqual(workflow["jobs"]["deploy"]["with"]["apply"], "${{ inputs.apply }}")

    def test_production_updates_the_existing_site_on_its_own_queue(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        deploy = workflow["jobs"]["deploy"]["with"]

        self.assertEqual(deploy["mode"], "InPlace")
        self.assertEqual(deploy["queue_name"], "commands-prod")
        self.assertNotEqual(deploy["queue_name"], "commands")
        self.assertIn("target_site_path", deploy)

    def test_ci_never_writes_a_production_connection_string(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        self.assertFalse(workflow["jobs"]["deploy"]["with"]["write_connection_string"])

        text = PRODUCTION_WORKFLOW.read_text()
        for forbidden in ["DB_PASSWORD", "DB_USER", "PROD_DB", "PRODUCTION_CONNECTION_STRING"]:
            self.assertNotIn(forbidden, text)

    def test_production_deploys_are_never_cancelled_midway(self):
        """Cancelling a deploy while robocopy is halfway through the webroot leaves
        a site made of two different builds."""
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])


class ReusableWorkflowPermissionTests(unittest.TestCase):
    """A called workflow can only narrow the caller's GITHUB_TOKEN, never widen it.

    If a callee's `permissions` block asks for a scope the caller did not grant,
    GitHub kills the entire run as a `startup_failure`: no jobs, no logs, and
    `actionlint` reports the files clean. This cost a real debugging cycle on
    staging-deploy.yml, which granted only `contents: read` while the build
    workflow it calls asks for `actions: read`.

    This walks every local `uses: ./.github/workflows/...` edge in the repo rather
    than naming the two known callers, so a future caller cannot reintroduce it.
    """

    #: Ordered weakest to strongest -- a caller granting `write` satisfies a callee
    #: asking for `read`, but not the reverse.
    _RANK = {"none": 0, "read": 1, "write": 2}

    def _permissions(self, workflow):
        declared = workflow.get("permissions")
        if declared in ("read-all", "write-all") or declared is None:
            # Inherited or blanket permissions are always a superset of anything a
            # callee can ask for, so there is nothing to check.
            return None
        return declared

    def test_every_caller_grants_at_least_what_its_called_workflows_request(self):
        workflow_dir = REPO_ROOT / ".github" / "workflows"
        edges = 0

        for caller_path in sorted(workflow_dir.glob("*.yml")):
            caller = yaml.safe_load(caller_path.read_text())
            caller_permissions = self._permissions(caller)

            for job_id, job in (caller.get("jobs") or {}).items():
                uses = (job or {}).get("uses", "")
                if not uses.startswith("./.github/workflows/"):
                    continue

                # removeprefix, not lstrip: lstrip("./") strips a character set and
                # would eat the dot off ".github" as well.
                callee_path = REPO_ROOT / uses.removeprefix("./")
                self.assertTrue(callee_path.exists(), f"{caller_path.name}:{job_id} calls missing {uses}")

                callee_permissions = self._permissions(yaml.safe_load(callee_path.read_text()))
                edges += 1

                # A job-level `permissions` block on the calling job overrides the
                # workflow-level one for that call.
                effective = (job.get("permissions") if "permissions" in job else caller_permissions)
                if effective is None or callee_permissions is None:
                    continue

                for scope, level in callee_permissions.items():
                    granted = effective.get(scope, "none")
                    self.assertGreaterEqual(
                        self._RANK[granted],
                        self._RANK[level],
                        f"{caller_path.name} job '{job_id}' grants {scope}: {granted} but "
                        f"{callee_path.name} requests {scope}: {level}. GitHub will fail the "
                        f"whole run as a startup_failure with no logs.",
                    )

        # Guard against the walk silently finding nothing, which would make this
        # test pass forever without checking anything.
        self.assertGreaterEqual(edges, 3, "expected to find local reusable workflow calls")


if __name__ == "__main__":
    unittest.main()
