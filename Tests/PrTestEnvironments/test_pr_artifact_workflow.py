import pathlib
import re
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-test-artifact.yml"
BOOTSTRAP_ISSUE_PATH = REPO_ROOT / "Documentation" / "Discussion Docs" / "PR-Test-Environments-Issues" / "01-bootstrap-server-prerequisites.md"


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
        # production without their artifacts colliding with a PR's.
        self.assertRegex(workflow_text, r"RockWeb-\$\{\{\s*env\.ARTIFACT_SLUG\s*\}\}-\$\{\{\s*env\.SHORT_SHA\s*\}\}\.zip")
        self.assertIn("pr-environments/${{ env.ARTIFACT_SLUG }}/${{ env.HEAD_SHA }}", workflow_text)
        self.assertIn("format('pr-{0}', inputs.pr_number)", workflow_text)
        self.assertIn("artifact_gcs_object_path", workflow_text)
        self.assertIn("actions/upload-artifact@v4", workflow_text)
        self.assertIn("google-github-actions/upload-cloud-storage@v2", workflow_text)
        self.assertIn("PR_TEST_GCS_BUCKET", workflow_text)
        self.assertIn("gsutil mb -p ${{ secrets.GCP_PROJECT_ID }} gs://$env:PR_TEST_GCS_BUCKET", workflow_text)

        forbidden_secret_names = ["DB_PASSWORD", "DB_USER", "DB_NAME", "CLOUD_SQL_CONNECTION_NAME"]
        for secret_name in forbidden_secret_names:
            self.assertNotIn(secret_name, workflow_text)

    def test_msbuild_is_resolved_via_vswhere_not_a_pinned_version_folder(self):
        """The runner image moved Visual Studio from .../2022/... to .../18/...,
        which broke every PR build until vswhere replaced the hardcoded path.
        Only vswhere.exe has a stable location, so pinning any version folder is
        a latent outage."""
        workflow_text = WORKFLOW_PATH.read_text()

        self.assertIn("vswhere.exe", workflow_text)
        self.assertIn("MSBUILD_PATH", workflow_text)
        self.assertRegex(workflow_text, r"-find\s+MSBuild\\\*\*\\Bin\\MSBuild\.exe")

        pinned_paths = re.findall(r"Microsoft Visual Studio\\\\?[0-9]{2,4}\\\\?", workflow_text)
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
        steps = workflow["jobs"]["package"]["steps"]

        build_step = next(s for s in steps if s.get("name") == "Build Rock Projects (Dependency Order)")

        self.assertNotEqual(build_step.get("continue-on-error"), True)
        self.assertNotRegex(build_step["run"], r"(?m)^\s*exit 0\s*$")
        self.assertIn("::error::", build_step["run"])

    def test_obsidian_block_javascript_is_built_and_verified(self):
        """The compiled .obs.js files are not committed to the repo, so without
        an explicit Rock.JavaScript.Obsidian.Blocks build the artifact ships a
        site whose every Obsidian block renders blank."""
        workflow_text = WORKFLOW_PATH.read_text()
        workflow = yaml.safe_load(workflow_text)
        step_names = [s.get("name") for s in workflow["jobs"]["package"]["steps"]]

        self.assertIn("Build Rock.JavaScript.Obsidian.Blocks", step_names)
        self.assertIn("Install Rock.JavaScript.Obsidian.Blocks Dependencies", step_names)

        # The framework bundle must be built before the blocks that import it.
        self.assertLess(
            step_names.index("Build Rock.JavaScript.Obsidian"),
            step_names.index("Build Rock.JavaScript.Obsidian.Blocks"),
        )

        verify_step = next(
            s for s in workflow["jobs"]["package"]["steps"] if s.get("name") == "Verify Build Artifacts"
        )
        self.assertIn("*.obs.js", verify_step["run"])

    def test_verification_gates_on_every_assembly_the_site_serves(self):
        """Gating on Rock.dll alone let artifacts through that were missing the
        REST API, migrations, or block implementations -- each of which yields a
        site that boots and then fails on the first page load."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        verify_step = next(
            s for s in workflow["jobs"]["package"]["steps"] if s.get("name") == "Verify Build Artifacts"
        )

        for assembly in [
            "Rock.dll",
            "Rock.Blocks.dll",
            "Rock.Rest.dll",
            "Rock.Migrations.dll",
            "Rock.WebStartup.dll",
            "Rock.ViewModels.dll",
        ]:
            self.assertIn(assembly, verify_step["run"])


ROCKWEB_BIN = REPO_ROOT / "RockWeb" / "Bin"
ROCKWEB_PACKAGES_CONFIG = REPO_ROOT / "RockWeb" / "packages.config"


def _read_refresh_pointer(path):
    """.refresh files are written with mixed encodings across the repo -- some
    UTF-16LE, some UTF-8 with a BOM. Drop NULs so a BOM-less UTF-16 file read as
    single bytes still yields the path, then strip the BOM character itself."""
    raw = path.read_bytes().replace(b"\x00", b"")
    return raw.decode("utf-8-sig", errors="replace").strip().strip("﻿")


class RefreshPointerResolutionTests(unittest.TestCase):
    """RockWeb is a Web Site project. Its assemblies arrive through *.dll.refresh
    pointers written in the packages.config convention, and every one of them was
    silently absent from every artifact ever produced -- which is what returned a
    500 on every request while the build reported green."""

    def test_website_packages_config_is_restored_into_the_folder_pointers_name(self):
        """Rock's .csproj projects use PackageReference, so their packages land in
        the global ~/.nuget cache, not in a solution packages\\ folder. A Web Site
        project has no .csproj for `nuget restore <solution>` to walk, so without
        an explicit packages.config restore the folder every pointer names is
        never created and all of them fail to resolve."""
        workflow = yaml.safe_load(WORKFLOW_PATH.read_text())
        restore_step = next(
            s for s in workflow["jobs"]["package"]["steps"] if s.get("name") == "NuGet Restore"
        )

        self.assertIn("RockWeb\\packages.config", restore_step["run"])
        self.assertIn("-PackagesDirectory packages", restore_step["run"])

    # Two pointers name a folder the restore does not create: packages.config pins
    # OpenXMLSDK-MOT at "2.6.0" but the pointers were written against "2.6.0.0", and
    # the packages folder is named for the version string exactly as declared. They
    # resolve today only because a project build already puts both assemblies in
    # RockWeb\bin, so the resolver counts them as already-built and never consults
    # packages\ -- confirmed against run 31422321277, which listed neither among its
    # unresolved pointers. Recorded rather than normalized away: if either assembly
    # ever stops being emitted as build output, the pointer will not save it.
    KNOWN_UNDECLARED_POINTERS = {
        "DocumentFormat.OpenXml.dll.refresh",
        "System.IO.Packaging.dll.refresh",
    }

    def test_every_refresh_pointer_resolves_to_a_declared_package_version(self):
        """A pointer naming a version packages.config does not pin resolves to a
        folder the restore never creates, so the assembly drops out of the
        artifact. Google.Protobuf failing this way is what took staging down."""
        config = ROCKWEB_PACKAGES_CONFIG.read_text()
        declared = set(re.findall(r'id="([^"]+)"\s+version="([^"]+)"', config))
        self.assertGreater(len(declared), 0, "parsed no packages from packages.config")

        pointers = sorted(ROCKWEB_BIN.glob("*.dll.refresh"))
        self.assertEqual(len(pointers), 84, "the pointer count changed; re-check the resolver step")

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

    def test_the_known_undeclared_pointers_are_still_the_only_exceptions(self):
        """Keeps the allowlist honest: if one of the two gets fixed upstream, or its
        version drifts again, this fails and the comment above gets revisited."""
        config = ROCKWEB_PACKAGES_CONFIG.read_text()
        declared = set(re.findall(r'id="([^"]+)"\s+version="([^"]+)"', config))

        for name in self.KNOWN_UNDECLARED_POINTERS:
            pointer = ROCKWEB_BIN / name
            self.assertTrue(pointer.exists(), f"{name} is gone; drop it from the allowlist")
            match = re.match(r"^\.\.\\packages\\(.+?)\.(\d+\.\d.*?)\\", _read_refresh_pointer(pointer))
            self.assertIsNotNone(match)
            self.assertNotIn(
                (match.group(1), match.group(2)),
                declared,
                f"{name} now matches packages.config; drop it from the allowlist",
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
        verify_step = next(
            s for s in workflow["jobs"]["package"]["steps"] if s.get("name") == "Verify Build Artifacts"
        )

        self.assertIn("Google.Protobuf.dll", verify_step["run"])
        self.assertIn("Google.Protobuf", ROCKWEB_PACKAGES_CONFIG.read_text())


if __name__ == "__main__":
    unittest.main()
