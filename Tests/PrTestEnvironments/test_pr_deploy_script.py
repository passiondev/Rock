import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-PrEnvironment.ps1"


class DeployPrEnvironmentScriptTests(unittest.TestCase):
    def test_deploy_script_exposes_idempotent_pr_environment_contract(self):
        text = DEPLOY_SCRIPT.read_text()

        for parameter in ["PrNumber", "Sha", "ArtifactGcsPath", "HostName", "SandboxConnectionString"]:
            self.assertRegex(text, rf"\[Parameter\(Mandatory\s*=\s*\$true\)\]\s*\[.+?\]\s*\${parameter}")

        self.assertIn('$SiteName = "rock-pr-$PrNumber"', text)
        self.assertIn('$AppPoolName = "rock-pr-$PrNumber"', text)
        self.assertIn('Join-Path $EnvironmentRoot "pr-$PrNumber"', text)
        self.assertIn('env.json', text)

    def test_deploy_script_updates_runtime_resources_without_requiring_vm_restart(self):
        text = DEPLOY_SCRIPT.read_text()

        required_behaviors = [
            "Stop-WebAppPool",
            "Expand-Archive",
            "New-WebAppPool",
            "New-Website",
            "New-WebBinding",
            "AddSslCertificate",
            "Start-WebAppPool",
            "Start-Website",
        ]
        for behavior in required_behaviors:
            self.assertIn(behavior, text)

        self.assertNotIn("Restart-Computer", text)
        self.assertNotIn("iisreset", text.lower())


if __name__ == "__main__":
    unittest.main()
