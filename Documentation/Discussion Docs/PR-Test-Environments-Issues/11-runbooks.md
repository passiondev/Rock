# Write operator and developer runbooks

**Type:** AFK  
**Blocked by:** 05-sticky-comment-label-reconciliation, 06-stop-destroy-lifecycle, 08-scheduled-idle-cleanup  
**User stories covered:** 1, 2, 4, 5, 6, 8, 13, 16

## What to build

Document how developers use PR test environments and how operators maintain the supporting infrastructure.

## Acceptance criteria

- [x] Developer docs explain when to use `rock:start`, `rock:stop`, `rock:destroy`, and `rock:auto`.
- [x] Developer docs explain that PR sites require VPN access.
- [x] Developer docs explain that the sandbox DB and file storage are shared and refreshed daily.
- [x] Developer docs explain that re-adding `rock:start` restarts/redeploys stale environments.
- [x] Operator docs cover DNS, TLS certificate, firewall/VPN allowlist, SSH deploy user, GCS bucket, and GitHub secrets.
- [x] Operator docs cover environment paths, manifests, IIS naming, logs, cleanup policy, and manual recovery.
- [x] Operator docs cover sandbox DB refresh coordination.
- [x] Docs include a troubleshooting section for failed builds, failed deploys, stopped environments, and certificate/DNS issues.

## Implemented artifacts

- `Documentation/PR-Test-Environments-Developer-Runbook.md`
- `Documentation/PR-Test-Environments-Operator-Runbook.md`
- `Tests/PrTestEnvironments/test_runbooks.py`

## Blocked by

- 05-sticky-comment-label-reconciliation
- 06-stop-destroy-lifecycle
- 08-scheduled-idle-cleanup
