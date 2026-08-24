"""Production has no agent, and the one thing that installs an agent is aimed at staging.

`production-deploy.yml` queues its command to `commands-prod`. Nothing polls that
prefix. `connect-srv-prod` carries no `windows-startup-script-ps1`, no scheduled
task, and a service account scoped to `devstorage.read_only` -- which cannot write
the result object the deploy workflow then waits for. A production deploy dispatched
today queues a command that is never read and polls for a result that is never
written, until it times out.

`pr-test-bootstrap-command-queue.yml` is the only thing in the repository that
installs the agent, and it resolves its VM from `GCP_VM_EXTERNAL_IP` -- the test box.
Pointing it at production would also hand production staging's queue and staging's
scripts.

So there are two halves here, and they fail differently:

  * The queue name is already a parameter, so production gets its own commands.
    The *script source* is not: `$BootstrapPrefix` is a hardcoded literal, so a
    production agent would refresh itself once a minute from the prefix the staging
    bootstrap publishes -- an unreviewed staging script would reach production
    within 60 seconds of being uploaded. BootstrapPrefixIsolationTests covers that.

  * Nothing installs the agent on production at all.
    ProductionBootstrapWorkflowTests covers that.
"""

import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
INSTALL_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Install-PrEnvironmentCommandQueueTask.ps1"
WORKFLOW_NAME = "production-bootstrap-command-queue.yml"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-bootstrap-command-queue.yml"
STAGING_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"

STAGING_PREFIX = "pr-environments/bootstrap/latest/"
PRODUCTION_PREFIX = "pr-environments/bootstrap/prod/"
PRODUCTION_QUEUE = "commands-prod"


class BootstrapPrefixIsolationTests(unittest.TestCase):
    """One bucket, two hosts, one script source is one host too many."""

    def setUp(self):
        self.agent = QUEUE_SCRIPT.read_text()
        self.installer = INSTALL_SCRIPT.read_text()

    def test_the_agent_takes_the_bootstrap_prefix_as_a_parameter(self):
        self.assertIn(
            "$BootstrapPrefix",
            self.agent,
            "the agent has no bootstrap prefix at all",
        )
        self.assertIn(
            "[Parameter(Mandatory = $false)][string]$BootstrapPrefix",
            self.agent,
            "the bootstrap prefix is still a hardcoded literal, so every host that "
            "runs this agent refreshes itself from the same place",
        )

    def test_the_default_prefix_is_what_the_test_vm_already_uses(self):
        """The test VM's scheduled task was installed without this argument and will
        keep running without it until somebody re-bootstraps. A default that moved
        would silently stop refreshing the box that does work today."""
        self.assertIn(
            f'$BootstrapPrefix = "{STAGING_PREFIX}"',
            self.agent,
            "the default bootstrap prefix changed; every already-installed agent "
            "would start syncing from a prefix nothing publishes to",
        )

    def test_a_malformed_prefix_is_rejected_before_it_is_used(self):
        """`$Prefix` goes straight into a GCS list query. An empty string lists the
        whole bucket -- every command object, every log, every artifact -- and then
        parse-checks the ones ending in .ps1. A missing trailing slash matches
        sibling prefixes: `bootstrap/prod` also matches `bootstrap/production-old/`."""
        self.assertIn(
            "$BootstrapPrefix -notmatch",
            self.agent,
            "the bootstrap prefix is never validated, so a typo silently widens what "
            "the agent downloads and executes",
        )

    def test_the_queue_name_is_not_reused_as_the_script_source(self):
        """Deriving one from the other looks tidy and moves the test VM's prefix,
        which is the one change nothing in this repository can roll back."""
        self.assertNotIn(
            'pr-environments/bootstrap/$QueueName',
            self.agent,
            "the script prefix is derived from the queue name, which moves the test "
            "VM off the prefix its installed task already reads",
        )

    def test_the_installer_passes_the_prefix_through_to_the_task(self):
        """The installer writes the scheduled task's command line once, at bootstrap.
        A parameter it does not pass is a parameter production cannot set."""
        self.assertIn(
            "[Parameter(Mandatory = $false)][string]$BootstrapPrefix",
            self.installer,
            "the installer cannot be told which prefix to install against",
        )
        self.assertIn(
            "-BootstrapPrefix",
            self.installer,
            "the installer accepts a bootstrap prefix and drops it; the task it "
            "writes still runs the agent on its default",
        )

        task_line = next(
            (line for line in self.installer.splitlines() if "$taskCommand =" in line),
            None,
        )
        self.assertIsNotNone(task_line, "the scheduled task command line moved")
        self.assertIn(
            "-BootstrapPrefix",
            task_line,
            "the prefix is accepted but not written into the scheduled task command, "
            "so it applies to nothing",
        )


