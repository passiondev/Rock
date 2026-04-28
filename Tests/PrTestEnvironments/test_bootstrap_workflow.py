import pathlib
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"

class BootstrapCommandQueueWorkflowTests(unittest.TestCase):
    def test_bootstrap_workflow_uses_gcp_metadata_startup_script_not_manual_ssh(self):
        text = WORKFLOW.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("workflow_dispatch", workflow["on"])
        self.assertIn("google-github-actions/auth@v2", text)
        self.assertIn("google-github-actions/upload-cloud-storage@v2", text)
        self.assertIn("gcloud compute instances add-metadata", text)
        self.assertIn("windows-startup-script-ps1", text)
        self.assertIn("gcloud compute instances stop", text)
        self.assertIn("gcloud compute instances start", text)
        self.assertIn("Install-PrEnvironmentCommandQueueTask.ps1", text)
        self.assertIn("Invoke-PrEnvironmentCommandQueue.ps1", text)
        self.assertIn("rock-deployments-${{ secrets.GCP_PROJECT_ID }}", text)
        self.assertNotIn("sshpass", text)
        self.assertNotIn("scp ", text)

if __name__ == "__main__":
    unittest.main()
