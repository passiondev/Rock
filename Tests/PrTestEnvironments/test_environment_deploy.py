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

TRUNK_BRANCH = "passion-19.4.4"
STAGING_HOST = "staging.connect.passion.team"


def _enclosing_opener(lines, index):
    """Index of the line opening the innermost block containing lines[index].

    Walks upwards counting braces, so the answer is the `if`/`else`/`foreach` the
    line actually sits inside rather than the nearest one that happens to be
    above it. Returns None when the line is at the top level of the script.
    """
    depth = 0
    for candidate in range(index - 1, -1, -1):
        line = lines[candidate]
        depth += line.count("}") - line.count("{")
        if depth < 0:
            return candidate
    return None


def _chained_if(lines, opener):
    """Index of the `if` that lines[opener] chains from, or opener itself.

    `else {` carries no condition of its own, so a caller asking what a block
    branches on has to follow the chain back to the `if` that opened it.
    """
    text = lines[opener].strip()
    if not (text.startswith("else") or text.startswith("} else") or text.startswith("elseif")):
        return opener

    depth = 0
    start = opener if text.startswith("}") else opener - 1
    for candidate in range(start, -1, -1):
        line = lines[candidate]
        depth += line.count("}") - line.count("{")
        if depth == 0 and "{" in line:
            return _chained_if(lines, candidate)
    raise AssertionError(f"could not find the `if` that line {opener + 1} chains from")


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

    def test_font_awesome_is_a_server_owned_path(self):
        """Passion holds a Font Awesome Pro licence and the Pro webfonts sit on the
        servers. Upstream Rock ships the Free fonts under the same filenames, so the
        artifact always carries a Free fa-solid-900.woff2 (78 KB against Pro's
        137 KB) and a Free fa-regular-400.woff2 (13 KB against Pro's 169 KB). Free
        covers roughly 1,600 glyphs where Pro covers more than 16,000, so whenever
        the artifact's copy wins, every Pro-only icon renders as an empty box.

        Committing the Pro fonts instead is not available: this repository is a
        public fork of SparkDevNetwork/Rock, and pushing licensed commercial font
        binaries to it would breach the licence and could not be taken back.
        """
        text = DEPLOY_SCRIPT.read_text()

        match = re.search(r"\$ServerOwnedDirectories\s*=\s*@\(([^)]*)\)", text)
        self.assertIsNotNone(match, "could not find the $ServerOwnedDirectories list")

        paths = re.findall(r"'([^']+)'", match.group(1))
        self.assertIn(
            "Assets/Fonts/FontAwesome", paths,
            f"the Font Awesome directory must be server-owned, got {paths}",
        )

    def test_server_owned_copy_is_allowed_to_overwrite(self):
        """The one flag difference that makes this function do anything. Carrying
        /XC /XN /XO across from Sync-SharedSiteAssets would make the second pass an
        exact repeat of the first: same source, same destination, same skip.

        /MIR and /PURGE stay out for the reason they stay out everywhere else here.
        The base site is authoritative for the files it has, not for the absence of
        files it does not have, so a weight the artifact ships and the box lacks
        must survive.
        """
        body = harness.powershell_function(DEPLOY_SCRIPT.read_text(), "Sync-ServerOwnedAssets")

        copy = re.search(r"&\s*robocopy[^\r\n]*", body)
        self.assertIsNotNone(copy, "Sync-ServerOwnedAssets does not call robocopy")
        flags = copy.group(0)

        for excluded in ("/XC", "/XN", "/XO"):
            self.assertNotIn(
                excluded, flags,
                f"{excluded} makes this pass skip files that already exist, which is every "
                f"file it exists to replace: {flags}",
            )
        for destructive in ("/MIR", "/PURGE"):
            self.assertNotIn(
                destructive, flags,
                f"{destructive} would delete artifact-shipped files the base site lacks: {flags}",
            )

    def test_theme_override_files_are_kept_by_both_modes(self):
        """Everything this organisation has changed about a legacy LESS theme is in
        _variable-overrides.less and _css-overrides.less. Production's copies carry
        the brand palette and the Pro Font Awesome wiring; upstream ships an empty
        pair under the same names.

        Both modes lose them without help, in opposite directions. InPlace robocopies
        the artifact over the site and overwrites production's pair at the moment of
        the v19 cutover. DedicatedSite runs the overlay with /XC /XN /XO, which skips
        production's pair because the artifact has already put a file there -- which
        is why staging renders in stock Rock blue while production renders in #00b8e4.

        This also decides whether the Font Awesome exclusion works at all. Restoring
        the Pro .woff2 files is half the job: the compiled CSS only asks for the Pro
        faces because _variable-overrides.less sets @fa-edition and calls
        .fa-font-face for the regular and light weights.
        """
        text = DEPLOY_SCRIPT.read_text()

        match = re.search(r"\$ServerOwnedThemeFiles\s*=\s*@\(([^)]*)\)", text)
        self.assertIsNotNone(match, "could not find the $ServerOwnedThemeFiles list")
        declared = set(re.findall(r"'([^']+)'", match.group(1)))
        self.assertEqual(
            declared,
            {"_variable-overrides.less", "_css-overrides.less"},
            "the two files Rock reserves for per-organisation theme customization",
        )

        # Both files exist in the repository, so a rename upstream is caught here
        # rather than by a staging deploy that silently keeps nothing.
        for name in sorted(declared):
            self.assertTrue(
                (REPO_ROOT / "RockWeb" / "Themes" / "Rock" / "Styles" / name).is_file(),
                f"RockWeb/Themes/Rock/Styles/{name} does not exist, so nothing in the "
                "artifact has that name and the exclusion protects nothing",
            )

    def test_in_place_deploy_is_a_dry_run_unless_apply_is_passed(self):
        """A production overwrite should never be one mistyped argument away. The
        script reports its plan and returns unless -Apply is explicitly given."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("$Apply", text)
        self.assertIn("if ($Mode -eq 'InPlace' -and -not $Apply)", text)
        self.assertIn("DRY RUN", text)

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

    def test_the_preserved_directory_list_says_it_only_binds_in_place(self):
        """The list reads like a promise the whole script keeps, and it is not.

        InPlace hands it to robocopy as /XD exclusions and the directories survive.
        DedicatedSite deletes $SitePath outright and moves the artifact in, so the
        same four directories are destroyed on every staging and pr-* deploy. Only
        $PreservedFiles crosses that replace, by hand.

        The asymmetry is fine -- blobs are in S3 and App_Data is a rebuildable
        cache -- but it has to be written down. Somebody reading the declaration and
        no further will assume staging keeps its Logs, and reach for a deploy to
        reproduce a fault that the deploy has already erased the evidence of.
        """
        text = DEPLOY_SCRIPT.read_text()
        lines = text.splitlines()

        declaration = next(
            (index for index, line in enumerate(lines) if line.startswith("$PreservedDirectories = @(")),
            None,
        )
        self.assertIsNotNone(declaration, "$PreservedDirectories is no longer declared at column 0")

        # The comment block immediately above the declaration, walked upwards.
        start = declaration
        while start > 0 and lines[start - 1].startswith("#"):
            start -= 1
        comment = "\n".join(lines[start:declaration])

        self.assertIn(
            "DedicatedSite",
            comment,
            "the $PreservedDirectories comment never mentions the branch that ignores it",
        )
        self.assertIn(
            "$PreservedFiles",
            comment,
            "the comment does not say which list does survive a DedicatedSite replace",
        )
        # "Logs" alone would be a vacuous check -- the first paragraph already says
        # "Logs are forensic evidence" and said so before any of this was written.
        # S3 is the claim that is actually load-bearing and actually new: it is the
        # reason losing Content and Uploads on a dedicated site is survivable, and
        # without it the paragraph is an unexplained assertion that this is fine.
        self.assertIn(
            "S3",
            comment,
            "the comment says the asymmetry is acceptable without saying why -- name where "
            "the binary files actually live",
        )

    def test_the_dry_run_promises_preservation_only_where_it_runs(self):
        """A dry run exists so a human can read the plan and decide. On DedicatedSite
        the unconditional line "Would preserve directories: Content, App_Data, Logs,
        Uploads" once told that human the exact reverse of what the apply run does.

        The dry run only ever runs InPlace, so the DedicatedSite arm that answered it
        -- "would NOT survive" -- could never run and has gone. What is left to hold
        here is the guard: a change that lifted the promise out of the InPlace block,
        or wrote it for both modes, would bring the reversed plan back.

        The plan is now printed by Write-InPlaceOverlayPlan, and what it prints is
        asked of the function itself: DeployBranch.Tests.ps1 runs it against a real
        overlay plan and compares the report line for line. What Pester cannot run is
        the script body, which decides when the function is called, so that is what
        this holds. The promise is made only inside that function; the function is
        called once, under the InPlace guard and not from an else arm; and a return
        follows the call in the same block. Without that return a dry run prints its
        plan and then goes on to deploy, and nothing held it before the lift either.
        """
        text = DEPLOY_SCRIPT.read_text()
        # Comments blanked, line numbers kept. The script body explains the call in
        # a comment that names the function, and that is not a second call.
        lines = harness.strip_powershell_comments(text).splitlines()
        message = "Would preserve directories:"
        printer = "Write-InPlaceOverlayPlan"
        body_start, body_end = harness.powershell_function_lines(text, printer)

        occurrences = [index for index, line in enumerate(lines) if message in line]
        self.assertTrue(occurrences, f'the dry run no longer says "{message}" at all')
        for index in occurrences:
            self.assertTrue(
                body_start <= index < body_end,
                f'"{message}" at line {index + 1} is outside {printer}, so it is printed '
                "by code this test does not know is guarded",
            )

        calls = [
            index
            for index, line in enumerate(lines)
            if re.search(rf"\b{printer}\b", line) and not line.lstrip().startswith("function ")
        ]
        self.assertEqual(
            1,
            len(calls),
            f"{printer} is called at lines {[index + 1 for index in calls]}; the dry run "
            "should print its plan from exactly one place",
        )
        call = calls[0]

        # Walk out to the innermost block containing the call and read the mode off
        # its condition. A call moved to the top level has no opener; one moved into
        # an else arm runs for whatever the condition rejects.
        opener = _enclosing_opener(lines, call)
        self.assertIsNotNone(
            opener,
            f"{printer} at line {call + 1} sits at the top level of the script, where "
            "no branch can be guarding it",
        )
        self.assertEqual(
            opener,
            _chained_if(lines, opener),
            f"{printer} at line {call + 1} is called from an else arm, so it runs for "
            "the case its condition rejects",
        )
        condition = lines[opener]
        self.assertRegex(
            condition,
            r"\$Mode\s+-eq\s+'InPlace'",
            f"{printer} at line {call + 1} is inside `{condition.strip()}`, which does "
            "not select InPlace -- so the plan is printed for the mode that keeps none of it",
        )
        self.assertRegex(
            condition,
            r"-not\s+\$Apply",
            f"{printer} at line {call + 1} is inside `{condition.strip()}`, which does "
            "not exclude -Apply -- so the plan is printed on a run that deploys",
        )

        following = next(
            (index for index in range(call + 1, len(lines)) if lines[index].strip() == "return"),
            None,
        )
        self.assertIsNotNone(following, f"nothing returns after {printer} at line {call + 1}")
        self.assertEqual(
            opener,
            _enclosing_opener(lines, following),
            f"the first return after {printer} (line {following + 1}) is not in the "
            f"block that calls it (line {opener + 1}), so a dry run goes on to deploy",
        )

    def test_production_connection_string_on_disk_is_left_alone_when_none_supplied(self):
        """CI has no production database credentials by design. With no connection
        string in the command, the deploy must keep the file already on the box
        rather than writing an empty one and taking the site down."""
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("if (![string]::IsNullOrWhiteSpace($Connection))", text)
        self.assertIn("leaving the existing web.ConnectionStrings.config in place", text)

    # Staging's manifest landing where certificate renewal finds it used to be
    # asserted here, as string matches on the deploy script's root default and on
    # three lines of its manifest hashtable. Pester/ManifestContract.Tests.ps1
    # now writes staging's manifest with the deploy's own writer, at the deploy's
    # own default root, and hands it to renewal's own reader -- "renews staging,
    # which is deployed as its own site". The strings said the fields were spelled
    # somewhere; the suite says renewal reads what the deploy wrote.

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
        that is about to throw a yellow screen.

        What Test-EnvironmentHealth does with a sick site -- poll, recycle the
        pool, give up -- is Pester/DeployVerification.Tests.ps1's job, and it
        runs the function to find out. What is left here is the wiring, which no
        Pester suite reaches because it is the script body: the deploy hands the
        check the window, the host and the pool it was configured with, and a
        failed check ends in a throw instead of a warning the run carries on
        past. This used to be three `assertIn`s against the whole script, which
        a comment naming all three tokens would have satisfied.
        """
        lines = harness.strip_powershell_comments(DEPLOY_SCRIPT.read_text()).splitlines()

        calls = [index for index, line in enumerate(lines) if re.search(r"Test-EnvironmentHealth\s+-", line)]
        self.assertEqual(
            1, len(calls),
            f"expected the deploy to call Test-EnvironmentHealth once, found it on lines "
            f"{[index + 1 for index in calls]}",
        )
        call = calls[0]

        # Each one is a value the operator can set on the run. A call that
        # dropped one would fall back to the function's default and quietly
        # ignore what the workflow asked for.
        for argument in (
            "-TimeoutSeconds $HealthCheckTimeoutSeconds",
            "-HostHeader $HostName",
            "-AppPoolName $AppPoolName",
        ):
            self.assertIn(argument, lines[call], f"the health check call no longer passes {argument}")

        throws = [
            index for index, line in enumerate(lines)
            if "throw" in line and "did not become healthy" in line
        ]
        self.assertTrue(throws, "nothing throws 'did not become healthy', so a failed check cannot fail the deploy")

        # Walked block by block rather than read as "below the call", because a
        # throw that is merely further down the script runs whether or not the
        # check failed.
        for throw in throws:
            opener = _enclosing_opener(lines, throw)
            while opener is not None and opener != call:
                opener = _enclosing_opener(lines, opener)
            self.assertEqual(
                call, opener,
                f"the throw on line {throw + 1} is not inside the block the health check "
                f"on line {call + 1} opens, so it does not depend on the check failing",
            )

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

    # That both probe paths force TLS 1.2 used to be asserted here, as string
    # matches on the bodies of Invoke-SiteProbe and Test-EnvironmentHealth. Both
    # are lifted functions, and Pester/DeployVerification.Tests.ps1 runs each one
    # with the process left on SystemDefault and reads the setting back -- "forces
    # TLS 1.2 before it polls" and "forces TLS 1.2 before it connects".

    def test_app_pool_is_stopped_and_drained_before_files_are_replaced(self):
        text = DEPLOY_SCRIPT.read_text()
        self.assertIn("Stop-EnvironmentAppPool", text)
        self.assertIn("Get-WebAppPoolState", text)
        self.assertNotIn("Restart-Computer", text)
        self.assertNotIn("iisreset", text.lower())