class ProductionBootstrapWorkflowTests(unittest.TestCase):
    """The workflow that gives production an agent, and the guards that stop it
    becoming a way to restart production by accident."""

    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.parsed = harness.workflow(WORKFLOW_NAME)

    def test_the_workflow_exists(self):
        self.assertTrue(
            WORKFLOW.exists(),
            "nothing installs the command queue agent on the production VM, so "
            "production-deploy.yml queues to a prefix no host reads",
        )

    def test_it_can_only_be_started_by_hand(self):
        """A push or a schedule that reaches production is a production restart
        nobody asked for."""
        triggers = harness.triggers(self.parsed)
        self.assertEqual(
            set(triggers),
            {"workflow_dispatch"},
            f"the production bootstrap answers to more than a manual dispatch: {sorted(triggers)}",
        )

    def test_restarting_the_vm_is_opt_in(self):
        """Writing the metadata is harmless: it takes effect at the next boot. The
        stop/start is the outage. Splitting them means the default dispatch stages
        the change and an operator picks the window."""
        inputs = self.parsed["on"]["workflow_dispatch"]["inputs"]
        self.assertIn(
            "restart_vm",
            inputs,
            "the production bootstrap restarts the VM with no way to say no",
        )
        self.assertIs(
            inputs["restart_vm"]["default"],
            False,
            "restarting production is the default behaviour of a manual dispatch",
        )

    def test_every_command_that_interrupts_production_is_gated_on_that_input(self):
        gated = ("instances stop", "set-service-account", "instances start")
        for command in gated:
            with self.subTest(command=command):
                self.assertIn(command, self.text, f"{command} is missing entirely")
        self.assertIn(
            "inputs.restart_vm",
            self.text,
            "the restart input is declared and never read",
        )

    def test_the_restart_needs_the_production_environment_approval(self):
        """The same gate `production-deploy.yml` uses. A bootstrap that reboots the
        production web server without review is a deploy in everything but name."""
        jobs = self.parsed["jobs"]
        restarting = [
            name
            for name, job in jobs.items()
            if "restart" in name or "environment" in job
        ]
        self.assertTrue(restarting, "no job in the production bootstrap is gated at all")

        gated = [
            name
            for name, job in jobs.items()
            if str(job.get("environment", "")).find("production") >= 0
            or (isinstance(job.get("environment"), dict)
                and job["environment"].get("name") == "production")
        ]
        self.assertTrue(
            gated,
            "no job declares environment: production, so the reviewer requirement "
            "that covers production deploys does not cover a production restart",
        )

    def test_it_installs_against_the_production_queue(self):
        self.assertIn(
            PRODUCTION_QUEUE,
            self.text,
            "the production bootstrap installs an agent on the staging queue, so both "
            "hosts would race for every command",
        )

    def test_it_installs_against_a_production_only_script_prefix(self):
        self.assertIn(
            PRODUCTION_PREFIX,
            self.text,
            "production refreshes its scripts from the prefix the staging bootstrap "
            "publishes to, so a staging script change reaches production in 60 seconds",
        )

    def test_it_does_not_publish_to_or_read_the_staging_prefix(self):
        for line in self.text.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            with self.subTest(line=stripped[:70]):
                self.assertNotIn(
                    STAGING_PREFIX,
                    stripped,
                    "the production bootstrap touches the staging script prefix",
                )

    def test_it_publishes_scripts_as_text(self):
        """Same failure as the staging publisher: an octet-stream .ps1 arrives at the
        agent as a byte[], fails the parse check, and is skipped on every poll."""
        self.assertIn(
            'gsutil -h "Content-Type:text/plain',
            self.text,
            "the production bootstrap publishes .ps1 files untyped, so the agent "
            "never refreshes any of them",
        )

    def test_it_targets_the_production_vm_and_not_the_test_vm(self):
        self.assertIn(
            "connect-srv-prod",
            self.text,
            "the production bootstrap does not name the production VM",
        )
        # The expression, not the name. The prose above explains why that secret is
        # the wrong way to find this VM, and a substring match on the name would make
        # writing that explanation down a test failure.
        self.assertNotIn(
            "secrets.GCP_VM_EXTERNAL_IP",
            self.text,
            "the production bootstrap resolves its VM the way the staging bootstrap "
            "does, which finds the test box",
        )

    def test_it_parse_checks_the_scripts_before_publishing_them(self):
        """The staging bootstrap does this and the reason is stronger here: a syntax
        error published to the production prefix is a production agent that dies
        silently every minute."""
        self.assertIn(
            "[System.Management.Automation.Language.Parser]::ParseFile",
            self.text,
            "scripts are published to production without a parse check",
        )

    def _step(self, name):
        """One named step of the bootstrap job, whole. Callers that want the shell
        body take `["run"]`; the expressions a step reads can live in `env` instead,
        so a helper that returned only the body would miss them."""
        steps = self.parsed["jobs"]["bootstrap"]["steps"]
        matching = [step for step in steps if step.get("name") == name]
        self.assertEqual(len(matching), 1, f"expected exactly one step named {name!r}")
        return matching[0]

    def test_the_startup_script_will_not_install_an_agent_that_cannot_write(self):
        """Staging the metadata is described as inert, and it is only inert because
        of this check. A startup script runs at every boot, so any reboot between
        staging and the restart -- Windows Update is enough -- would otherwise
        install an agent while the scopes are still read_only. That agent can read
        the queue and cannot write a result, and the failed write aborts before the
        command object is deleted, so one queued production command would run again
        every minute for as long as the box stayed up."""
        staging = self._step("Stage the startup script on the production VM")["run"]

        self.assertIn(
            "service-accounts/default/scopes",
            staging,
            "the startup script never asks what scopes it has, so a boot before "
            "the restart installs an agent that cannot write its results",
        )

        guard = staging.index("service-accounts/default/scopes")
        install = staging.index("Install-PrEnvironmentCommandQueueTask.ps1 -BucketName")
        self.assertLess(
            guard,
            install,
            "the scope check runs after the installer, which is not a check",
        )

        self.assertIn(
            "devstorage.read_write",
            staging[guard:install],
            "the scope check does not name the scope the agent actually needs",
        )

    def test_a_bad_scope_read_stops_before_production_does(self):
        """The scope list is read, filtered, and written back. If the read fails or
        returns nothing, the filtered list collapses to the one scope this workflow
        adds, and writing that back strips `logging.write` and `monitoring.write` --
        production's Ops Agent goes quiet on upgrade day. The read happens before
        `instances stop`, so refusing there costs nothing: production is still up."""
        restart = self._step("Restart the production VM to apply it")["run"]

        read = restart.index("gcloud compute instances describe")
        stop = restart.index("gcloud compute instances stop")
        preflight = restart[read:stop]

        self.assertIn(
            "$LASTEXITCODE",
            preflight,
            "the scopes are read without checking the read succeeded",
        )
        self.assertIn(
            "throw",
            preflight,
            "a failed scope read does not abort, so the union runs on nothing",
        )
        self.assertIn(
            "$scopes.Count",
            preflight,
            "an empty scope list is not rejected, so set-service-account would be "
            "handed the one scope this workflow adds and drop the rest",
        )

    def test_the_run_checks_the_agent_installed_rather_than_assuming_it(self):
        """`instances start` returns when the instance is running, and the startup
        script runs afterwards, on the box, reporting to nobody. Without a check the
        job is green whether the agent installed or not -- and the next thing anyone
        does with a green bootstrap is dispatch a production deploy into it."""
        verify = self._step("Wait for the agent to report in")["run"]
        staging = self._step("Stage the startup script on the production VM")["run"]

        self.assertIn(
            "get-serial-port-output",
            verify,
            "nothing reads back what the startup script did",
        )

        # The two halves of a check that only works if they agree: the string the
        # startup script prints, and the string the runner greps for.
        marker = "ROCK-BOOTSTRAP:"
        self.assertIn(marker, staging, "the startup script prints no marker to find")
        self.assertIn(marker, verify, "the check looks for a marker nothing prints")

        self.assertIn(
            "refusing to install",
            verify,
            "a startup script that declined to install reads as a pass, because the "
            "check only asks whether it said anything at all",
        )

    def test_the_summary_reports_what_happened_not_what_was_asked_for(self):
        """`restart_vm` records a request. Whether production came back up is the
        restart step's outcome, and those differ exactly when it matters: announcing
        a healthy agent over a failed restart is the one summary that would send
        somebody to dispatch a deploy at an instance that is still stopped."""
        summary = self._step("Say what happened")
        # What the step is handed, and what it does with it. Both matter: reading
        # the outcome into `env` and then branching on the input would pass a check
        # of either half on its own.
        passed_in = " ".join(str(value) for value in summary.get("env", {}).values())
        body = summary["run"]

        self.assertIn(
            "steps.restart.outcome",
            passed_in,
            "the summary never reads the restart step's outcome",
        )
        self.assertIn(
            "steps.verify.outcome",
            passed_in,
            "the summary never reads whether the agent was confirmed",
        )

        # Four states, and the interesting one is a restart that was asked for and
        # did not succeed -- the case the earlier version of this step reported as
        # a healthy production agent.
        for outcome in ("$RESTART_OUTCOME", "$VERIFY_OUTCOME", "$RESTART_REQUESTED"):
            with self.subTest(outcome=outcome):
                self.assertIn(
                    outcome,
                    body,
                    "the summary does not distinguish a completed restart from a "
                    "requested one",
                )

    def test_the_staging_bootstrap_still_owns_only_staging(self):
        """The inverse of the isolation: if the staging bootstrap ever learns the
        production queue name, both workflows install onto whichever VM ran last."""
        self.assertNotIn(
            PRODUCTION_QUEUE,
            STAGING_WORKFLOW.read_text(),
            "the staging bootstrap references the production queue",
        )


if __name__ == "__main__":
    unittest.main()
