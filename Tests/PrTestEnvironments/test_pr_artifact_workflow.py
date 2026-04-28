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
        self.assertRegex(workflow_text, r"RockWeb-pr-\$\{\{\s*env\.PR_NUMBER\s*\}\}-\$\{\{\s*env\.SHORT_SHA\s*\}\}\.zip")
        self.assertIn("pr-environments/pr-${{ env.PR_NUMBER }}/${{ env.HEAD_SHA }}", workflow_text)
        self.assertIn("artifact_gcs_object_path", workflow_text)
        self.assertIn("actions/upload-artifact@v4", workflow_text)
        self.assertIn("google-github-actions/upload-cloud-storage@v2", workflow_text)

        forbidden_secret_names = ["DB_PASSWORD", "DB_USER", "DB_NAME", "CLOUD_SQL_CONNECTION_NAME"]
        for secret_name in forbidden_secret_names:
            self.assertNotIn(secret_name, workflow_text)


if __name__ == "__main__":
    unittest.main()
