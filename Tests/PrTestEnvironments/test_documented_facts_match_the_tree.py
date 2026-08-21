"""Facts the documentation states, re-derived from the thing that owns them.

`test_trap7_counts_match_the_tree.py` already makes this bargain for one section
of one guide: keep the concrete number in the prose where it is useful, and let
the suite carry the burden of keeping it true. The bargain worked. The gap was
that it covered one file, and the same numbers are stated in others -- so the
WebForms block count sat at 448 in the open-items document, as a present-tense
measurement, while the tree held 353 and the guide that was pinned said so.

Every fact below is derived, never hard-coded. A number written here would be a
fifth copy of the thing this file exists to stop.
"""

import re
import unittest

import pipeline_harness as harness

REPO_ROOT = harness.REPO_ROOT

BLOCKS_DIR = REPO_ROOT / "RockWeb" / "Blocks"
THEMES_DIR = REPO_ROOT / "RockWeb" / "Themes"
OBSIDIAN_BLOCKS_DIR = REPO_ROOT / "Rock.JavaScript.Obsidian.Blocks" / "src"

ENGINEERING_GUIDE = REPO_ROOT / "Documentation" / "Local-Engineering-Training-Edit-Test-and-Deploy.md"
OPERATOR_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"
DEVELOPER_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md"
MAKING_A_CHANGE = REPO_ROOT / "Documentation" / "Making-A-Change-To-Rock.md"
FORK_LOCAL_CHANGES = REPO_ROOT / "Documentation" / "Fork-Local-Changes.md"
DEVOPS_OPEN_ITEMS = REPO_ROOT / "Documentation" / "Training" / "DevOps-Open-Items-Rock-CICD.md"
FACILITATOR_SCRIPT = REPO_ROOT / "Documentation" / "Training" / "Facilitator-Script-Rock-CICD-Training.md"

BASE_BRANCH_TEST = REPO_ROOT / "Tests" / "PrTestEnvironments" / "test_base_branch_config.py"

# Everything an engineer or an operator is pointed at. Requirement and incident
# documents are absent on purpose: they record what was true on a date, and
# rewriting them to match today is what destroys their value.
REFERENCE_DOCS = [
    ENGINEERING_GUIDE,
    OPERATOR_RUNBOOK,
    DEVELOPER_RUNBOOK,
    MAKING_A_CHANGE,
    FORK_LOCAL_CHANGES,
    DEVOPS_OPEN_ITEMS,
    FACILITATOR_SCRIPT,
]


class BlockCountsAreDerivedEverywhereTheyAppearTests(harness.HarnessAssertions, unittest.TestCase):
    """The count of tracked WebForms blocks moves at every Rock upgrade, and it is
    quoted in two documents for two different arguments. Trap 7 uses it to say
    blocks were converted rather than deleted; open item 14 uses it to say
    Passion's plugins are not on the trunk. Both are live claims."""

    def setUp(self):
        self.webforms = len(harness.tracked_under(BLOCKS_DIR, ".ascx"))
        self.obsidian = len(harness.tracked_under(OBSIDIAN_BLOCKS_DIR, ".obs"))
        self.assertNotVacuous(
            harness.tracked_under(BLOCKS_DIR, ".ascx"),
            "no .ascx blocks are tracked, so every count below would compare zero to zero",
        )

    def test_open_item_14_states_the_current_block_count(self):
        """This sentence read 448 from 2026-08-10 until 2026-08-21, nine days after
        the cutover moved it to 353. It is dated and present-tense, so a reader has
        no way to tell it went stale."""
        text = DEVOPS_OPEN_ITEMS.read_text(encoding="utf-8")
        match = re.search(r"against ([\d,]+) tracked\s*\n?core blocks under `RockWeb/Blocks/`", text)
        self.assertIsNotNone(
            match,
            "open item 14 no longer states a tracked-core-block count in the form this "
            "test reads. Restore the phrasing or update the pattern.",
        )
        self.assertEqual(
            self.webforms,
            int(match.group(1).replace(",", "")),
            f"git tracks {self.webforms:,} .ascx blocks under RockWeb/Blocks/ and open item 14 "
            f"says {match.group(1)}. A Rock upgrade moves this number.",
        )

    def test_every_live_block_count_in_the_documentation_agrees_with_the_tree(self):
        """The catch-all. Any four-digit-or-more figure introduced as a live count
        of blocks, anywhere in the reference documentation, has to match. Numbers
        that are explicitly pinned to a past branch or date are the point of the
        `it was N before` sentences and are left alone."""
        live_claim = re.compile(
            r"(?<!was )(?<!from )\b([\d,]{3,6}) (?:tracked )?core WebForms blocks",
        )
        offenders = []
        for path in REFERENCE_DOCS:
            text = path.read_text(encoding="utf-8")
            for match in live_claim.finditer(" ".join(text.split())):
                stated = int(match.group(1).replace(",", ""))
                if stated != self.webforms:
                    offenders.append(f"{path.name}: says {match.group(1)}, tree has {self.webforms:,}")

        self.assertFalse(offenders, "live WebForms block counts disagree with the tree:\n  " + "\n  ".join(offenders))


