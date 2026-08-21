"""Hold the copied PowerShell helpers identical across the deploy scripts.

Card 03 of the 2026-08-21 architecture review counted twelve PowerShell scripts
and no shared module, and proposed one `.psm1` beside them. The codebase had
already considered and rejected that, in a comment repeated at the top of
`Stop-PrEnvironment.ps1` and `Invoke-PrEnvironmentCleanup.ps1`:

    Duplicated ... rather than shared, deliberately: the bootstrap ships this
    directory with `gsutil cp Deployment/PrTestEnvironments/*.ps1`, so a .psm1
    would never reach the VM -- the same class of silent non-deployment this
    function exists to fix.

That reasoning still holds, and the bootstrap has since grown a second reason.
`pr-test-bootstrap-command-queue.yml` discovers published scripts with
`Where-Object { $_ -like '*.ps1' }`, which does not match `.psm1`, on top of a
hand-typed floor list of ten names. On 2026-08-18 those two disagreed by one file
and the agent failed a command on a bootstrap that had reported success. A module
would add a fourth place to keep in step, in the one path where being out of step
is silent.

There is a third reason the module cannot be complete even if it shipped.
`Get-GcsAccessToken` and `Copy-GcsObjectToFile` are defined inline in the VM
startup script, because they are what fetches everything else onto the box. The
bootstrap copy can never import a module. It is the copy most likely to drift and
the only one no refactor can remove.

So the copies stay. What was missing is any check that they agree, which is what
this module is. Bodies are compared after normalising whitespace, because the
bootstrap copy lives in a YAML here-string at a different indent with `$` escaped
as a backtick-dollar.
"""

import re
import unittest

import pipeline_harness as harness

DEPLOY_DIR = harness.REPO_ROOT / "Deployment" / "PrTestEnvironments"
BOOTSTRAP_WORKFLOW = (
    harness.REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
)

# Each helper, and every file expected to carry a copy. Listing the files rather
# than counting them means a new copy appearing somewhere unexpected is a failure
# that names itself, instead of a number quietly going up.
SHARED_HELPERS = {
    "Get-GcsAccessToken": [
        "Deploy-PrEnvironment.ps1",
        "Deploy-RockEnvironment.ps1",
        "Invoke-PrEnvironmentCommandQueue.ps1",
    ],
    "ConvertTo-ManifestHashtable": [
        "Invoke-PrEnvironmentCleanup.ps1",
        "Invoke-SandboxRefreshWithPrEnvironments.ps1",
        "Stop-PrEnvironment.ps1",
    ],
    "Ensure-Directory": [
        "Deploy-PrEnvironment.ps1",
        "Deploy-RockEnvironment.ps1",
        "Invoke-PrEnvironmentCertificateRenewal.ps1",
        "Invoke-SandboxRefreshWithPrEnvironments.ps1",
        "Set-PrEnvironmentRuntimeConfiguration.ps1",
    ],
}

# Deliberately absent from the map above. These names appear in both
# `Deploy-PrEnvironment.ps1` and `Deploy-RockEnvironment.ps1`, which are two live
# scripts serving different environments -- PR sites and staging or production --
# and their bodies differ on purpose. Pinning them identical would be asserting a
# sameness that is not true and does not want to be.
DELIBERATELY_DIVERGENT = [
    "Sync-SharedSiteAssets",
    "Remove-PluginBuildArtifacts",
    "Ensure-Website",
    "Ensure-AppPool",
    "Copy-GcsObjectToFile",
]


def function_body(text, name):
    """Every `function <name>` in `text`, cut at its matching close brace.

    Brace matching rather than a cut at the next `function ` keyword: several of
    these are the last function in their file, and a keyword cut runs to the end
    of the file and reports two copies as different when they are not.
    """
    bodies = []
    for match in re.finditer(rf"^[ \t]*function {re.escape(name)}\b", text, re.MULTILINE):
        opening = text.find("{", match.start())
        if opening == -1:
            continue
        depth, index = 0, opening
        while index < len(text):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        bodies.append(text[match.start(): index + 1])
    return bodies


def normalized(body):
    """A body reduced to what its behaviour depends on.

    Indentation and blank lines go, because the bootstrap copy sits inside a YAML
    here-string at a different depth. The backtick before `$` goes for the same
    reason: it is the here-string escaping itself, not part of the script the VM
    runs.
    """
    body = body.replace("`$", "$")
    lines = [line.strip() for line in body.splitlines()]
    return "\n".join(line for line in lines if line)


