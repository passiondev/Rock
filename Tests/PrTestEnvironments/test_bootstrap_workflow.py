import unittest

import yaml

import pipeline_harness as harness

REPO_ROOT = harness.REPO_ROOT
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"

class BootstrapCommandQueueWorkflowTests(unittest.TestCase):
    def test_bootstrap_workflow_uses_gcp_metadata_startup_script_not_manual_ssh(self):
        text = WORKFLOW.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("workflow_dispatch", workflow["on"])
        # Authenticating is the claim; the pair moved behind a composite action,
        # and test_gcp_session_consistency.py is what holds that one place honest.
        self.assertIn("./.github/actions/gcp-session", text)
        # Not the whole command: the upload also sets -h Content-Type, without which
        # the agent fetches every script as a byte[] and refreshes none of them
        # (test_command_queue_self_update.ContentTypeOfPublishedScriptsTests). Pinning
        # the flag order here would break that fix rather than notice it.
        self.assertIn("Deployment/PrTestEnvironments/*.ps1", text)
        self.assertIn("gsutil", text)
        self.assertIn("gcloud compute instances list", text)
        self.assertIn("GCP_VM_EXTERNAL_IP", text)
        self.assertIn("gcloud compute instances add-metadata", text)
        self.assertIn("windows-startup-script-ps1", text)
        self.assertIn("gcloud compute instances stop", text)
        self.assertIn("gcloud compute instances set-service-account", text)
        self.assertIn("https://www.googleapis.com/auth/cloud-platform", text)
        self.assertIn("gcloud compute instances start", text)
        self.assertIn("Install-PrEnvironmentCommandQueueTask.ps1", text)
        self.assertIn("Invoke-PrEnvironmentCommandQueue.ps1", text)
        self.assertIn("PR_TEST_GCS_BUCKET", text)
        self.assertIn("rock-pr-env-{0}-{1}", text)
        self.assertNotIn("sshpass", text)
        self.assertNotIn("scp ", text)

if __name__ == "__main__":
    unittest.main()
