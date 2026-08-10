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

    def test_deploy_script_can_overlay_shared_site_assets_from_same_server(self):
        text = DEPLOY_SCRIPT.read_text()
        for expected in [
            "SharedAssetSourcePath",
            "PR_TEST_SHARED_ASSET_SOURCE_PATH",
            "SharedAssetDirectories",
            "Themes,Content,Assets,Styles",
            "Sync-SharedSiteAssets",
            "robocopy",
            "Get-SharedAssetSourcePath",
            "Default Web Site",
        ]:
            self.assertIn(expected, text)

    def test_shared_asset_overlay_never_overwrites_files_the_branch_ships(self):
        """The overlay exists to backfill files the artifact cannot carry --
        uploaded Content/Assets and UI-customized themes. It used to run
        `robocopy /MIR`, which mirrored the base site over the PR site: every
        file the branch changed was overwritten and every file it added was
        deleted. A PR that edited a theme or stylesheet deployed green and then
        showed none of its own changes."""
        text = DEPLOY_SCRIPT.read_text()

        # Check the invocation itself, not the file -- the surrounding comment
        # names /MIR to explain why it was removed.
        robocopy_lines = [
            line for line in text.splitlines()
            if line.lstrip().startswith("& robocopy")
        ]
        self.assertEqual(len(robocopy_lines), 1, f"expected exactly one robocopy invocation, got {robocopy_lines}")
        invocation = robocopy_lines[0]

        self.assertNotIn("/MIR", invocation, "shared asset overlay must not mirror over the branch's own files")
        for exclusion in ["/E", "/XC", "/XN", "/XO"]:
            self.assertIn(exclusion, invocation, f"overlay must pass {exclusion} so existing files are left alone")


if __name__ == "__main__":
    unittest.main()
