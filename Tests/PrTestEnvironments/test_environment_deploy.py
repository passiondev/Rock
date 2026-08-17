"""Tests for the long-lived environment (staging / production) deploy path.

These environments reuse the PR test environment control plane -- the same GCS
command queue and the same Windows build -- but they differ in ways that are easy
to get wrong and expensive to get wrong on production. The tests below pin the
properties that make the production path safe.
"""

import pathlib
import re
import subprocess
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-RockEnvironment.ps1"
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
TASK_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Install-PrEnvironmentCommandQueueTask.ps1"
RENEWAL_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCertificateRenewal.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
ARTIFACT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-artifact.yml"
COMMAND_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "env-deploy-command.yml"
STAGING_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "staging-deploy.yml"
PRODUCTION_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-deploy.yml"

TRUNK_BRANCH = "passion-18.4.1"
STAGING_HOST = "staging.rock-dev.connect.passion.team"


def _block_body(lines, opener_index):
    """Line range [start, end) of the braced block opened at lines[opener_index].

    Brace counting is crude but sufficient for these scripts, and the InPlace
    assertion in the production guard below fails loudly if it ever stops being
    sufficient -- it checks that a line unique to the InPlace branch landed
    outside the range this returns.
    """
    depth = 0
    start = None
    for index in range(opener_index, len(lines)):
        line = lines[index]
        depth += line.count("{") - line.count("}")
        if start is None and "{" in line:
            start = index + 1
        if start is not None and depth <= 0:
            return start, index
    raise AssertionError(f"unbalanced braces after line {opener_index + 1}")


