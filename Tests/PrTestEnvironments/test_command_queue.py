import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
BOOTSTRAP_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Install-PrEnvironmentCommandQueueTask.ps1"
DEPLOY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"
LIFECYCLE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-lifecycle.yml"

class CommandQueueTests(unittest.TestCase):
    def test_queue_processor_pulls_commands_from_gcs_and_runs_local_scripts(self):
        text = QUEUE_SCRIPT.read_text()
        for expected in [
            "Get-GcsAccessToken", "Invoke-GcsRequest",
            # The prefix is templated on $QueueName so each VM owns its own queue;
            # see test_environment_deploy.py::test_each_vm_polls_its_own_queue_prefix.
            "$QueueName/pending/", "$QueueName/processing/", "$QueueName/results/",
            "Deploy-PrEnvironment.ps1", "Stop-PrEnvironment.ps1", "Destroy-PrEnvironment.ps1", "Invoke-PrEnvironmentCertificateRenewal.ps1",
            "ConvertFrom-Json", "ConvertTo-Json", "CommandId", "status = \"succeeded\"", "status = \"failed\""
        ]:
            self.assertIn(expected, text)
        self.assertNotIn("ssh", text.lower())
        self.assertNotIn("Restart-Computer", text)

    def test_bootstrap_installs_windows_scheduled_task_for_queue_processor(self):
        text = BOOTSTRAP_SCRIPT.read_text()
        for expected in ["schtasks.exe", "/SC MINUTE", "/RU SYSTEM", "Invoke-PrEnvironmentCommandQueue.ps1", "C:\\RockDeploy"]:
            self.assertIn(expected, text)

    def test_workflows_upload_commands_and_poll_results_without_ssh(self):
        for path in [DEPLOY_WORKFLOW, LIFECYCLE_WORKFLOW]:
            text = path.read_text()
            self.assertIn("commands/pending", text)
            self.assertIn("gsutil cp", text)
            self.assertNotIn("sshpass", text)
            self.assertNotIn("Deploy over SSH", text)

            # Polling for the result moved to .github/actions/await-vm-command.
            # test_local_composite_actions.py asserts every producer waits through
            # it, which is a stronger claim than the string this used to match.

if __name__ == "__main__":
    unittest.main()
