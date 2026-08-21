import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
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
            "Themes,Content,Assets,Styles,Plugins",
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

    def test_shared_asset_overlay_backfills_plugins_so_custom_blocks_render(self):
        """RockWeb/Plugins/.gitignore is `*/*`, so not one plugin subfolder is
        tracked in git and none of them reach the build artifact. Passion's login
        page is a custom plugin block at Plugins/org_passion/Security/Login.ascx,
        so unless the overlay backfills Plugins from the base site that file is
        simply absent and every test site serves

            Error Loading Block: Login
            The file '/Plugins/org_passion/Security/Login.ascx' does not exist.

        as its landing page. That is not a cosmetic fault: /Login and /page/3 both
        render the error, and the admin pages 302 to /page/3, so nobody can log in
        to a PR environment at all.

        The artifact ships nothing under Plugins, so /XC /XN /XO has none of the
        branch's own files to protect here -- for this directory the overlay can
        only ever add.
        """
        text = DEPLOY_SCRIPT.read_text()

        match = re.search(r"PR_TEST_SHARED_ASSET_DIRECTORIES\)\)\s*\{\s*'([^']+)'\s*\}", text)
        self.assertIsNotNone(match, "could not find the shared asset directory default list")

        directories = [entry.strip() for entry in match.group(1).split(",")]
        self.assertIn("Plugins", directories, f"overlay default must backfill Plugins, got {directories}")
        for existing in ["Themes", "Content", "Assets", "Styles"]:
            self.assertIn(existing, directories, f"overlay default must still carry {existing}")

    def test_plugin_build_artifacts_are_stripped_after_the_overlay(self):
        """Remove-PluginBuildArtifacts keeps a developer's bin/obj leftovers out of
        a deployed site. It used to run before the overlay, which was harmless
        while the overlay could not carry Plugins at all -- now that it does, a
        strip that runs first is a strip that runs too early, because the base
        site's own Plugins/*/bin and Plugins/*/obj are copied in behind it. The
        strip has to be the last thing that touches Plugins.

        The argument is asserted, not just the ordering. A later strip aimed at
        $ExtractPath would satisfy any ordering check while doing nothing at all,
        because Move-Item has already consumed that directory by then.
        """
        lines = DEPLOY_SCRIPT.read_text().splitlines()

        overlay = [
            index for index, line in enumerate(lines)
            if line.lstrip().startswith("Sync-SharedSiteAssets")
        ]
        self.assertTrue(overlay, "no Sync-SharedSiteAssets call site found")

        strips = [
            index for index, line in enumerate(lines)
            if re.match(r"Remove-PluginBuildArtifacts\s+-(?:Site)?Path\s+\$SitePath\b", line.strip())
        ]
        self.assertTrue(
            strips,
            "no Remove-PluginBuildArtifacts call targets $SitePath; stripping $ExtractPath "
            "is a no-op once Move-Item has consumed that directory",
        )
        self.assertTrue(
            any(index > max(overlay) for index in strips),
            f"a $SitePath strip must follow the overlay at line {max(overlay) + 1}; "
            f"found strips at {[index + 1 for index in strips]}",
        )


if __name__ == "__main__":
    unittest.main()