class EnvironmentDeployScriptTests(unittest.TestCase):
    def test_script_supports_both_dedicated_site_and_in_place_modes(self):
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("[ValidateSet('DedicatedSite', 'InPlace')]", text)
        self.assertIn("$EnvironmentName", text)

    def test_shared_asset_overlay_backfills_plugins_for_staging(self):
        """Staging deploys through this script, not Deploy-PrEnvironment.ps1, so the
        overlay default has to carry Plugins here too or staging keeps serving
        "Error Loading Block: Login" as its landing page. RockWeb/Plugins/.gitignore
        is `*/*`, so no plugin subfolder is in git or in the artifact, and the
        overlay is the only mechanism that can supply org_passion/Security."""
        text = DEPLOY_SCRIPT.read_text()

        match = re.search(r"PR_TEST_SHARED_ASSET_DIRECTORIES\)\)\s*\{\s*'([^']+)'\s*\}", text)
        self.assertIsNotNone(match, "could not find the shared asset directory default list")

        directories = [entry.strip() for entry in match.group(1).split(",")]
        self.assertIn("Plugins", directories, f"overlay default must backfill Plugins, got {directories}")
        for existing in ["Themes", "Content", "Assets", "Styles"]:
            self.assertIn(existing, directories, f"overlay default must still carry {existing}")

    def test_shared_asset_overlay_never_runs_against_production(self):
        """This is what makes adding Plugins to the overlay default safe to ship
        without a production window: the overlay is reachable only from the
        DedicatedSite branch, and production deploys InPlace. An InPlace deploy
        copies over a live site that already has its own Plugins tree, maintained
        outside git -- backfilling it from another site is exactly the wrong thing
        to do there.

        Checked by brace nesting, not by text position. The first version of this
        test did `text.index("if ($Mode -eq 'DedicatedSite') {")`, which matches an
        unrelated app-pool naming block near the top of the script rather than the
        deploy branch; it passed even when the overlay was hoisted out of the branch
        and onto the production path, which is the one thing it existed to catch.
        """
        lines = DEPLOY_SCRIPT.read_text().splitlines()

        openers = [
            index for index, line in enumerate(lines)
            if line.strip() == "if ($Mode -eq 'DedicatedSite') {"
        ]
        self.assertTrue(openers, "no DedicatedSite branch found")

        guarded = set()
        for opener in openers:
            start, end = _block_body(lines, opener)
            guarded.update(range(start, end))

        in_place_only = [
            index for index, line in enumerate(lines)
            if line.lstrip().startswith("$backupPath = Join-Path")
        ]
        self.assertTrue(in_place_only, "could not find the InPlace backup line to calibrate against")
        for index in in_place_only:
            self.assertNotIn(
                index, guarded,
                "brace walk is unreliable: it placed the InPlace-only backup line inside a "
                "DedicatedSite branch, so the rest of this test proves nothing",
            )

        overlay = [
            index for index, line in enumerate(lines)
            if line.lstrip().startswith("Sync-SharedSiteAssets")
        ]
        self.assertTrue(overlay, "no Sync-SharedSiteAssets call site found")
        for index in overlay:
            self.assertIn(
                index, guarded,
                f"Sync-SharedSiteAssets at line {index + 1} is not inside a DedicatedSite branch, "
                "so the shared-asset overlay now runs on the InPlace production path",
            )

    def test_plugin_build_artifacts_are_stripped_after_the_overlay(self):
        """The strip runs on the freshly extracted artifact, which was sufficient
        while the overlay could not carry Plugins. Now that it does, the base
        site's Plugins/*/bin and Plugins/*/obj arrive after the strip has already
        run, so a second strip has to follow the overlay.

        The argument is asserted, not just the ordering. A later strip aimed at
        $ExtractPath would satisfy any ordering check while doing nothing at all,
        because Move-Item has already consumed that directory by then.
        """
        lines = DEPLOY_SCRIPT.read_text().splitlines()

        overlay = [
            index for index, line in enumerate(lines)
            if line.lstrip().startswith("Sync-SharedSiteAssets")
        ]
        self.assertTrue(overlay, "no Sync-SharedSiteAssets call site found")

        strips = [
            index for index, line in enumerate(lines)
            if re.match(r"Remove-PluginBuildArtifacts\s+-(?:Site)?Path\s+\$SitePath\b", line.strip())
        ]
        self.assertTrue(
            strips,
            "no Remove-PluginBuildArtifacts call targets $SitePath; stripping $ExtractPath "
            "is a no-op once Move-Item has consumed that directory",
        )
        self.assertTrue(
            any(index > max(overlay) for index in strips),
            f"a $SitePath strip must follow the overlay at line {max(overlay) + 1}; "
            f"found strips at {[index + 1 for index in strips]}",
        )

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

    def test_health_check_recycles_the_app_pool_instead_of_only_retrying(self):
        """ASP.NET caches an Application_Start failure for the lifetime of the app
        domain, so a site that faults its first start after a replace serves that
        same cached exception to every later probe. Retrying alone therefore reads a
        stale failure until the window closes -- which is how the 2026-08-10 staging
        deploy reported unhealthy three times over while serving Rock normally
        minutes later. The probe has to be able to discard the bad domain."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("$RecycleAfterSeconds", text)
        self.assertIn("-AppPoolName $AppPoolName", text)
        health = text.split("function Test-EnvironmentHealth", 1)[1]
        health = health.split("\nfunction ", 1)[0]
        self.assertIn("Stop-EnvironmentAppPool", health)
        self.assertIn("Start-WebAppPool", health)

    def test_health_check_window_outlasts_rock_running_its_migrations(self):
        """First request after a deploy runs EF and plugin migrations; the demo
        environment needed three 30-second timeouts before answering at all. The
        window also has to stay under the queue agent's 1800s command timeout and
        the deploy job's 60-minute limit, or the real ceiling moves to a layer that
        reports 'timed out' with no diagnostics."""
        text = DEPLOY_SCRIPT.read_text()
        match = re.search(r"\$HealthCheckTimeoutSeconds = (\d+)", text)
        self.assertIsNotNone(match, "health check timeout default not found")
        seconds = int(match.group(1))
        self.assertGreaterEqual(seconds, 600)
        self.assertLess(seconds, 1800)

    def test_health_check_forces_a_modern_tls_version(self):
        """PowerShell 5.1 can default ServicePointManager to SSL3/TLS1.0, which a
        hardened IIS refuses. It surfaces as 'the underlying connection was closed',
        which reads like the site is down rather than like the probe is broken."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("SecurityProtocol", text)
        self.assertIn("Tls12", text)

    def test_app_pool_is_stopped_and_drained_before_files_are_replaced(self):
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("Stop-EnvironmentAppPool", text)
        self.assertIn("Get-WebAppPoolState", text)
        self.assertNotIn("Restart-Computer", text)
        self.assertNotIn("iisreset", text.lower())


