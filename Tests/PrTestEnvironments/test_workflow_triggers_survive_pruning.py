"""No workflow may depend on a branch the documentation says to delete.

`ptp-14803-build-artifact.yml` carried `push: [deploy/ptp-14803-18.4.1]` while
open item 9 listed that same branch as safe to prune, and the item had to add a
hand-written caveat pointing out the coupling. A caveat in prose is not a guard:
it only works if the person pruning reads that paragraph, and the whole reason
the branch is on the list is that nobody thinks about it.

So derive the coupling instead. The prune list is a table in the open items
document; the triggers are in the workflows. If the two ever overlap again, this
fails with both halves named.
"""

import pathlib
import re
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT

WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
DEVOPS_OPEN_ITEMS = REPO_ROOT / "Documentation" / "Training" / "DevOps-Open-Items-Rock-CICD.md"

# The prune table's rows look like:
#   | `deploy/ptp-14803-18.4.1` | 3 | 0 | **Yes** -- 0 unique commits; ... |
PRUNE_ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|[^|]*\|[^|]*\|\s*\*\*Yes\*\*", re.MULTILINE)


def _prunable_branches():
    return set(PRUNE_ROW.findall(DEVOPS_OPEN_ITEMS.read_text(encoding="utf-8")))


def _trigger_branches():
    """Every branch named in a `push:` or `pull_request:` filter, by workflow."""
    found = {}
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        parsed = harness.workflow(path.name)
        triggers = harness.triggers(parsed)
        if not isinstance(triggers, dict):
            continue
        for event in ("push", "pull_request"):
            spec = triggers.get(event)
            if not isinstance(spec, dict):
                continue
            for branch in spec.get("branches") or []:
                if "*" in branch:
                    continue
                found.setdefault(branch, []).append(f"{path.name} ({event})")
    return found


class TriggersDoNotDependOnPrunableBranchesTests(harness.HarnessAssertions, unittest.TestCase):
    def test_no_workflow_fires_on_a_branch_marked_for_deletion(self):
        prunable = _prunable_branches()
        self.assertNotVacuous(
            prunable,
            "the prune table in open item 9 parsed to nothing, so this check compares "
            "the triggers against an empty set and proves nothing",
        )

        triggers = _trigger_branches()
        self.assertNotVacuous(triggers, "no workflow declares a literal branch trigger")

        collisions = [
            f"{branch} triggers {', '.join(where)} and open item 9 lists it as safe to prune"
            for branch, where in sorted(triggers.items())
            if branch in prunable
        ]

        self.assertFalse(
            collisions,
            "pruning one of these branches silently disables a workflow:\n  " + "\n  ".join(collisions)
            + "\n(either drop the trigger, or take the branch off the prune list and say why)",
        )

    def test_the_hand_deploy_set_workflow_is_dispatch_only(self):
        """It was the one collision. Pinned specifically because the fix is a
        deletion, and a deletion is the easiest thing to undo by accident when
        somebody copies the trigger block from a sibling workflow."""
        triggers = harness.triggers(harness.workflow("ptp-14803-build-artifact.yml"))

        self.assertIn("workflow_dispatch", triggers)
        self.assertNotIn(
            "push",
            triggers,
            "the hand-deploy-set build fires on a push again. Its only push branch is on "
            "the prune list, which is what made a 311-line workflow read as an orphan.",
        )


if __name__ == "__main__":
    unittest.main()
