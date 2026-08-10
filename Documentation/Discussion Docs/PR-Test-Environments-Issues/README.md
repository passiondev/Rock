# Implementation Issues: PR Test Environments for Rock RMS

Parent PRD: `Documentation/Discussion Docs/PR-Test-Environments-PRD.md`

These are tracer-bullet implementation slices written as markdown issue drafts instead of GitHub issues.

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
