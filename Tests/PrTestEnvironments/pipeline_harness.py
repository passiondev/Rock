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

import functools
import pathlib
import re
import subprocess
from collections import Counter

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# Only the two directories this module itself walks. `SCRIPTS_DIR`,
# `DEPLOYMENT_DIR` and `DOCUMENTATION_DIR` were here too and nothing ever used
# them, which looks like an oversight and is not: a test that addressed a file as
# `DOCUMENTATION_DIR / "x.md"` would hide that path from
# test_ci_trigger_coverage.py, which finds what the suite reads by looking for the
# literal quoted-segment form. Adopting them would empty that scan file by file.
# So test files spell their paths out, and these two stay because the walks below
# are in this module, where the literal form is right here.
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
# directory, this file included.) Rolling an accessor out
# across the suite would have emptied that scan file by file, and the CI trigger's
# coverage check would have gone green over a suite it could no longer see. The
# duplication the card counted is real; it is also what keeps the paths visible.
# Test files spell their paths out for that reason, and the cost is one line each.


@functools.lru_cache(maxsize=None)
def workflow(name):
    """A parsed workflow. `on:` is returned under the key `True` by PyYAML, because
    YAML 1.1 reads a bare `on` as a boolean, so callers reach for `triggers()`."""
    return yaml.safe_load((WORKFLOWS_DIR / name).read_text(encoding="utf-8"))


@functools.lru_cache(maxsize=None)
def composite_action(name):
    """A parsed composite action, addressed by its directory name.

    Mirrors `workflow()` because the two are read the same way and for the same
    reasons. A composite action's steps run inside the caller's job and show up in
    the caller's run, so anything asserted about workflow steps -- that a title
    exists, that a block is PowerShell -- has to look here too or it reports a
    clean result over half the tree."""
    return yaml.safe_load((ACTIONS_DIR / name / "action.yml").read_text(encoding="utf-8"))


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
            f"line {text.count(chr(10), 0, m.start()) + 1}: {m.group(0)!r}"
            for m in re.finditer(pattern, text, flags)
        ]
        self.assertFalse(offenders, f"{why}:\n  " + "\n  ".join(offenders))
