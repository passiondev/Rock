"""The suite only guards a file if changing that file runs the suite.

`deployment-pipeline-tests.yml` filters on `paths:`, so a file the suite reads but
the filter does not list is tested on every run except the one that matters. The
workflow's own comment claimed that gap had been closed by naming parent
directories. It had not: on 2026-08-19 four read paths sat outside the list, the
worst being `.github/pr-test-environments.json` -- the base-branch pin a trunk
cutover flips, guarded by test_base_branch_config.py, and editing it ran nothing.

This is the third time the same hole has been found. `.github/scripts/**` had to be
added because `pr-test-status.js` lives there and `scripts` is a sibling of
`workflows`, not a child of it. `Deployment/**` replaced `Deployment/PrTestEnvironments/**`
because `Deployment/Repository/set-trunk-protection.sh` sat outside the narrower glob.
Both were then fixed by hand and pinned with a hand-kept list of required paths --
which is why the third gap went unnoticed: a hand-kept list only knows what somebody
remembered to add to it, and it cannot fail for a path nobody thought of.

So this file derives the required set from the test sources instead. A new test that
reads somewhere new fails here until the trigger is widened to match, whether or not
anyone remembers this file exists. It replaces PipelineTestTriggerTests in
test_environment_deploy.py, whose literal-membership assertion also had the inverse
failure mode: it fired on a change that widened a glob to a parent directory and so
strictly improved coverage.
"""

import pathlib
import re
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SUITE_DIR = REPO_ROOT / "Tests" / "PrTestEnvironments"
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "deployment-pipeline-tests.yml"

# REPO_ROOT / "a" / "b" / "c" -- the only way this suite addresses repository files.
READ_PATH = re.compile(r'REPO_ROOT\s*((?:/\s*"[^"]+"\s*)+)')


def _read_paths():
    """Every repository path the suite resolves, as posix strings relative to the root.

    Every `*.py` here, not only `test_*.py`. `pipeline_harness.py` holds path
    constants on behalf of the tests that import it, and a scan restricted to
    test files would stop seeing them the moment a path moved into the harness
    -- reopening this exact hole through the refactor meant to close others.
    """
    found = {}
    for source in sorted(SUITE_DIR.glob("*.py")):
        # This file quotes the pattern it looks for, in its own docstring and in its
        # own regex, so scanning itself finds paths no test actually reads.
        if source.name == pathlib.Path(__file__).name:
            continue
        for match in READ_PATH.finditer(source.read_text()):
            parts = re.findall(r'"([^"]+)"', match.group(1))
            found.setdefault("/".join(parts), set()).add(source.name)
    return found


def _covered(path, patterns):
    """GitHub path-filter semantics, restricted to the two forms this workflow uses:
    a `dir/**` tree and a literal file. A directory the suite reads is covered by a
    glob rooted at it or above it, which plain fnmatch would not say."""
    for pattern in patterns:
        if pattern.endswith("/**"):
            prefix = pattern[: -len("/**")]
            if path == prefix or path.startswith(prefix + "/"):
                return pattern
        elif path == pattern:
            return pattern
    return None


class TriggerCoversWhatTheSuiteReadsTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(CI_WORKFLOW.read_text())
        self.triggers = self.workflow.get("on") or self.workflow.get(True)

    def test_every_path_the_suite_reads_is_in_the_push_filter(self):
        patterns = self.triggers["push"]["paths"]

        uncovered = {
            path: sorted(sources)
            for path, sources in _read_paths().items()
            if not _covered(path, patterns)
        }

        self.assertEqual(
            {},
            uncovered,
            "these paths are read by the suite but no push filter matches them, so "
            "changing one does not run the test that guards it:\n"
            + "\n".join(f"  {p}  (read by {', '.join(s)})" for p, s in sorted(uncovered.items())),
        )

    def test_the_suite_reads_enough_for_this_check_to_mean_something(self):
        """A refactor away from `REPO_ROOT / "..."` would empty the scan and leave the
        test above passing vacuously against nothing at all."""
        paths = _read_paths()

        self.assertGreater(len(paths), 20, "the path scan found almost nothing -- it has stopped working")
        self.assertIn(".github/pr-test-environments.json", paths)

    def test_the_scan_reaches_the_shared_harness(self):
        """The harness is not a `test_*.py` file, so the scan had to be widened to
        see it. If that widening is ever undone, every path the harness owns
        silently leaves the CI trigger's coverage."""
        sources = {source for paths in _read_paths().values() for source in paths}

        self.assertIn(
            "pipeline_harness.py",
            sources,
            "the path scan no longer reads pipeline_harness.py, so the repository "
            "paths it names are not checked against the CI trigger",
        )

    def test_the_pull_request_filter_matches_the_push_filter(self):
        """The two lists are copies by necessity -- GitHub Actions rejects YAML anchors,
        which is why the workflow repeats itself. Copies drift; this is the check that
        they have not."""
        self.assertEqual(
            self.triggers["push"]["paths"],
            self.triggers["pull_request"]["paths"],
            "the push and pull_request path filters have drifted apart, so a change "
            "runs the suite on one event and not the other",
        )
