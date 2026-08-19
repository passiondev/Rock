"""Trap 7 of the engineering guide counts things in the repository, and a Rock
upgrade changes every one of those counts.

The guide tells a developer that plugin blocks and Passion's themes are not on the
branch they work from, and backs it with four measurements. Three of them moved at
the 19.3.4 cutover without anyone noticing: WebForms blocks fell 448 -> 353,
Obsidian blocks rose 1,122 -> 1,294, and `RockWeb/Themes/` gained
`RockManagerNextGen`. The numbers had been measured on 2026-08-10 and 2026-08-11
against `passion-18.4.1` and read, nine days later, as claims about a trunk they
were never measured on.

Stale numbers here are worse than no numbers. The whole point of the section is to
stop someone concluding a block was deleted when it was converted, and a count that
is wrong by ninety-five sends them looking for a cause that does not exist.

So this derives each count from the checkout and asserts the guide still states it.
The intended failure is at the *next* Rock upgrade: it fires the moment the tree
moves, names the old and new numbers, and points at the paragraph to edit. That is
the same bargain `test_runbooks_and_pilot_document_base_branch_config` already
makes for the trunk branch name -- keep the concrete value in the prose, where it
is useful, and let the suite carry the burden of keeping it true.

Historical figures in that section (448, 13, 1,122 on `passion-18.4.1`) are
deliberately not checked. They are measurements of a branch this checkout is not
on, and they are correct precisely because they are pinned to a date and a branch.
"""

import functools
import pathlib
import re
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
GUIDE = REPO_ROOT / "Documentation" / "Local-Engineering-Training-Edit-Test-and-Deploy.md"

# Written as REPO_ROOT paths rather than as the bare "RockWeb/Blocks/" strings the
# git output is filtered by, because test_ci_trigger_coverage.py discovers what this
# suite reads by scanning for exactly that form. As plain strings these four trees
# would be invisible to it, and the CI trigger could stop covering them without
# anything failing -- which is the hole that test exists to close.
PLUGINS_DIR = REPO_ROOT / "RockWeb" / "Plugins"
THEMES_DIR = REPO_ROOT / "RockWeb" / "Themes"
BLOCKS_DIR = REPO_ROOT / "RockWeb" / "Blocks"
OBSIDIAN_BLOCKS_DIR = REPO_ROOT / "Rock.JavaScript.Obsidian.Blocks" / "src"


@functools.lru_cache(maxsize=1)
def _tracked():
    """Every path git tracks, as posix strings.

    Deliberately `git ls-files` and not a filesystem walk, and the distinction is the
    section's whole subject rather than a detail. A working Rock checkout has real
    plugin folders sitting in `RockWeb/Plugins/` -- `team_passion`, `org_secc`,
    `cc_newspring` -- because plugins install there. None of them is tracked. A test
    that counted files on disk would fail on every developer's machine while passing
    in CI, and it would be asserting the opposite of what Trap 7 says.
    """
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def _tracked_under(directory, suffix=""):
    prefix = directory.relative_to(REPO_ROOT).as_posix() + "/"
    return [p for p in _tracked() if p.startswith(prefix) and p.endswith(suffix)]


def _trap7():
    """Just the Trap 7 section. Scoping matters: these counts are four-digit numbers
    in a long document that quotes plenty of others, so an unscoped search would find
    a match somewhere and pass while the section itself was wrong."""
    text = GUIDE.read_text()
    marker = "### Trap 7:"
    assert marker in text, (
        f"{GUIDE.name} no longer has a '{marker}' heading. If the section was renamed, "
        "point this test at the new heading; if it was deleted, delete this test with it."
    )
    start = text.index(marker)
    end = text.index("\n### ", start + 1)
    return text[start:end]


# Each count is read out of the one sentence that states it, rather than searched for
# anywhere in the section. The difference is not cosmetic: the WebForms figure was
# briefly written twice -- once as the live count and once in the "it was N before"
# aside -- and a substring check over the whole section passed happily with one of
# them mutated, because the other still matched. An anchored read has exactly one
# number to disagree with.
DECLARED = {
    "WebForms blocks": re.compile(r"The ([\d,]+) core WebForms blocks under"),
    "Obsidian blocks": re.compile(r"Obsidian blocks went the other way over the same span, [\d,]+ to ([\d,]+)"),
    "themes": re.compile(r"tracks ([\d,]+) themes on the current trunk"),
}