class CertificateSelectionTests(unittest.TestCase):
    """The deploy script rebinds an SSL certificate on every run, so its choice of
    certificate silently decides whether renewal is durable or pointless."""

    # Which certificate the deploy binds used to be asserted here, as string
    # matches on the sort and filter lines of the selector. The selector is a
    # lifted function, and Pester/CertificateSelection.Tests.ps1 runs it
    # against a fake store -- "prefers a CA-issued certificate over the
    # longer-lived self-signed placeholder" and "ignores a certificate that has
    # already expired". Reading the line proved it was written. Running it
    # proves it is true.

    # Renewal walking C:\RockBackups used to be required here, by string match,
    # from when staging was deployed InPlace and kept its manifest there. Staging
    # is a DedicatedSite now, so the only manifest left under that root is
    # production's, and the default that walked it would have let a
    # renew-certificate on production's queue stop W3SVC there.
    # Pester/ManifestContract.Tests.ps1 holds the opposite, by running renewal's
    # reader over manifests the real deploy writers produced: "never reaches the
    # production manifest at its own defaults". The one-level-only rule for a root
    # an operator names by hand is "reads one level down and no further" there.

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
        self.assertIn("deploy-environment", harness.command_contract_verbs(text))

        contract = harness.command_contract(text, "deploy-environment")
        self.assertEqual(contract.get("Script"), "Deploy-RockEnvironment.ps1")
        self.assertEqual(contract.get("TimeoutSeconds"), 1800)

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
        empty string instead would overwrite it with nothing.

        Optional is the binding kind that says so: forwarded when the field is
        present and non-blank, omitted otherwise. As a Required it would refuse
        every production deploy; as a Verbatim it would forward the empty string
        that overwrites the box's own."""
        contract = harness.command_contract(QUEUE_SCRIPT.read_text(), "deploy-environment")

        self.assertEqual(contract.get("Optional", {}).get("connectionString"), "ConnectionString")
        for kind in ("Required", "Verbatim"):
            self.assertNotIn("connectionString", contract.get(kind, {}))

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

    def test_each_build_job_records_the_hash_of_the_zip_it_uploaded(self):
        """The hash travels as a job output, which nobody holding a bucket key can
        rewrite. It is taken in the workflow rather than in the packaging script
        because the repackage path runs the target ref's own copy of that script."""
        workflow = yaml.safe_load(ARTIFACT_WORKFLOW.read_text())

        for job_name in ["package", "repackage"]:
            job = workflow["jobs"][job_name]
            self.assertEqual(
                job["outputs"]["artifact_sha256"],
                "${{ steps.artifact-hash.outputs.sha256 }}",
                job_name,
            )
            step = harness.step(workflow, "Record the zip's hash for the deploy", job=job_name)
            self.assertEqual(step["id"], "artifact-hash")
            self.assertIn("Get-FileHash", step["run"])
            self.assertIn("-Algorithm SHA256", step["run"])

            # Hashed before the upload, so the bytes hashed are the bytes uploaded.
            names = [candidate.get("name") for candidate in job["steps"]]
            upload = [name for name in names if name and name.startswith("Upload")]
            self.assertTrue(upload, job_name)
            self.assertLess(
                names.index("Record the zip's hash for the deploy"),
                names.index(upload[0]),
                job_name,
            )

        value = workflow["on"]["workflow_call"]["outputs"]["artifact_sha256"]["value"]
        self.assertIn("jobs.package.outputs.artifact_sha256", value)
        self.assertIn("jobs.repackage.outputs.artifact_sha256", value)

    def test_staging_and_production_pin_the_hash_their_build_recorded(self):
        """Staging carries the same pin so every push rehearses the check that
        guards production."""
        for caller in [STAGING_WORKFLOW, PRODUCTION_WORKFLOW]:
            workflow = yaml.safe_load(caller.read_text())
            self.assertEqual(
                workflow["jobs"]["deploy"]["with"]["artifact_sha256"],
                "${{ needs.build.outputs.artifact_sha256 }}",
                caller.name,
            )


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
            if (step.get("uses") or "") == "./.github/actions/run-vm-command"
        ]
        self.assertEqual(
            1, len(steps), "expected exactly one queue step in the deploy command workflow"
        )
        return steps[0]

    def test_the_pinned_hash_travels_in_the_command(self):
        """Optional with an empty default, so a caller that pins nothing -- the pr-*
        fleet -- sends an empty hash, which the VM reads as nothing to check."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        hash_input = workflow["on"]["workflow_call"]["inputs"]["artifact_sha256"]
        self.assertFalse(hash_input["required"])
        self.assertEqual(hash_input["default"], "")

        payload = str((self.queue_step().get("with") or {}).get("payload") or "")
        # toJSON rather than a quoted interpolation, so the value cannot change the
        # shape of the JSON around it.
        self.assertIn('"artifactSha256": ${{ toJSON(env.ARTIFACT_SHA256) }}', payload)

        # The agent binds only the fields its contract names, so a hash it does not
        # list would arrive and be dropped without a word.
        self.assertRegex(QUEUE_SCRIPT.read_text(), r"artifactSha256\s+=\s+'ArtifactSha256'")

    def test_only_production_queue_writes_wait_for_the_production_gate(self):
        """Keyed on the queue rather than on a caller's input, so a caller cannot
        forget the gate. An empty name runs with no environment, which keeps
        staging's deploy unattended."""
        workflow = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        environment = workflow["jobs"]["deploy"]["environment"]

        self.assertEqual(
            environment["name"],
            "${{ inputs.queue_name == 'commands-prod' && 'production' || '' }}",
        )
        self.assertIn("inputs.queue_name == 'commands-prod'", environment["url"])

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
        step = harness.step(workflow, "Report which catalog this deploy will use", job="deploy")

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
        step = harness.step(workflow, "Report which catalog this deploy will use", job="deploy")

        self.assertIn("::warning::", step["run"])
        self.assertIn("shared sandbox catalog", step["run"])