class PinCountsAreDerivedTests(harness.HarnessAssertions, unittest.TestCase):
    """The cutover section tells an operator how many pins to expect and over how
    many files. That is a checklist they work against under time pressure, and it
    said eight over seven when the list held seven over six -- so an operator who
    trusted it would have gone looking for a pin that does not exist."""

    WORDS = {
        1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six",
        7: "seven", 8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve",
    }

    def setUp(self):
        source = BASE_BRANCH_TEST.read_text(encoding="utf-8")
        block = self._bracketed(source, "BASE_BRANCH_PIN_SITES")
        self.pin_count = len(re.findall(r"\bPinSite\(", block))
        # The second argument of each PinSite is the module-level constant naming
        # the file, so distinct constants is distinct files.
        self.file_count = len(set(re.findall(r"PinSite\(\s*\"[^\"]*\",\s*([A-Z_][A-Z_0-9]*)", block)))
        self.assertNotVacuous(range(self.pin_count), "no PinSite entries were found, so the counts below are zero")

    @staticmethod
    def _bracketed(text, name):
        """The list literal assigned to `name`, anchored on the assignment. The
        first mention of the constant is in a docstring, so searching for the
        bare name and then the next `[` lands somewhere else entirely."""
        assignment = re.search(rf"^{name}\s*=\s*\[", text, re.MULTILINE)
        assert assignment, f"{name} is not assigned a list literal at module level"
        start = assignment.end() - 1
        depth = 0
        for index in range(start, len(text)):
            if text[index] in "[(":
                depth += 1
            elif text[index] in "])":
                depth -= 1
                if depth == 0:
                    return text[start:index + 1]
        raise AssertionError(f"{name} is not a closed literal")

    def test_the_cutover_states_the_real_number_of_pins_and_files(self):
        prose = " ".join(OPERATOR_RUNBOOK.read_text(encoding="utf-8").split())
        match = re.search(
            r"`BASE_BRANCH_PIN_SITES` enumerates the (\w+) real pins?, spread over (\w+) other files?",
            prose,
        )
        self.assertIsNotNone(
            match,
            "the cutover section no longer states the pin and file counts in the form "
            "this test reads. Restore the phrasing or update the pattern.",
        )

        self.assertEqual(
            self.WORDS[self.pin_count],
            match.group(1),
            f"BASE_BRANCH_PIN_SITES holds {self.pin_count} pins and the runbook says "
            f"'{match.group(1)}'. An operator works that number as a checklist.",
        )
        self.assertEqual(
            self.WORDS[self.file_count],
            match.group(2),
            f"those pins are spread over {self.file_count} files and the runbook says "
            f"'{match.group(2)}'.",
        )


class ReferencedPathsExistTests(harness.HarnessAssertions, unittest.TestCase):
    """A path in backticks reads as something you can go and open. Nothing fails
    today, which is the point: this is cheap now and catches the next rename,
    where the alternative is an operator running `ls` on a path that moved.

    Two kinds of reference are deliberately allowed. A path that is tracked on
    another branch but not this one is how the documentation talks about what a
    cutover deleted. `RockWeb/Plugins/org_passion/` is Trap 7's whole subject --
    it exists on a working machine and is absent from git on purpose.
    """

    NOT_ON_THIS_BRANCH = {
        # Deleted from the trunk on 2026-08-10; still on `develop`, and the open
        # items document says exactly that where it names it.
        ".github/workflows/build-develop.yml",
        "build-develop.yml",
        # 18.x carried the version here. Rock 19 deleted it and moved the version
        # into Directory.Build.props. Both are named on purpose.
        "Rock.Version/AssemblySharedInfo.cs",
        # Installed, never tracked. This is what Trap 7 is about.
        "RockWeb/Plugins/org_passion/",
        "RockWeb/Plugins/team_passion/",
    }

    PATHISH = re.compile(
        r"`((?:\.github|Deployment|Tests|Documentation|RockWeb|Rock\.[A-Za-z.]+)/[A-Za-z0-9_./-]+)`"
    )

    def test_every_repository_path_the_documentation_names_is_in_the_tree(self):
        tracked = set(harness.tracked())
        self.assertNotVacuous(tracked, "git ls-files returned nothing")

        offenders = []
        for path in REFERENCE_DOCS:
            text = path.read_text(encoding="utf-8")
            for match in self.PATHISH.finditer(text):
                named = match.group(1).rstrip(".")
                if named in self.NOT_ON_THIS_BRANCH or named in tracked:
                    continue
                if any(entry.startswith(named.rstrip("/") + "/") for entry in tracked):
                    continue
                line = text.count("\n", 0, match.start()) + 1
                offenders.append(f"{path.name}:{line} names `{named}`, which is not in the tree")

        self.assertFalse(
            offenders,
            "documentation points at paths that do not exist:\n  " + "\n  ".join(offenders)
            + "\n(if the path is deliberately off this branch, add it to NOT_ON_THIS_BRANCH with the reason)",
        )

    def test_the_scan_still_finds_paths_to_check(self):
        found = sum(
            len(self.PATHISH.findall(path.read_text(encoding="utf-8")))
            for path in REFERENCE_DOCS
        )
        self.assertGreater(found, 100, "the path scan matched almost nothing -- it has stopped working")


if __name__ == "__main__":
    unittest.main()
