"""The PowerShell in this pipeline is checked for syntax, and the check sees all of it.

Every other test in this suite asserts on the *text* of the PowerShell. None of
them asked whether it parses, which is how a hundred lines could move into
.github/actions/await-vm-command on 2026-08-21 with a production deploy as the
first thing that would ever run them.

The parse itself needs pwsh, so it runs in CI rather than here. What this file
guards is the part that can rot quietly: that the job still exists, and that the
extractor still hands it every block. An extractor that silently stops finding
the embedded PowerShell turns the whole job into a check on twelve .ps1 files
while reporting the same green it always did.
"""

import importlib.util
import re
import unittest

import yaml

import pipeline_harness as harness

PIPELINE_WORKFLOW = harness.REPO_ROOT / ".github" / "workflows" / "deployment-pipeline-tests.yml"
EXTRACTOR = harness.REPO_ROOT / ".github" / "scripts" / "extract-powershell-blocks.py"
AWAIT_ACTION_FILE = harness.REPO_ROOT / ".github" / "actions" / "await-vm-command" / "action.yml"
PESTER_DIR = harness.REPO_ROOT / "Tests" / "PrTestEnvironments" / "Pester"

# Deliberately naive, and that is the point: it sees what a person skimming the
# YAML would see. It cannot count blocks -- one `defaults:` line covers a whole
# job -- but it can say whether a file has PowerShell in it at all, which is the
# question that matters when the extractor stops understanding a file's shape.
DECLARES_PWSH = re.compile(r"^\s*shell:\s*pwsh\s*$", re.MULTILINE)


