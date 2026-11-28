import json
import re
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-test-artifact.yml"
HAND_DEPLOY_PATH = REPO_ROOT / ".github" / "workflows" / "ptp-14803-build-artifact.yml"
DOTNET_BUILD_SCRIPT = REPO_ROOT / ".github" / "scripts" / "Invoke-RockDotNetBuild.ps1"
JS_BUILD_SCRIPT = REPO_ROOT / ".github" / "scripts" / "Invoke-RockJsBuild.ps1"
VERIFY_SCRIPT = REPO_ROOT / ".github" / "scripts" / "Test-RockWebArtifact.ps1"
BOOTSTRAP_ISSUE_PATH = REPO_ROOT / "Documentation" / "Discussion Docs" / "PR-Test-Environments-Issues" / "01-bootstrap-server-prerequisites.md"
ROCK_CORE_LESS = REPO_ROOT / "RockWeb" / "Styles" / "_rock-core.less"


class PrTestEnvironmentBootstrapTests(unittest.TestCase):
    def test_bootstrap_issue_records_confirmed_domain_and_default_paths(self):
        text = BOOTSTRAP_ISSUE_PATH.read_text()

        self.assertIn("*.rock-dev.connect.passion.team", text)
        self.assertIn("C:\\RockTestEnvs", text)
        self.assertIn("C:\\RockDeploy", text)
        self.assertIn("WINDOWS_USERNAME", text)
        self.assertIn("GCP_VM_EXTERNAL_IP", text)


