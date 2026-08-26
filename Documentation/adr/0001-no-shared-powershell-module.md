# ADR-0001: The deploy scripts copy their shared helpers rather than importing a module

- **Status:** accepted
- **Date:** 2026-08-26 (recording a decision the code has held since before 2026-08-18)
- **Governs:** `Deployment/PrTestEnvironments/*.ps1`, `.github/workflows/pr-test-bootstrap-command-queue.yml`
- **Enforced by:** `Tests/PrTestEnvironments/test_shared_powershell_helpers.py`

## Context

`Deployment/PrTestEnvironments/` holds twelve PowerShell scripts. Several carry the
same helper functions, copied rather than shared. A reviewer who counts those
copies reaches for a `.psm1` beside them, and an architecture review has now
proposed exactly that twice.

These scripts do not run from the repository. They run on a Windows VM that fetches
them from a bucket, and the fetch is the part that constrains the design.

## Decision

The copies stay. `Deployment/PrTestEnvironments/` gets no shared `.psm1`.

Instead, a test compares the copied bodies and fails when they drift apart. The
test normalizes whitespace first, because the bootstrap copy lives in a YAML
here-string at a different indent, with `$` escaped as a backtick-dollar.

## Why

Three reasons. The third is the one no design removes.

**1. The shipping path does not carry a `.psm1` today.**

The bootstrap publishes with `gsutil cp Deployment/PrTestEnvironments/*.ps1`.
`pr-test-bootstrap-command-queue.yml` then finds published scripts with
`Where-Object { $_ -like '*.ps1' }`. Neither matches `.psm1`.

On top of those sits a hand-typed floor list of ten names. On 2026-08-18 the glob
and the floor list disagreed by one file, and the agent failed a command on a
bootstrap that had reported success. A module would add a fourth place to keep in
step, in the one path where being out of step is silent.

**2. A partly applied publish would break everything rather than one thing.**

Widening the glob is a one-line edit, so reason 1 alone would not settle this. What
the edit buys is a deploy that fails when the module is absent, on a queue agent
that updates itself out of the same bucket that updates it.

Scripts new and module missing breaks every command on the VM. A drifted copy
breaks one.

**3. One copy can never import anything.**

The VM startup script defines `Get-GcsAccessToken` and `Copy-GcsObjectToFile`
inline, because they are what fetches everything else onto the box. That copy runs
before any module could reach the machine.

It is the copy most likely to drift, and the only one no refactor can remove.

## Consequences

A helper that changes must change in every copy. The test names the copies that
disagree, so the cost is a red test rather than a silent divergence.

The duplication is visible and will keep drawing review comments. That is what this
record is for.

## What would reopen this

The bootstrap no longer being the publish path. If the VM ever pulls this directory
as a versioned unit that either lands whole or does not land at all, reason 1 and
reason 2 both go, and only the startup-script copy remains. A module is worth a
second look at that point.
