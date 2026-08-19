"""Every `rock:` label a document names has to be one the automation actually uses.

Labels are the whole user interface of the PR test fleet: they are how a developer
starts an environment and how the robot reports back. A document that names one wrong
does not fail loudly -- the developer adds a label GitHub happily creates, nothing
watches it, and nothing happens. That is the worst failure mode the fleet has, because
it looks exactly like the build being slow.

The training material got this wrong in a subtler way. `pr-test-status.js` renders the
sticky comment's Status row as the bare word (`| Status | **deployed** |`) while the
*label* it reconciles is `rock:deployed`. The deck and the cheat sheet showed the four
action labels prefixed and the six state labels bare, and the facilitator script used
both spellings for the same label three lines apart. Every bare one was a state label
being described as though it were what appears in the sidebar.

Note the asymmetry this leaves behind, because it is easy to "fix" wrongly: a bare
state word is correct when the text is describing the comment's Status row, and wrong
when it is describing a label. Only the label spellings are checked here.
"""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
SCRIPT_DIR = REPO_ROOT / ".github" / "scripts"
DOCS_DIR = REPO_ROOT / "Documentation"
TRAINING_DIR = DOCS_DIR / "Training"
PR_TEMPLATE = REPO_ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md"
STATUS_SCRIPT = SCRIPT_DIR / "pr-test-status.js"
CHEAT_SHEET = TRAINING_DIR / "rock-cicd-cheat-sheet.html"

LABEL = re.compile(r"rock:[a-z-]+")
STATE_LABELS_BLOCK = re.compile(r"const STATE_LABELS = \[(.*?)\]", re.S)
# <span class="tag tag-state">deployed</span> -- the markup the two HTML handouts use
# for a label chip, as opposed to prose about the comment's Status row.
STATE_TAG = re.compile(r'<span class="tag tag-state">([^<]+)</span>')
# The cheat sheet's roll-call of states: the first paragraph under that heading. The
# section also explains two of them in a following sentence, so matching the whole
# section would let a chip go missing from the list and still look complete.
ROBOT_LABEL_ROSTER = re.compile(
    r"<h2>Labels the robot sets[^<]*</h2>\s*<p>(.*?)</p>", re.S
)


def labels_used_by_the_automation():
    """Every label the workflows and scripts reference. This is the vocabulary; a
    document may name a subset of it but must not invent anything outside it."""
    found = set()
    for source in sorted(WORKFLOW_DIR.glob("*.yml")) + sorted(SCRIPT_DIR.glob("*.js")):
        found.update(LABEL.findall(source.read_text()))
    return found


def state_labels():
    """The six the robot sets, read from the script that owns them."""
    block = STATE_LABELS_BLOCK.search(STATUS_SCRIPT.read_text())
    return set(LABEL.findall(block.group(1)))


def documents_naming_labels():
    paths = sorted(DOCS_DIR.rglob("*.md")) + sorted(DOCS_DIR.rglob("*.html")) + [PR_TEMPLATE]
    return [p for p in paths if LABEL.search(p.read_text())]


class DocumentedLabelsExistTests(unittest.TestCase):
    def setUp(self):
        self.vocabulary = labels_used_by_the_automation()

    def test_the_vocabulary_was_actually_found(self):
        self.assertGreaterEqual(
            len(self.vocabulary), 8, "found almost no labels in the automation -- the scan has broken"
        )
        self.assertIn("rock:start", self.vocabulary)

    def test_no_document_names_a_label_the_automation_does_not_use(self):
        invented = {}
        for document in documents_naming_labels():
            unknown = sorted(set(LABEL.findall(document.read_text())) - self.vocabulary)
            if unknown:
                invented[str(document.relative_to(REPO_ROOT))] = unknown

        self.assertEqual(
            {},
            invented,
            "these documents name labels no workflow or script reacts to, so following "
            "them does nothing at all:\n"
            + "\n".join(f"  {d}: {labels}" for d, labels in sorted(invented.items())),
        )

    def test_the_cheat_sheet_lists_exactly_the_state_labels_the_code_defines(self):
        """Equality, not containment, and only for the cheat sheet: it prints the set
        under the heading "Labels the robot sets (don't touch)", which is a claim to be
        complete. Missing one reads as a state that cannot happen; keeping one the code
        has retired sends a reader looking for a chip that will never appear.

        The deck is deliberately held to the weaker check below -- a slide is allowed to
        show three states to make a point, and pinning it to all six would fail on a
        perfectly good edit."""
        roster = ROBOT_LABEL_ROSTER.search(CHEAT_SHEET.read_text())
        self.assertIsNotNone(roster, "the cheat sheet's roll-call of robot labels has moved")
        chips = set(STATE_TAG.findall(roster.group(1)))

        self.assertEqual(
            state_labels(),
            chips,
            "the cheat sheet's state labels and the ones pr-test-status.js defines have "
            f"drifted; only on the sheet: {sorted(chips - state_labels())}, "
            f"only in the code: {sorted(state_labels() - chips)}",
        )


class LabelChipsAreSpelledAsLabelsTests(unittest.TestCase):
    """The regression guard for the bug this file was written for."""

    def test_every_state_chip_in_the_handouts_carries_the_prefix(self):
        bare = {}
        for handout in sorted(TRAINING_DIR.glob("*.html")):
            wrong = sorted({t for t in STATE_TAG.findall(handout.read_text()) if not t.startswith("rock:")})
            if wrong:
                bare[handout.name] = wrong

        self.assertEqual(
            {},
            bare,
            "these chips render a state label without its `rock:` prefix, so a reader "
            "looking for them in the PR sidebar will not find them:\n"
            + "\n".join(f"  {h}: {labels}" for h, labels in sorted(bare.items())),
        )

    def test_the_chips_are_real_labels(self):
        """Prefixed but misspelled is no better than bare."""
        vocabulary = labels_used_by_the_automation()
        for handout in sorted(TRAINING_DIR.glob("*.html")):
            for chip in STATE_TAG.findall(handout.read_text()):
                self.assertIn(chip, vocabulary, f"{handout.name} shows a chip for {chip!r}")


if __name__ == "__main__":
    unittest.main()
