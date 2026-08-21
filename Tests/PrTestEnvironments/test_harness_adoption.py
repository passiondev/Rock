"""The suite's own conventions, pinned the same way it pins everything else.

Forty test files read the same tree, and for most of the suite's life each one
re-derived where that tree was: `pathlib.Path(__file__).resolve().parents[2]`,
copied thirty-three times. The copies agreed, so nothing was visibly wrong. What
made it worth undoing is the failure mode when they stop agreeing -- move the
suite one directory and `parents[2]` does not raise, it resolves to a different
directory, and every test that reads from it goes looking for files that are not
there. Some of those tests assert a file's contents and would fail loudly. Others
scan a tree and assert on what they find, and an empty tree is a green run.

So the root is derived once, in `pipeline_harness`, and these tests keep it that
way.
"""

import ast
import pathlib
import unittest

import pipeline_harness as harness


SUITE_DIR = harness.REPO_ROOT / "Tests" / "PrTestEnvironments"
CI_WORKFLOW = harness.REPO_ROOT / ".github" / "workflows" / "deployment-pipeline-tests.yml"


def suite_sources():
    """(name, text) for every test file in the suite except this one.

    This file quotes the patterns it bans -- in its own prose and in its own
    checks -- so scanning itself reports itself."""
    this_file = pathlib.Path(__file__).name
    return [
        (p.name, p.read_text(encoding="utf-8"))
        for p in sorted(SUITE_DIR.glob("test_*.py"))
        if p.name != this_file
    ]


class OneRepositoryRootTests(harness.HarnessAssertions, unittest.TestCase):
    def test_no_test_file_derives_the_repository_root_for_itself(self):
        sources = suite_sources()
        self.assertNotVacuous(sources, "no test files were found to check")

        offenders = [name for name, text in sources if "parents[" in text]

        self.assertEqual(
            [],
            offenders,
            "these walk up from __file__ to find the repository root instead of taking "
            "it from the harness, so moving the suite silently repoints them: "
            + ", ".join(offenders),
        )

    def test_the_harness_is_the_one_place_that_walks_up_from_a_file(self):
        """The check above is only worth anything while the harness still does the walk
        itself. Assert where the one copy lives, so a change that moves it has to come
        past here rather than leaving the suite with no derivation at all."""
        self.assertIn(
            "parents[2]",
            (SUITE_DIR / "pipeline_harness.py").read_text(encoding="utf-8"),
            "the harness no longer derives the repository root, so nothing does",
        )


class ImportBootstrapTests(harness.HarnessAssertions, unittest.TestCase):
    """`import pipeline_harness` works because the suite directory is on `sys.path`,
    and it is on `sys.path` because of how the suite is invoked -- not because any
    file arranges it. That was two lines of ceremony in every file that imported the
    harness, and the ceremony was load-bearing for nothing. These tests hold the
    invocation that makes it unnecessary."""

    def test_the_pipeline_invokes_the_suite_by_discovery_over_its_own_directory(self):
        """`unittest discover` puts its top-level directory on `sys.path`. Run the
        suite some other way -- naming modules by dotted path from the repository
        root, say -- and every import of the harness fails at collection."""
        steps = harness.steps(harness.workflow("deployment-pipeline-tests.yml"), job="test")
        runs = [s.get("run") or "" for s in steps]
        discovers = [r for r in runs if "unittest discover" in r]

        self.assertEqual(1, len(discovers), "the suite is no longer run by unittest discovery")
        self.assertRegex(
            discovers[0],
            r"-s\s+Tests/PrTestEnvironments",
            "discovery no longer starts at the suite directory, so that directory is "
            "not on sys.path and `import pipeline_harness` cannot resolve",
        )

    def test_no_test_file_edits_the_import_path(self):
        offenders = [name for name, text in suite_sources() if "sys.path" in text]

        self.assertEqual(
            [],
            offenders,
            "these still adjust sys.path by hand: " + ", ".join(offenders),
        )


class MixinOrderTests(harness.HarnessAssertions, unittest.TestCase):
    def test_the_assertions_mixin_precedes_the_test_case(self):
        """Python resolves bases left to right, so a mixin listed after
        `unittest.TestCase` cannot override anything on it. `HarnessAssertions`
        overrides nothing today and both orders behave the same, which is exactly why
        the suite had drifted into using both -- seven classes each way. The day
        somebody adds a sharper `assertIn` to the mixin, half of them would quietly
        keep the blunt one."""
        offenders = []
        for name, text in suite_sources():
            for node in ast.walk(ast.parse(text)):
                if not isinstance(node, ast.ClassDef):
                    continue
                bases = [ast.unparse(b) for b in node.bases]
                if "harness.HarnessAssertions" not in bases:
                    continue
                if bases.index("harness.HarnessAssertions") > bases.index("unittest.TestCase"):
                    offenders.append(f"{name}:{node.lineno} {node.name}")

        self.assertEqual(
            [],
            offenders,
            "these list the mixin after the base class, so its methods lose any "
            "resolution conflict: " + "\n  ".join(offenders),
        )

    def test_some_class_actually_uses_the_mixin(self):
        users = [name for name, text in suite_sources() if "harness.HarnessAssertions" in text]
        self.assertNotVacuous(users, "nothing mixes in HarnessAssertions, so the order check is vacuous")


class CollectionSafetyTests(harness.HarnessAssertions, unittest.TestCase):
    """The suite runs under unittest, but it is not the only runner that can pick it up.

    unittest only collects methods on a TestCase, so a module-level helper named
    like a test is invisible to it and stays green forever. pytest collects on the
    name alone, calls the helper with no arguments, and treats whatever it returns
    as a failing test -- a warning today, an error from pytest 9. This suite had one
    of those for as long as it had a shared helper module: the function handing every
    test file to the convention checks was itself named like a test.

    Nothing in CI runs pytest right now. The point is that switching runner should be
    a decision rather than an incident.
    """

    def test_no_module_level_helper_is_named_like_a_test(self):
        own_name = pathlib.Path(__file__).name
        own_text = pathlib.Path(__file__).read_text(encoding="utf-8")
        checked = [(own_name, own_text)] + suite_sources()
        self.assertNotVacuous(checked, "no sources were found to check")

        offenders = []
        for name, text in checked:
            for node in ast.parse(text).body:
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                if node.name.startswith("test"):
                    offenders.append(f"{name}:{node.lineno} {node.name}")

        self.assertEqual(
            [],
            offenders,
            "these are module-level helpers whose names make pytest collect them as "
            "tests and call them with no arguments: " + "\n  ".join(offenders),
        )


if __name__ == "__main__":
    unittest.main()
