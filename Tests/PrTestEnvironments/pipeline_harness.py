"""What every test in this suite needs before it can assert anything.

Thirty-three files opened with the same four lines: resolve the repository root,
name a file under it, read the text, parse the YAML. Four of them also sliced a
PowerShell function body out by hand, and each slice was spelled slightly
differently. None of that is the thing under test, and repeating it is how the
suite ended up with assertions that cannot fail -- `assertIn("SecurityProtocol",
text)` against a 918-line script passes while the two sites that set it are
deleted, because a comment mentioning TLS keeps the token in the file.

So the harness supplies the reading *and* the guard against reading too loosely.
`assertNotVacuous` makes a set-derived test say out loud that it found anything
at all, and `assertNoMatch` reports the line rather than just failing. Both were
already present in this suite, applied unevenly, in four files out of thirty-three.

This module is deliberately not named `test_*.py`: unittest discovery would
collect it. `test_ci_trigger_coverage.py` scans every `*.py` here, not only the
test files, so paths that move into this module stay visible to the CI trigger
check.
"""

import copy
import functools
import json
import pathlib
import re
import subprocess
from collections import Counter

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# Only the two directories this module itself walks. `SCRIPTS_DIR`,
# `DEPLOYMENT_DIR` and `DOCUMENTATION_DIR` were here too and nothing ever used
# them, which looks like an oversight and is not. See ADR-0003: an accessor hides
# its path from test_ci_trigger_coverage.py, which finds what the suite reads by
# matching the literal quoted-segment form, so adopting accessors would empty that
# scan one file at a time with nothing going red. These two stay because the walks
# below are in this module, where the literal form is right here.
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
ACTIONS_DIR = REPO_ROOT / ".github" / "actions"


# Card 05 of the 2026-08-21 architecture review asked this module for four things:
# the root, `workflow()`, `script()` and the non-vacuity guard. Three of them are
# here. `script()` is the one that is deliberately absent, and a `repo_text(*parts)`
# standing in for it was removed rather than adopted.
#
# The reason is that `REPO_ROOT.joinpath(*parts)` hides the path from
# test_ci_trigger_coverage.py, which finds what the suite reads by looking for the
# literal quoted-segment form: the root constant, then each directory as its own
# quoted string. (Spelling that shape out here as an example makes this comment a
# path the scan then goes looking for -- it is derived from every `*.py` in this
# directory, this file included.) Rolling an accessor out across the suite would
# have emptied that scan file by file, and the CI trigger's coverage check would
# have gone green over a suite it could no longer see. The duplication the card
# counted is real; it is also what keeps the paths visible. Test files spell their
# paths out for that reason, and the cost is one line each.
#
# The same answer governs how far `workflow()` goes, which is the part of the card
# that looks half-finished and is not. Some files call it; the rest still parse a
# module-level constant of their own. Those constants are the declaration -- a file
# saying `REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"` is how the
# scan learns that file reads that workflow. Swapping them for `workflow("...")`
# would collapse fifteen named workflows into this module's `WORKFLOWS_DIR` and
# leave the trigger check unable to say which test guards which file. Nothing about
# the CI filter would go red, because `.github/workflows/**` is wide enough to hide
# it -- which is the failure mode, not the reassurance.
#
# So `workflow()` is for callers that already hold a name: iterating the directory,
# or reading a workflow a constant elsewhere already declares. It is not a
# replacement for the constants, and the eight-of-forty count is the shape this is
# meant to have rather than a migration that stalled.


@functools.lru_cache(maxsize=None)
def _parsed_workflow(name):
    """The cached parse. Callers get a copy of it, never this object."""
    return yaml.safe_load((WORKFLOWS_DIR / name).read_text(encoding="utf-8"))


def workflow(name):
    """A parsed workflow. `on:` is returned under the key `True` by PyYAML, because
    YAML 1.1 reads a bare `on` as a boolean, so callers reach for `triggers()`.

    A fresh copy each call. The parse is cached because it is the expensive half and
    forty test files read the same dozen workflows, but handing every caller the same
    dictionary makes one test that edits a step visible to every test that runs after
    it -- in whatever order the runner happened to pick. A suite whose whole job is
    catching false greens should not ship that one."""
    return copy.deepcopy(_parsed_workflow(name))