class PrArtifactWorkflowTests(unittest.TestCase):
    def test_workflow_publishes_pr_sha_scoped_zip_without_database_secrets(self):
        workflow_text = WORKFLOW_PATH.read_text()
        workflow = yaml.safe_load(workflow_text)

        self.assertIn("workflow_call", workflow["on"])
        self.assertIn("workflow_dispatch", workflow["on"])
        # The artifact name and GCS folder are keyed on ARTIFACT_SLUG, which
        # defaults to pr-<pr_number>, so the same build also serves staging and
        # production without their artifacts colliding with a PR's. The name and
        # the folder the uploads take are composed by Get-ArtifactAddress in
        # ArtifactRecord.psm1, and the Pester suite ArtifactRecord.Tests.ps1
        # pins them; what is left to hold here is that the build hands it the
        # bucket, the slug and the commit. test_artifact_reuse.py holds the
        # uploads to what it composes.
        package = next(s for s in workflow["jobs"]["package"]["steps"] if s.get("id") == "package-metadata")
        self.assertIn("-Bucket $env:PR_TEST_GCS_BUCKET", package["run"])
        self.assertIn("-ArtifactSlug $env:ARTIFACT_SLUG", package["run"])
        self.assertIn("-TargetSha $env:HEAD_SHA", package["run"])
        self.assertIn("format('pr-{0}', inputs.pr_number)", workflow_text)
        self.assertIn("artifact_gcs_object_path", workflow_text)
        self.assertIn("actions/upload-artifact@v4", workflow_text)
        self.assertIn("google-github-actions/upload-cloud-storage@v2", workflow_text)
        self.assertIn("PR_TEST_GCS_BUCKET", workflow_text)
        self.assertIn("gsutil mb -p ${{ secrets.GCP_PROJECT_ID }} gs://$env:PR_TEST_GCS_BUCKET", workflow_text)

        forbidden_secret_names = ["DB_PASSWORD", "DB_USER", "DB_NAME", "CLOUD_SQL_CONNECTION_NAME"]
        for secret_name in forbidden_secret_names:
            self.assertNotIn(secret_name, workflow_text)

    def test_dotnet_build_uses_cross_platform_sdk_without_pinned_vs_paths(self):
        """The .NET build runs via .NET 9 SDK + Microsoft.NETFramework.ReferenceAssemblies.net472
        on ubuntu-latest (and locally on macOS/Linux) with no pinned Visual Studio paths."""
        workflow_text = WORKFLOW_PATH.read_text()
        workflow = yaml.safe_load(workflow_text)

        self.assertEqual("ubuntu-latest", workflow["jobs"]["dotnet"]["runs-on"])
        build_step = harness.step(workflow, "Build Rock Projects (net472)", job="dotnet")
        self.assertIn("Invoke-RockDotNetBuild.ps1", build_step["run"])

        script_text = DOTNET_BUILD_SCRIPT.read_text()
        self.assertIn("Microsoft.NETFramework.ReferenceAssemblies.net472", script_text)
        self.assertIn("TargetFrameworks=net472", script_text)

        pinned_paths = re.findall(r"Microsoft Visual Studio\\\\?[0-9]{2,4}\\\\?", workflow_text + script_text)
        self.assertEqual(
            pinned_paths,
            [],
            f"pinned Visual Studio version folder(s) found: {pinned_paths}",
        )

    def test_build_failures_are_not_suppressed(self):
        """`continue-on-error: true` on the build step swallowed the step's own
        `exit $LASTEXITCODE` guards, and a trailing `exit 0` forced the step
        green, so a failed compile still packaged and deployed an artifact."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        build_step = harness.step(workflow, "Build Rock Projects (net472)", job="dotnet")

        self.assertNotEqual(build_step.get("continue-on-error"), True)
        self.assertNotRegex(build_step["run"], r"(?m)^\s*exit 0\s*$")

        script_text = DOTNET_BUILD_SCRIPT.read_text()
        self.assertNotRegex(script_text, r"(?m)^\s*exit 0\s*$")
        self.assertIn("::error::", script_text)

    def test_obsidian_block_javascript_is_built_and_verified(self):
        """The compiled .obs.js files are not committed to the repo, so without
        an explicit Rock.JavaScript.Obsidian.Blocks build the artifact ships a
        site whose every Obsidian block renders blank."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        blocks_step = harness.step(workflow, "Build Rock.JavaScript.Obsidian.Blocks", job="js-blocks")
        self.assertIn("Invoke-RockJsBuild.ps1", blocks_step["run"])
        self.assertIn("-Package blocks", blocks_step["run"])

        obsidian_step = harness.step(workflow, "Build Rock.JavaScript.Obsidian", job="js-obsidian")
        self.assertIn("Invoke-RockJsBuild.ps1", obsidian_step["run"])
        self.assertIn("-Package obsidian", obsidian_step["run"])

        typecheck_step = harness.step(workflow, "Run Obsidian & Blocks TypeScript typecheck", job="js-typecheck")
        self.assertIn("-Package typecheck", typecheck_step["run"])

        verify_step = harness.step(workflow, "Verify Build Artifacts", job="package")
        self.assertIn("Test-RockWebArtifact.ps1", verify_step["run"])
        self.assertIn("*.obs.js", VERIFY_SCRIPT.read_text())

    def test_verification_gates_on_every_assembly_the_site_serves(self):
        """Gating on Rock.dll alone let artifacts through that were missing the
        REST API, migrations, or block implementations -- each of which yields a
        site that boots and then fails on the first page load."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        verify_step = harness.step(workflow, "Verify Build Artifacts", job="package")
        self.assertIn("Test-RockWebArtifact.ps1", verify_step["run"])

        verify_text = VERIFY_SCRIPT.read_text()
        for assembly in [
            "Rock.dll",
            "Rock.Blocks.dll",
            "Rock.Rest.dll",
            "Rock.Migrations.dll",
            "Rock.WebStartup.dll",
            "Rock.ViewModels.dll",
        ]:
            self.assertIn(assembly, verify_text)


ROCKWEB_BIN = REPO_ROOT / "RockWeb" / "Bin"
ROCKWEB_PACKAGES_CONFIG = REPO_ROOT / "RockWeb" / "packages.config"


def _read_refresh_pointer(path):
    """.refresh files are written with mixed encodings across the repo -- some
    UTF-16 with a BOM, some UTF-8 with a BOM, some plain.

    A UTF-16 BOM has to be decoded, not stripped of NULs: 0xFF and 0xFE are not NUL,
    so they survive the NUL pass and are then invalid UTF-8, which `errors="replace"`
    turns into replacement characters at the front of the path. That is silent -- the
    caller gets a string back, just not one any pattern matches. Over half the
    pointers in the repo are written this way."""
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = raw.decode("utf-16")
    else:
        # A BOM-less UTF-16LE file is ASCII interleaved with NULs; dropping them
        # recovers the path where there is no BOM to key off.
        text = raw.replace(b"\x00", b"").decode("utf-8-sig", errors="replace")
    return text.strip().strip("﻿")


class RefreshPointerResolutionTests(unittest.TestCase):
    """RockWeb is a Web Site project. Its assemblies arrive through *.dll.refresh
    pointers written in the packages.config convention, and every one of them was
    silently absent from every artifact ever produced -- which is what returned a
    500 on every request while the build reported green."""

    def test_website_packages_config_is_restored_into_the_folder_pointers_name(self):
        """Rock's .csproj projects use PackageReference, so their packages land in
        the global ~/.nuget cache. RockWeb/packages.config is restored via a
        synthetic PackageReference project into that same global cache so
        Resolve-RefreshAssemblies can resolve every *.dll.refresh pointer
        cross-platform without nuget.exe."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        build_step = harness.step(workflow, "Build Rock Projects (net472)", job="dotnet")
        self.assertIn("Invoke-RockDotNetBuild.ps1", build_step["run"])

        script_text = DOTNET_BUILD_SCRIPT.read_text()
        self.assertIn("packages.config", script_text)
        self.assertIn("New-RockWebPackagesProject", script_text)
        self.assertIn("Resolve-RefreshAssemblies", script_text)

    # Empty on Rock 19. On 18.4 this held two pointers: packages.config pinned
    # OpenXMLSDK-MOT at "2.6.0" while the pointers were written against "2.6.0.0",
    # and the packages folder is named for the version string exactly as declared.
    # Rock 19 repins DocumentFormat.OpenXml at 3.3.0 -- declared and resolving --
    # and drops System.IO.Packaging from RockWeb\Bin, so neither is needed.
    KNOWN_UNDECLARED_POINTERS = set()

    def test_every_refresh_pointer_is_parseable(self):
        """The resolution test skips any pointer it cannot parse (`if not match:
        continue`), so a pointer the reader mangles is never checked -- it is
        silently excused. That is the exact failure mode this class exists to catch,
        so the skip has to be an asserted invariant rather than a quiet branch.

        It was not. 47 of the 84 pointers on 18.4 are UTF-16 with a BOM, which the
        reader turned into replacement characters, and the regex then declined every
        one of them -- so the check examined 37 of 84 while reporting success.
        Google.Protobuf, the package whose absence returned a 500 on every request
        and took staging down, was among the pointers being skipped."""
        pointers = sorted(ROCKWEB_BIN.glob("*.dll.refresh"))
        self.assertGreater(len(pointers), 0, "found no refresh pointers at all")
        unparseable = [
            f"{pointer.name} -> {_read_refresh_pointer(pointer)!r}"
            for pointer in pointers
            if not re.match(r"^\.\.\\packages\\(.+?)\.(\d+\.\d.*?)\\", _read_refresh_pointer(pointer))
        ]
        self.assertEqual(
            unparseable,
            [],
            "pointers the reader cannot parse are skipped by the resolution check "
            "rather than verified:\n  " + "\n  ".join(unparseable),
        )

    def test_every_refresh_pointer_resolves_to_a_declared_package_version(self):
        """A pointer naming a version packages.config does not pin resolves to a
        folder the restore never creates, so the assembly drops out of the
        artifact. Google.Protobuf failing this way is what took staging down."""
        config = ROCKWEB_PACKAGES_CONFIG.read_text()
        declared = set(re.findall(r'id="([^"]+)"\s+version="([^"]+)"', config))
        self.assertGreater(len(declared), 0, "parsed no packages from packages.config")

        pointers = sorted(ROCKWEB_BIN.glob("*.dll.refresh"))
        self.assertEqual(len(pointers), 158, "the pointer count changed; re-check the resolver step")

        package_style = 0
        undeclared = []
        for pointer in pointers:
            target = _read_refresh_pointer(pointer)
            match = re.match(r"^\.\.\\packages\\(.+?)\.(\d+\.\d.*?)\\", target)
            if not match:
                continue
            package_style += 1
            if (match.group(1), match.group(2)) in declared:
                continue
            if pointer.name in self.KNOWN_UNDECLARED_POINTERS:
                continue
            undeclared.append(f"{pointer.name} -> {target}")

        self.assertGreater(package_style, 0, "no pointers used the ..\\packages\\ convention")
        self.assertEqual(undeclared, [], "pointers name package versions RockWeb/packages.config does not pin")

    def test_the_allowlist_matches_the_pointers_that_actually_need_it(self):
        """Asserted in both directions so it stays meaningful while the allowlist is
        empty. The one-directional form -- iterate the allowlist, check each entry --
        passes vacuously on an empty set, which is exactly the state a Rock upgrade
        leaves it in, and would let a newly-undeclared pointer go unreported."""
        config = ROCKWEB_PACKAGES_CONFIG.read_text()
        declared = set(re.findall(r'id="([^"]+)"\s+version="([^"]+)"', config))

        actually_undeclared = set()
        for pointer in sorted(ROCKWEB_BIN.glob("*.dll.refresh")):
            match = re.match(r"^\.\.\\packages\\(.+?)\.(\d+\.\d.*?)\\", _read_refresh_pointer(pointer))
            if match and (match.group(1), match.group(2)) not in declared:
                actually_undeclared.add(pointer.name)

        self.assertEqual(
            self.KNOWN_UNDECLARED_POINTERS,
            actually_undeclared,
            "the allowlist and the tree disagree; a pointer either started or stopped "
            "naming a package version RockWeb/packages.config does not pin",
        )

    def test_roslyn_pointers_are_satisfied_by_committed_binaries(self):
        """The resolver step is deliberately non-recursive. That is only safe while
        every pointer under Bin\\roslyn\\ -- the compiler <system.codedom> uses to
        build .ascx at run time -- has its target committed next to it."""
        roslyn = ROCKWEB_BIN / "roslyn"
        pointers = sorted(roslyn.glob("*.refresh"))
        self.assertGreater(len(pointers), 0, "expected committed roslyn pointers")

        for pointer in pointers:
            target = roslyn / pointer.name[: -len(".refresh")]
            self.assertTrue(
                target.exists(),
                f"{target.name} is not committed, so the non-recursive resolver would miss it",
            )

    def test_protobuf_stays_gated_as_the_canary_for_this_whole_class_of_bug(self):
        """Google.Protobuf reaches bin only via .refresh resolution and is loaded
        during Application_Start, so its absence is a 500 on every request -- and
        the custom error page cannot render either, which hides the cause."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        verify_step = harness.step(workflow, "Verify Build Artifacts", job="package")
        self.assertIn("Test-RockWebArtifact.ps1", verify_step["run"])

        self.assertIn("Google.Protobuf.dll", VERIFY_SCRIPT.read_text())
        self.assertIn("Google.Protobuf", ROCKWEB_PACKAGES_CONFIG.read_text())

    def test_the_styles_build_runs_and_its_output_is_gated(self):
        """Rock.Frontend.Styles compiles styles-v2/icons/tabler-icon.css and core.css
        on 19.x while staying guarded on package-lock.json for 18.4.1 compatibility."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        steps = workflow["jobs"]["js-misc"]["steps"]

        styles_cache = [s for s in steps if "Rock.Frontend.Styles" in (s.get("name") or "") and s.get("uses", "").startswith("actions/cache@")]
        self.assertTrue(styles_cache, "js-misc should cache Rock.Frontend.Styles build outputs")
        for step in styles_cache:
            self.assertIn("Rock.Frontend.Styles/package-lock.json", step.get("if", ""))

        js_script = JS_BUILD_SCRIPT.read_text()
        self.assertIn("Rock.Frontend.Styles", js_script)
        self.assertIn("package-lock.json", js_script)

        verify_step = harness.step(workflow, "Verify Build Artifacts", job="package")
        self.assertIn("Test-RockWebArtifact.ps1", verify_step["run"])
        run = VERIFY_SCRIPT.read_text()
        self.assertIn("tabler-icon.css", run)
        self.assertIn("styles-v2", run)

        check = re.search(
            r"if \(-not \(Test-Path -LiteralPath \$tablerIcons\)\) \{(.*?)\}", run, re.S
        )
        self.assertIsNotNone(
            check, "no Test-Path check on the tabler-icon.css path in Test-RockWebArtifact.ps1"
        )
        self.assertIn(
            "$failures.Add(", check.group(1),
            "the missing stylesheet has to fail the build, not warn",
        )

    def test_the_stylesheet_the_gate_names_is_the_one_less_actually_imports(self):
        """The gate is only worth anything while it names the file _rock-core.less
        imports. If a Rock upgrade renames or moves that import, the gate would keep
        passing on a file nothing reads."""
        verify_text = VERIFY_SCRIPT.read_text()
        imports = re.findall(
            r'@import[^;]*"([^"]*styles-v2[^"]*)"', ROCK_CORE_LESS.read_text()
        )
        self.assertTrue(imports, "_rock-core.less no longer imports anything from styles-v2")
        for imported in imports:
            self.assertIn(
                imported.rsplit("/", 1)[-1], verify_text,
                f"_rock-core.less imports {imported} but Test-RockWebArtifact.ps1 does not check for it",
            )


