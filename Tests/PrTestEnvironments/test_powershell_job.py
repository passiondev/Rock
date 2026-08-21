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
import pathlib
import re
import sys
import unittest

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
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
    spec = importlib.util.spec_from_file_location("extract_powershell_blocks", EXTRACTOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def yaml_sources():
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
        workflow = harness.workflow("deployment-pipeline-tests.yml")
        job = workflow["jobs"].get("powershell")

        self.assertIsNotNone(job, "deployment-pipeline-tests.yml no longer parses the PowerShell.")

        steps = job["steps"]
        extracts = [s for s in steps if "extract-powershell-blocks.py" in (s.get("run") or "")]
        self.assertEqual(1, len(extracts), "The embedded blocks are no longer extracted before the parse.")

        parses = [s for s in steps if "Language.Parser" in (s.get("run") or "")]
        self.assertEqual(1, len(parses), "Nothing in the job calls the PowerShell parser.")

        parse = parses[0]
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
            declares = bool(DECLARES_PWSH.search(raw))
            name = path.relative_to(harness.REPO_ROOT).as_posix()

            if declares:
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

    def test_the_shared_wait_is_among_the_extracted_blocks(self):
        """The action holds the largest single block of PowerShell in the pipeline and
        it is the reason the parse job was written. A composite action's steps sit
        under `runs:` rather than `jobs:`, so it is also the shape most likely to be
        dropped by a change to the extractor."""
        module = load_extractor()
        parsed = yaml.safe_load(AWAIT_ACTION_FILE.read_text(encoding="utf-8"))
        blocks = list(module.powershell_steps(parsed, "await-vm-command"))

        self.assertEqual(1, len(blocks))
        self.assertIn("AWAIT_COMMAND_ID", blocks[0][1])

    def test_a_runner_expression_does_not_become_two_empty_strings(self):
        """`'${{ x }}'` is already quoted by its author. Adding another pair yields
        `''PLACEHOLDER''`, which is a bareword between two empty strings -- a
        different thing entirely, and in expression position a parse error the job
        would report against innocent code."""
        module = load_extractor()

        self.assertEqual("Get-Content 'RUNNER_EXPRESSION' -Raw", module.substitute("Get-Content '${{ steps.a.outputs.b }}' -Raw"))
        self.assertEqual("$x = 'RUNNER_EXPRESSION'", module.substitute("$x = ${{ inputs.y }}"))


class PesterJobTests(unittest.TestCase):
    """The same job also runs the behaviour tests, and the same rot applies.

    Parsing says the script is well formed. Pester says what it decides, which is
    where the failures have actually been -- the certificate selector preferred a
    self-signed placeholder for months while every test in this suite passed. A
    Pester suite nobody runs is worth exactly as much as the parse job would have
    been if it had never been wired up.
    """

    def pester_step(self):
        job = harness.workflow("deployment-pipeline-tests.yml")["jobs"].get("powershell")
        self.assertIsNotNone(job, "The PowerShell job is gone.")
        runs = [s for s in job["steps"] if "Invoke-Pester" in (s.get("run") or "")]
        self.assertEqual(1, len(runs), "Nothing in the pipeline runs Pester.")
        return runs[0]

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
        job = harness.workflow("deployment-pipeline-tests.yml")["jobs"]["powershell"]
        names = [s.get("run") or "" for s in job["steps"]]
        installs = [i for i, run in enumerate(names) if "Install-Module Pester" in run]
        invokes = [i for i, run in enumerate(names) if "Invoke-Pester" in run]

        self.assertEqual(1, len(installs), "Pester is never installed, so the run needs whatever the image ships.")
        self.assertLess(installs[0], invokes[0], "Pester is installed after the step that uses it.")

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
        deployment = harness.REPO_ROOT / "Deployment" / "PrTestEnvironments"
        checked = 0

        for suite in sorted(PESTER_DIR.glob("*.ps1")):
            for literal in quoted.findall(suite.read_text(encoding="utf-8")):
                checked += 1

                # A literal with a path in it is resolved the way the suite itself
                # resolves it, relative to $PSScriptRoot. The scripts under test are
                # no longer all in one directory: the queue action keeps its
                # PowerShell in .github/actions/ so that action.yml stays a wrapper
                # and the logic inside it can be executed. A bare filename comes from
                # a -ForEach table and is still a deploy script.
                if "/" in literal:
                    script = (PESTER_DIR / literal).resolve()
                    where = literal
                else:
                    script = deployment / literal
                    where = "Deployment/PrTestEnvironments/"

                self.assertTrue(
                    script.is_file(),
                    f"{suite.name} loads {literal}, which is not at {where}.",
                )

        # Nine references across four suites at the time of writing. The floor is
        # there so a regex that stops matching reads as a failure and not as a pass.
        self.assertGreaterEqual(checked, 9, f"Only found {checked} script references; the suites name more than that.")


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
