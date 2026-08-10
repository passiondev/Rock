import pathlib
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-diagnose-command-queue.yml"

class DiagnoseCommandQueueWorkflowTests(unittest.TestCase):
    def test_diagnostics_workflow_collects_vm_task_state_via_startup_script(self):
        text = WORKFLOW.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("workflow_dispatch", workflow["on"])
        self.assertIn("windows-startup-script-ps1", text)
        self.assertIn("Get-ScheduledTask", text)
        self.assertIn("Get-ScheduledTaskInfo", text)
        self.assertIn("C:\\RockDeploy", text)
        self.assertIn("Invoke-PrEnvironmentCommandQueue.ps1", text)
        self.assertIn("Get-GcsObjectList", text)
        self.assertIn("pr-environments/diagnostics", text)
        self.assertIn("gcloud compute instances add-metadata", text)
        self.assertIn("gcloud compute instances stop", text)
        self.assertIn("gcloud compute instances start", text)
        self.assertIn("gcloud compute instances get-serial-port-output", text)
        self.assertIn("Poll diagnostics", text)

if __name__ == "__main__":
    unittest.main()
