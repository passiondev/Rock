import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CLEANUP_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCleanup.ps1"


class PrEnvironmentCleanupTests(unittest.TestCase):
    def test_cleanup_script_applies_idle_stop_and_destroy_policy_from_manifests(self):
        text = CLEANUP_SCRIPT.read_text()

        self.assertIn('Get-ChildItem', text)
        self.assertIn('env.json', text)
        self.assertIn('StopAfterHours = 6', text)
        self.assertIn('DestroyAfterDays = 7', text)
        self.assertIn('Stop-PrEnvironment.ps1', text)
        self.assertIn('Destroy-PrEnvironment.ps1', text)
        self.assertIn('ConvertFrom-Json', text)

    def test_cleanup_script_is_safe_for_corrupt_manifests_and_non_pr_resources(self):
        text = CLEANUP_SCRIPT.read_text()

        self.assertIn('try {', text)
        self.assertIn('catch', text)
        self.assertIn('Write-Warning', text)
        self.assertIn('if ($manifest.prNumber -le 0)', text)
        self.assertIn('WhatIf', text)
        self.assertIn('GitHubToken', text)
        self.assertNotIn('Get-Website', text)


if __name__ == "__main__":
    unittest.main()
