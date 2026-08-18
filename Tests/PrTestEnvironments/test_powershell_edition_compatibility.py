import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_DIR = REPO_ROOT / "Deployment" / "PrTestEnvironments"

# Every script in Deployment/PrTestEnvironments runs on the test VM under the command
# queue scheduled task, which is Windows PowerShell 5.1 -- the edition that ships with
# Windows Server. It is not PowerShell 7 and there is no pwsh on the box. A 6+ only
# construct therefore does not fail review, does not fail CI, and does not fail at
# install: it fails at the moment an operator runs the verb, with a parameter-binding
# error that reads like a typo.
#
# Each entry is (pattern, what to write instead). Deliberately a short curated list
# rather than a general "is this 7-only" analysis -- a scan that guesses produces false
# positives, and a test with false positives gets widened until it matches nothing.
SEVEN_ONLY = [
    (
        re.compile(r"ConvertFrom-Json\b[^\n|;]*\s-AsHashtable\b"),
        "-AsHashtable is 6+. Convert the PSCustomObject that 5.1 returns into a "
        "hashtable explicitly (see ConvertTo-ManifestHashtable).",
    ),
    (
        re.compile(r"ForEach-Object\b[^\n|;]*\s-Parallel\b"),
        "-Parallel is 7+. Use a sequential foreach, or Start-Job.",
    ),
    (
        re.compile(r"Get-Content\b[^\n|;]*\s-AsByteStream\b"),
        "-AsByteStream is 6+. 5.1 spells it -Encoding Byte.",
    ),
    (
        re.compile(r"(?<![\w-])Test-Json(?![\w-])"),
        "Test-Json is 6+. Wrap ConvertFrom-Json in try/catch instead.",
    ),
    (
        re.compile(r"\?\?=?[^\S\n]"),
        "?? and ??= are 7+. Use an if/else or a ternary-free default assignment.",
    ),
]


def _strip_comments(text):
    """Drop block comments and line comments so a construct *named in prose* is not
    reported as a use of it. The fixes for these bugs explain themselves in comments,
    and several of those comments have to quote the very parameter they replaced --
    without this, adding the explanation would re-fail the test that motivated it.

    Quote handling is deliberately shallow: a `#` inside a string literal ends the line
    early here. That can only ever hide a real match, never invent one, and no script in
    this directory puts one of these constructs after a `#` in a string.

    Block comments are replaced by their own newlines rather than deleted, so the line
    numbers in a failure still point at the offending line in the real file. Collapsing
    them instead reported Invoke-SandboxRefreshWithPrEnvironments.ps1:80 for a bug that
    lives on line 89, which sends the reader to an unrelated line."""
    text = re.sub(
        r"<#.*?#>",
        lambda match: "\n" * match.group(0).count("\n"),
        text,
        flags=re.DOTALL,
    )
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class PowerShellEditionCompatibilityTests(unittest.TestCase):
    def test_deployment_scripts_avoid_powershell_7_only_constructs(self):
        offenders = []

        for script in sorted(SCRIPT_DIR.glob("*.ps1")):
            body = _strip_comments(script.read_text())
            for lineno, line in enumerate(body.splitlines(), start=1):
                for pattern, remedy in SEVEN_ONLY:
                    if pattern.search(line):
                        offenders.append(f"{script.name}:{lineno}: {remedy}")

        self.assertEqual(
            offenders,
            [],
            "PowerShell 7-only syntax in scripts that run under Windows PowerShell 5.1:"
            "\n  " + "\n  ".join(offenders),
        )

    def test_the_scan_would_have_caught_the_ashashtable_bug(self):
        """Guard against the scan being satisfied by an empty directory or a regex that
        stopped matching. This is the exact line that shipped in three scripts and made
        `rock:stop` fail every time it was invoked."""
        shipped = '        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json -AsHashtable'

        hits = [remedy for pattern, remedy in SEVEN_ONLY if pattern.search(shipped)]
        self.assertEqual(len(hits), 1, f"the shipped bug line no longer matches: {shipped}")
        self.assertIn("-AsHashtable is 6+", hits[0])

    def test_the_scan_reads_real_files(self):
        """A glob that matches nothing makes the main test vacuously green."""
        scripts = list(SCRIPT_DIR.glob("*.ps1"))
        self.assertGreaterEqual(len(scripts), 8, f"only found {len(scripts)} scripts to scan")

    def test_comments_may_name_the_construct_they_replaced(self):
        """The remedy for each of these bugs is worth explaining in place, and the
        explanation has to say which parameter it replaced. If the scan read comments,
        documenting the fix would reintroduce the failure."""
        commented = "\n".join([
            "# ConvertFrom-Json -AsHashtable is 6+ and fails on 5.1.",
            "<# also -AsHashtable in a block comment #>",
            "$manifest = ConvertTo-ManifestHashtable -Json $raw",
        ])

        body = _strip_comments(commented)
        for pattern, _ in SEVEN_ONLY:
            self.assertIsNone(
                pattern.search(body),
                "the scan flagged a construct that only appears inside a comment",
            )

    def test_failures_report_the_real_line_number(self):
        """A stripper that deletes block comments instead of preserving their newlines
        still finds the bug, but points the reader at an unrelated line. That is how
        this scan first reported the sandbox-refresh bug nine lines above where it
        actually lives."""
        body = "\n".join([
            "$SiteName = 'rock'",
            "<#",
            "  a block comment",
            "  spanning several lines",
            "#>",
            "$m = $raw | ConvertFrom-Json -AsHashtable",
        ])

        matching = [
            lineno
            for lineno, line in enumerate(_strip_comments(body).splitlines(), start=1)
            if any(pattern.search(line) for pattern, _ in SEVEN_ONLY)
        ]
        self.assertEqual(matching, [6], "the reported line drifted from the source line")

    def test_a_real_use_next_to_a_comment_is_still_caught(self):
        """The complement of the test above -- stripping comments must not swallow code
        that shares the line with one."""
        body = _strip_comments("$m = $raw | ConvertFrom-Json -AsHashtable  # legacy read")

        self.assertTrue(
            any(pattern.search(body) for pattern, _ in SEVEN_ONLY),
            "a genuine use was hidden because a trailing comment followed it",
        )


if __name__ == "__main__":
    unittest.main()
