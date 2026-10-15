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
import re
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


class OnePowerShellReaderTests(harness.HarnessAssertions, unittest.TestCase):
    """The same story as the repository root, one directory over.

    Four files declared their own `_strip_comments`, and the four bodies differed
    only in a lambda parameter name. They agreed, so nothing was visibly wrong.
    What made it worth undoing is that every one of them exists for the same
    reason -- these scripts explain in comments the exact construct the test scans
    for -- so a fix to the stripping in one file is a fix the other three need and
    do not get.

    The alias is fine and is what the four files carry now. A fresh definition is
    not: it is the copy coming back.
    """

    def test_no_test_file_defines_its_own_comment_stripper(self):
        """Either language. `_without_comments` was one of the bash copies, which is
        why `without` matches as well as `strip`. A test method is exempt because its
        name describes a case rather than declaring a helper."""
        offenders = []
        for name, text in suite_sources():
            for node in ast.walk(ast.parse(text)):
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                if node.name.startswith("test"):
                    continue
                if re.search(r"(strip|without).*comment", node.name, re.IGNORECASE):
                    offenders.append(f"{name}:{node.lineno} {node.name}")

        self.assertEqual(
            [],
            offenders,
            "these declare their own comment stripper instead of taking the harness "
            "one, so a fix to the stripping reaches only the file it was made in: "
            + ", ".join(offenders),
        )

    def test_the_harness_is_the_one_place_that_strips_them(self):
        """The ban above is worth something only while the harness still has the
        function. Without this, deleting it from the harness leaves a suite where
        nothing strips comments and nothing says so."""
        self.assertTrue(
            callable(getattr(harness, "strip_powershell_comments", None)),
            "the harness no longer strips PowerShell comments, so the four files "
            "that alias it import nothing",
        )

    def test_the_files_that_read_powershell_use_it(self):
        users = [name for name, text in suite_sources() if "strip_powershell_comments" in text]
        self.assertNotVacuous(
            users, "no test file uses the harness stripper, so the ban above watches nothing"
        )


class OneContractReaderTests(harness.HarnessAssertions, unittest.TestCase):
    """The same story again, on the queue agent's contract table.

    Three files sliced the agent's verb table by hand -- find the arm's opening
    brace, cut to the next `default {`, regex the middle -- each with its own
    spelling of the brace. They were reading a script no test could run: the verb
    switch lived inside the block handed to Start-Job, in a runspace nothing here
    can reach, so matching its source was the only assertion available.

    The table is data now, and the harness reads it as data. What must not come
    back is a file parsing it for itself: a slice that misses returns the empty
    string, every assertion inside it stops being able to fail, and the file goes
    on reporting that a command it no longer finds is correctly configured.
    """

    def test_no_test_file_parses_the_contract_table_for_itself(self):
        offenders = [
            name
            for name, text in suite_sources()
            if "[ordered]@{" in text or 'index("default {")' in text
        ]

        self.assertEqual(
            [],
            offenders,
            "these read the agent's contract table by hand instead of taking the "
            "harness reader, so a change to the table's shape leaves them slicing "
            "nothing and asserting nothing: " + ", ".join(offenders),
        )

    def test_the_harness_is_the_one_place_that_reads_it(self):
        """The ban is worth something only while the harness still has the reader."""
        for name in ("command_contract", "command_contract_verbs"):
            self.assertTrue(
                callable(getattr(harness, name, None)),
                f"the harness no longer provides {name}, so the files that call it "
                "import nothing",
            )

    def test_the_files_that_read_the_agent_use_it(self):
        users = [name for name, text in suite_sources() if "command_contract" in text]
        self.assertNotVacuous(
            users, "no test file reads the contract table, so the ban above watches nothing"
        )


