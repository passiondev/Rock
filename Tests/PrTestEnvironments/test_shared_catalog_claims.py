"""One guard for one fact: the shared catalog is a straight copy of production.

The claim that it is sanitized was written into six operational surfaces and
corrected in two of them on 2026-08-19. The correction was pinned by
`test_runbooks.py` and `test_status_comment_script.py`, but each of those reads
exactly one file, so the four uncorrected copies stayed green for two days --
including the pull request template, which every contributor reads, and the
operator runbook, which reasons from `sanitized` to "the exposure is bounded"
while describing a firewall that is open to the internet.

A per-file pin cannot catch that. This test names the surfaces instead, so the
next surface added is a line in one list rather than a file nobody thought of.
"""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# Everything an engineer or an operator reads to decide how to treat what they
# see in a PR environment. Requirement documents under `Discussion Docs` are
# deliberately absent: the PRD records what was asked for, carries its own
# status note saying the sanitization step does not exist, and is preserved as
# written rather than edited to match reality.
CATALOG_SURFACES = [
    "Documentation/PR-Test-Environments-Developer-Runbook.md",
    "Documentation/PR-Test-Environments-Operator-Runbook.md",
    "Documentation/Local-Engineering-Training-Edit-Test-and-Deploy.md",
    "Documentation/Training/Facilitator-Script-Rock-CICD-Training.md",
    "Documentation/Training/rock-cicd-training-deck.html",
    "Documentation/Training/rock-cicd-cheat-sheet.html",
    ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/scripts/pr-test-status.js",
]

# Claims that the data is safe to treat casually. Each of these was in the tree.
UNSAFE_CLAIMS = [
    (r"sanitized sandbox", "calls the catalog a sanitized sandbox"),
    (r"shared,?\s+sanitized", "calls the catalog shared and sanitized"),
    (r"sanitized,\s*daily-refreshed", "calls the catalog sanitized and daily-refreshed"),
    (r"[Ii]t'?s sanitized", "says the catalog is sanitized"),
    (r"with sanitized data", "says the environments hold sanitized data"),
    (r"same sanitized data", "says the catalog holds sanitized data"),
    (r"is not real", "says the data is not real"),
    (r"cannot see production data", "says the environments cannot see production data"),
]

# Claims that the catalog resets. It has had no data load since 2026-04-14 and
# no scheduler exists, so anything promising a refresh tells the reader their
# test data will disappear when it will not, and that the drift self-corrects
# when it does not.
UNSAFE_REFRESH_CLAIMS = [
    (r"wiped by a sandbox refresh", "promises a sandbox refresh that does not exist"),
    (r"daily[- ]refreshed", "promises a daily refresh that does not exist"),
    (r"refreshed (from production )?(on a )?dail", "promises a daily refresh that does not exist"),
]


class SharedCatalogClaimTests(unittest.TestCase):
    def surface_texts(self):
        for relative in CATALOG_SURFACES:
            path = REPO_ROOT / relative
            self.assertTrue(path.exists(), f"{relative} is listed as a catalog surface but does not exist")
            yield relative, path.read_text(encoding="utf-8")

    def test_no_surface_calls_the_catalog_sanitized(self):
        offenders = []
        for relative, text in self.surface_texts():
            for pattern, why in UNSAFE_CLAIMS:
                for match in re.finditer(pattern, text):
                    line = text.count("\n", 0, match.start()) + 1
                    offenders.append(f"{relative}:{line} {why} ({match.group(0)!r})")

        self.assertFalse(offenders, "the catalog is a straight copy of production:\n  " + "\n  ".join(offenders))

    def test_no_surface_promises_a_refresh(self):
        offenders = []
        for relative, text in self.surface_texts():
            for pattern, why in UNSAFE_REFRESH_CLAIMS:
                for match in re.finditer(pattern, text):
                    line = text.count("\n", 0, match.start()) + 1
                    # The correction itself has to be able to name the thing it
                    # is correcting, so allow a match that is being denied.
                    window = text[max(0, match.start() - 120):match.start()]
                    if re.search(r"not\b|never|no\b|despite|until 2026", window):
                        continue
                    line_text = text.splitlines()[line - 1].strip()
                    offenders.append(f"{relative}:{line} {why} ({line_text[:90]!r})")

        self.assertFalse(offenders, "the catalog has had no data load since 2026-04-14:\n  " + "\n  ".join(offenders))

    def test_the_surfaces_a_contributor_reads_first_carry_the_correction(self):
        """Absence of the false claim is not the same as presence of the true
        one. These three are where somebody decides whether to paste a
        screenshot into a ticket, so they have to say it outright."""
        required = {
            "Documentation/PR-Test-Environments-Developer-Runbook.md": "not sanitized",
            ".github/PULL_REQUEST_TEMPLATE.md": "real\ncongregant data",
            ".github/scripts/pr-test-status.js": "not a sanitized one",
        }
        for relative, needle in required.items():
            text = (REPO_ROOT / relative).read_text(encoding="utf-8")
            self.assertIn(
                needle,
                text,
                f"{relative} does not tell the reader the catalog holds real congregant data",
            )


if __name__ == "__main__":
    unittest.main()
