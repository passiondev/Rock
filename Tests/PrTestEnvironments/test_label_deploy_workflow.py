import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"


class LabelTriggeredDeployWorkflowTests(unittest.TestCase):
    def test_workflow_is_label_triggered_and_refuses_forks_before_building(self):
        text = WORKFLOW_PATH.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("pull_request_target", workflow["on"])
        self.assertIn("labeled", workflow["on"]["pull_request_target"]["types"])
        self.assertIn("rock:start", text)
        self.assertIn("head.repo.full_name !== context.payload.repository.full_name", text)
        self.assertIn("Skipping forked PR", text)

    def test_workflow_builds_artifact_then_queues_deploy_command(self):
        text = WORKFLOW_PATH.read_text()

        self.assertIn("./.github/workflows/pr-test-artifact.yml", text)
        self.assertIn("secrets: inherit", text)
        # Queueing the command is `.github/actions/queue-vm-command` now. Where it
        # writes, and that the echo redacts, are asserted once in
        # test_local_composite_actions.py instead of once per producer -- which is
        # how two of the six came to redact a field name the third does not use.
        # The wait itself is .github/actions/await-vm-command now, and its
        # behaviour is asserted once in test_local_composite_actions.py rather
        # than once per producer. What stays here is what this workflow chooses.
        self.assertIn("attempts: '120'", text)
        self.assertIn("artifactGcsPath", text)
        self.assertIn("rock-dev.connect.passion.team", text)
        self.assertNotIn("sshpass", text)

    def test_workflow_reconciles_command_and_state_labels(self):
        text = WORKFLOW_PATH.read_text()

        for label in [
            "rock:queued",
            "rock:building",
            "rock:deploying",
            "rock:deployed",
            "rock:failed",
        ]:
            self.assertIn(label, text)

        self.assertIn("removeLabel", text)
        self.assertIn("updatePrTestStatus", text)


if __name__ == "__main__":
    unittest.main()