def _declared(what, section):
    """The number the guide states for `what`, or a failure naming the sentence that
    has gone missing -- a reworded sentence must fail loudly, not silently stop being
    checked.

    Whitespace is collapsed first because the guide is hard-wrapped at 100 columns, so
    any phrase long enough to anchor on is also long enough to contain a newline, and
    where that newline falls changes whenever the sentence is edited.
    """
    match = DECLARED[what].search(" ".join(section.split()))
    assert match, (
        f"Trap 7 no longer states a {what} count in the form this test reads. Either "
        f"restore the phrasing or update DECLARED[{what!r}] to match the new wording."
    )
    return int(match.group(1).replace(",", ""))


class Trap7CountsAreCurrentTests(unittest.TestCase):
    def setUp(self):
        self.section = _trap7()

    def test_the_section_is_still_where_this_test_thinks_it_is(self):
        """A retitled or moved section would leave every assertion below scanning the
        wrong text, and most of them would still pass."""
        self.assertIn("RockWeb/Plugins/.gitignore", self.section)
        self.assertIn("RockWeb/Themes/", self.section)
        self.assertGreater(len(self.section), 800, "the Trap 7 slice came out too short to be the section")

    def test_nothing_but_the_two_placeholders_is_tracked_under_plugins(self):
        """The claim the whole section rests on. If a plugin ever does get committed,
        this is the sentence that becomes a lie."""
        present = sorted(p.split("/")[-1] for p in _tracked_under(PLUGINS_DIR))

        self.assertEqual(
            [".gitignore", "readme.txt"],
            present,
            f"git tracks {present} under RockWeb/Plugins/ -- Trap 7 says it tracks exactly "
            "two placeholder files, and the section's argument depends on that",
        )

    def test_no_passion_plugin_paths_are_tracked(self):
        offenders = [
            p for p in _tracked()
            if "org_passion" in p.lower() or "team_passion" in p.lower()
        ]

        self.assertEqual(
            [],
            offenders,
            "Trap 7 says git tracks zero paths matching org_passion or team_passion, but "
            f"these are tracked: {offenders}",
        )

    def test_the_webforms_block_count_is_current(self):
        actual = len(_tracked_under(BLOCKS_DIR, ".ascx"))

        self.assertEqual(
            actual,
            _declared("WebForms blocks", self.section),
            f"git tracks {actual:,} .ascx blocks under RockWeb/Blocks/ and Trap 7 says "
            "otherwise. A Rock upgrade moves this number -- update the sentence, and "
            "check the Obsidian count in the same edit, since the section's argument is "
            "that the two move in opposite directions.",
        )

    def test_the_obsidian_block_count_is_current(self):
        actual = len(_tracked_under(OBSIDIAN_BLOCKS_DIR, ".obs"))

        self.assertEqual(
            actual,
            _declared("Obsidian blocks", self.section),
            f"git tracks {actual:,} .obs blocks and Trap 7 says otherwise. This is the "
            "counterweight to the WebForms count -- the section's point is that blocks "
            "were converted rather than deleted, so the two are updated together.",
        )

    def test_the_theme_count_is_current(self):
        themes = sorted({p.split("/")[2] for p in _tracked_under(THEMES_DIR)})

        self.assertEqual(
            len(themes),
            _declared("themes", self.section),
            f"git tracks {len(themes)} themes ({', '.join(themes)}) and Trap 7 says "
            "otherwise.",
        )

    def test_passions_own_themes_are_still_absent(self):
        """Named in the guide as the reason a signed-out test page looks wrong. If they
        ever are committed, the guide's advice stops applying."""
        present = {p.split("/")[2] for p in _tracked_under(THEMES_DIR)}

        for theme in ("CONNECT", "Checkin-Guest"):
            self.assertNotIn(
                theme,
                present,
                f"{theme} is now tracked under RockWeb/Themes/, which contradicts Trap 7",
            )
