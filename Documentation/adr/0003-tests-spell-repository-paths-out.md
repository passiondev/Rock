# ADR-0003: Test files write repository paths out in full rather than through an accessor

- **Status:** accepted
- **Date:** 2026-08-26 (recording a decision first taken 2026-08-21)
- **Governs:** `Tests/PrTestEnvironments/*.py`, `Tests/PrTestEnvironments/pipeline_harness.py`
- **Enforced by:** `Tests/PrTestEnvironments/test_ci_trigger_coverage.py`

## Context

`deployment-pipeline-tests.yml` filters on `paths:`. A file the suite reads that
the filter does not list runs the suite on every push except the one that matters.

That hole has turned up three times. Twice the team patched it by hand and pinned
the fix with a hand-kept list of required paths.

The third gap went unnoticed for the same reason. A hand-kept list only knows what
somebody remembered to add to it. It cannot fail for a path nobody thought of.

So `test_ci_trigger_coverage.py` derives the required set from the test sources
themselves. It finds every path the suite reads by matching one literal form:

```python
READ_PATH = re.compile(r'REPO_ROOT\s*((?:/\s*"[^"]+"\s*)+)')
```

That is `REPO_ROOT / "a" / "b"`, with every segment a quoted literal. A new test
that reads somewhere new fails the coverage check until somebody widens the
trigger, whether or not anyone remembers the check exists.

## Decision

Test files write their repository paths out in the literal form above. They do not
address a file through a directory accessor or a path helper.

`pipeline_harness.py` exports `WORKFLOWS_DIR` and `ACTIONS_DIR` and nothing else of
that kind. Those two survive because the walks that use them sit inside the harness,
where the literal form is right there in the same file.

The module dropped `SCRIPTS_DIR`, `DEPLOYMENT_DIR` and `DOCUMENTATION_DIR` rather
than keep them, and dropped a proposed `repo_text(*parts)` rather than adopt it.

## Why

An accessor is invisible to the scan. A test that reads `DOCUMENTATION_DIR / "x.md"`
names no literal path, so the coverage check counts zero reads for it and never asks
the CI filter to cover it.

The failure is silent, and it is silent in the direction that matters. The check
keeps passing while the coverage it reports shrinks.

Accessors would empty the scan one file at a time, and nothing would go red on the
day it happened.

## Consequences

Paths in test files are longer than they need to be, and a directory rename is a
wider edit.

That trades a small repeated cost for a guard nobody can quietly defeat. A reviewer
who does not know why will read the verbosity as an oversight, which is what this
record answers.

An architecture review has proposed the accessor twice. The second proposal fell
mid-implementation, once somebody traced the scan.

## What would reopen this

A scan that follows an accessor through to the paths behind it, rather than matching
one literal form. That is a real option and nobody has built it. Until somebody
does, the literal form is what makes the check work.