class OneStepLookupTests(harness.HarnessAssertions, unittest.TestCase):
    """Sixteen places found a workflow step by name, in four spellings, and a missing
    step meant something different depending on which one asked. Ten called
    `next()`, which raises a bare StopIteration -- unittest reports it as an error,
    and nothing in it names the step. Five failed an assertion of their own, each
    worded differently. One returned None, so its callers had to remember an
    `assertIsNotNone`; one of its three did not, and would have failed on
    subscripting None.

    A renamed step is the ordinary way this happens -- step names are prose, and
    prose gets edited -- so the answer cannot depend on which spelling of the
    lookup the test happened to use."""

    WORKFLOW = {
        "jobs": {
            "build": {"steps": [{"name": "Compile", "run": "make"}, {"name": "Pack", "run": "zip"}]},
            "deploy": {"steps": [{"name": "Pack", "run": "unzip"}, {"run": "true"}]},
        }
    }

    def test_a_step_is_found_by_its_name(self):
        self.assertEqual("make", harness.step(self.WORKFLOW, "Compile")["run"])

    def test_naming_the_job_tells_two_same_named_steps_apart(self):
        self.assertEqual("unzip", harness.step(self.WORKFLOW, "Pack", job="deploy")["run"])

    def test_a_missing_step_fails_and_says_which_name_it_looked_for(self):
        with self.assertRaisesRegex(AssertionError, r"'Publish'.*found 0"):
            harness.step(self.WORKFLOW, "Publish")

    def test_a_job_that_does_not_exist_fails_rather_than_finding_nothing(self):
        with self.assertRaisesRegex(AssertionError, r"'Compile'.*'release'.*found 0"):
            harness.step(self.WORKFLOW, "Compile", job="release")

    def test_two_steps_with_one_name_fail_rather_than_picking_the_first(self):
        """Taking the first match is how a test ends up asserting about the build's
        copy of a step while the deploy's copy is the one that changed."""
        with self.assertRaisesRegex(AssertionError, r"'Pack'.*found 2"):
            harness.step(self.WORKFLOW, "Pack")

    def test_a_composite_action_is_searched_too(self):
        """An action's steps run inside the caller's job, so they are looked up the
        same way rather than through `runs.steps` by hand."""
        action = {"runs": {"using": "composite", "steps": [{"name": "Probe", "run": "curl"}]}}
        self.assertEqual("curl", harness.step(action, "Probe")["run"])

    def test_no_test_file_looks_a_step_up_by_name_for_itself(self):
        # `\w+\.get` and not a bare `.get`: a job's `environment:` block also has a
        # name, and `job["environment"].get("name")` is not a step lookup.
        pattern = re.compile(r"\b\w+\.get\(\s*[\"']name[\"']\s*\)\s*==")
        offenders = [
            f"{name}:{harness.line_of(text, match.start())}"
            for name, text in suite_sources()
            for match in pattern.finditer(text)
        ]

        self.assertEqual(
            [],
            offenders,
            "these compare a step's name by hand instead of calling harness.step, so "
            "a renamed step fails -- or passes -- however that file's spelling of the "
            "lookup happens to behave: " + ", ".join(offenders),
        )

    def test_the_files_that_read_steps_use_it(self):
        users = [name for name, text in suite_sources() if "harness.step(" in text]
        self.assertNotVacuous(users, "no test file calls harness.step, so the ban above watches nothing")


class OneBashRunnerTests(harness.HarnessAssertions, unittest.TestCase):
    """Five files ran bash for themselves, and each rebuilt a different part of the
    job around it. Two passed `-u`, which neither guard they ran is given in CI.
    Two set GITHUB_STEP_SUMMARY and not GITHUB_OUTPUT, so a step that grew an
    output would, inside CI, append it to the suite's own job. The point of running
    a step rather than reading it is that the run is the one CI does, and five
    approximations of that run are five places to be wrong about it."""

    def test_a_step_runs_under_the_flags_actions_gives_a_bash_step(self):
        """`shell: bash` is `bash --noprofile --norc -eo pipefail {0}`: a failing
        stage of a pipe fails the step, and an unset variable does not."""
        piped = harness.run_bash("false | true\necho reached")
        self.assertNotEqual(0, piped.returncode, piped.output)
        self.assertNotIn("reached", piped.stdout)

        unset = harness.run_bash('echo "[${NOTHING_SETS_THIS_VARIABLE}]"')
        self.assertEqual(0, unset.returncode, unset.output)
        self.assertEqual("[]", unset.stdout.strip())

    def test_outputs_are_read_back_in_both_of_the_forms_actions_accepts(self):
        result = harness.run_bash(
            'echo "version=19.4.4" >> "$GITHUB_OUTPUT"\n'
            '{ echo "notes<<EOF"; echo "line one"; echo "line two"; echo "EOF"; } >> "$GITHUB_OUTPUT"'
        )
        self.assertEqual(0, result.returncode, result.output)
        self.assertEqual({"version": "19.4.4", "notes": "line one\nline two"}, result.outputs)

    def test_the_step_summary_is_read_back(self):
        result = harness.run_bash('echo "| Check | Result |" >> "$GITHUB_STEP_SUMMARY"')
        self.assertEqual("| Check | Result |\n", result.summary)

    def test_a_stub_shadows_the_real_command(self):
        result = harness.run_bash("gh api user", stubs={"gh": 'echo "stub gh: $*"\n'})
        self.assertEqual(0, result.returncode, result.output)
        self.assertEqual("stub gh: api user", result.stdout.strip())

    def test_the_workspace_is_this_checkout_unless_the_caller_says_otherwise(self):
        """Steps reach the repository's own scripts through $GITHUB_WORKSPACE, and
        a fixture tree as the working directory is how these tests feed a step a
        branch other than this one."""
        result = harness.run_bash('echo "$GITHUB_WORKSPACE"')
        self.assertEqual(str(harness.REPO_ROOT), result.stdout.strip())

    def test_the_caller_environment_reaches_the_step(self):
        result = harness.run_bash('echo "$HOST_NAME"', env={"HOST_NAME": "site.example.org"})
        self.assertEqual("site.example.org", result.stdout.strip())

    def test_no_test_file_starts_bash_for_itself(self):
        pattern = re.compile(r"\[\s*[\"']bash[\"']\s*,")
        offenders = [
            f"{name}:{harness.line_of(text, match.start())}"
            for name, text in suite_sources()
            for match in pattern.finditer(text)
        ]

        self.assertEqual(
            [],
            offenders,
            "these start bash themselves instead of calling harness.run_bash, so each "
            "decides on its own which flags and which Actions files the step gets: "
            + ", ".join(offenders),
        )

    def test_the_files_that_run_bash_use_it(self):
        users = [name for name, text in suite_sources() if "harness.run_bash(" in text]
        self.assertNotVacuous(users, "no test file calls harness.run_bash, so the ban above watches nothing")


