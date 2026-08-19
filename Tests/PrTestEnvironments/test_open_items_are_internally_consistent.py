"""DevOps-Open-Items-Rock-CICD.md is a hand-maintained register, and its two
hand-maintained structures are the ones that break.

The item numbers are stable ids, deliberately not in document order -- items are
grouped by priority and renumbering them would invalidate every cross-reference in
the file and in the runbooks. That makes "item 25" a link, and links rot: a forward
reference written for an item that did not exist yet pointed at item 27, which by
then was a real and completely unrelated item. Nothing said so.

The Suggested order is a numbered list somebody renumbers by hand whenever an entry
is inserted. Inserting item 25 at position 10 on 2026-08-19 meant shifting five
entries down by one, in a file where two entries already spanned several lines.

Both checks here are purely structural. There is deliberately no test that a "done"
item has left the Suggested order, even though a stale entry there is exactly the
drift found on 2026-08-19 -- the order still said to enable backups that had been
enabled the day before. Completion is recorded in prose (`**Fixed`, `> **Done.**`,
`**Half fixed`, `**Root cause found ... and proven`), and two items are legitimately
finished-and-still-listed: item 23 is done for the 19.3.4 cutover and kept as
pre-work for the next one, and item 15's branch question is settled while its
migration is not. A regex over that prose would fail on both for the wrong reason,
which is the failure mode this suite keeps rediscovering: an assertion pinned next
to the thing it means to guard rather than on it.
"""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
OPEN_ITEMS = REPO_ROOT / "Documentation" / "Training" / "DevOps-Open-Items-Rock-CICD.md"
DOCS_DIR = REPO_ROOT / "Documentation"

ITEM_HEADING = re.compile(r"^### (\d+)\. (.+)$", re.M)
ORDER_ENTRY = re.compile(r"^(\d+)\. ", re.M)

# "item 7", "Item 25", "items 5, 6 and 18", "Items 10-13". The second group catches
# only the last number of a list or range, which is all these checks need: a range's
# endpoints must exist, and a bucket's interior members are covered by the endpoints.
ITEM_REFERENCE = re.compile(r"\b[Ii]tems? (\d+)(?:\s*(?:,|and|–|-)\s*(\d+))?")


def _defined_items():
    return {int(number): title for number, title in ITEM_HEADING.findall(OPEN_ITEMS.read_text())}


def _suggested_order():
    text = OPEN_ITEMS.read_text()
    heading = "## Suggested order"
    assert heading in text, "the Suggested order section has been renamed or removed"
    return text.split(heading, 1)[1]


class ItemNumbersAreCompleteTests(unittest.TestCase):
    def test_item_numbers_have_no_gaps_or_duplicates(self):
        """Stable ids only work if they are unique. Two items numbered the same makes
        every reference to that number ambiguous, and a gap usually means an item was
        deleted rather than marked fixed -- this file keeps fixed items."""
        numbers = [int(number) for number, _ in ITEM_HEADING.findall(OPEN_ITEMS.read_text())]

        duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
        self.assertEqual([], duplicates, f"these item numbers are used more than once: {duplicates}")

        self.assertEqual(
            list(range(1, len(numbers) + 1)),
            sorted(numbers),
            "item numbers are not 1..N with no gaps -- an item was deleted rather than "
            "marked fixed, or a new one reused or skipped a number",
        )


class ItemReferencesResolveTests(unittest.TestCase):
    def test_every_item_reference_in_the_documentation_names_a_real_item(self):
        """A reference to an item that does not exist yet silently becomes a reference
        to whatever later takes that number. That is not hypothetical: a forward
        reference written on 2026-08-19 pointed at item 27, which already existed and
        was about something else entirely."""
        defined = _defined_items()
        dangling = {}

        for source in sorted(DOCS_DIR.rglob("*.md")):
            for match in ITEM_REFERENCE.finditer(source.read_text()):
                for group in match.groups():
                    if group and int(group) not in defined:
                        dangling.setdefault(int(group), set()).add(source.name)

        self.assertEqual(
            {},
            dangling,
            "these documents reference open items that do not exist:\n"
            + "\n".join(f"  item {n} <- {', '.join(sorted(w))}" for n, w in sorted(dangling.items())),
        )

    def test_the_reference_scan_still_finds_references(self):
        """If the prose stops saying "item N" -- a rewrite to "the backup issue", say --
        the check above passes against an empty set and guards nothing."""
        defined = _defined_items()
        found = {
            int(group)
            for match in ITEM_REFERENCE.finditer(OPEN_ITEMS.read_text())
            for group in match.groups()
            if group
        }

        self.assertGreater(len(defined), 20, "the item heading scan has stopped working")
        self.assertGreater(len(found), 10, "the item reference scan has stopped working")


class SuggestedOrderIsWellFormedTests(unittest.TestCase):
    def test_the_order_is_numbered_contiguously_from_one(self):
        """Inserting an entry means renumbering every entry below it by hand. A skipped
        or repeated position is what a half-finished renumber looks like, and markdown
        renders it as a tidy list either way, so reading the rendered page will not
        show it."""
        positions = [int(n) for n in ORDER_ENTRY.findall(_suggested_order())]

        self.assertGreater(len(positions), 5, "the Suggested order parsed as almost nothing")
        self.assertEqual(
            list(range(1, len(positions) + 1)),
            positions,
            f"the Suggested order's numbering is {positions} -- a renumber was left half done",
        )

    def test_every_order_entry_names_an_item(self):
        """An entry that names no item cannot be acted on and cannot be checked against
        the item it came from."""
        entries = [
            line
            for line in _suggested_order().splitlines()
            if ORDER_ENTRY.match(line)
        ]
        unnamed = [e for e in entries if not ITEM_REFERENCE.search(e)]

        self.assertEqual([], unnamed, f"these Suggested order entries name no item: {unnamed}")
