import unittest

import yaml

import pipeline_harness as harness

REPO_ROOT = harness.REPO_ROOT
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-diagnose-command-queue.yml"

class DiagnoseCommandQueueWorkflowTests(unittest.TestCase):
    def test_diagnostics_workflow_collects_vm_task_state_via_startup_script(self):
        text = WORKFLOW.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("workflow_dispatch", workflow["on"])
        # The metadata key moved into inject-startup-script with the staging; the
        # claim this test makes is that the diagnostics reach the VM as a startup
        # script at all, and the action's name is what carries that now.
        self.assertIn("./.github/actions/inject-startup-script", text)
        self.assertIn("Get-ScheduledTask", text)
        self.assertIn("Get-ScheduledTaskInfo", text)
        self.assertIn("C:\\RockDeploy", text)
        self.assertIn("Invoke-PrEnvironmentCommandQueue.ps1", text)
        self.assertIn("Get-GcsObjectList", text)
        self.assertIn("pr-environments/diagnostics", text)
        # The reboot is the delivery, not a step around it (ADR-0007), so it stays
        # asserted -- but the stop and the start moved into restart-vm alongside
        # the retry loop this workflow used to spell itself.
        self.assertIn("./.github/actions/restart-vm", text)
        self.assertIn("gcloud compute instances get-serial-port-output", text)
        self.assertIn("Poll diagnostics", text)

    def test_the_diagnose_run_does_not_deliver_itself_through_the_queue(self):
        """The one caller that must not use the queue actions -- see ADR-0007.

        Five workflows queue a command and wait for it, this one does not, and from
        the workflow directory that reads as the last un-migrated caller. It is the
        reason ADR-0007 exists: the diagnosis is of a queue agent that is not
        running, so a command sent through the queue arrives only when the fault it
        is looking for is absent, and otherwise sits in `pending/` forever.

        Asserted rather than left to the record because the record is a file
        somebody has to think to open, and this migration looks like tidying.
        """
        text = WORKFLOW.read_text()

        for action in ("run-vm-command", "queue-vm-command", "await-vm-command"):
            with self.subTest(action=action):
                self.assertNotIn(
                    f"./.github/actions/{action}",
                    text,
                    f"the diagnose run has been routed through {action}. It exists to "
                    "diagnose an agent that is not consuming commands, so a command is "
                    "the one delivery mechanism guaranteed not to arrive in the case it "
                    "was built for. See ADR-0007.",
                )

        # The other half of the decision: what it *does* share is shared. The VM
        # lookup used to be its own copy here, spelled differently from its two
        # siblings and missing their guard.
        self.assertIn("./.github/actions/resolve-vm", text)

    def test_the_diagnostics_payload_still_asks_the_questions_it_exists_to_ask(self):
        """ADR-0007 rests on what this run reports; if that changes the record is stale.

        The claim is that the diagnosis is of a dead agent. What makes it true is
        that the payload inspects the scheduled task and runs the queue processor
        by hand. Strip either and the workflow is a generic remote-command runner,
        which is a thing the queue actions do better.
        """
        text = WORKFLOW.read_text()

        self.assertIn("Rock PR Environment Command Queue", text)
        self.assertIn("powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\RockDeploy\\Invoke-PrEnvironmentCommandQueue.ps1", text)
        for prefix in ("pending/", "processing/", "results/"):
            with self.subTest(prefix=prefix):
                self.assertIn(f"pr-environments/commands/{prefix}", text)

if __name__ == "__main__":
    unittest.main()