@functools.lru_cache(maxsize=None)
def _parsed_composite_action(name):
    """The cached parse. Callers get a copy of it, never this object."""
    return yaml.safe_load((ACTIONS_DIR / name / "action.yml").read_text(encoding="utf-8"))


def composite_action(name):
    """A parsed composite action, addressed by its directory name.

    Mirrors `workflow()` because the two are read the same way and for the same
    reasons -- including the copy. A composite action's steps run inside the
    caller's job and show up in the caller's run, so anything asserted about
    workflow steps -- that a title exists, that a block is PowerShell -- has to
    look here too or it reports a clean result over half the tree."""
    return copy.deepcopy(_parsed_composite_action(name))


def composite_actions():
    """Every composite action's directory name, sorted."""
    return sorted(path.parent.name for path in ACTIONS_DIR.glob("*/action.yml"))


def action_steps(parsed):
    """The step list of a parsed composite action, or empty for any other kind.

    A `using: node20` action has no steps to walk, and neither does one whose
    `runs:` block is missing entirely."""
    runs = parsed.get("runs") or {}
    if runs.get("using") != "composite":
        return []
    return runs.get("steps") or []


def line_of(text, index):
    """The 1-based line number of `index` in `text`.

    Hand-rolled as `text.count("\n", 0, match.start()) + 1` in six places before
    this existed. It is correct every time it is written out, which is why it kept
    getting written out -- but a failure message that points at the wrong line
    costs more to debug than the assertion saved."""
    return text.count("\n", 0, index) + 1


def triggers(parsed):
    """The `on:` block of a parsed workflow, whichever key PyYAML put it under."""
    return parsed.get("on") or parsed.get(True)


def steps(parsed, job=None):
    """Every step of a workflow, or of one named job."""
    jobs = parsed.get("jobs", {})
    names = [job] if job else list(jobs)
    found = []
    for name in names:
        found.extend(jobs.get(name, {}).get("steps", []) or [])
    return found


# The T-SQL a script issues when it changes something. One list, because two
# tests read it for opposite purposes -- proving the read-only finder contains
# none of these, and sorting `Deployment/Database` into the scripts that write and
# the scripts that do not -- and two lists would let a verb be added to the
# classifier while the read-only scan went on ignoring it.
SQL_WRITE_VERBS = (
    r"\bALTER\s+TABLE\b",
    # `UPDATE [dbo].[x]`, `UPDATE $table`, `UPDATE dbo.x` and `UPDATE TOP (n)
    # $table` -- the last one is how the anonymizer batches, and pinned to `[` this
    # matched none of it. Found by sorting Deployment/Database with this list and
    # having the anonymizer come back read-only.
    r"\bUPDATE\s+(?:TOP\s*\([^)]*\)\s*)?(?:\[|\$|dbo\.)",
    r"\bDELETE\s+FROM\b",
    r"\bINSERT\s+INTO\b",
    r"\bDROP\s+\w",
    r"\bTRUNCATE\s+TABLE\b",
    r"\bCREATE\s+(TABLE|INDEX|PROCEDURE)\b",
    r"\bEXEC(UTE)?\s+sp_",
)


def strip_powershell_comments(text):
    """`text` with block and line comments blanked, line numbers preserved.

    Four files had a copy of this, differing only in a lambda parameter name. It
    is here for the reason `line_of` is: correct every time somebody writes it,
    which is why it kept getting written, and the cost is not the duplication but
    that a fix to one copy reaches none of the others.

    Every caller needs it for the same reason. These scripts explain in comments
    exactly the thing the test scans for -- the read-only finder names the write
    it deliberately does not perform, the anonymizer quotes the house rule it
    diverges from -- so without this, adding the explanation fails the test that
    the explanation is about."""
    text = re.sub(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.DOTALL)
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def powershell_function(text, name):
    """The body of one PowerShell function, from its declaration to the next one.

    Four tests did this by hand with three different spellings, and a slice that
    silently misses leaves every assertion inside it running against the empty
    string -- which passes for `assertNotIn` and fails confusingly for
    `assertIn`. This raises instead.
    """
    marker = f"function {name}"
    if marker not in text:
        raise AssertionError(f"no `{marker}` in the text under test")
    body = text.split(marker, 1)[1]
    return body.split("\nfunction ", 1)[0]