def load_extractor():
    """The extractor script as a module.

    Loaded by path because `.github/scripts` is not a package and the file name
    is hyphenated, so neither plain import form reaches it."""
    spec = importlib.util.spec_from_file_location("extract_powershell_blocks", EXTRACTOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def yaml_sources():
    """Every YAML file a runner may find PowerShell in: the workflows, and each
    composite action's `action.yml`."""
    workflows = sorted((harness.REPO_ROOT / ".github" / "workflows").glob("*.yml"))
    actions = sorted((harness.REPO_ROOT / ".github" / "actions").glob("*/action.yml"))
    return workflows + actions


class SyntaxJobTests(unittest.TestCase):
    def parse_step(self):
        """The step that runs the PowerShell parser over the tree."""
        job = harness.workflow("deployment-pipeline-tests.yml")["jobs"].get("powershell")
        self.assertIsNotNone(job, "The PowerShell job is gone.")
        parses = [s for s in job["steps"] if "Language.Parser" in (s.get("run") or "")]
        self.assertEqual(1, len(parses), "Nothing in the job calls the PowerShell parser.")
        return parses[0]

    def test_the_parse_step_reaches_every_powershell_script_in_the_repository(self):
        """Derived from the tree rather than restated, so a script added somewhere
        new fails here instead of quietly never being parsed. That is not
        hypothetical: the queue action's script sat outside the only glob the job
        had, and it is the code that decides whether a password reaches a public
        log."""
        step = self.parse_step()["run"]
        roots = set(re.findall(r"Get-ChildItem -Path (\S+) -Recurse -Filter \*\.ps1", step))

        for script in harness.tracked_under(harness.REPO_ROOT / ".github", suffix=".ps1"):
            self.assertTrue(
                any(script.startswith(root.strip("'\"") + "/") for root in roots),
                f"{script} is PowerShell that no glob in the parse step matches, so "
                f"nothing ever checks that it parses. Globs: {sorted(roots)}",
            )

    def test_the_pipeline_runs_a_parse_over_the_powershell(self):
        """The parse exists, runs under pwsh, and covers both halves of the tree.

        `parse_step()` already asserts the job and the step are there, so finding
        it is the first half of this test rather than something to restate."""
        parse = self.parse_step()

        job = harness.workflow("deployment-pipeline-tests.yml")["jobs"]["powershell"]
        extracts = [s for s in job["steps"] if "extract-powershell-blocks.py" in (s.get("run") or "")]
        self.assertEqual(1, len(extracts), "The embedded blocks are no longer extracted before the parse.")

        self.assertEqual("pwsh", parse.get("shell"))
        # Both halves, or the job checks one and reports on both.
        self.assertIn("Deployment", parse["run"])
        self.assertIn("powershell-blocks", parse["run"])

    def test_every_file_that_declares_pwsh_yields_blocks(self):
        """A block the extractor misses is a block nothing ever parses, and the job
        stays green either way. Counting is not the check -- one `defaults:` line
        covers a whole job -- so this asks the weaker question both sides can answer
        independently: does this file have PowerShell in it, yes or no."""
        module = load_extractor()
        checked = 0

        for path in yaml_sources():
            raw = path.read_text(encoding="utf-8")
            source = path.parent.name if path.name == "action.yml" else path.stem
            parsed = yaml.safe_load(raw)
            blocks = list(module.powershell_steps(parsed, source))
            declares_pwsh = bool(DECLARES_PWSH.search(raw))
            name = path.relative_to(harness.REPO_ROOT).as_posix()

            if declares_pwsh:
                checked += 1
                self.assertTrue(
                    blocks,
                    f"{name} declares `shell: pwsh` but the extractor found nothing "
                    f"in it, so none of its PowerShell reaches the parser.",
                )
            else:
                self.assertFalse(
                    blocks,
                    f"{name} declares no pwsh shell yet the extractor pulled "
                    f"{len(blocks)} block(s) out of it.",
                )

        self.assertGreater(checked, 0, "No file declares pwsh; this test is checking nothing.")

    def test_a_composite_action_is_still_a_shape_the_extractor_understands(self):
        """A composite action's steps sit under `runs:` rather than `jobs:`, so it is
        the shape most likely to be dropped by a change to the extractor.

        This used to assert on the wait's inline body, which held the largest block
        of PowerShell in the pipeline. That block is a script now, so pwsh parses it
        directly and the extractor has nothing to do with it. What is still worth
        holding is that the extractor reads this file shape at all: the moment
        someone inlines PowerShell into an action.yml again, it has to be found.
        """
        module = load_extractor()
        parsed = yaml.safe_load(AWAIT_ACTION_FILE.read_text(encoding="utf-8"))
        blocks = list(module.powershell_steps(parsed, "await-vm-command"))

        self.assertEqual(1, len(blocks))
        self.assertIn("Await-VmCommand.ps1", blocks[0][1])


class ScriptsLiveInScriptFilesTests(harness.HarnessAssertions, unittest.TestCase):
    """Script code embedded in YAML is a string until a runner expands it.

    Nothing can execute it, so the strongest check available is a parse, and a
    parse is not a run: it said the wait's log tail sliced without an error and
    said nothing about which sixty lines it took. Two composite actions kept 97 and
    64 lines inline, and neither had a test that ran a single branch. Both are
    scripts now, and the branch that decides whether a certificate is self-signed
    has a test for all three printed forms of a name, rather than a comment saying
    all three were seen.

    The rule is absolute for composite actions and a downward ratchet for
    workflows. That split is deliberate, the reasoning for both halves is in
    ADR-0002, and the numbers below are the state that reasoning describes.
    """

    # An invocation, a guard, a couple of exports. Past this a block has branches,
    # and branches want a test that can reach them.
    MAXIMUM_INLINE_LINES = 10

    # What the workflows carried when the rule was written. It may fall. A change
    # that raises it is adding script code nothing can run, which is the thing this
    # file exists to stop.
    WORKFLOW_BACKLOG = 27

    def _inline_blocks(self, paths):
        """(file, step name, executable line count) for every `run:` block."""
        for path in paths:
            parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            groups = list((parsed.get("jobs") or {}).values())
            runs = parsed.get("runs") or {}
            if runs.get("steps"):
                groups.append(runs)

            for group in groups:
                for step in group.get("steps") or []:
                    body = step.get("run")
                    if not body:
                        continue
                    lines = [
                        line for line in body.splitlines()
                        if line.strip() and not line.strip().startswith("#")
                    ]
                    yield path, step.get("name") or "(unnamed)", len(lines)

    def _oversized(self, paths):
        return sorted(
            f"  {path.relative_to(harness.REPO_ROOT)} :: {name} ({count} lines)"
            for path, name, count in self._inline_blocks(paths)
            if count > self.MAXIMUM_INLINE_LINES
        )

    def test_no_composite_action_inlines_a_script(self):
        actions = sorted((harness.REPO_ROOT / ".github" / "actions").glob("*/action.yml"))
        self.assertNotVacuous(actions, "there are no composite actions to check")

        oversized = self._oversized(actions)

        self.assertEqual(
            [],
            oversized,
            f"a `run:` block over {self.MAXIMUM_INLINE_LINES} lines cannot be executed "
            "by any test. Several workflows call each action, so this is the surface "
            "where one untested branch is untested everywhere. Move it beside its "
            "action.yml as a .ps1 or .sh and call it from one line. See "
            ".github/actions/queue-vm-command/Write-VmCommand.ps1 for the pattern:\n"
            + "\n".join(oversized),
        )

    def test_the_workflows_are_not_adding_more_inline_script(self):
        workflows = sorted((harness.REPO_ROOT / ".github" / "workflows").glob("*.yml"))
        self.assertNotVacuous(workflows, "there are no workflows to check")

        oversized = self._oversized(workflows)

        self.assertLessEqual(
            len(oversized),
            self.WORKFLOW_BACKLOG,
            f"the workflows now hold {len(oversized)} `run:` blocks over "
            f"{self.MAXIMUM_INLINE_LINES} lines, up from {self.WORKFLOW_BACKLOG}. "
            "Put the new one in a .ps1 or .sh beside the workflow rather than "
            "inline, where a test can run it:\n" + "\n".join(oversized),
        )

        self.assertEqual(
            self.WORKFLOW_BACKLOG,
            len(oversized),
            f"the backlog is down to {len(oversized)}. Lower WORKFLOW_BACKLOG to "
            "match so the ratchet keeps holding.",
        )

class DuplicateYamlKeyTests(harness.HarnessAssertions, unittest.TestCase):
    """No workflow or action declares the same key twice in one mapping.

    `yaml.safe_load` takes the last value and says nothing, and every test in this
    suite loads YAML with it. So a duplicated key is invisible to the whole suite
    while still being a real defect in the file.

    Found the moment it happened. Extracting the bash out of `verify-public-url`
    under ADR-0002 left the step with two `run: |` lines, one empty. The step ran
    the second, so the action still worked by luck. Nothing in 550 tests noticed,
    because the loader they all share had already dropped the evidence.

    The lesson is narrower than "lint the YAML". It is that a tolerant parser makes
    a class of defect unreachable for every assertion written on top of it, so the
    intolerant parse has to be its own test."""

    def _strict_load(self, path):
        """Parse `path`, raising rather than resolving a duplicate mapping key."""

        class Loader(yaml.SafeLoader):
            pass

        def no_duplicates(loader, node, deep=False):
            mapping = {}
            for key_node, value_node in node.value:
                key = loader.construct_object(key_node, deep=deep)
                if key in mapping:
                    raise yaml.constructor.ConstructorError(
                        None, None, f"duplicate key {key!r}", key_node.start_mark
                    )
                mapping[key] = loader.construct_object(value_node, deep=deep)
            return mapping

        Loader.add_constructor(
            yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates
        )
        yaml.load(path.read_text(encoding="utf-8"), Loader=Loader)

    def test_no_pipeline_yaml_declares_a_key_twice(self):
        files = sorted(
            [
                *(harness.REPO_ROOT / ".github" / "workflows").glob("*.yml"),
                *(harness.REPO_ROOT / ".github" / "actions").glob("*/action.yml"),
            ]
        )
        self.assertNotVacuous(files, "there is no pipeline YAML to check")

        offenders = []
        for path in files:
            try:
                self._strict_load(path)
            except yaml.constructor.ConstructorError as error:
                offenders.append(
                    f"  {path.relative_to(harness.REPO_ROOT)} :: {error.problem} "
                    f"at line {error.problem_mark.line + 1}"
                )

        self.assertEqual(
            [],
            offenders,
            "a key is declared twice in one mapping. safe_load takes the last one "
            "and every other test in this suite will agree with it, so this is the "
            "only assertion that can see it:\n" + "\n".join(offenders),
        )


class RunnerExpressionPlacementTests(harness.HarnessAssertions, unittest.TestCase):
    """A `${{ }}` pasted against bare text is a bug twice over, and one fix clears both.

    The runner substitutes the expression's value in as raw text, so
    `${{ github.action_path }}/Write-VmCommand.ps1` is a path nothing quoted. One
    space anywhere in that value and pwsh reads the first word as the command.

    The extractor has to guess at the same line. It wraps the expression in quotes
    so the block parses at all, which turns that path into
    `'RUNNER_EXPRESSION'/Write-VmCommand.ps1` -- a string with a bare `/` after it,
    and a parse error the syntax job reports against code that is fine on a runner.
    A red job nobody can act on gets muted, and it takes the real failures with it.

    Both problems go away the same way: put the expression in `env:` and read
    `$env:NAME` inside the block, or quote it where it stands. For an action's own
    directory the runner already exports `$env:GITHUB_ACTION_PATH`, so no
    expression is needed there at all.

    The check runs the real `substitute()` over the real blocks rather than
    matching the YAML, so it follows the extractor: change how substitution quotes
    things and this moves with it instead of going quietly stale.
    """

    # The shape of the parse error, before pwsh is asked. A quoted placeholder is
    # fine next to whitespace, a bracket, a comma, a pipe, or a `.` method call --
    # all of those legitimately follow a string. A word character, a path
    # separator, or a `$` means it was pasted into the middle of a token.
    JAMMED = re.compile(r"[\w/\\$]'RUNNER_EXPRESSION'|'RUNNER_EXPRESSION'[\w/\\$]")

    # Inside a double-quoted string the substituted quotes are literal characters
    # and nothing is jammed, so those spans come out before the scan. The runner
    # is safe there too: `"a/${{ x }}/b"` is a quoted value however the expression
    # expands. Backtick is PowerShell's escape, so a `" does not end the span.
    DOUBLE_QUOTED = re.compile(r'"(?:`.|[^"`])*"')

    def test_no_runner_expression_is_pasted_into_the_middle_of_a_token(self):
        module = load_extractor()

        blocks = []
        for path in yaml_sources():
            parsed = yaml.safe_load(path.read_text())
            source = path.parent.name if path.name == "action.yml" else path.stem
            for slug, script in module.powershell_steps(parsed, source):
                blocks.append((path.relative_to(harness.REPO_ROOT).as_posix(), slug, script))

        self.assertNotVacuous(blocks, "no pwsh blocks were found, so nothing was checked")

        jammed = []
        for relative, slug, script in blocks:
            for line in module.substitute(script).splitlines():
                if self.JAMMED.search(self.DOUBLE_QUOTED.sub("", line)):
                    jammed.append(f"{relative} ({slug}): {line.strip()}")

        self.assertEqual(
            [],
            jammed,
            "a runner expression is pasted against bare text. On the runner that is "
            "an unquoted value; to the syntax job it is a parse error against code "
            "that would have run. Read it from `env:` instead, or quote it in "
            "place:\n  " + "\n  ".join(jammed),
        )


class PesterJobTests(harness.HarnessAssertions, unittest.TestCase):
    """A second job runs the behaviour tests, and the same rot applies.

    Parsing says the script is well formed. Pester says what it decides, which is
    where the failures have actually been -- the certificate selector preferred a
    self-signed placeholder for months while every test in this suite passed. A
    Pester suite nobody runs is worth exactly as much as the parse job would have
    been if it had never been wired up.
    """

    def pester_job(self):
        """Whichever job runs the suite, found by what it does rather than by name.

        The Pester steps sat in the parse job until they were split out for a
        Windows runner. A lookup pinned to a job name fails for the rename and says
        nothing about whether the suite still runs, which is the only question here.
        """
        jobs = harness.workflow("deployment-pipeline-tests.yml")["jobs"]
        running = {
            name: job
            for name, job in jobs.items()
            if any("Invoke-Pester" in (step.get("run") or "") for step in job["steps"])
        }
        self.assertEqual(
            1,
            len(running),
            f"Expected exactly one job to run Pester, found {sorted(running) or 'none'}.",
        )
        return next(iter(running.values()))

    def pester_step(self):
        """The step that runs the Pester suite."""
        runs = [s for s in self.pester_job()["steps"] if "Invoke-Pester" in (s.get("run") or "")]
        self.assertEqual(1, len(runs), "Nothing in the pipeline runs Pester.")
        return runs[0]

    def runner_images(self, job):
        """The runner images a job actually runs on.

        `runs-on` is either an image or an expression reading a matrix key. Taking
        the literal would read `${{ matrix.os }}` as the name of an image and report
        a job that never goes near Windows as though it did.
        """
        runs_on = str(job.get("runs-on", "")).strip()
        reference = re.fullmatch(r"\$\{\{\s*matrix\.(\w+)\s*\}\}", runs_on)
        if not reference:
            return [runs_on]

        key = reference.group(1)
        matrix = job.get("strategy", {}).get("matrix", {})
        self.assertIn(key, matrix, f"runs-on reads matrix.{key}, which the matrix never defines.")
        return [str(image) for image in matrix[key]]

    def test_the_pipeline_runs_the_pester_suite(self):
        step = self.pester_step()
        self.assertEqual("pwsh", step.get("shell"))

        run = step["run"]
        self.assertIn("Tests/PrTestEnvironments/Pester", run)
        # -PassThru is what makes the result inspectable. Without it the step reads
        # the exit code of a cmdlet that does not set one, and a failing suite goes
        # green.
        self.assertIn("-PassThru", run)
        self.assertIn("FailedCount", run)
        self.assertIn("exit 1", run)

    def test_the_job_installs_pester_before_running_it(self):
        names = [s.get("run") or "" for s in self.pester_job()["steps"]]
        installs = [i for i, run in enumerate(names) if "Install-Module Pester" in run]
        invokes = [i for i, run in enumerate(names) if "Invoke-Pester" in run]

        self.assertEqual(1, len(installs), "Pester is never installed, so the run needs whatever the image ships.")
        self.assertLess(installs[0], invokes[0], "Pester is installed after the step that uses it.")

    def test_the_suite_runs_on_a_windows_runner(self):
        """The one machine these scripts ever run on is a Windows VM.

        Join-Path resolves a drive qualifier through the provider, so
        `Join-Path 'C:\\x' 'y'` finds no drive C on Linux and hands back $null. An
        assertion written with Windows literals then compares $null to $null and
        passes having checked nothing, which is why DeploymentTarget.Tests.ps1
        builds every path from $TestDrive instead. That keeps the Linux leg honest
        and leaves the platform itself unchecked. The Windows leg is what checks it.
        """
        images = self.runner_images(self.pester_job())
        self.assertNotVacuous(images, "The Pester job names no runner image at all.")

        self.assertTrue(
            any("windows" in image for image in images),
            "The Pester suite runs only on "
            + ", ".join(images)
            + ". The deploy target is Windows, and Linux cannot fail an assertion "
            "about a drive letter -- it returns $null and passes.",
        )
        self.assertTrue(
            any("ubuntu" in image for image in images),
            "The Linux leg is gone. It is the cheap one and it is what every other "
            "job in this workflow runs on, so losing it trades fast feedback for "
            "nothing.",
        )

    def test_one_leg_failing_does_not_cancel_the_other(self):
        """Two legs exist because they answer different questions. fail-fast left on
        its default cancels Windows the moment Linux goes red, so the platform
        difference -- the entire reason for the second leg -- is the first thing
        lost on the run that would have shown it."""
        job = self.pester_job()
        if len(self.runner_images(job)) < 2:
            self.skipTest("Single runner image, so there is no sibling leg to cancel.")

        strategy = job.get("strategy", {})
        self.assertIn("fail-fast", strategy, "fail-fast is unset, so it defaults to true.")
        self.assertFalse(strategy["fail-fast"], "fail-fast is on, so the first leg to fail cancels the rest.")

    def test_the_run_refuses_to_report_success_on_zero_tests(self):
        """A -Path that matches nothing returns zero failures, and so does a
        discovery error. Both are the same green as a passing suite unless the step
        says otherwise."""
        run = self.pester_step()["run"]
        self.assertIn("PassedCount", run)
        self.assertIn("throw", run)

    def test_the_path_the_job_names_holds_the_tests(self):
        """Read the directory out of the step rather than restating it here. A
        constant would pass while the job pointed somewhere empty, which is the
        exact failure the step's own zero-test guard exists to catch -- and a test
        that cannot catch it is decoration."""
        run = self.pester_step()["run"]
        named = re.search(r"Invoke-Pester\s+-Path\s+(\S+)", run)
        self.assertIsNotNone(named, "Cannot tell which path the job runs Pester over.")

        target = harness.REPO_ROOT / named.group(1).strip("'\"")
        self.assertTrue(target.is_dir(), f"The pipeline points Pester at {named.group(1)}, which is not a directory.")

        suites = sorted(target.glob("*.Tests.ps1"))
        self.assertTrue(suites, f"{named.group(1)} holds no *.Tests.ps1, so the run would discover nothing.")
        # The constant is what the rest of this file reads. If the job has moved on
        # from it, the two have drifted and one of them is stale.
        self.assertEqual(PESTER_DIR.resolve(), target.resolve())

    def test_every_suite_names_a_script_that_still_exists(self):
        """A suite reaches into Deployment/ by name, including through the -ForEach
        tables that run one behaviour suite against several copies of a function.
        Rename a script and the failure lands in CI as a broken test rather than
        here as a moved file.

        Quoted literals only. The same names appear in prose above each suite, and a
        comment saying `Deployment/PrTestEnvironments/*.ps1` is a glob, not a path.
        """
        quoted = re.compile(r"""['"]([^'"]*?[A-Za-z0-9_-]+\.ps1)['"]""")
        swept = re.compile(r"""Get-RepositoryPath\s+['"]([^'"]+)['"]""")
        deployment = harness.REPO_ROOT / "Deployment" / "PrTestEnvironments"
        found = {}

        for suite in sorted(PESTER_DIR.glob("*.ps1")):
            text = suite.read_text(encoding="utf-8")
            literals = quoted.findall(text)

            # A suite that sweeps a directory rather than loading one script is
            # anchored to that directory instead. ScriptDefaults.Tests.ps1 walks
            # every .ps1 under Deployment/ looking for a parameter default stated
            # twice, so there is no one script for it to name -- but the root it
            # walks still has to exist, or the sweep finds nothing and passes.
            # `$Script` interpolated into the path comes from a -ForEach table, and
            # the table's entries are already checked above as bare filenames.
            directories = [
                target
                for target in swept.findall(text)
                if not target.endswith(".ps1") and "$" not in target
            ]
            for target in directories:
                self.assertTrue(
                    (harness.REPO_ROOT / target).is_dir(),
                    f"{suite.name} sweeps {target}, which is not a directory.",
                )

            found[suite.name] = literals + directories

            for literal in literals:
                # A literal with a path in it is resolved the way the suite itself
                # resolves it: Get-RepositoryPath takes a path from the repository
                # root. The scripts under test are no longer all in one directory --
                # the queue action keeps its PowerShell in .github/actions/ so that
                # action.yml stays a wrapper and the logic inside it can be
                # executed. A bare filename comes from a -ForEach table and is still
                # a deploy script.
                if "/" in literal:
                    script = harness.REPO_ROOT / literal
                    where = literal
                else:
                    script = deployment / literal
                    where = "Deployment/PrTestEnvironments/"

                self.assertTrue(
                    script.is_file(),
                    f"{suite.name} loads {literal}, which is not at {where}.",
                )

        # Per suite rather than a total across all of them. A suite in this
        # directory exists to run a script, so one that names none has had its
        # loader rewritten into a shape this regex no longer sees -- and a total
        # stays comfortably above any floor while that happens to a single file.
        self.assertNotVacuous(found, f"{PESTER_DIR} holds no suites at all.")
        silent = sorted(name for name, anchors in found.items() if not anchors)
        self.assertEqual(
            [],
            silent,
            "These suites name neither a script nor a directory, so nothing here "
            "checked them: " + ", ".join(silent),
        )


class GuardTests(unittest.TestCase):
    """Prove the count check can fail rather than trusting that it would."""

    def test_a_pwsh_step_the_extractor_skips_is_caught(self):
        module = load_extractor()
        parsed = {"jobs": {"build": {"steps": [
            {"name": "runs pwsh", "shell": "pwsh", "run": "Write-Host hi"},
            {"name": "runs bash", "shell": "bash", "run": "echo hi"},
        ]}}}
        blocks = list(module.powershell_steps(parsed, "fixture"))

        self.assertEqual(1, len(blocks))
        self.assertNotIn("echo hi", blocks[0][1])

    def test_a_job_default_shell_still_counts_as_pwsh(self):
        """A step under `defaults.run.shell: pwsh` carries no shell of its own. Missing
        these would drop whole jobs from the parse without changing the count of
        anything visible."""
        module = load_extractor()
        parsed = {"jobs": {"build": {
            "defaults": {"run": {"shell": "pwsh"}},
            "steps": [{"name": "inherits", "run": "Write-Host hi"}],
        }}}

        self.assertEqual(1, len(list(module.powershell_steps(parsed, "fixture"))))

    def test_the_extractor_refuses_to_report_success_on_an_empty_run(self):
        """Zero blocks and a clean exit are indistinguishable to the parse step."""
        source = EXTRACTOR.read_text()
        self.assertIn("Refusing to report success", source)
        self.assertIn("if not written:", source)


if __name__ == "__main__":
    unittest.main()