class StylesGateCompletenessTests(unittest.TestCase):
    """The gate has to tell a complete build from an empty one, on two branch lines
    whose styles-v2 folders look nothing alike."""

    STYLES_V2_SOURCE = REPO_ROOT / "Rock.Frontend.Styles" / "src" / "styles" / "styles-v2"

    def _verify_run(self):
        return VERIFY_SCRIPT.read_text()

    def test_the_gate_does_not_treat_a_file_count_as_completeness(self):
        run = self._verify_run()

        counting_failures = re.findall(
            r"if \(\$stylesV2\.Count[^)]*\)\s*\{(.*?)\}", run, re.S
        )
        for body in counting_failures:
            self.assertNotIn(
                "$failures.Add(", body,
                "the gate fails the build on a styles-v2 file count again",
            )

    def test_the_gate_measures_the_stylesheet_that_carries_the_partials(self):
        run = self._verify_run()

        self.assertIn("core.css", run)
        self.assertRegex(
            run,
            r"\$coreBytes\s*-lt\s*\d+KB",
            "nothing checks how big core.css is, so an empty stub passes the gate",
        )

    def test_every_stylesheet_the_gate_names_is_also_size_checked(self):
        run = self._verify_run()

        for stylesheet in ("tabler-icon.css", "core.css"):
            with self.subTest(stylesheet=stylesheet):
                binding = re.search(
                    r"^\s*(\$\w+)\s*=\s*Join-Path[^\n]*" + re.escape(stylesheet),
                    run,
                    re.M,
                )
                self.assertIsNotNone(
                    binding, f"{stylesheet} is not bound to a variable Test-RockWebArtifact.ps1 checks"
                )

                variable = re.escape(binding.group(1))
                block = run[binding.end():]
                next_binding = re.search(r"^\s*\$\w+\s*=\s*Join-Path", block, re.M)
                if next_binding:
                    block = block[:next_binding.start()]

                self.assertRegex(
                    block,
                    variable + r"\)?\.Length",
                    f"{stylesheet} is checked for presence but its size is never read",
                )
                self.assertRegex(
                    block,
                    r"-lt\s*\d+KB",
                    f"{stylesheet} has its size read but never compared against a floor",
                )

    def test_the_generated_layout_this_gate_assumes_is_the_one_the_source_produces(self):
        """Derived from the source tree rather than asserted as a number, so the day
        someone adds a second entry point the expectation moves with it. Only
        non-partial .scss files and plain .css files emit anything; a leading
        underscore means the file compiles into another one."""
        if not self.STYLES_V2_SOURCE.is_dir():
            self.skipTest("Rock.Frontend.Styles does not exist on this branch")

        entry_points = [
            p for p in self.STYLES_V2_SOURCE.rglob("*.scss") if not p.name.startswith("_")
        ]
        plain_css = list(self.STYLES_V2_SOURCE.rglob("*.css"))

        self.assertEqual(
            [p.name for p in entry_points],
            ["core.css".replace(".css", ".scss")],
            "styles-v2 has an entry point other than core.scss, so core.css alone no "
            "longer represents the build and the gate needs to name the new one too",
        )
        self.assertLess(
            len(entry_points) + len(plain_css),
            10,
            "the generated output now exceeds the count the old gate demanded, which "
            "would make that gate look correct again -- reread why it was removed",
        )