def powershell_function_lines(text, name):
    """Line range `[start, end)` of one PowerShell function, 0-indexed.

    `powershell_function` above answers the same question as a string, which is
    what a test wants when it greps the body. This is for the tests that ask
    where a line *is* -- whether the icacls grant sits inside the branch that
    wipes the directory, whether the server-owned restore runs where there is
    anything to restore. Those need line numbers on both sides of the question.

    Four of them counted braces from `if ($Mode -eq \'DedicatedSite\') {` to find
    that range. A branch condition is a weak thing to anchor on: the same line
    appears twice in the deploy script at the same indent, one of them inside
    Resolve-DeploymentTarget, and the docstring of one of those tests still
    records the version that matched an app-pool naming block and passed while
    the overlay sat on the production path. A function name is not ambiguous in
    that way, and when the ordering moves into a named function the anchor moves
    with it instead of quietly matching nothing.

    The range is the body, so `start` is the line after the declaration and `end`
    is the closing brace's line. Raises when the name is absent, for the reason
    `powershell_function` does: a missing range is a passing test.
    """
    lines = text.splitlines()
    declaration = re.compile(rf"^function\s+{re.escape(name)}\b")
    openers = [index for index, line in enumerate(lines) if declaration.match(line)]
    if not openers:
        raise AssertionError(f"no column-zero `function {name}` in the text under test")
    if len(openers) > 1:
        raise AssertionError(
            f"`function {name}` is defined {len(openers)} times, at lines "
            + ", ".join(str(index + 1) for index in openers)
        )

    depth = 0
    start = None
    for index in range(openers[0], len(lines)):
        line = lines[index]
        depth += line.count("{") - line.count("}")
        if start is None and "{" in line:
            start = index + 1
        if start is not None and depth <= 0:
            return start, index
    raise AssertionError(f"`function {name}` is never closed")


def _balanced(text, start):
    """The text from the `{` at or after `start` to the brace that closes it."""
    open_index = text.index("{", start)
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_index + 1 : index]
    raise AssertionError("unbalanced braces from index %d" % open_index)


def command_binding_kinds(text):
    """The section names of a contract row that bind a field to a script parameter.

    Asked of the queue agent rather than restated here. `Get-CommandBindingKind`
    is the one place the binder reads them from, and a section it does not
    recognise is a refusal rather than a binding that quietly does nothing -- so
    a Python test carrying its own copy of the six names would be holding rows to
    a list that can drift away from the one doing the refusing, in the direction
    that passes.
    """
    body = powershell_function(text, "Get-CommandBindingKind")
    returned = re.search(r"return\s+@\(([^)]*)\)", body)
    if returned is None:
        raise AssertionError("Get-CommandBindingKind no longer returns a list literal")
    return re.findall(r"'([^']+)'", returned.group(1))


def command_contract(text, verb):
    """One verb's row of the queue agent's contract table, as its sections.

    Returns `Script` and `TimeoutSeconds` as a string and an int, each binding
    section -- `Required`, `Optional`, `Flag`, `List`, `Verbatim`, `Runtime` --
    as a dict from the queued document's field name to the script parameter it
    reaches, and `Unreachable` as the list of script parameters that row holds
    out of reach. Absent sections are absent, not empty, so a test can say a
    field is bound as a Flag by where it turns up.

    Both shapes are read because the row has two. A binding section maps a name
    to a name and is written `[ordered]@{}`; `Unreachable` names parameters and
    nothing else, so it is a plain `@()`. Reading only the first shape dropped
    the second silently, which for a reader whose whole job is to say what a row
    contains is the failure to avoid.

    Three files sliced the old switch's arm for this by hand, each with its own
    spelling of the arm's opening brace, and then regexed the slice. Those regexes
    were reading a script the tests could not run: the switch lived inside the
    block handed to Start-Job, so matching its source text was the only assertion
    available. The table it became is data, and this reads it as data.

    The behaviour behind a row is asserted by calling the binder --
    Pester/CommandContract.Tests.ps1 does that. What is left for Python is the
    half that crosses languages: that the workflows queue the verbs this table
    has rows for, and that the rows name scripts that exist.
    """
    rows = _balanced(text, text.index("$contracts = [ordered]@{"))

    marker = re.search(rf"^\s*'{re.escape(verb)}'\s*=\s*@\{{", rows, re.MULTILINE)
    if marker is None:
        raise AssertionError(f"the contract table has no row for '{verb}'")

    row = _balanced(rows, marker.start())
    contract = {}

    script = re.search(r"Script\s*=\s*'([^']+)'", row)
    if script:
        contract["Script"] = script.group(1)

    timeout = re.search(r"TimeoutSeconds\s*=\s*(\d+)", row)
    if timeout:
        contract["TimeoutSeconds"] = int(timeout.group(1))

    for section in re.finditer(r"^\s*(\w+)\s*=\s*\[ordered\]@\{", row, re.MULTILINE):
        body = _balanced(row, section.start())
        contract[section.group(1)] = dict(
            re.findall(r"(\w+)\s*=\s*'([^']+)'", body)
        )

    for section in re.finditer(r"^\s*(\w+)\s*=\s*@\(", row, re.MULTILINE):
        opened = row.index("(", section.start())
        closed = row.index(")", opened)
        contract[section.group(1)] = re.findall(r"'([^']+)'", row[opened + 1 : closed])

    return contract


