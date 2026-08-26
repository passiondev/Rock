"""Keep the recorded decisions and the code that depends on them pointing at each other.

Card 06 of the 2026-08-26 architecture review: three times a review has proposed a
change this pipeline had already rejected for a reason that still holds. Twice the
reason was caught, both times because the reviewer happened to open a test whose
docstring carried it. The third got as far as a written card and a started
implementation before the reason surfaced -- that was card 04 of the same review,
withdrawn mid-flight once the scan it would have blinded was traced.

A docstring is the wrong home for that reasoning. Whoever edits the test reads it.
Whoever proposes changing the design does not open the test.

So the reasons moved to `Documentation/adr/`, and this file is what stops the move
from decaying into a directory nobody reads. It holds two directions in step:

- a citation the tree makes must name a record that exists, and
- a record that exists must be cited from the code it governs.

The second is the one that matters. An ADR nothing points at is invisible exactly
when it is needed, which is the failure this whole card is about, moved one level up.
"""

import pathlib
import re
import unittest

import pipeline_harness as harness

REPO_ROOT = harness.REPO_ROOT
ADR_DIR = REPO_ROOT / "Documentation" / "adr"
ADR_README = REPO_ROOT / "Documentation" / "adr" / "README.md"

# `ADR-0001`, the form the prose uses, and the form a citation must take. Matched
# case-sensitively: a lowercase `adr-0001` is a typo, and quietly accepting it means
# the citation check passes on a string no reader will follow.
CITATION = re.compile(r"ADR-(\d{4})")

# A record is a decision, not a rule, and the difference is whether it says what
# would change its mind. Anything without the last heading is a rule in ADR clothing.
REQUIRED_HEADINGS = (
    "## Context",
    "## Decision",
    "## Consequences",
    "## What would reopen this",
)

# The header fields every record carries. `Enforced by` is load-bearing rather than
# decorative: it is what the second direction of the citation check reads.
REQUIRED_FIELDS = (
    "- **Status:**",
    "- **Date:**",
    "- **Governs:**",
    "- **Enforced by:**",
)


def adr_files():
    """Every record in the directory, README excluded, ordered by number."""
    return sorted(path for path in ADR_DIR.glob("*.md") if path.name != "README.md")


def adr_number(path):
    """The four-digit number a record's filename starts with."""
    return path.name.split("-", 1)[0]


def cited_files_of(path):
    """Repository-relative paths a record names in its `Enforced by:` field."""
    for line in path.read_text().splitlines():
        if not line.startswith("- **Enforced by:**"):
            continue
        return re.findall(r"`([^`]+)`", line)
    return []


class RecordShapeTests(harness.HarnessAssertions, unittest.TestCase):
    """Each record carries the sections that make it a decision rather than a rule."""

    def test_there_are_records_to_check(self):
        self.assertNotVacuous(
            adr_files(),
            f"{ADR_DIR} holds no records, so every other test in this file passes "
            "by finding nothing.",
        )

    def test_every_record_says_what_would_reopen_it(self):
        for path in adr_files():
            with self.subTest(record=path.name):
                text = path.read_text()
                for heading in REQUIRED_HEADINGS:
                    self.assertIn(
                        heading,
                        text,
                        f"{path.name} has no `{heading}` section. A record that does "
                        "not say what would change its mind is a rule, and a rule "
                        "with no stated cost gets followed until it is wrong.",
                    )

    def test_every_record_names_what_enforces_it(self):
        for path in adr_files():
            with self.subTest(record=path.name):
                text = path.read_text()
                for field in REQUIRED_FIELDS:
                    self.assertIn(
                        field,
                        text,
                        f"{path.name} is missing its `{field}` header field.",
                    )

    def test_every_record_is_numbered_uniquely(self):
        numbers = [adr_number(path) for path in adr_files()]
        self.assertNotVacuous(numbers, "no records found")
        duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
        self.assertEqual(
            [],
            duplicates,
            f"two records share a number: {duplicates}. A citation of `ADR-{duplicates}` "
            "would be ambiguous.",
        )

    def test_the_index_lists_every_record(self):
        index = ADR_README.read_text()
        for path in adr_files():
            with self.subTest(record=path.name):
                self.assertIn(
                    f"({path.name})",
                    index,
                    f"{path.name} is not linked from {ADR_README.name}, so it is only "
                    "reachable by listing the directory.",
                )


class CitationTests(harness.HarnessAssertions, unittest.TestCase):
    """The tree and the records point at each other, in both directions."""

    def _tree_text(self):
        """(path, text) for every tracked file that could carry a citation.

        Records themselves are excluded: ADR-0002 citing ADR-0001 would satisfy the
        `is it cited` check without a line of code depending on either."""
        searched = sorted(
            {
                *harness.tracked_under(REPO_ROOT / "Tests" / "PrTestEnvironments"),
                *harness.tracked_under(REPO_ROOT / ".github"),
                *harness.tracked_under(REPO_ROOT / "Deployment"),
                *harness.tracked_under(REPO_ROOT / "Documentation"),
            }
        )

        out = []
        for relative in searched:
            path = REPO_ROOT / relative
            if path.is_relative_to(ADR_DIR):
                continue
            try:
                out.append((relative, path.read_text()))
            except (UnicodeDecodeError, OSError):
                continue
        return out

    def test_every_citation_names_a_record_that_exists(self):
        numbers = {adr_number(path) for path in adr_files()}
        self.assertNotVacuous(numbers, "no records found")

        dangling = []
        for relative, text in self._tree_text():
            for cited in set(CITATION.findall(text)):
                if cited not in numbers:
                    dangling.append(f"{relative} cites ADR-{cited}")

        self.assertEqual(
            [],
            sorted(dangling),
            "a citation names a record that is not in Documentation/adr. Either the "
            "record was renumbered or it was never written, and the reader following "
            "the citation finds nothing.",
        )

    def test_every_record_is_cited_from_the_code_it_governs(self):
        cited = set()
        for _, text in self._tree_text():
            cited.update(CITATION.findall(text))

        self.assertNotVacuous(cited, "nothing in the tree cites any record at all")

        uncited = sorted(
            adr_number(path) for path in adr_files() if adr_number(path) not in cited
        )
        self.assertEqual(
            [],
            uncited,
            f"ADR {uncited} is not cited anywhere outside Documentation/adr. Nobody "
            "reads a directory of records on a hunch. The reasoning is only found if "
            "the code that depends on it points at the record.",
        )

    def test_the_file_each_record_names_as_its_enforcer_exists_and_cites_it(self):
        for path in adr_files():
            enforcers = cited_files_of(path)
            with self.subTest(record=path.name):
                self.assertNotVacuous(
                    enforcers,
                    f"{path.name} names no file in its `Enforced by:` field, so "
                    "nothing fails when the decision is undone.",
                )

                number = adr_number(path)
                for enforcer in enforcers:
                    enforcing_file = REPO_ROOT / enforcer
                    if not enforcing_file.exists():
                        # The field also names a class inside a file. Only check the
                        # entries that look like a path.
                        self.assertNotIn(
                            "/",
                            enforcer,
                            f"{path.name} says `{enforcer}` enforces it and no such "
                            "file exists.",
                        )
                        continue

                    self.assertIn(
                        f"ADR-{number}",
                        enforcing_file.read_text(),
                        f"{path.name} names {enforcer} as its enforcer, but that file "
                        f"never mentions ADR-{number}. The link has to run both ways "
                        "or the reader arrives at the guard without the reason.",
                    )


if __name__ == "__main__":
    unittest.main()
