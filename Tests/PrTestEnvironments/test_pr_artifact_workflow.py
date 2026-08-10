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


if __name__ == "__main__":
    unittest.main()