class ProductionQueueGateTests(unittest.TestCase):
    PRODUCTION_GATE = "inputs.queue_name == 'commands-prod' && 'production' ||"

    def test_every_job_that_can_post_to_production_waits_for_the_production_gate(self):
        """Open item 33. Only a job that declares `production` receives that
        environment's secrets, so once production's key lives there a job without
        the gate cannot write production's queue at all -- it fails instead of
        posting. Pinned across every workflow that takes a queue name, so a new
        command workflow is checked on the day it is added rather than on the day
        it is first pointed at production."""
        checked = []
        for path in sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml")):
            workflow = yaml.safe_load(path.read_text()) or {}
            for job_name, job in (workflow.get("jobs") or {}).items():
                if "inputs.queue_name" not in str(job.get("env")):
                    continue
                environment = job.get("environment")
                name = environment.get("name") if isinstance(environment, dict) else environment
                self.assertIn(
                    self.PRODUCTION_GATE,
                    str(name),
                    f"{path.name} job {job_name!r} can post to production's queue "
                    "without the production gate",
                )
                checked.append(f"{path.name}:{job_name}")

        # Six jobs today. Fewer means the scan stopped seeing them, which would
        # turn the assertion above into a check of nothing.
        self.assertGreaterEqual(len(checked), 6, checked)


