import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEV_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md"
OP_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"


class RunbookTests(unittest.TestCase):
    def test_developer_runbook_covers_commands_access_and_shared_data(self):
        text = DEV_RUNBOOK.read_text()
        for expected in [
            'rock-test:start',
            'rock-test:stop',
            'rock-test:destroy',
            'rock-test:auto',
            'VPN',
            '159.63.145.194',
            'shared sanitized sandbox database',
            'shared sandbox file storage',
            're-add `rock-test:start`',
        ]:
            self.assertIn(expected, text)

    def test_operator_runbook_covers_infrastructure_and_recovery(self):
        text = OP_RUNBOOK.read_text()
        for expected in [
            '*.rock-dev.connect.passion.team',
            'wildcard TLS certificate',
            '159.63.145.194/32',
            'WINDOWS_USERNAME',
            'GCP_VM_EXTERNAL_IP',
            'C:\\RockTestEnvs',
            'env.json',
            'rock-pr-<number>',
            'Invoke-PrEnvironmentCleanup.ps1',
            'Invoke-SandboxRefreshWithPrEnvironments.ps1',
            'Troubleshooting',
        ]:
            self.assertIn(expected, text)


if __name__ == "__main__":
    unittest.main()
