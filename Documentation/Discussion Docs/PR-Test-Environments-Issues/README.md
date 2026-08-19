# Implementation Issues: PR Test Environments for Rock RMS

Parent PRD: `Documentation/Discussion Docs/PR-Test-Environments-PRD.md`

These are tracer-bullet implementation slices written as markdown issue drafts instead of GitHub issues.

**All twelve shipped.** These are kept as the design record of how the pipeline was
built and why, not as work outstanding. They are frozen at the time they were written
and are deliberately not bumped as the system changes -- so do not read a value here as
current. For how the pipeline behaves today, read, in order of authority:

- the workflows in `.github/workflows/` and `.github/pr-test-environments.json`, which
  are the only definitive source;
- `Documentation/PR-Test-Environments-Operator-Runbook.md` and
  `Documentation/PR-Test-Environments-Developer-Runbook.md`;
- `Documentation/Training/DevOps-Open-Items-Rock-CICD.md` for what is still open, and
  `Documentation/Incidents/` for what has gone wrong.

Two of the slices below have since been overtaken by measurement, which is worth
knowing before you take either at face value. Slice 9 coordinates PR app pools with a
nightly sandbox refresh that **does not exist** -- the sandbox was seeded once and has
had no data load since (open item 7). Slice 12's acceptance criteria were re-marked
against observed evidence on 2026-08-19 and several came back unmet.

## Proposed Order

1. [Bootstrap server prerequisites and network access](./01-bootstrap-server-prerequisites.md) — HITL
2. [Add reusable PR artifact packaging](./02-pr-artifact-packaging.md) — AFK
3. [Create PR environment deploy script](./03-deploy-pr-environment-script.md) — AFK
4. [Create GitHub label-triggered deploy workflow](./04-label-triggered-deploy-workflow.md) — AFK
5. [Add sticky PR status comment and label reconciliation](./05-sticky-comment-label-reconciliation.md) — AFK
6. [Implement stop and destroy lifecycle commands](./06-stop-destroy-lifecycle.md) — AFK
7. [Implement auto-redeploy and latest-commit-wins concurrency](./07-auto-redeploy-concurrency.md) — AFK
8. [Add scheduled idle cleanup](./08-scheduled-idle-cleanup.md) — AFK
9. [Coordinate sandbox DB refresh with PR app pools](./09-sandbox-db-refresh-coordination.md) — HITL
10. [Harden PR runtime configuration and integration lockdown](./10-runtime-config-integration-lockdown.md) — AFK
11. [Write operator and developer runbooks](./11-runbooks.md) — AFK
12. [Pilot rollout on one internal PR](./12-pilot-rollout.md) — HITL
