import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
CONFIG_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Set-PrEnvironmentRuntimeConfiguration.ps1"
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-PrEnvironment.ps1"
ISSUE = REPO_ROOT / "Documentation" / "Discussion Docs" / "PR-Test-Environments-Issues" / "10-runtime-config-integration-lockdown.md"


class RuntimeLockdownTests(unittest.TestCase):
    def test_runtime_config_writes_sandbox_connection_and_pr_specific_paths(self):
        text = CONFIG_SCRIPT.read_text()

        self.assertIn('SandboxConnectionString', text)
        self.assertIn('web.ConnectionStrings.config', text)
        self.assertIn('RunJobsInIISContext', text)
        self.assertIn('False', text)
        self.assertIn('App_Data\\PrTestEnvironment.json', text)
        self.assertIn('Logs', text)
        self.assertIn('Temp', text)
        self.assertIn('SharedFileStorageRoot', text)

    def test_runtime_config_removes_or_overrides_external_integration_settings(self):
        text = CONFIG_SCRIPT.read_text()

        for forbidden in ['SMTP', 'Twilio', 'SMS', 'Payment', 'Webhook', 'SparkApiUrl']:
            self.assertIn(forbidden, text)
        self.assertIn('web.PrTestEnvironment.config', text)
        self.assertIn('Production integration credentials are intentionally not deployed', text)

    def test_deploy_invokes_runtime_lockdown_and_issue_documents_browser_testing_contract(self):
        deploy = DEPLOY_SCRIPT.read_text()
        issue = ISSUE.read_text()

        self.assertIn('Set-PrEnvironmentRuntimeConfiguration.ps1', deploy)
        self.assertIn('Shared sandbox file storage', issue)
        self.assertIn('basic browser testing without contacting real external systems', issue)


if __name__ == "__main__":
    unittest.main()