class OneBashCommentStripperTests(harness.HarnessAssertions, unittest.TestCase):
    """Two files read bash with its comments removed -- a deploy guard in one, a
    repository script in the other -- because the comment explains the exact thing
    the test scans for. Both dropped full-line comments only, since a `#` later in
    a line can be `$#` or quoted text. The reasoning is the same in both, so it
    lives once."""

    def test_full_line_comments_go_and_line_numbers_stay(self):
        script = 'set -e\n  # no DELETE here\necho "#1 of 2"\n'
        self.assertEqual('set -e\n\necho "#1 of 2"', harness.strip_bash_comments(script))

    def test_the_files_that_read_bash_guards_use_it(self):
        users = [name for name, text in suite_sources() if "strip_bash_comments" in text]
        self.assertNotVacuous(
            users,
            "no test file uses the bash stripper, so the stripper ban covers only PowerShell",
        )


class NoHandSlicedFunctionTests(harness.HarnessAssertions, unittest.TestCase):
    """`text.split("function X")` hands back everything after the first mention of
    the name, comments included, and an empty slice when the name is gone -- and
    every `assertNotIn` over an empty slice passes. The deploy-script tests sliced
    that way until their functions moved to Pester; the harness reader raises
    instead, and this keeps the string slices from coming back."""

    def test_no_test_file_slices_a_powershell_function_out_by_hand(self):
        pattern = re.compile(r"\.(?:split|index|find|rfind|partition)\(\s*f?[\"'](?:\\n)?function\s")
        offenders = [
            f"{name}:{harness.line_of(text, match.start())}"
            for name, text in suite_sources()
            for match in pattern.finditer(text)
        ]

        self.assertEqual(
            [],
            offenders,
            "these cut a function body out of a script by string search instead of "
            "harness.powershell_function, which raises when the function is gone: "
            + ", ".join(offenders),
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

    def test_a_main_block_is_the_last_thing_in_its_file(self):
        """`python test_x.py` runs `unittest.main()` where the block sits, and that
        call exits. Four files had it part-way down, so run on their own they ran
        only the classes above it -- and passed, because nothing it skipped could
        fail. Discovery imports the module and never reaches the block, which is why
        CI never showed it."""
        own_name = pathlib.Path(__file__).name
        own_text = pathlib.Path(__file__).read_text(encoding="utf-8")
        checked = [(own_name, own_text)] + suite_sources()

        offenders = []
        for name, text in checked:
            body = ast.parse(text).body
            for index, node in enumerate(body):
                is_main_block = (
                    isinstance(node, ast.If)
                    and isinstance(node.test, ast.Compare)
                    and isinstance(node.test.left, ast.Name)
                    and node.test.left.id == "__name__"
                )
                if is_main_block and index != len(body) - 1:
                    offenders.append(f"{name}:{node.lineno}")

        self.assertEqual(
            [],
            offenders,
            "these files call unittest.main() before their last class, so running "
            "the file directly skips everything below it: " + ", ".join(offenders),
        )


if __name__ == "__main__":
    unittest.main()