def command_contract_verbs(text):
    """Every verb the queue agent has a row for."""
    rows = _balanced(text, text.index("$contracts = [ordered]@{"))
    return [
        match.group(1)
        for match in re.finditer(r"^\s*'([a-z][a-z0-9-]*)'\s*=\s*@\{", rows, re.MULTILINE)
    ]


@functools.lru_cache(maxsize=1)
def tracked():
    """Every path git tracks, as posix strings.

    `git ls-files` and not a filesystem walk. A working Rock checkout has real
    plugin folders on disk under `RockWeb/Plugins/` that are not tracked, so a
    walk would measure the developer's machine rather than the branch.
    """
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def tracked_under(directory, suffix=""):
    """Tracked files below `directory`, as posix strings relative to the repository root.

    `directory` is a Path under REPO_ROOT, not a string. Tracked rather than
    globbed, so a build output or a scratch file sitting in the tree does not
    become something a test demands the pipeline account for."""
    prefix = directory.relative_to(REPO_ROOT).as_posix() + "/"
    return [p for p in tracked() if p.startswith(prefix) and p.endswith(suffix)]


# The node half of `run_github_script`. It stands in for the three things a
# github-script body reaches for -- `github`, `core` and `require` -- and nothing
# else, so a body that grows a fourth fails here by name instead of passing.
#
# The fake GitHub holds one thing: the labels on each pull request. It answers a
# missing label or an unknown pull request with a 404, as GitHub does, so a body
# that sends the wrong issue number fails on the add rather than quietly labelling
# nothing. Labels are what these bodies exist to change, and what a test asserts.
#
# `require` resolves a relative path against the working directory, which is how
# github-script resolves it against the workspace. The runner starts node at the
# repository root, so the module a body requires is the one in this tree -- the
# one the job's checkout would have put there.
_GITHUB_SCRIPT_DRIVER = r"""
const path = require('path');
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));

const pulls = new Map(Object.entries(input.labels).map(([number, names]) => [Number(number), new Set(names)]));

function notFound(what) {
  const error = new Error(`Not Found: ${what}`);
  error.status = 404;
  return error;
}

function labelsOf(issue_number) {
  if (!pulls.has(issue_number)) {
    throw notFound(`pull request ${issue_number}`);
  }
  return pulls.get(issue_number);
}

const github = {
  rest: {
    issues: {
      async removeLabel({ issue_number, name }) {
        if (!labelsOf(issue_number).delete(name)) {
          throw notFound(`label ${name}`);
        }
      },
      async addLabels({ issue_number, labels }) {
        const held = labelsOf(issue_number);
        for (const name of labels) {
          held.add(name);
        }
      }
    },
    repos: {
      async getContent({ path: filePath }) {
        if (!(filePath in input.files)) {
          throw notFound(filePath);
        }
        return { data: { content: Buffer.from(input.files[filePath]).toString('base64') } };
      }
    }
  }
};

const outputs = {};
let failed = null;
const core = {
  setOutput(name, value) { outputs[name] = String(value); },
  setFailed(message) { failed = String(message); },
  info() {},
  warning() {}
};

const context = { repo: { owner: 'passiondev', repo: 'Rock' }, ...input.context };
const workspaceRequire = (id) => require(id.startsWith('.') ? path.resolve(id) : id);
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

new AsyncFunction('github', 'context', 'core', 'require', input.body)(github, context, core, workspaceRequire)
  .then(() => {
    const labels = Object.fromEntries([...pulls].map(([number, held]) => [number, [...held].sort()]));
    process.stdout.write(JSON.stringify({ labels, outputs, failed }));
  });
"""


