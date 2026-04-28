import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
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

    def test_issue_records_human_decisions(self):
        text = ISSUE.read_text()

        self.assertIn('Restart only PR environments that were running before refresh', text)
        self.assertIn('C:\\RockTestEnvs\\maintenance.json', text)
        self.assertIn('C:\\RockDeploy\\logs', text)


if __name__ == "__main__":
    unittest.main()
