"""Tests for the long-lived environment (staging / production) deploy path.

These environments reuse the PR test environment control plane -- the same GCS
command queue and the same Windows build -- but they differ in ways that are easy
to get wrong and expensive to get wrong on production. The tests below pin the
properties that make the production path safe.
"""

import collections
import re
import subprocess
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-RockEnvironment.ps1"
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
TASK_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Install-PrEnvironmentCommandQueueTask.ps1"
RENEWAL_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCertificateRenewal.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
ARTIFACT_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-artifact.yml"
COMMAND_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "env-deploy-command.yml"
STAGING_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "staging-deploy.yml"
PRODUCTION_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-deploy.yml"

TRUNK_BRANCH = "passion-19.3.4"
STAGING_HOST = "staging.connect.passion.team"


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

    def test_shared_asset_overlay_backfills_bin_for_staging(self):
        """Plugin source without plugin assemblies is not a working site. The
        namespaces the .ascx.cs files reference are defined in DLLs that live only
        in the base site's bin -- not in git, not in the artifact -- so a deploy
        that backfills Plugins but not bin fails to compile them with

            error CS0103: The name 'rocks' does not exist in the current context

        Worse than the blocks, it takes out file storage. Every BinaryFileType on
        this catalog stores through
        rocks.pillars.AmazonStorageProvider.S3BlobStorage, and Rock 19 ships no
        core S3 provider to fall back to, so a missing assembly means the provider
        cannot load and GetImage.ashx answers 404 for every image on the site.

        Distinguishing that from missing data is worth keeping written down:
        GetImage.ashx sets Last-Modified and ETag after the metadata lookup but
        before the content lookup, so a 404 that still carries those headers means
        the row was found and only the bytes were missing.
        """
        text = DEPLOY_SCRIPT.read_text()

        match = re.search(r"PR_TEST_SHARED_ASSET_DIRECTORIES\)\)\s*\{\s*'([^']+)'\s*\}", text)
        self.assertIsNotNone(match, "could not find the shared asset directory default list")

        directories = [entry.strip() for entry in match.group(1).split(",")]
        self.assertIn("bin", directories, f"overlay default must backfill bin, got {directories}")

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

    def test_dedicated_site_grants_the_app_pool_write_access(self):
        """Rock compiles its legacy LESS themes to .css on a background thread at
        every application start, so the app pool identity needs write access to the
        site directory. A DedicatedSite deploy expands a fresh tree, which inherits
        only the parent's ACLs and leaves that identity read-only; InPlace copies
        over a directory that already has the right ACEs, which is the only reason
        production was never affected.

        Losing the grant fails almost silently, which is why it went unnoticed from
        January to August 2026. RockTheme.Compile dies on the first file with
        UnauthorizedAccessException and abandons the theme's whole loop before
        reaching theme.css; the exception reaches ExceptionLog and nowhere else, and
        the stale .css keeps being served with a 200. Every health check passes while
        every theme silently rots -- so no other test in this suite can catch it, and
        nothing on the deploy path will either. That is what this one is for.
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

        grants = [
            index for index, line in enumerate(lines)
            if "icacls" in line and "/grant" in line
        ]
        self.assertTrue(
            grants,
            "the DedicatedSite deploy no longer grants the app pool modify rights on the "
            "site directory, so Rock cannot compile its themes and will serve stale .css "
            "while every health check passes",
        )
        for index in grants:
            self.assertIn(
                index, guarded,
                f"the icacls grant at line {index + 1} is not inside a DedicatedSite branch; "
                "it must not run on the InPlace production path",
            )
            grant = lines[index]
            # (OI)(CI) so NTFS propagates to existing children and to whatever the
            # preserved-file restore and the shared-asset overlay write afterwards;
            # (M) because compiling a theme rewrites files rather than only adding them.
            self.assertIn("(OI)(CI)(M)", grant)
            self.assertIn("$SitePath", grant)

            # The identity is assembled a line or two above rather than inlined, so
            # widen to the surrounding lines instead of matching the grant alone.
            window = "\n".join(lines[max(0, index - 4):index + 6])
            self.assertIn(
                "IIS AppPool", window,
                "the grant no longer names the app pool identity, so whatever it grants "
                "rights to is not the account Rock compiles its themes under",
            )
            # A grant that fails and says nothing is the same outcome as no grant at all.
            self.assertIn("$LASTEXITCODE", window)
            self.assertIn("throw", window)

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
        # Where the manifest actually lands moved into Resolve-DeploymentTarget and
        # is checked by running it: Pester/DeploymentTarget.Tests.ps1, "puts the
        # manifest beside the site it describes".
        self.assertIn('status = "deployed"', text)
        self.assertIn("hostName = $HostName", text)
        self.assertIn("siteName = $SiteName", text)

    # The production manifest staying out of the certificate renewal job's search
    # path used to be asserted here, as a string match on the assignment. That
    # decision now lives in Resolve-DeploymentTarget, and
    # Pester/DeploymentTarget.Tests.ps1 checks it by calling the function and
    # looking at the path that comes back -- "keeps the manifest out of the
    # environment root" and "puts the manifest under the backup root instead".
    # Reading the line proved it was written. Running it proves it is true.

    def test_no_caller_pairs_a_dedicated_site_with_an_in_place_target(self):
        """Resolve-DeploymentTarget now throws on that pair rather than dropping it,
        which turns a silent mis-deploy into a loud refusal. That is the right
        trade for a hand-dispatched run, and the wrong one to discover on a
        scheduled staging deploy -- so the two callers that exist are checked here
        instead."""
        in_place_only = ("target_site_path", "target_site_name")
        checked = 0

        # `workflow_path`, not `workflow`: in this suite `harness.workflow(...)` is a
        # parsed dictionary, and one name for two kinds of thing is how a `.get()`
        # ends up on a Path.
        for workflow_path in (STAGING_WORKFLOW, PRODUCTION_WORKFLOW):
            parsed = yaml.safe_load(workflow_path.read_text())
            for name, job in parsed["jobs"].items():
                if "env-deploy-command.yml" not in (job.get("uses") or ""):
                    continue

                checked += 1
                passed = job.get("with") or {}
                mode = passed.get("mode")
                self.assertIn(mode, ("DedicatedSite", "InPlace"), f"{workflow_path.name}:{name} passes mode {mode!r}.")

                if mode == "InPlace":
                    continue

                for parameter in in_place_only:
                    self.assertNotIn(
                        parameter,
                        passed,
                        f"{workflow_path.name}:{name} deploys DedicatedSite but passes "
                        f"{parameter}. The deploy script rejects that pair, so this "
                        f"run would fail before it copied anything.",
                    )

        self.assertEqual(2, checked, f"Expected the staging and production callers; found {checked}.")

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
        which reads like the site is down rather than like the probe is broken.

        This test used to be `assertIn("SecurityProtocol", text)` against the whole
        918-line script, which could not fail: the token also appears in the
        comment explaining why the line is there, so deleting both real sites left
        it green. TLS is set at two independent probe paths and both need it --
        `Invoke-SiteProbe` is what the deploy polls with, `Test-EnvironmentHealth`
        is what decides the deploy succeeded -- so name both.
        """
        text = DEPLOY_SCRIPT.read_text()

        for function_name in ("Invoke-SiteProbe", "Test-EnvironmentHealth"):
            body = harness.powershell_function(text, function_name)
            self.assertIn(
                "[Net.ServicePointManager]::SecurityProtocol",
                body,
                f"{function_name} no longer sets SecurityProtocol, so on a hardened "
                "IIS its probe fails with a message that reads like the site is down",
            )
            self.assertIn("Tls12", body, f"{function_name} sets SecurityProtocol to something other than Tls12")

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
    def queue_step(self):
        """The step that puts the deploy-environment command on the VM queue.

        Found by the action it calls rather than by name, so renaming the step
        does not quietly turn the assertions below into a check of nothing.
        """
        parsed = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = [
            step
            for job in (parsed.get("jobs") or {}).values()
            for step in (job.get("steps") or [])
            if (step.get("uses") or "") == "./.github/actions/queue-vm-command"
        ]
        self.assertEqual(
            1, len(steps), "expected exactly one queue step in the deploy command workflow"
        )
        return steps[0]

    def test_command_workflow_fails_fast_when_the_artifact_is_missing(self):
        text = COMMAND_WORKFLOW.read_text()
        self.assertIn("gsutil -q stat", text)
        self.assertIn("::error::Artifact not found", text)

    # test_timeout_message_names_the_actual_cause moved to
    # test_local_composite_actions.py. This workflow was the only one of six that
    # carried that message, which is the argument the shared wait was built on --
    # asserting it here would have gone on passing while the other five stayed
    # wrong.

    def test_connection_string_travels_as_a_secret_rather_than_in_the_payload(self):
        """The repo is public and these logs get screenshotted in training.

        The redaction itself is `.github/actions/queue-vm-command`, executed by
        Tests/PrTestEnvironments/Pester/QueueCommand.Tests.ps1 and wired up in
        test_local_composite_actions.py. What is this workflow's own decision is
        which channel the connection string travels on: `secret-value` keeps it
        out of the interpolated JSON payload, where a password containing a quote
        would break the JSON and be written into the expanded workflow text.
        """
        step = self.queue_step()
        supplied = step.get("with") or {}

        self.assertIn("CONNECTION_STRING", str(supplied.get("secret-value") or ""))
        self.assertNotIn("CONNECTION_STRING", str(supplied.get("payload") or ""))

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


