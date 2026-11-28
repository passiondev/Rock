"""Hold the copied PowerShell helpers identical across the deploy scripts.

`Deployment/PrTestEnvironments/` holds twelve PowerShell scripts and no shared
module. Several carry the same helper functions, copied rather than shared. That
is on purpose, and ADR-0001 has the three reasons. The short form: the bootstrap
publishes with a `*.ps1` glob that no `.psm1` matches, a half-applied publish would
break every command on the VM rather than one, and the copy in the VM startup
script runs before any module could reach the machine.

Two architecture reviews have proposed the module anyway. Both read the code, and
neither had a way to reach the reasoning, which is why it is an ADR now.

What the decision was missing is any check that the copies agree, which is what
this module is. Bodies are compared after whitespace is normalised, because the
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

# Two roots, because the copies that matter most cross between them. The queue's
# redaction rule has to be the same sentence on the producer -- whose PowerShell
# sits beside its action.yml under `.github/actions/` per ADR-0002 -- and on the
# agent under Deployment/. This module only ever looked at the second, so the
# producer keyed on the shape of a field name while the agent carried a list of
# two known ones, and nothing here could see the pair to compare them.
HELPER_ROOTS = (
    DEPLOY_DIR,
    harness.REPO_ROOT / ".github" / "actions",
)


def helper_scripts():
    """`{repo-relative path: path}` for every script that could carry a copy."""
    found = {}
    for root in HELPER_ROOTS:
        for path in sorted(root.rglob("*.ps1")):
            found[path.relative_to(harness.REPO_ROOT).as_posix()] = path
    return found

# Each helper, and every file expected to carry a copy. Listing the files rather
# than counting them means a new copy appearing somewhere unexpected is a failure
# that names itself, instead of a number quietly going up.
DEPLOYMENT = "Deployment/PrTestEnvironments"
QUEUE_ACTION = ".github/actions/queue-vm-command"

SHARED_HELPERS = {
    "Get-GcsAccessToken": [
        f"{DEPLOYMENT}/Deploy-PrEnvironment.ps1",
        f"{DEPLOYMENT}/Deploy-RockEnvironment.ps1",
        f"{DEPLOYMENT}/Invoke-PrEnvironmentCommandQueue.ps1",
    ],
    "ConvertTo-ManifestHashtable": [
        f"{DEPLOYMENT}/Invoke-PrEnvironmentCleanup.ps1",
        f"{DEPLOYMENT}/Invoke-SandboxRefreshWithPrEnvironments.ps1",
        f"{DEPLOYMENT}/Stop-PrEnvironment.ps1",
    ],
    "Ensure-Directory": [
        f"{DEPLOYMENT}/Deploy-PrEnvironment.ps1",
        f"{DEPLOYMENT}/Deploy-RockEnvironment.ps1",
        f"{DEPLOYMENT}/Invoke-PrEnvironmentCertificateRenewal.ps1",
        f"{DEPLOYMENT}/Invoke-SandboxRefreshWithPrEnvironments.ps1",
        f"{DEPLOYMENT}/Set-PrEnvironmentRuntimeConfiguration.ps1",
    ],
    "Expand-ArtifactArchive": [
        f"{DEPLOYMENT}/Deploy-PrEnvironment.ps1",
        f"{DEPLOYMENT}/Deploy-RockEnvironment.ps1",
    ],
    "Remove-DirectoryFast": [
        f"{DEPLOYMENT}/Deploy-PrEnvironment.ps1",
        f"{DEPLOYMENT}/Deploy-RockEnvironment.ps1",
    ],
    "Add-DeployDefenderExclusions": [
        f"{DEPLOYMENT}/Deploy-PrEnvironment.ps1",
        f"{DEPLOYMENT}/Deploy-RockEnvironment.ps1",
    ],
    # The two halves of what "redacted" means, one on each side of the queue.
    # These are the reason HELPER_ROOTS has a second entry.
    "Get-SecretFieldNamePattern": [
        f"{DEPLOYMENT}/Invoke-PrEnvironmentCommandQueue.ps1",
        f"{QUEUE_ACTION}/Write-VmCommand.ps1",
    ],
    "Get-PasswordValuePattern": [
        f"{DEPLOYMENT}/Invoke-PrEnvironmentCommandQueue.ps1",
        f"{QUEUE_ACTION}/Write-VmCommand.ps1",
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
                scripts = helper_scripts()
                for filename in expected_files:
                    self.assertIn(filename, scripts, f"{filename} is not under any HELPER_ROOTS")
                    bodies = function_body(scripts[filename].read_text(), name)
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
        for relative, path in helper_scripts().items():
            text = path.read_text()
            for name in SHARED_HELPERS:
                if function_body(text, name):
                    actual[name].append(relative)

        for name, expected in SHARED_HELPERS.items():
            self.assertEqual(
                sorted(expected),
                sorted(actual[name]),
                f"the set of scripts defining `{name}` changed. Update "
                "SHARED_HELPERS so a new copy is held to the others rather than "
                "drifting unwatched.",
            )

    def test_every_helper_duplicated_in_the_tree_is_accounted_for(self):
        """The two lists above are hand-kept, and the sweep that uses them only
        looks at the names they already hold.

        So the guard knows which files carry `Ensure-Directory` and says nothing at
        all about a tenth helper someone copies into a second script tomorrow. That
        copy is exactly the thing ADR-0001 traded a shared module for a test to
        catch, and it would arrive unwatched.

        Derived from the tree, so the failure names the new helper rather than a
        count. A copy is either held identical or declared divergent on purpose --
        there is no third state, and this is the line that says so."""
        defined = {}
        for relative, path in helper_scripts().items():
            text = path.read_text()
            for match in re.finditer(r"^[ \t]*function\s+([A-Za-z]+-[A-Za-z0-9]+)", text, re.MULTILINE):
                defined.setdefault(match.group(1), set()).add(relative)

        duplicated = {name for name, files in defined.items() if len(files) > 1}
        self.assertNotVacuous(duplicated, "no helper appears in two scripts, so this check compares nothing")

        accounted = set(SHARED_HELPERS) | set(DELIBERATELY_DIVERGENT)
        unwatched = sorted(duplicated - accounted)
        self.assertEqual(
            [],
            unwatched,
            "these helpers are defined in more than one deploy script and neither "
            "list mentions them, so nothing holds the copies together:\n  "
            + "\n  ".join(f"{name} in {', '.join(sorted(defined[name]))}" for name in unwatched),
        )

        stale = sorted(name for name in DELIBERATELY_DIVERGENT if name not in duplicated)
        self.assertEqual(
            [],
            stale,
            "these are declared divergent but no longer appear in two scripts, so "
            "the declaration is stale: " + ", ".join(stale),
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