def run_github_script(body, labels, context=None, expressions=None, files=None):
    """Run an `actions/github-script` body under node against a fake GitHub, and
    return what it left behind: `labels` (pull request number to its sorted label
    names), `outputs` (what it passed to `core.setOutput`) and `failed` (what it
    passed to `core.setFailed`, or None).

    `labels` is the starting state, `{42: ["rock:queued"]}`. `files` is what
    `repos.getContent` serves, by path. `expressions` maps each `${{ }}` in the body
    to the text Actions would paste in its place. Pasting is what Actions does
    before node ever sees the body, so the runner does the same -- and refuses a
    body with one left over, because node would read it as a string, turn the
    number in it into NaN, and fail somewhere unrelated.

    Reading a `script:` body as text proves a word is in it. Running it proves
    what it does to the pull request, which is the only thing the step is for.
    A node failure raises with node's own stderr; it is never a quiet empty result.
    """
    for expression, value in (expressions or {}).items():
        body = body.replace("${{ " + expression + " }}", value)
    leftover = re.search(r"\$\{\{.*?\}\}", body)
    if leftover:
        raise AssertionError(f"no value supplied for {leftover.group(0)}; pass it in `expressions`")

    completed = subprocess.run(
        ["node", "-e", _GITHUB_SCRIPT_DRIVER],
        input=json.dumps({
            "body": body,
            "labels": {str(number): names for number, names in labels.items()},
            "context": context or {},
            "files": files or {},
        }),
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise AssertionError(f"the script failed under node:\n{completed.stderr}")

    result = json.loads(completed.stdout)
    result["labels"] = {int(number): names for number, names in result["labels"].items()}
    return result


class HarnessAssertions:
    """Mixed into a TestCase. Every method here exists because the plain
    assertion it replaces was, somewhere in this suite, unable to fail."""

    def assertOneShape(self, labelled, what, why):
        """Every text in `labelled` is byte-identical, or fail naming each distinct
        shape and the sources carrying it.

        `labelled` is (source, text) pairs. Three places in this suite guard a block
        that is copied on purpose -- a workflow cannot import another workflow, and a
        composite action cannot reach the VM -- so the copies are the design and this
        is the only thing holding them in step. What makes the report worth sharing
        rather than the assertion is that "they differ" across nine files leaves the
        reader diffing by eye; grouped by shape, the odd one out is the short list."""
        self.assertNotVacuous(labelled, f"nothing matched, so {what} is not being checked at all")

        shapes = Counter(text for _, text in labelled)
        if len(shapes) == 1:
            return

        report = "\n\n".join(
            f"--- in {sorted({source for source, text in labelled if text == shape})} ---\n{shape}"
            for shape in shapes
        )
        self.fail(
            f"{what} has drifted into {len(shapes)} shapes across {len(labelled)} "
            f"copies. {why}\n\n{report}"
        )

    def assertNotVacuous(self, collection, why):
        """A derived set that comes back empty makes every assertion over it
        pass. Four tests in this suite guard against that. The rest did not."""
        self.assertTrue(
            len(collection) > 0,
            f"the derivation found nothing, so the check over it proves nothing: {why}",
        )

    def assertNoMatch(self, pattern, text, why, flags=0):
        """assertNotIn against a long file prints the whole file into the
        failure. Report the offending lines and nothing else."""
        offenders = [
            f"line {line_of(text, m.start())}: {m.group(0)!r}"
            for m in re.finditer(pattern, text, flags)
        ]
        self.assertFalse(offenders, f"{why}:\n  " + "\n  ".join(offenders))