class DeployScriptDriftTests(unittest.TestCase):
    """The deploy scripts the VM runs are not the ones in the repository.

    `Sync-DeploymentScripts` refreshes C:\\RockDeploy from the bootstrap prefix on
    every queue poll, and the only publisher to that prefix is
    pr-test-bootstrap-command-queue.yml, which is workflow_dispatch-only. So a fix
    merged to Deployment/PrTestEnvironments/** changes nothing on the VM until
    somebody dispatches a bootstrap -- and every deploy in between runs the old
    script and reports success, because the code that would have done the work was
    never there. That is open item 25.
    """

    def _drift_step(self):
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = workflow["jobs"]["deploy"]["steps"]
        matching = [s for s in steps if s.get("name") == "Report deploy script drift"]
        self.assertEqual(len(matching), 1)
        return matching[0]

    def test_the_deploy_compares_the_published_scripts_against_this_commit(self):
        step = self._drift_step()

        self.assertIn("Deployment/PrTestEnvironments", step["run"])
        self.assertIn("::warning::", step["run"])

    def test_it_compares_against_the_prefix_the_bootstrap_actually_publishes_to(self):
        """The coupling this test exists for: the drift check reads one GCS prefix
        and the bootstrap writes another, and nothing at runtime would notice them
        diverging -- the check would just report 'in sync' forever against an empty
        prefix. Renaming the prefix in one file has to fail here."""
        prefix = "pr-environments/bootstrap/latest"

        self.assertIn(prefix, self._drift_step()["run"])
        self.assertIn(prefix, BOOTSTRAP_WORKFLOW.read_text())

    def test_the_working_tree_it_compares_against_is_actually_checked_out(self):
        """This job has no working tree of its own -- it authenticates, queues a
        command and waits. Comparing against Deployment/PrTestEnvironments without
        checking it out first reads an empty directory, which reports 'in sync' and
        is worse than not checking at all."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = workflow["jobs"]["deploy"]["steps"]

        names = [s.get("name") for s in steps]
        checkout = next(
            index for index, step in enumerate(steps)
            if str(step.get("uses", "")).startswith("actions/checkout")
            and "Deployment/PrTestEnvironments" in str(step.get("with", {}).get("sparse-checkout", ""))
        )

        self.assertLess(checkout, names.index("Report deploy script drift"))

    def test_the_warning_arrives_before_the_command_is_queued(self):
        """A warning printed after the deploy has already run is a post-mortem. The
        point is to see it while the deploy can still be abandoned."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        names = [s.get("name") for s in workflow["jobs"]["deploy"]["steps"]]

        self.assertLess(
            names.index("Report deploy script drift"),
            names.index("Queue deploy-environment command"),
        )

    def test_it_covers_every_directory_the_bootstrap_publishes_from(self):
        """Derived from the bootstrap rather than listed here, because a hard-coded
        list is how the check silently stops covering things. The publish step is a
        glob over N directories; on 2026-08-19 it was two, and a drift check that
        knew about one of them would have reported "in sync" while the other was
        stale. Add a third directory to the publish line and this fails until the
        comparison and its checkout follow."""
        published_from = re.findall(
            r"(Deployment/[A-Za-z]+)/\*\.ps1",
            BOOTSTRAP_WORKFLOW.read_text(),
        )
        self.assertGreater(len(set(published_from)), 0)

        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = workflow["jobs"]["deploy"]["steps"]
        drift = next(s for s in steps if s.get("name") == "Report deploy script drift")
        checkout = next(
            s for s in steps
            if str(s.get("uses", "")).startswith("actions/checkout")
            and "Deployment/" in str((s.get("with") or {}).get("sparse-checkout", ""))
        )

        for directory in sorted(set(published_from)):
            with self.subTest(directory=directory):
                self.assertIn(directory, drift["run"])
                self.assertIn(directory, checkout["with"]["sparse-checkout"])

    def test_no_two_published_directories_hold_the_same_script_name(self):
        """The publish step globs N directories into one flat GCS prefix, so a
        basename is the whole identity of a script once it lands on the VM. Two
        directories holding the same name means whichever copies last wins,
        silently, and the drift check then compares both local copies against that
        one file and reports the loser as drifted forever. Cheaper to forbid the
        collision than to teach the flat prefix about directories."""
        published_from = sorted(set(re.findall(
            r"(Deployment/[A-Za-z]+)/\*\.ps1",
            BOOTSTRAP_WORKFLOW.read_text(),
        )))

        owners = collections.defaultdict(list)
        for directory in published_from:
            for script in (REPO_ROOT / directory).glob("*.ps1"):
                owners[script.name].append(directory)

        collisions = {name: dirs for name, dirs in owners.items() if len(dirs) > 1}

        self.assertEqual(
            collisions,
            {},
            "these script names exist in more than one published directory and "
            "would overwrite each other on the VM",
        )

    def test_an_empty_local_directory_is_not_reported_as_in_sync(self):
        """The comparison walks the checkout. If the checkout silently produced
        nothing, a naive loop reports zero differences -- "in sync" -- which is the
        precise failure this check exists to catch, now with a green tick on it."""
        run = self._drift_step()["run"]

        self.assertIn("$localScripts.Count -eq 0", run)
        self.assertIn("could not check", run)

    def test_the_check_cannot_break_a_deploy_it_is_only_observing(self):
        """Structural rather than incidental. Warning-only holds today because the
        script happens to be correct; continue-on-error holds it when the script is
        not, or when gsutil has a bad afternoon. A diagnostic that can fail a
        production deploy gets deleted the first time it does."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        steps = workflow["jobs"]["deploy"]["steps"]
        step = next(s for s in steps if s.get("name") == "Report deploy script drift")

        self.assertTrue(step.get("continue-on-error"))

    def test_drift_warns_and_does_not_fail_the_deploy(self):
        """Deliberate, and the reason this is option 2 of open item 25 rather than
        option 3: failing closed would block every deploy from the moment a script
        is merged until somebody dispatches a bootstrap, including the deploys that
        have nothing to do with the changed script. Failing closed is a separate
        decision with an operational cost, not a free upgrade to this one."""
        step = self._drift_step()

        self.assertNotIn("exit 1", step["run"])
        self.assertNotIn("::error::", step["run"])


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
        prod-derived one. This variable moves staging and nothing else -- the pr-*
        fleet reads vars.PR_TEST_DB_NAME, split out on 2026-08-18 after reading this
        one meant staging could not change minor without dragging every pr-* site
        along. A repository variable rather than a secret -- a catalog name is not a
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
        default branch means promoting the new trunk to default is enough.

        Look in the step as a whole, not only its `run:`. The expansion moved into
        `env:` so that operator-typed input in the same script stops being pasted in
        as source (see test_workflow_input_injection.py); the guard still reads the
        default branch, it just reads it a line higher up."""
        step = self._guard_step()

        self.assertIn(
            "github.event.repository.default_branch",
            str(step.get("env", {})) + step["run"],
            "the version guard no longer reads the trunk from the repository, so it "
            "would compare against whatever branch name was hardcoded when it was written",
        )
        self.assertNotRegex(
            step["run"],
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


class DeployAuditTrailTests(unittest.TestCase):
    """A production deploy has to leave evidence of what it did.

    The log the agent uploads for a deploy is the only durable record: the VM is
    unattended, the scheduled task redirects nothing, and the GitHub run prints
    whatever that object contains and nothing else. Every deploy-staging-* object
    in the bucket is 435 bytes -- the eight-line header and nothing after it. That
    is not a truncation bug. The script simply does not say anything between
    printing its header and printing that it finished.

    On staging that is an annoyance. On production it means a deploy that copied
    nothing, a deploy that copied everything, and a deploy that copied half a
    webroot before the app pool came back all produce the same log, and the only
    way to tell them apart afterwards is to go and look at the box.

    These tests do not ask for verbose logging. They ask for the four facts an
    operator needs at 2am: when each step happened, whether the copy moved any
    files, where the backup went, and what the site said at the end.
    """

    def setUp(self):
        self.text = DEPLOY_SCRIPT.read_text()
        self.lines = self.text.splitlines()

    def test_the_script_has_a_timestamped_step_reporter(self):
        """Plain Write-Host lines cannot be placed in time. Two deploys, one of
        which spent nine minutes in robocopy, are indistinguishable without a
        clock on each line."""
        self.assertIn(
            "function Write-DeployStep",
            self.text,
            "the deploy has no timestamped step reporter, so its log cannot be "
            "read as a timeline",
        )

    def test_the_step_reporter_stamps_utc_iso_8601(self):
        """The runner, the VM and whoever is reading are rarely in one timezone,
        and a log correlated against a Cloud SQL restore point has to be UTC."""
        start = self.text.index("function Write-DeployStep")
        body = self.text[start : self.text.index("\n}", start)]

        self.assertIn(
            "ToUniversalTime()",
            body,
            "the step reporter stamps local time, which cannot be lined up against "
            "GCS object timestamps or a Cloud SQL restore point",
        )
        self.assertIn(
            '"s"',
            body,
            'the step reporter does not format as ISO 8601 (ToString("s"))',
        )

    def test_the_step_reporter_is_defined_before_the_deploy_body(self):
        """test_function_definition_order.py holds the general rule. This one is
        specific: a reporter defined after its first call takes down every deploy,
        which is a worse failure than the missing log it was added to fix."""
        definition = self.text.index("function Write-DeployStep")
        calls = [
            self.text.index(line)
            for line in self.lines
            if "Write-DeployStep" in line and "function" not in line
        ]
        self.assertTrue(calls, "Write-DeployStep is defined but never called")
        self.assertLess(
            definition,
            min(calls),
            "Write-DeployStep is called before it is defined",
        )

    def test_the_in_place_copy_reports_what_it_moved(self):
        """/NJS suppresses robocopy's job summary -- the count of files copied, the
        bytes, and the error tally. With it set, a copy that moved 12,000 files and
        a copy that moved none produce identical output, and the deploy reports
        success either way because the exit code is 0 in both cases.

        /NFL and /NDL stay. Nobody needs a filename per file; they need the total.

        Scoped to the in-place copies -- the backup and the deploy -- because those
        are the two production runs. Sync-SharedSiteAssets is reached only from the
        DedicatedSite branch, and it shares its wording with Deploy-PrEnvironment.ps1,
        so it is left alone rather than edited for a path it does not serve."""
        robocopy_lines = [
            line
            for line in self.lines
            if line.lstrip().startswith("& robocopy") and "$SitePath" in line
        ]
        self.assertEqual(
            len(robocopy_lines),
            2,
            "expected the backup copy and the deploy copy; the in-place path moved",
        )
        for line in robocopy_lines:
            with self.subTest(line=line.strip()[:60]):
                self.assertNotIn(
                    "/NJS",
                    line,
                    "robocopy is told to suppress its job summary, so the log cannot "
                    "show whether the copy moved anything",
                )

    def test_a_successful_deploy_ends_with_the_rollback_path(self):
        """The backup path is printed once, before the copy, and then buried under
        everything the deploy prints afterwards. Rolling back is the one thing
        somebody does in a hurry, and the path has to be at the end of the log
        where they are already looking."""
        deployed = next(
            index
            for index, line in enumerate(self.lines)
            if "Deployed $EnvironmentName" in line
        )

        # Reported, not thrown. The unhealthy path already names $backupPath in its
        # throw, and matching that would let this pass on exactly the deploy that
        # succeeded and told nobody where the backup went.
        reported = [
            line
            for line in self.lines[deployed:]
            if "$backupPath" in line and "throw" not in line and not line.lstrip().startswith("#")
        ]
        self.assertTrue(
            reported,
            "a successful deploy never repeats where the backup went, so a rollback "
            "starts by scrolling",
        )

    def test_the_health_check_reports_through_the_step_reporter(self):
        """Every line Test-EnvironmentHealth emits has to carry a timestamp, and
        that includes the line for a pass. A production health check that says
        nothing on success leaves no record of what the site returned, which is
        the one detail worth having when the next deploy is argued about."""
        # Inside the function, not merely somewhere after it. Every call in the
        # deploy body sits after this definition, so a search from here to the end
        # of the file finds them whether or not the health check reports anything.
        start = self.text.index("function Test-EnvironmentHealth")
        # To the closing brace at column 0. This is the last function in the file,
        # so slicing to the next `function` keyword runs off the end.
        body = self.text[start : self.text.index("\n}\n", start)]

        self.assertIn(
            "Write-DeployStep",
            body,
            "the health check does not report through the step reporter, so its "
            "timings are missing from the timeline",
        )
        # The pass branch specifically, not just the function as a whole. Every
        # failed attempt reports from the bottom of the loop; a first-attempt pass
        # returns before reaching any of that, so success is the path that would
        # silently stop reporting without anything else in this test noticing.
        pass_branch = body[body.index("if ($probe.Ok)") : body.index("return $true")]
        self.assertIn(
            "Write-DeployStep",
            pass_branch,
            "the health check returns success without reporting it, so a deploy "
            "that passed first time records nothing about what the site returned",
        )

        self.assertNotIn(
            "Write-Host",
            body,
            "the health check still logs through Write-Host, so its lines have no "
            "timestamp while the rest of the deploy does",
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
