"""Passion's branding lives in the repository, not on the boxes.

The colours below were hand edits on the production server until 2026-08-26, present
in no repository and protected only by the fact that production had never had an
automated deploy. The InPlace copy is plain `robocopy /E` and both override files ride
in the artifact, so the v19 cutover would have been the first run to reach them, and it
would have reverted the staff-facing site to Rock's default orange with no warning and
no log line. Staging had already demonstrated the outcome: it deployed from the artifact,
came up orange, and got its blue put back by hand through the admin UI.

These tests exist so that a merge which resolves either file towards upstream fails here
rather than in front of staff. See `Documentation/Fork-Local-Changes.md` item 4.
"""

import pathlib
import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
THEME_ROOT = REPO_ROOT / "RockWeb" / "Themes"
FONT_ROOT = REPO_ROOT / "RockWeb" / "Assets" / "Fonts" / "FontAwesome"
FORK_LOCAL_REGISTER = REPO_ROOT / "Documentation" / "Fork-Local-Changes.md"
DEPLOY_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Deploy-RockEnvironment.ps1"

# Read off what production serves, not chosen here. Every value below was taken from
# https://connect.passion.team/Themes/<theme>/Styles/_variable-overrides.less on
# 2026-08-26, which is the only place they had ever been written down.
PASSION_BRAND_COLOR = "#00b8e4"

ROCK_THEME_VARIABLES = {
    "@brand-color": PASSION_BRAND_COLOR,
    "@link-color": "#599ac2",
    "@link-hover-color": "#51c0f5",
    "@brand-critical": "#ee7625",
    "@text-selection-color": "#000000",
}


def _overrides(theme):
    return (THEME_ROOT / theme / "Styles" / "_variable-overrides.less").read_text()


def _declared(text, variable):
    """The value assigned to `variable`, or None when the file never assigns it.

    Matched on the whole declaration rather than by searching for the hex string,
    because several of these colours are close enough to each other that a substring
    hit proves nothing about which variable carries it.
    """
    match = re.search(rf"^\s*{re.escape(variable)}\s*:\s*([^;]+);", text, re.MULTILINE)
    return match.group(1).strip() if match else None


class ThemeBrandingTests(unittest.TestCase):
    def test_the_rock_theme_carries_every_passion_colour(self):
        """The staff-facing internal site runs this theme."""
        text = _overrides("Rock")

        for variable, expected in ROCK_THEME_VARIABLES.items():
            with self.subTest(variable=variable):
                self.assertEqual(
                    expected, _declared(text, variable),
                    f"{variable} does not match what production serves. Resolving this file "
                    "towards upstream reverts the staff site to Rock's default orange",
                )

    def test_the_rock_manager_theme_carries_the_brand_colour(self):
        """RockManager takes the brand colour and nothing else, which is all production
        has. It is listed separately rather than folded into the loop above so that the
        difference is visible: a future edit that copies all five colours across is a
        change to what production looks like, not a consistency fix.
        """
        self.assertEqual(
            PASSION_BRAND_COLOR, _declared(_overrides("RockManager"), "@brand-color"),
            "RockManager lost its brand colour",
        )

    def test_the_rock_theme_registers_the_font_awesome_pro_weights(self):
        """Without `@fa-edition: 'pro'` and the two `.fa-font-face` calls, the compiled
        CSS emits no @font-face rule for the Regular and Light weights and every Pro-only
        icon falls back to an empty box -- even on a server that has the Pro fonts.
        """
        text = _overrides("Rock")

        self.assertEqual(
            "'pro'", _declared(text, "@fa-edition"),
            "@fa-edition is not set to 'pro'",
        )
        for weight in ("regular", "light"):
            with self.subTest(weight=weight):
                self.assertRegex(
                    text, rf"\.fa-font-face\(\s*'{weight}'\s*,\s*'pro'\s*\)",
                    f"the {weight} Pro weight is not registered",
                )

    def test_the_pro_webfont_binaries_are_not_committed(self):
        """The counterpart to the test above, and the reason the fonts cannot simply be
        committed alongside the declarations that name them. This repository is a public
        fork of SparkDevNetwork/Rock. The Pro webfonts are licensed commercial binaries,
        and pushing them here would breach the licence and could not be taken back --
        git history, forks and GitHub's CDN all keep their own copy.

        Free and Pro share every filename, so presence alone proves nothing and this
        checks size. Free's fa-solid-900.woff2 is about 78 KB against Pro's 137 KB, and
        Free's fa-regular-400.woff2 about 13 KB against Pro's 169 KB. The 100 KB line
        sits clear of both Free files and below both Pro ones. fa-light-300.woff2 has no
        Free edition at all, so any copy of it is a Pro copy.
        """
        self.assertFalse(
            (FONT_ROOT / "fa-light-300.woff2").exists(),
            "fa-light-300.woff2 has no Free edition, so committing it publishes a "
            "licensed Pro binary to a public repository",
        )

        for name in ("fa-solid-900.woff2", "fa-regular-400.woff2"):
            path = FONT_ROOT / name
            if not path.exists():
                continue
            with self.subTest(font=name):
                self.assertLess(
                    path.stat().st_size, 100_000,
                    f"{name} is {path.stat().st_size} bytes, which is the Pro edition. "
                    "Pro webfonts must stay on the servers and reach a deploy through "
                    "$ServerOwnedDirectories",
                )

    def test_the_deploy_script_carries_the_fonts_the_repository_cannot(self):
        """The two halves have to stay together. Refusing the binaries above only works
        because the deploy has another way to get them onto a site, and a change that
        removed `$ServerOwnedDirectories` would leave this suite happily asserting that
        the fonts are absent from a repository that no longer has any means of supplying
        them.
        """
        text = DEPLOY_SCRIPT.read_text()

        match = re.search(r"\$ServerOwnedDirectories\s*=\s*@\(([^)]*)\)", text)
        self.assertIsNotNone(
            match,
            "$ServerOwnedDirectories is gone, so nothing puts the Font Awesome Pro fonts "
            "on a deployed site and nothing keeps the artifact's Free copies off "
            "production",
        )
        self.assertIn("Assets/Fonts/FontAwesome", re.findall(r"'([^']+)'", match.group(1)))

    def test_the_register_lists_both_override_files(self):
        """`test_upgrade_diff.py` already fails when the register misses a fork-local
        file, but it derives its list from the upstream tag and needs the upstream remote
        to do it. This runs everywhere and names the two files directly, so a laptop
        without the remote still catches a register that has fallen behind.
        """
        register = FORK_LOCAL_REGISTER.read_text()

        for theme in ("Rock", "RockManager"):
            with self.subTest(theme=theme):
                self.assertIn(
                    f"RockWeb/Themes/{theme}/Styles/_variable-overrides.less", register,
                    f"the {theme} theme override is fork-local and is not in the register",
                )


if __name__ == "__main__":
    unittest.main()