class DeployScriptDriftTests(unittest.TestCase):
    """The deploy scripts the VM runs are not the ones in the repository.

    `Sync-DeploymentScripts` refreshes C:\\RockDeploy from the bootstrap prefix on
    every queue poll, and the only publisher to that prefix is
    pr-test-bootstrap-command-queue.yml, which is workflow_dispatch-only. So a fix
    merged to Deployment/** changes nothing on the VM until somebody dispatches a
    bootstrap -- and every deploy in between runs the old script and reports
    success, because the code that would have done the work was never there. That
    is open item 25.

    The check lived inline in env-deploy-command.yml, which is the staging and
    production path. The pr-* fleet queues a different verb from a different
    workflow and never ran it -- and the fleet is the half most likely to be
    deploying just after somebody edited Deploy-PrEnvironment.ps1, which is in the
    same published set. Sixty lines of YAML string do not get a second caller, so
    the comparison moved to .github/actions/report-script-drift and both paths run
    it. Its branches are executed by Pester/ScriptDrift.Tests.ps1; what is left
    here is the wiring those branches cannot see.
    """

    DRIFT_ACTION = "./.github/actions/report-script-drift"

    def _queued_commands(self):
        """(path, job name, job, command) for every step that queues a VM command."""
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            workflow = yaml.safe_load(path.read_text()) or {}
            for job_name, job in (workflow.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    if "run-vm-command" in str(step.get("uses", "")):
                        yield path, job_name, job, str((step.get("with") or {}).get("command", ""))

    def _deploy_jobs(self):
        """Every job that queues a deploy. Two verbs, two scripts, one published set.

        `deploy` runs Deploy-PrEnvironment.ps1 for the fleet and `deploy-environment`
        runs Deploy-RockEnvironment.ps1 for staging and production -- see ADR-0006.
        Both scripts are published to the one bootstrap prefix, so the question this
        check asks is the same one whoever is deploying.
        """
        found = [
            (path, job_name, job)
            for path, job_name, job, command in self._queued_commands()
            if command.startswith("deploy")
        ]
        self.assertGreaterEqual(len(found), 2, "expected the fleet and the named environments")
        return found

    def _drift_script(self):
        return (REPO_ROOT / ".github" / "actions" / "report-script-drift" / "Get-ScriptDrift.ps1").read_text()

    def _published_directories(self):
        """Derived from the bootstrap rather than listed here.

        A hard-coded list is how the check silently stops covering things. The
        publish step is a glob over N directories; on 2026-08-19 it was two, and a
        drift check that knew about one would have reported "in sync" while the
        other was stale.
        """
        found = sorted(set(re.findall(r"(Deployment/[A-Za-z]+)/\*\.ps1", BOOTSTRAP_WORKFLOW.read_text())))
        self.assertGreater(len(found), 0)
        return found

    def test_every_workflow_that_queues_a_deploy_reports_drift_first(self):
        """The finding this action exists for. Adding a third deploy path without
        the check gives it the silence the first two grew out of."""
        for path, job_name, job in self._deploy_jobs():
            with self.subTest(workflow=path.name, job=job_name):
                uses = [str(step.get("uses", "")) for step in job["steps"]]
                self.assertIn(self.DRIFT_ACTION, uses)

    def test_no_producer_hides_its_command_behind_an_expression(self):
        """The sweep above reads literal `command:` values, so a producer that
        resolves its verb at runtime is invisible to it -- and invisible quietly,
        which is the failure mode that matters.

        One does: pr-test-lifecycle.yml passes `${{ env.COMMAND }}`, and its prepare
        job fails the run unless that resolves to `stop` or `destroy`, so it can
        never be a deploy. That is the whole allowance. A second one has to come
        here and say why."""
        expression = [
            f"{path.name} [{job_name}]"
            for path, job_name, _, command in self._queued_commands()
            if "${{" in command
        ]

        self.assertEqual(
            ["pr-test-lifecycle.yml [lifecycle]"],
            sorted(expression),
            "a queue producer names its command with an expression, so the deploy "
            "sweep in this class cannot see it. Either pin the command to a "
            "literal, or establish here that it can never be a deploy.",
        )

    def test_the_comparison_reads_every_directory_the_bootstrap_publishes_from(self):
        """Add a third directory to the publish line and this fails until the
        comparison and every caller's checkout follow."""
        script = self._drift_script()

        for directory in self._published_directories():
            with self.subTest(directory=directory):
                self.assertIn(directory, script)

    def test_it_compares_against_the_prefix_the_bootstrap_actually_publishes_to(self):
        """The coupling this test exists for: the drift check reads one GCS prefix
        and the bootstrap writes another, and nothing at runtime would notice them
        diverging -- the check would just report 'in sync' forever against an empty
        prefix. Renaming the prefix in one file has to fail here."""
        prefix = "pr-environments/bootstrap/latest"

        self.assertIn(prefix, self._drift_script())
        self.assertIn(prefix, BOOTSTRAP_WORKFLOW.read_text())

    def test_every_caller_checks_out_the_tree_the_comparison_reads(self):
        """An action cannot widen its caller's sparse-checkout. Running it against
        a checkout that did not bring the scripts down reads an empty directory --
        which this action reports as a check that did not run rather than as "in
        sync", and which is still not what the caller wanted."""
        published = self._published_directories()

        for path, job_name, job in self._deploy_jobs():
            with self.subTest(workflow=path.name, job=job_name):
                steps = job["steps"]
                drift = next(i for i, s in enumerate(steps) if str(s.get("uses", "")) == self.DRIFT_ACTION)
                checkout = next(
                    i for i, s in enumerate(steps)
                    if str(s.get("uses", "")).startswith("actions/checkout")
                    and "Deployment/" in str((s.get("with") or {}).get("sparse-checkout", ""))
                )

                self.assertLess(checkout, drift)
                for directory in published:
                    self.assertIn(directory, steps[checkout]["with"]["sparse-checkout"])

    def test_the_warning_arrives_before_the_command_is_queued(self):
        """A warning printed after the deploy has already run is a post-mortem. The
        point is to see it while the deploy can still be abandoned."""
        for path, job_name, job in self._deploy_jobs():
            with self.subTest(workflow=path.name, job=job_name):
                steps = job["steps"]
                drift = next(i for i, s in enumerate(steps) if str(s.get("uses", "")) == self.DRIFT_ACTION)
                queue = next(i for i, s in enumerate(steps) if "run-vm-command" in str(s.get("uses", "")))

                self.assertLess(drift, queue)

    def test_no_two_published_directories_hold_the_same_script_name(self):
        """The publish step globs N directories into one flat GCS prefix, so a
        basename is the whole identity of a script once it lands on the VM. Two
        directories holding the same name means whichever copies last wins,
        silently, and the drift check then compares both local copies against that
        one file and reports the loser as drifted forever. Cheaper to forbid the
        collision than to teach the flat prefix about directories."""
        owners = collections.defaultdict(list)
        for directory in self._published_directories():
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
        precise failure this check exists to catch, now with a green tick on it.

        Pester runs this branch; what is asserted here is only that the branch is
        still the shape the suite reaches for. See ScriptDrift.Tests.ps1, 'says the
        check did not run rather than reporting a clean result over nothing'."""
        script = self._drift_script()

        self.assertIn("Checked -eq 0", script)
        self.assertIn("could not check", script)

    def test_the_check_cannot_break_a_deploy_it_is_only_observing(self):
        """Structural rather than incidental. A diagnostic that can fail a
        production deploy gets deleted the first time it does.

        This was `continue-on-error: true` on the one caller's step. With two
        callers that is one forgotten line away from a reporting step that blocks a
        deploy, and a composite action's steps do not take the flag at all -- so
        the guarantee is the script's own: the body runs inside a try/catch and the
        file ends by exiting zero. Neither caller carries the flag, and neither
        needs to."""
        script = self._drift_script()

        self.assertIn("catch {", script)
        self.assertTrue(script.rstrip().endswith("exit 0"))

        for path, job_name, job in self._deploy_jobs():
            with self.subTest(workflow=path.name, job=job_name):
                step = next(s for s in job["steps"] if str(s.get("uses", "")) == self.DRIFT_ACTION)
                self.assertNotIn("continue-on-error", step)

    def test_drift_warns_and_does_not_fail_the_deploy(self):
        """Deliberate, and the reason this is option 2 of open item 25 rather than
        option 3: failing closed would block every deploy from the moment a script
        is merged until somebody dispatches a bootstrap, including the deploys that
        have nothing to do with the changed script. Failing closed is a separate
        decision with an operational cost, not a free upgrade to this one."""
        script = self._drift_script()

        self.assertNotIn("exit 1", script)
        self.assertNotIn("::error::", script)


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
        """The gate sits on the job that writes the command, inside
        env-deploy-command.yml. A separate approve job in front of it approved the
        run and left the write to a job no environment covered, so a key held as a
        `production` environment secret could never have reached the write."""
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())

        self.assertNotIn(
            "approve",
            workflow["jobs"],
            "a second job holding `production` would ask for a second approval",
        )
        # Approval must come after the build: nobody should be asked to approve a
        # commit that does not compile.
        self.assertIn("build", workflow["jobs"]["deploy"]["needs"])
        self.assertEqual(workflow["jobs"]["deploy"]["with"]["queue_name"], "commands-prod")

        command = yaml.safe_load(COMMAND_WORKFLOW.read_text())
        environment = command["jobs"]["deploy"]["environment"]
        self.assertEqual(
            environment["name"],
            "${{ inputs.queue_name == 'commands-prod' && 'production' || '' }}",
        )

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
        return harness.step(workflow, "Refuse a ref from a different Rock version", job="resolve")

    def test_the_guard_runs_before_anything_is_built_or_approved(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        step_names = [s.get("name") for s in workflow["jobs"]["resolve"]["steps"]]

        self.assertIn("Refuse a ref from a different Rock version", step_names)
        # `resolve` is what every other job depends on, so failing here costs no
        # build minutes and never reaches a human approver.
        for job in ["build", "deploy"]:
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

    def test_the_version_is_read_through_the_shared_reader(self):
        """Which files, in which order, and with which pattern are not this guard's
        to decide. They were until 2026-09-15, and the staging catalog guard decided
        them separately and differently -- opposite probe orders, each with a comment
        arguing it was the correct one, each pinned by a test that named only its own
        guard. Both passed, because this tree carries one of the two files they read
        and any order returns the same answer.

        The order, the pattern and the argument for them now live in
        .github/scripts/rock-version.sh, and test_rock_version_reader.py runs them
        against a tree carrying both files -- the layout that tells the two orders
        apart, and the one no checkout here has. What is left for this test is the
        seam: that this guard still reads through it rather than growing its own
        reader back."""
        run = self._guard_step()["run"]

        self.assertIn(
            '. "$GITHUB_WORKSPACE/.github/scripts/rock-version.sh"',
            run,
            "the production version guard no longer sources the shared reader",
        )
        self.assertIn(
            "rock_version_of_tree",
            run,
            "the guard sources the reader without asking it for the ref's version",
        )
        self.assertIn(
            "rock_version_of_file",
            run,
            "the expected version is no longer read with the shared reader, so the "
            "two sides of the comparison can be read differently again",
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

    # A mismatch failing the run, and the acknowledgement letting it through, are
    # run rather than read: ProductionVersionGuardRunTests in
    # test_production_deploy.py executes this step against a stubbed `gh`.

    def test_the_acknowledgement_is_off_by_default(self):
        workflow = yaml.safe_load(PRODUCTION_WORKFLOW.read_text())
        ack = workflow["on"]["workflow_dispatch"]["inputs"]["acknowledge_version_change"]

        self.assertFalse(ack["default"])
        self.assertFalse(ack.get("required", False))

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
        # The reporter's own help names it, and so do notes beside its callers.
        # The tests that look for the reporter read the code without them.
        self.code = harness.strip_powershell_comments(self.text)
        self.code_lines = self.code.splitlines()

    def test_the_script_has_a_timestamped_step_reporter(self):
        """Plain Write-Host lines cannot be placed in time. Two deploys, one of
        which spent nine minutes in robocopy, are indistinguishable without a
        clock on each line."""
        # The harness raises on a missing or doubled declaration; caught here only
        # so the failure says what the reporter is for.
        try:
            harness.powershell_function_lines(self.code, "Write-DeployStep")
        except AssertionError as error:
            self.fail(
                f"the deploy has no single timestamped step reporter, so its log "
                f"cannot be read as a timeline ({error})"
            )

    def test_the_step_reporter_stamps_utc_iso_8601(self):
        """The runner, the VM and whoever is reading are rarely in one timezone,
        and a log correlated against a Cloud SQL restore point has to be UTC."""
        start, end = harness.powershell_function_lines(self.code, "Write-DeployStep")
        body = "\n".join(self.code_lines[start:end])

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
        start, end = harness.powershell_function_lines(self.code, "Write-DeployStep")
        # The body starts on the line after the opening brace, and that brace sits
        # on the declaration line.
        definition = start - 1

        # Indexes, not `text.index(line)`: two calls with the same text would both
        # report the first one's position. Comments are already gone, so a note
        # that names the reporter above its definition is not mistaken for a call.
        calls = [
            index for index, line in enumerate(self.code_lines)
            if "Write-DeployStep" in line and not definition <= index <= end
        ]
        self.assertTrue(calls, "Write-DeployStep is defined but never called")
        self.assertLess(
            definition,
            min(calls),
            f"Write-DeployStep is called on line {min(calls) + 1} but defined on line {definition + 1}",
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

        # Spelled as the branch hands it back rather than as the in-place branch's
        # own local. $backupPath is now a variable inside Invoke-InPlaceOverlay and
        # never appears at this level; what the deploy body has is the record the
        # branch returned, and the dedicated-site branch returns an empty path
        # precisely so this line can be skipped when there is nowhere to roll back
        # to.
        #
        # Reported, not merely mentioned. Two other lines down here name the same
        # field -- the `if` that asks whether there is a backup at all, and the
        # throw on the unhealthy path -- and both would match a search for the name
        # alone. Deleting the report and keeping its guard is the exact regression
        # this test exists for, and it passed that plant until the filter asked for
        # Write-DeployStep.
        reported = [
            line
            for line in self.lines[deployed:]
            if "$deployed.BackupPath" in line
            and "Write-DeployStep" in line
            and "throw" not in line
            and not line.lstrip().startswith("#")
        ]
        self.assertTrue(
            reported,
            "a successful deploy never repeats where the backup went, so a rollback "
            "starts by scrolling",
        )


class StepReporterAdoptionTests(unittest.TestCase):
    """Nothing in the deploy reports through Write-Host without saying why.

    Two guards used to hold this line, each naming one function. This file
    asserted Test-EnvironmentHealth carried no Write-Host; DeployVerification.
    Tests.ps1 asserted the same of one message in Save-UnhealthyDiagnostics. Both
    were written the day a report went missing, and both guarded only the function
    whose report had gone missing that day.

    Fifteen calls sat outside the pair of them: the eight header lines, the two
    shared-asset skips, the two server-owned skips, the connection-string notice,
    the app-pool ACL grant and the preserved-file restore. Five of those say the
    deploy skipped something, which is the sentence an operator most needs stamped
    and most often finds absent.

    So the list is derived from the script rather than written here, and the only
    hand-written part is the two calls that have a reason to stay. Scoped to the
    deploy script on purpose: Invoke-PrEnvironmentCommandQueue.ps1 is the process
    doing the capturing, not one being captured, and Write-Host is correct there.
    """

    # Keyed on the call as written, because what is excused is the line, not the
    # function around it. A second Write-Host inside Write-DeployStep would still
    # have to come and argue for itself.
    WRITE_HOST_ALLOWED = {
        "Write-Host $line": (
            "Write-DeployStep's own host half -- routing it through the reporter "
            "would recurse"
        ),
        'Write-Host ""': (
            "a blank spacer above the dry-run plan; a timestamped empty line is "
            "noise in the timeline and reads as a message that lost its text"
        ),
        "& robocopy $SitePath $backupPath /E @backupExclusions /R:2 /W:2 /NFL /NDL /NP | Write-Host": (
            "robocopy's job summary, redirected rather than reported. These two "
            "calls sit inside Invoke-InPlaceOverlay, whose success stream is now "
            "its return value; left alone, robocopy's header and byte counts would "
            "be handed back as if they were the record. Write-Host is the channel "
            "Write-DeployStep already writes to, so the summary still reaches the "
            "log -- and Write-DeployStep cannot take its place, because it stamps "
            "each line and would stamp forty of them"
        ),
        "& robocopy $ExtractPath $SitePath /E @copyExclusions /R:3 /W:5 /NFL /NDL /NP | Write-Host": (
            "the deploy copy's job summary, for the reason above. The neighbouring "
            "test asserts these two calls keep /NJS off, so the summary they emit "
            "is the thing an operator reads to see whether the copy moved anything"
        ),
        "& robocopy $sourcePath $destinationPath /E /XC /XN /XO /NFL /NDL /NJH /NJS /NP | Write-Host": (
            "the base-site overlay in Sync-SharedSiteAssets, redirected for the "
            "same reason. It runs inside Invoke-DedicatedSiteReplace, and the "
            "blank lines its quiet switches still leave turned that function's "
            "record into an array -- staging's deploy of 2026-10-20 then threw on "
            "$deployed.BackupPath after the site was up. Its error lines, if any, "
            "still reach the log this way; the file counts either side of it go "
            "through Write-DeployStep"
        ),
        "& robocopy $copyFrom $copyTo @arguments /NFL /NDL /NJH /NJS /NP | Write-Host": (
            "the server-owned restore in Sync-ServerOwnedAssets, which is called "
            "from the same function for the same reason; its byte counts go "
            "through Write-DeployStep"
        ),
    }

    def setUp(self):
        self.text = DEPLOY_SCRIPT.read_text(encoding="utf-8")

    @staticmethod
    def host_calls(text):
        """`(line number, call as written)` for each Write-Host outside a comment.

        Comments are blanked by the shared reader, which preserves line numbers,
        so the numbers reported here are the numbers in the file.
        """
        stripped = harness.strip_powershell_comments(text).splitlines()
        for number, line in enumerate(stripped, 1):
            if "Write-Host" in line:
                yield number, line.strip()

    def test_every_write_host_has_a_reason_to_be_one(self):
        offenders = [
            f"Deploy-RockEnvironment.ps1:{number} {call}"
            for number, call in self.host_calls(self.text)
            if call not in self.WRITE_HOST_ALLOWED
        ]
        self.assertEqual(
            [],
            offenders,
            "these lines report through Write-Host, which the command queue keeps "
            "only while the job stream survives -- the staging rehearsal of "
            "2026-08-25 proved it does not. Send them through Write-DeployStep, or "
            "add them to WRITE_HOST_ALLOWED with the reason:\n  "
            + "\n  ".join(offenders),
        )

    def test_every_exemption_is_still_a_line_in_the_script(self):
        """An allow-list outliving its lines widens the rule without saying so."""
        present = {call for _, call in self.host_calls(self.text)}
        for call in self.WRITE_HOST_ALLOWED:
            with self.subTest(call=call):
                self.assertIn(
                    call,
                    present,
                    f"WRITE_HOST_ALLOWED excuses `{call}`, which the deploy script "
                    "no longer contains",
                )

    def test_the_sweep_catches_a_report_both_old_guards_missed(self):
        """Non-vacuity, planted where the pair of them could not see.

        Sync-SharedSiteAssets is neither Test-EnvironmentHealth nor
        Save-UnhealthyDiagnostics, and its skip notice is one of the fourteen that
        moved. Putting it back has to fail, or this sweep is asserting nothing.
        """
        moved = 'Write-DeployStep "Shared asset source is the destination; skipping overlay."'
        self.assertIn(moved, self.text, "the line this plant targets has moved or been reworded")

        planted = self.text.replace(moved, moved.replace("Write-DeployStep", "Write-Host", 1))
        offenders = [
            call
            for _, call in self.host_calls(planted)
            if call not in self.WRITE_HOST_ALLOWED
        ]
        self.assertTrue(offenders, "the sweep did not report a Write-Host it was handed")

    def test_a_comment_about_write_host_is_not_read_as_a_call(self):
        """Both comment forms discuss Write-Host at length. Counting those as
        calls would have made the allow-list a list of paragraphs."""
        mentions = {
            number
            for number, line in enumerate(self.text.splitlines(), 1)
            if "Write-Host" in line
        }
        called = {number for number, _ in self.host_calls(self.text)}
        self.assertTrue(
            mentions - called,
            "nothing in the script mentions Write-Host outside a call any more, so "
            "this test no longer proves the comment stripper is running",
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