class CertificateSelectionTests(unittest.TestCase):
    """The deploy script rebinds an SSL certificate on every run, so its choice of
    certificate silently decides whether renewal is durable or pointless."""

    def test_deploy_prefers_a_ca_issued_certificate_over_the_self_signed_placeholder(self):
        """This was a real, long-lived outage of trust. The placeholder is minted for
        two years and a Let's Encrypt certificate lasts ninety days, so ranking
        candidates by NotAfter alone made the placeholder win forever: renewal would
        bind a real certificate and the very next deploy would quietly rebind the
        self-signed one. Measured 2026-08-10 -- pr-4 served a real certificate at
        16:57 UTC and was self-signed again after its 19:44 redeploy. A self-signed
        certificate is its own issuer, which is what the ranking keys on."""
        text = DEPLOY_SCRIPT.read_text()
        selector = text.split("function Get-EnvironmentCertificateThumbprint", 1)[1]
        selector = selector.split("\nfunction ", 1)[0]

        self.assertIn("$_.Issuer -eq $_.Subject", selector)

        issuer_rank = selector.index("$_.Issuer -eq $_.Subject")
        not_after_rank = selector.index("$_.NotAfter }; Descending")
        self.assertLess(
            issuer_rank,
            not_after_rank,
            "issuer trust must be the primary sort key, expiry only the tie-breaker",
        )

    def test_deploy_never_binds_an_already_expired_certificate(self):
        text = DEPLOY_SCRIPT.read_text()
        selector = text.split("function Get-EnvironmentCertificateThumbprint", 1)[1]
        selector = selector.split("\nfunction ", 1)[0]
        self.assertIn("$_.NotAfter -gt (Get-Date)", selector)

    def test_renewal_also_covers_in_place_environments_like_staging(self):
        """In-place environments keep their manifest outside $EnvironmentRoot on
        purpose, so a renewal that walked only that one tree could never see staging
        -- and never did. Renewal already stops W3SVC service-wide for the HTTP-01
        challenge, so those sites were taking the downtime without getting a
        certificate for it."""
        text = RENEWAL_SCRIPT.read_text()
        self.assertIn("$AdditionalManifestRoots", text)
        self.assertIn(r"C:\RockBackups", text)

        discovery = text.split("function Get-DeployedPrEnvironmentManifests", 1)[1]
        discovery = discovery.split("\nfunction ", 1)[0]
        self.assertIn("$AdditionalManifestRoots", discovery)
        # Backup siblings of that manifest are timestamped copies of the site.
        # Recursing into them would bind certificates from stale manifests.
        additional = discovery.split("foreach ($additionalRoot", 1)[1]
        self.assertNotIn("-Recurse", additional)

    def test_renewal_that_finds_nothing_says_so_instead_of_passing_quietly(self):
        """A clean exit over an empty VM is indistinguishable from a successful
        renewal in the command result. That ambiguity is why staging went months
        untrusted while every run reported success."""
        text = RENEWAL_SCRIPT.read_text()
        self.assertIn("RENEWAL ISSUED NOTHING", text)
        self.assertIn("Write-Warning", text)
        # The scope line names the hosts, so a log proves what was actually touched.
        self.assertIn("Renewal scope:", text)


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

    def test_db_name_is_optional_so_an_environment_that_names_no_catalog_is_unchanged(self):
        """Adding this input must not touch the pr-* sites. An unset caller variable
        arrives as the empty string, which is falsy in a GitHub expression, so those
        environments keep the exact behaviour they had before it existed -- which is
        what makes it safe to merge before the staging catalog is provisioned."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        db_name = workflow["on"]["workflow_call"]["inputs"]["db_name"]

        self.assertFalse(db_name["required"])
        self.assertEqual(db_name["default"], "")
        self.assertEqual(db_name["type"], "string")

    def test_connection_string_prefers_the_caller_catalog_over_the_shared_secret(self):
        """Operand order is the whole behaviour here and it is invisible at runtime:
        reversed, every environment silently lands back on the shared sandbox catalog
        while the deploy still reports success."""
        text = COMMAND_WORKFLOW.read_text()

        self.assertIn("inputs.db_name || secrets.DB_NAME", text)
        self.assertNotIn("secrets.DB_NAME || inputs.db_name", text)

    def test_the_catalog_source_is_reported_without_echoing_the_catalog(self):
        """Which catalog an environment landed on is redacted everywhere else, so a
        STAGING_DB_NAME that was never set -- or set under a slightly different name
        -- looks exactly like a healthy deploy. Naming the source is safe; echoing
        secrets.DB_NAME into a public log is not."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = workflow["jobs"]["deploy"]["steps"]
        reporting = [s for s in steps if s.get("name") == "Report which catalog this deploy will use"]

        self.assertEqual(len(reporting), 1)
        step = reporting[0]

        # Production passes write_connection_string: false and has no catalog here,
        # so this step must not run at all on that path.
        self.assertIn("inputs.write_connection_string", str(step["if"]))
        self.assertNotIn("secrets.DB_NAME", step["run"])

        # Read through the environment, not interpolated into the script body: a
        # value containing a quote should not be able to change the shape of the
        # script that reads it. Same reasoning as rebuilding the redaction key by
        # key rather than regex-scrubbing it.
        self.assertIn("$env:DB_NAME_REQUESTED", step["run"])
        self.assertNotIn("${{ inputs.db_name }}", step["run"])

    def test_falling_back_to_the_shared_catalog_is_a_warning_not_a_silent_default(self):
        """One catalog behind N sites is only safe while every live environment sits
        on the same Rock minor version. That condition failed on 2026-08-11 and put
        pr-3 on a permanent 500; a fallback nobody is told about is how it failed."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = workflow["jobs"]["deploy"]["steps"]
        step = next(s for s in steps if s.get("name") == "Report which catalog this deploy will use")

        self.assertIn("::warning::", step["run"])
        self.assertIn("shared sandbox catalog", step["run"])


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

    def test_staging_asks_for_its_own_catalog(self):
        """Open item 7: staging names its own catalog rather than inheriting the
        prod-derived one. Superseded 2026-08-17 in one respect -- the pr-* sites
        now follow staging onto this same catalog instead of being left behind on
        the shared one, so this variable moves the whole fleet, not just staging.
        A repository variable rather than a secret -- a catalog name is not a
        credential, and keeping it visible is what lets the deploy log state which
        database staging used without redacting it."""
        workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())

        self.assertEqual(
            workflow["jobs"]["deploy"]["with"]["db_name"],
            "${{ vars.STAGING_DB_NAME }}",
        )

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

    def test_workflows_that_cannot_change_the_build_do_not_cancel_a_staging_deploy(self):
        """`cancel-in-progress: true` means a needless trigger is not merely a
        wasted 26 minutes -- it kills whatever deploy is in flight. Anything that
        provably cannot change what staging builds belongs in paths-ignore. Both
        entries below run somewhere else entirely: production's orchestration, and
        the deployment test suite on an Ubuntu runner."""
        workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())
        ignored = workflow["on"]["push"]["paths-ignore"]
        for path in [
            ".github/workflows/production-deploy.yml",
            ".github/workflows/deployment-pipeline-tests.yml",
        ]:
            self.assertIn(path, ignored)

        self.assertNotIn(
            ".github/workflows/**", ignored,
            "a blanket workflow ignore would also ignore pr-test-artifact.yml, "
            "which does change the artifact staging is built from",
        )


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


class ProductionVersionGuardTests(unittest.TestCase):
    """Branch names in this repo do not carry the Rock version, and two of them are
    actively misleading: `develop` declares 19.0.3 and `staging` declares 17.6.1
    while the trunk declares 18.4.1. The last production build ran from `develop`,
    so a 19.0 artifact was produced for a site running 18.x; the only reason that
    was not an incident is that nobody installed it. Rock migrates the database on
    the first request after a deploy, so the guard has to read the version out of
    the source rather than trust the ref name."""

    def _guard_step(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        return next(
            s
            for s in workflow["jobs"]["resolve"]["steps"]
            if s.get("name") == "Refuse a ref from a different Rock version"
        )

    def test_the_guard_runs_before_anything_is_built_or_approved(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        step_names = [s.get("name") for s in workflow["jobs"]["resolve"]["steps"]]

        self.assertIn("Refuse a ref from a different Rock version", step_names)
        # `resolve` is what every other job depends on, so failing here costs no
        # build minutes and never reaches a human approver.
        for job in ["build", "approve", "deploy"]:
            self.assertIn("resolve", workflow["jobs"][job]["needs"] if isinstance(
                workflow["jobs"][job].get("needs"), list) else [workflow["jobs"][job]["needs"]])

    def test_the_expected_version_is_read_from_the_default_branch_not_hardcoded(self):
        """A hardcoded version would have to be edited during every Rock upgrade, and
        the upgrade is exactly when nobody is thinking about this file. Reading the
        default branch means promoting the new trunk to default is enough."""
        run = self._guard_step()["run"]

        self.assertIn("github.event.repository.default_branch", run)
        self.assertNotRegex(
            run,
            r'expected_version=["\']?1[0-9]\.[0-9]',
            "the expected Rock version is hardcoded; it must come from the default branch",
        )

    def test_both_version_file_locations_are_consulted_oldest_first(self):
        """Rock 19 deleted `Rock.Version/AssemblySharedInfo.cs` and moved the version
        into `Directory.Build.props`. A guard that knows only one location cannot
        compare an 18.x ref against a v19 default branch, and an unreadable version is
        a hard refusal below -- so a single-location guard would block the very
        upgrade it exists to make safe.

        Order is the substantive part, not style: 18.x ships a `Directory.Build.props`
        too, and it carries no `<Version>`. Probing the historical path first is what
        keeps an 18.x ref answering 18.x."""
        run = self._guard_step()["run"]

        match = re.search(r'VERSION_FILES="([^"]+)"', run)
        self.assertIsNotNone(match, "the guard does not declare its candidate version files")
        self.assertEqual(
            match.group(1).split(),
            ["Rock.Version/AssemblySharedInfo.cs", "Directory.Build.props"],
            "both version locations must be consulted, historical path first",
        )

    def test_a_missing_version_file_on_the_default_branch_is_not_fatal(self):
        """During the upgrade the two sides of the comparison sit on different lines,
        so exactly one of the two candidate paths 404s on the default branch. If that
        404 propagated as a failure the guard would refuse every deploy mid-upgrade."""
        run = self._guard_step()["run"]

        self.assertIn("continue", run)
        # `gh api` writes its own diagnostics to stderr on a 404; letting those
        # through would make a normal, expected probe look like a broken workflow.
        self.assertIn("2>/dev/null", run)

    def test_a_version_mismatch_fails_the_run(self):
        run = self._guard_step()["run"]

        self.assertIn("::error::", run)
        self.assertRegex(run, r"(?m)^\s*exit 1\s*$")
        self.assertIn("acknowledge_version_change", run)

    def test_the_acknowledgement_is_off_by_default(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        ack = workflow["on"]["workflow_dispatch"]["inputs"]["acknowledge_version_change"]

        self.assertFalse(ack["default"])
        self.assertFalse(ack.get("required", False))

    def test_the_guards_own_regex_reads_the_version_and_nothing_else(self):
        """The whole control rests on one sed expression. In the 18.x format
        AssemblyFileVersion, AssemblyInformationalVersion, and the prose comment above
        them all contain the word "version"; in the v19 format `<FileVersion>` and
        `<InformationalVersion>` do too. An over-broad pattern silently reads the wrong
        line and the guard starts comparing garbage."""
        run = self._guard_step()["run"]
        match = re.search(r"""sed -n '([^']+)' "\$1\"""", run)
        self.assertIsNotNone(match, "could not find the version_of sed expression in the guard")
        expression = match.group(1)

        def extract(text):
            result = subprocess.run(
                ["sed", "-n", expression],
                input=text,
                capture_output=True,
                text=True,
                check=True,
            )
            return result.stdout.split()

        # Whichever file THIS checkout declares its version in, so the fixtures below
        # cannot drift from reality. Reading a fixed path would make this test a
        # FileNotFoundError the moment the trunk moves to v19, where the .cs file is
        # gone -- the suite would fail before the guard it checks was even wrong.
        declarations = [
            (REPO_ROOT / "Rock.Version" / "AssemblySharedInfo.cs",
             r'AssemblyVersion\( *"([^"]+)"'),
            (REPO_ROOT / "Directory.Build.props",
             r"<Version>([^<]+)</Version>"),
        ]
        for path, pattern in declarations:
            if not path.exists():
                continue
            text = path.read_text()
            declared = re.search(pattern, text)
            if declared is None:
                continue
            self.assertEqual(
                extract(text),
                [declared.group(1)],
                f"the guard reads a different version out of {path.name} than it declares",
            )
            break
        else:
            self.fail(
                "no file in this checkout declares a Rock version; the guard has "
                "nothing to read and every production deploy would be refused"
            )

        # The 18.x format.
        for version, informational in [("19.0.3", "19.0"), ("17.6.1", "17.6")]:
            fixture = (
                "// The AssemblyVersion number should change only when we are\n"
                "// shipping a new major or minor release.\n"
                f'[assembly: AssemblyVersion( "{version}" )]\n'
                f'[assembly: AssemblyFileVersion( "{version}" )]\n'
                f'[assembly: AssemblyInformationalVersion( "Rock McKinley {informational}" )]\n'
            )
            self.assertEqual(
                extract(fixture),
                [version],
                f"expected exactly one match for {version}; the pattern is over-broad",
            )

        # The v19 format. `<FileVersion>` is a real line in Rock 19's props file and
        # is the most likely thing an over-broad `<Version>` pattern would swallow.
        for version, informational in [("19.3.4", "Rock McKinley 19.3"), ("19.0.3", "Rock McKinley 19.0")]:
            fixture = (
                "  <!-- Versioning information -->\n"
                "  <PropertyGroup>\n"
                f"    <Version>{version}</Version>\n"
                f"    <InformationalVersion>{informational}</InformationalVersion>\n"
                "    <FileVersion>$(Version)</FileVersion>\n"
                "  </PropertyGroup>\n"
            )
            self.assertEqual(
                extract(fixture),
                [version],
                f"expected exactly one match for {version}; the pattern is over-broad",
            )


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
