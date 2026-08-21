"""What every test in this suite needs before it can assert anything.

Thirty-three files opened with the same four lines: resolve the repository root,
name a file under it, read the text, parse the YAML. Four of them also sliced a
PowerShell function body out by hand, and each slice was spelled slightly
differently. None of that is the thing under test, and repeating it is how the
suite ended up with assertions that cannot fail -- `assertIn("SecurityProtocol",
text)` against a 918-line script passes while the two sites that set it are
deleted, because a comment mentioning TLS keeps the token in the file.

So the harness supplies the reading *and* the guard against reading too loosely.
`assertInScope` makes the caller name the region the token has to appear in, and
`assertNotVacuous` makes a set-derived test say out loud how many things it
found. Both were already present in this suite, applied unevenly, in four files
out of thirty-three.

This module is deliberately not named `test_*.py`: unittest discovery would
collect it. `test_ci_trigger_coverage.py` scans every `*.py` here, not only the
test files, so paths that move into this module stay visible to the CI trigger
check.
"""

import functools
import pathlib
import re
import subprocess

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
ACTIONS_DIR = REPO_ROOT / ".github" / "actions"
SCRIPTS_DIR = REPO_ROOT / ".github" / "scripts"
DEPLOYMENT_DIR = REPO_ROOT / "Deployment"
DOCUMENTATION_DIR = REPO_ROOT / "Documentation"


def repo_text(*parts):
    """The text of a repository file, addressed from the root."""
    path = REPO_ROOT.joinpath(*parts)
    if not path.exists():
        raise AssertionError(f"{path.relative_to(REPO_ROOT).as_posix()} does not exist in this checkout")
    return path.read_text(encoding="utf-8")


@functools.lru_cache(maxsize=None)
def workflow(name):
    """A parsed workflow. `on:` is returned under the key `True` by PyYAML, because
    YAML 1.1 reads a bare `on` as a boolean, so callers reach for `triggers()`."""
    return yaml.safe_load((WORKFLOWS_DIR / name).read_text(encoding="utf-8"))


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
    prefix = directory.relative_to(REPO_ROOT).as_posix() + "/"
    return [p for p in tracked() if p.startswith(prefix) and p.endswith(suffix)]


class HarnessAssertions:
    """Mixed into a TestCase. Every method here exists because the plain
    assertion it replaces was, somewhere in this suite, unable to fail."""

    def assertInScope(self, needle, text, scope, why=""):
        """Assert `needle` appears inside a named region of `text`, not anywhere
        in it. `scope` is a (start_marker, end_marker) pair, or a callable that
        returns the region."""
        if callable(scope):
            region = scope(text)
            label = getattr(scope, "__name__", "the scoped region")
        else:
            start_marker, end_marker = scope
            if start_marker not in text:
                raise AssertionError(f"the region marker {start_marker!r} is gone from the text under test")
            region = text.split(start_marker, 1)[1]
            region = region.split(end_marker, 1)[0] if end_marker and end_marker in region else region
            label = f"between {start_marker!r} and {end_marker!r}"

        self.assertIn(needle, region, f"{needle!r} is not {label}. {why}".strip())

    def assertOccursExactly(self, count, needle, text, why=""):
        """The count matters when a token appearing twice means two code paths
        and appearing once means somebody deleted one of them."""
        actual = text.count(needle)
        self.assertEqual(
            count,
            actual,
            f"{needle!r} appears {actual} times, expected {count}. {why}".strip(),
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