class SharedHelperTests(harness.HarnessAssertions, unittest.TestCase):
    """The helpers copied between scripts, which nothing else holds together."""

    def test_every_copy_of_each_helper_is_the_same_function(self):
        for name, expected_files in SHARED_HELPERS.items():
            with self.subTest(helper=name):
                found = []
                for filename in expected_files:
                    path = DEPLOY_DIR / filename
                    bodies = function_body(path.read_text(), name)
                    self.assertEqual(
                        1,
                        len(bodies),
                        f"expected exactly one `{name}` in {filename}, found {len(bodies)}",
                    )
                    found.append((filename, normalized(bodies[0])))

                self.assertOneShape(
                    found,
                    f"`{name}`",
                    "These are copies on purpose -- a module cannot reach the VM -- "
                    "so nothing but this test keeps them in step.",
                )

    def test_the_expected_files_are_the_ones_that_carry_each_helper(self):
        actual = {name: [] for name in SHARED_HELPERS}
        for path in sorted(DEPLOY_DIR.glob("*.ps1")):
            text = path.read_text()
            for name in SHARED_HELPERS:
                if function_body(text, name):
                    actual[name].append(path.name)

        for name, expected in SHARED_HELPERS.items():
            self.assertEqual(
                sorted(expected),
                sorted(actual[name]),
                f"the set of scripts defining `{name}` changed. Update "
                "SHARED_HELPERS so a new copy is held to the others rather than "
                "drifting unwatched.",
            )

    def test_the_divergent_pair_is_not_quietly_pinned(self):
        # A guard against this module over-reaching later. These five differ
        # between the PR and Rock deploy scripts for real reasons, and a future
        # edit that moves one into SHARED_HELPERS should have to delete this line
        # and think about it first.
        for name in DELIBERATELY_DIVERGENT:
            self.assertNotIn(
                name,
                SHARED_HELPERS,
                f"`{name}` differs between the PR and Rock deploy scripts on "
                "purpose. Pinning it identical asserts a sameness that is not true.",
            )


class BootstrapCopyTests(harness.HarnessAssertions, unittest.TestCase):
    """The copy inside the VM startup script, which no module could ever replace."""

    def test_the_bootstrap_token_helper_matches_the_scripts_it_installs(self):
        workflow_text = BOOTSTRAP_WORKFLOW.read_text()
        bootstrap = function_body(workflow_text, "Get-GcsAccessToken")
        self.assertEqual(
            1,
            len(bootstrap),
            "the VM startup script no longer defines `Get-GcsAccessToken` inline. "
            "It has to: that function is what fetches every other script onto the "
            "box, so it cannot come from one of them.",
        )

        reference = function_body(
            (DEPLOY_DIR / "Invoke-PrEnvironmentCommandQueue.ps1").read_text(),
            "Get-GcsAccessToken",
        )[0]
        self.assertEqual(
            normalized(reference),
            normalized(bootstrap[0]),
            "the bootstrap's inline `Get-GcsAccessToken` has drifted from the one "
            "in the scripts it installs. This copy is the only one that cannot be "
            "removed by any refactor, and it is the one nothing else watches.",
        )

    def test_the_bootstrap_still_cannot_discover_a_module(self):
        # The reason the helpers above are copies rather than a shared `.psm1`.
        # If this filter ever learns about `.psm1`, the trade in Card 03 is worth
        # reopening -- and this test is where the next reader should find that out.
        workflow_text = BOOTSTRAP_WORKFLOW.read_text()
        self.assertIn(
            "-like '*.ps1'",
            workflow_text,
            "the bootstrap's script-discovery filter changed shape. It used to "
            "exclude `.psm1`, which is why the shared helpers are copied by hand.",
        )


class GuardTests(unittest.TestCase):
    """Prove the comparison can fail, rather than trusting that it would."""

    def test_normalisation_ignores_layout_but_not_behaviour(self):
        base = "function F {\n    if (!(Test-Path $p)) {\n        New-Item $p\n    }\n}"
        reindented = "function F {\n\n  if (!(Test-Path `$p)) {\n\n      New-Item `$p\n  }\n}"
        changed = "function F {\n    if (Test-Path $p) {\n        New-Item $p\n    }\n}"
        self.assertEqual(normalized(base), normalized(reindented))
        self.assertNotEqual(normalized(base), normalized(changed))

    def test_brace_matching_stops_at_the_end_of_the_function(self):
        text = "function A {\n    if ($x) { $y }\n}\n$trailing = 1\n"
        self.assertEqual(["function A {\n    if ($x) { $y }\n}"], function_body(text, "A"))


if __name__ == "__main__":
    unittest.main()