class HandDeployBuildStaysCredentialFreeTests(harness.HarnessAssertions, unittest.TestCase):
    r"""`ptp-14803-build-artifact.yml` exists because it cannot reach anything.

    The architecture review recommended deleting it, on two grounds. Neither holds,
    and the record is here rather than in a commit message because the same two
    readings are what an automated scan produces.

    A second review then recommended it again -- retire the file, or make it call
    the artifact build with inputs -- which is how this docstring learned it was
    the wrong place to keep the answer. The decision is ADR-0009 now; what follows
    is why, and the tests below are what hold it.

    "Nobody triggers it." It was pinned to `push: [deploy/ptp-14803-18.4.1]`, a
    branch on the prune list, which is a real problem and is fixed -- it is dispatch
    only now, pinned by test_workflow_triggers_survive_pruning.py. The capability was
    last used on 2026-08-18 against a different branch entirely.

    "Fifteen of its nineteen steps are the same as the artifact build's." Nine are.
    The count of fifteen comes from matching step titles; six of those fifteen differ
    in substance, and the differences are the reason both files exist. The artifact
    build pins a SHA and fetches depth 10, restores `RockWeb\packages.config` into a
    named packages directory, caches five node_modules trees, and sorts build
    failures into required and advisory. This one takes whatever branch you dispatch,
    builds a fixed list of seven projects, and hard-fails on any of them. The nine
    that do match are not contiguous in either file, because the artifact build also
    compiles Rock.JavaScript and Rock.JavaScript.EditorJs in between -- so a shared
    prelude action would have to either carry those for both or split into three
    fragments, and neither is a deeper module than what is there.

    What is worth pinning is the property that makes deleting it a loss: it consumes
    no credentials, so it cannot boot Rock against the production catalog. That is a
    claim its header makes at length and nothing enforced.
    """

    def workflow(self):
        return harness.workflow(HAND_DEPLOY_PATH.name)

    def test_it_requests_nothing_beyond_reading_the_repository(self):
        self.assertEqual({"contents": "read"}, self.workflow().get("permissions"))

    def test_it_consumes_no_secrets(self):
        text = HAND_DEPLOY_PATH.read_text(encoding="utf-8")
        self.assertNoMatch(
            r"secrets\.",
            text,
            "this build is the one vehicle that cannot reach the production catalog, "
            "and a secret is how that stops being true",
        )

    def test_it_opens_no_cloud_session(self):
        text = HAND_DEPLOY_PATH.read_text(encoding="utf-8")
        for forbidden in ("google-github-actions/auth", "setup-gcloud", "gsutil", "gcloud "):
            self.assertNotIn(
                forbidden,
                text,
                f"{forbidden} appeared in the hand-deploy build. It uploads to nothing "
                "on purpose; the artifact workflow is where a cloud session belongs.",
            )

    def test_the_two_builds_do_not_cache_different_trees_under_one_key(self):
        """ptp-14803-build-artifact.yml caches node_modules under `js-<os>-...`, while
        pr-test-artifact.yml caches npm downloads (`npmcache-*`) and per-package build
        outputs (`jsout-*`) across parallel Ubuntu jobs. None of the keys or fallback
        prefixes may collide."""
        mine = harness.step(self.workflow(), "Cache JavaScript Dependencies", job="build")["with"]
        artifact_wf = harness.workflow(WORKFLOW_PATH.name)
        theirs_caches = [
            step["with"]
            for job in artifact_wf["jobs"].values()
            for step in (job.get("steps") or [])
            if (step.get("uses") or "").startswith("actions/cache@")
        ]
        self.assertTrue(theirs_caches, "pr-test-artifact.yml declares no actions/cache steps")

        for theirs in theirs_caches:
            self.assertNotEqual(mine["key"], theirs["key"])
            for fallback in mine.get("restore-keys", "").split():
                self.assertFalse(
                    theirs["key"].startswith(fallback),
                    f"restore-key {fallback!r} collides with artifact cache key {theirs['key']!r}",
                )
            for fallback in theirs.get("restore-keys", "").split():
                self.assertFalse(
                    mine["key"].startswith(fallback),
                    f"artifact restore-key {fallback!r} collides with hand-deploy cache key {mine['key']!r}",
                )

    def test_the_artifact_workflow_uses_all_ubuntu_parallel_jobs(self):
        """pr-test-artifact.yml intentionally diverged from ptp-14803-build-artifact.yml's
        single Windows job to run parallel Ubuntu jobs (.NET 9 SDK + sharded JS)."""
        artifact_wf = harness.workflow(WORKFLOW_PATH.name)
        for job_name, job in artifact_wf["jobs"].items():
            self.assertEqual(
                "ubuntu-latest",
                job.get("runs-on"),
                f"pr-test-artifact.yml job {job_name!r} should run on ubuntu-latest",
            )


if __name__ == "__main__":
    unittest.main()
