import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
REFRESH_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-SandboxRefreshWithPrEnvironments.ps1"
ISSUE = REPO_ROOT / "Documentation" / "Discussion Docs" / "PR-Test-Environments-Issues" / "09-sandbox-db-refresh-coordination.md"


class SandboxRefreshCoordinationTests(unittest.TestCase):
    def test_refresh_script_stops_pr_app_pools_and_restarts_previously_running_sites(self):
        text = REFRESH_SCRIPT.read_text()

        self.assertIn('Get-ChildItem', text)
        self.assertIn('env.json', text)
        self.assertIn('Stop-WebAppPool', text)
        self.assertIn('Start-WebAppPool', text)
        self.assertIn('previouslyRunning', text)
        self.assertIn('maintenance.json', text)
        self.assertIn('C:\\RockDeploy\\logs', text)

    def test_refresh_script_wraps_existing_refresh_command_and_logs_failures(self):
        text = REFRESH_SCRIPT.read_text()

        self.assertIn('RefreshCommand', text)
        self.assertIn('PostRefreshCommand', text)
        self.assertIn('SharedFileStorageCommand', text)
        self.assertIn('Start-Transcript', text)
        self.assertIn('Stop-Transcript', text)
        self.assertIn('try {', text)
        self.assertIn('catch', text)
        self.assertIn('finally', text)

    def test_non_pr_environments_are_left_running_rather_than_called_invalid(self):
        """`staging` writes its manifest at C:\\RockTestEnvs\\staging\\env.json --
        inside the tree this script walks -- but carries no prNumber, because only
        Deploy-PrEnvironment.ps1 emits one. So it has always reached this branch.

        Once staging has its own catalog it is not the database being refreshed, so
        leaving its app pool up is the correct outcome; calling it an invalid manifest
        read as a defect in the log on every run.
        """
        text = REFRESH_SCRIPT.read_text()

        self.assertIn("Leaving non-PR environment", text)
        self.assertNotIn("Skipping invalid PR manifest", text)

    def test_a_present_but_unusable_pr_number_still_warns(self):
        """Absent and <= 0 are different conditions with different owners: one is a
        non-PR environment behaving normally, the other is a genuinely malformed
        manifest that somebody needs to look at."""
        text = REFRESH_SCRIPT.read_text()

        self.assertIn("Skipping malformed manifest", text)
        self.assertIn("prNumber -le 0", text)

    def test_issue_records_human_decisions(self):
        text = ISSUE.read_text()

        self.assertIn('Restart only PR environments that were running before refresh', text)
        self.assertIn('C:\\RockTestEnvs\\maintenance.json', text)
        self.assertIn('C:\\RockDeploy\\logs', text)


if __name__ == "__main__":
    unittest.main()
