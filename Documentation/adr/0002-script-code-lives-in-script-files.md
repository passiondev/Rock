# ADR-0002: Script code lives in a script file, never inlined into YAML

- **Status:** accepted
- **Date:** 2026-08-26
- **Governs:** `.github/actions/**/action.yml`, `.github/workflows/*.yml`
- **Enforced by:** `Tests/PrTestEnvironments/test_powershell_job.py`, class `ScriptsLiveInScriptFilesTests`

## Context

A `run:` block in a workflow or a composite action is a string. Nothing can call
it, nothing can import it, and nothing can execute one part of it. The only way to
run it is to run the whole workflow.

`.github/scripts/extract-powershell-blocks.py` gives some cover. It parse-checks
every inline PowerShell block in CI. A parse is not a run: it catches a typo and
misses every wrong answer.

Two blocks made the cost concrete. The wait in `.github/actions/await-vm-command`
ran to 97 lines of PowerShell, with two copies of the same integer parse and a
log-tail slice nobody had ever executed.

The check in `.github/actions/verify-public-url` ran to 64 lines of bash comparing
certificate distinguished names, under a comment warning that a name arrives in
more than one form. Neither block had a test, because neither block could have one.

## Decision

Script code lives in a `.ps1` or a `.sh` beside the `action.yml` that calls it. The
YAML holds the call and the environment it passes.

The rule lands in two strengths, because the two surfaces differ in cost.

- **Composite actions: absolute.** No `run:` block over 10 lines. A composite
  action is a reusable module and its `run:` block is the implementation. There is
  no reason for that implementation to sit out of reach.

- **Workflows: a downward-only ratchet.** 27 blocks sit over the limit today. The
  test asserts the count has not risen, and fails when the count drops and the
  constant does not drop with it. So the backlog can only shrink.

A script file gets a dot-source guard, so a test can load its functions without
running its body:

```powershell
if ([string]::IsNullOrWhiteSpace($env:AWAIT_BUCKET)) { return }
```

## Why the split

One absolute rule across both surfaces would have meant extracting 27 blocks out of
production deploy workflows, in the same change that introduced the rule.

That is a large untested edit to the path that ships to production, and tidiness is
the whole of the case for it. The ratchet reaches the same end state and pays for
it one block at a time, next to whatever change is already in that workflow.

## Consequences

The extracted script and the `action.yml` must agree on environment variable names.
Those names are now an interface with two sides and no compiler.

`extract-powershell-blocks.py` still runs. It now covers a shrinking backlog rather
than the whole pipeline.

The test docstring names the 27 remaining blocks, so the number is a known debt
rather than an unmeasured one.

## What would reopen this

Nothing about the workflow ratchet. It already heads where the absolute rule points.

The composite-action rule is worth reopening only if GitHub gives a `run:` block a
callable form. Until then, no test can reach a block that nothing can execute, and
the argument does not turn on taste.
