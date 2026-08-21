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

import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT

# Everything an engineer or an operator reads to decide how to treat what they
# see in a PR environment. Requirement documents under `Discussion Docs` are
# deliberately absent: the PRD records what was asked for, carries its own
# status note saying the sanitization step does not exist, and is preserved as
# written rather than edited to match reality.
#
# Written out one quoted segment at a time, rather than as a list of
# slash-joined strings, because that literal form is the only one
# test_ci_trigger_coverage.py can see. Built from strings, these eight surfaces
# were invisible to it, so the CI trigger was never checked against them -- they
# were covered only because `.github/**` and `Documentation/**` happened to be
# wide enough.
CATALOG_SURFACES = [
    REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md",
    REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md",
    REPO_ROOT / "Documentation" / "Local-Engineering-Training-Edit-Test-and-Deploy.md",
    REPO_ROOT / "Documentation" / "Training" / "Facilitator-Script-Rock-CICD-Training.md",
    REPO_ROOT / "Documentation" / "Training" / "rock-cicd-training-deck.html",
    REPO_ROOT / "Documentation" / "Training" / "rock-cicd-cheat-sheet.html",
    REPO_ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md",
    REPO_ROOT / ".github" / "scripts" / "pr-test-status.js",
    REPO_ROOT / "Documentation" / "Making-A-Change-To-Rock.md",
]

# Files that talk about PR environments and are still not catalog surfaces. Each
# is here for a reason that does not expire, and the sweep below fails on anything
# that is neither listed above nor excluded here -- so a new runbook is a red build
# rather than a file nobody thought of.
NOT_A_SURFACE = {
    # Requirement documents record what was asked for. The PRD carries its own
    # status note saying the sanitization step does not exist, and editing it to
    # match reality would destroy the evidence of what was assumed.
    "Documentation/Discussion Docs",
    # An incident report is a record of a moment. Correcting its wording forward
    # would make it describe a system that is not the one the incident happened to.
    "Documentation/Incidents",
    # The open-items log quotes the wrong wording in order to record that it was
    # corrected. A guard against the claim cannot run over the document that
    # explains the guard.
    "Documentation/Training/DevOps-Open-Items-Rock-CICD.md",
}

# What makes a file a candidate: it is prose an engineer or operator reads, and it
# mentions the thing. Extensions rather than a directory, because the surfaces are
# already split across Documentation/ and .github/.
CANDIDATE_SUFFIXES = {".md", ".html", ".js"}
CANDIDATE_MENTION = re.compile(r"shared catalog|PR environment|PR test environment", re.IGNORECASE)

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


class SharedCatalogClaimTests(harness.HarnessAssertions, unittest.TestCase):
    def surface_texts(self):
        """(repository-relative name, contents) for every listed catalog surface.

        The name rather than the path, because it is what the failure messages
        print and an absolute path from somebody else's machine is noise."""
        for path in CATALOG_SURFACES:
            relative = path.relative_to(REPO_ROOT).as_posix()
            self.assertTrue(path.exists(), f"{relative} is listed as a catalog surface but does not exist")
            yield relative, path.read_text(encoding="utf-8")

    def test_every_document_that_mentions_the_catalog_is_accounted_for(self):
        """The list above is the thing this module is, and a list goes stale.

        Naming the surfaces is what let one guard replace six per-file pins, and it
        is also the weakness: a runbook added next month is not on it, so it is not
        checked, and nothing says so. This sweeps the two directories the surfaces
        live in and requires every candidate to be either listed or excluded on
        purpose. `Making-A-Change-To-Rock.md` is the one it found -- a live document
        engineers are pointed at, never checked, carrying no claim today and nothing
        stopping one from being added."""
        listed = {path.relative_to(REPO_ROOT).as_posix() for path in CATALOG_SURFACES}
        candidates, unaccounted = [], []

        for directory in ("Documentation", ".github"):
            for path in sorted((REPO_ROOT / directory).rglob("*")):
                if not path.is_file() or path.suffix.lower() not in CANDIDATE_SUFFIXES:
                    continue
                relative = path.relative_to(REPO_ROOT).as_posix()
                if not CANDIDATE_MENTION.search(path.read_text(encoding="utf-8", errors="ignore")):
                    continue
                candidates.append(relative)
                if relative in listed:
                    continue
                if any(relative == skip or relative.startswith(skip + "/") for skip in NOT_A_SURFACE):
                    continue
                unaccounted.append(relative)

        self.assertNotVacuous(candidates, "nothing under Documentation/ or .github/ mentions the catalog")
        self.assertEqual(
            [],
            unaccounted,
            "these describe PR environments and are neither checked as a catalog "
            "surface nor excluded from being one -- add to CATALOG_SURFACES, or to "
            "NOT_A_SURFACE with the reason:\n  " + "\n  ".join(unaccounted),
        )

    def test_no_surface_calls_the_catalog_sanitized(self):
        offenders = []
        for relative, text in self.surface_texts():
            for pattern, why in UNSAFE_CLAIMS:
                for match in re.finditer(pattern, text):
                    line = harness.line_of(text, match.start())
                    offenders.append(f"{relative}:{line} {why} ({match.group(0)!r})")

        self.assertFalse(offenders, "the catalog is a straight copy of production:\n  " + "\n  ".join(offenders))

    def test_no_surface_promises_a_refresh(self):
        offenders = []
        for relative, text in self.surface_texts():
            for pattern, why in UNSAFE_REFRESH_CLAIMS:
                for match in re.finditer(pattern, text):
                    line = harness.line_of(text, match.start())
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
        # Written out one quoted segment at a time for the same reason the module
        # header gives: joined from a string, these three paths are invisible to
        # test_ci_trigger_coverage.py and nothing checks the CI trigger against them.
        required = [
            (REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md", "not sanitized"),
            (REPO_ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md", "real\ncongregant data"),
            (REPO_ROOT / ".github" / "scripts" / "pr-test-status.js", "not a sanitized one"),
        ]
        for path, needle in required:
            relative = path.relative_to(REPO_ROOT).as_posix()
            text = path.read_text(encoding="utf-8")
            self.assertIn(
                needle,
                text,
                f"{relative} does not tell the reader the catalog holds real congregant data",
            )


if __name__ == "__main__":
    unittest.main()
