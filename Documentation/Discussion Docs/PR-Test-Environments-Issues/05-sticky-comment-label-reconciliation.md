# Add sticky PR status comment and label reconciliation

**Type:** AFK  
**Blocked by:** 04-label-triggered-deploy-workflow  
**User stories covered:** 2, 7, 16

## What to build

Add PR feedback that keeps one sticky bot comment up to date with the PR environment URL, current status, commit SHA, timestamps, and usage instructions. Reconcile state labels so the PR accurately reflects the environment state.

## Acceptance criteria

- [x] A single sticky PR comment is created or updated for each PR environment.
- [x] The comment includes current status, environment URL, deployed SHA, last updated time, and available labels/commands.
- [x] Successful deployments remove transient labels and apply `rock:deployed`.
- [x] Failed deployments remove transient labels and apply `rock:failed`.
- [x] Stopped environments apply `rock:stopped`.
- [x] Destroyed environments remove deployed/stopped/failed state labels.
- [x] Label reconciliation is safe to run repeatedly.
- [x] The comment clearly states that VPN access is required and the DB is shared/sandboxed.

## Implemented artifacts

- `.github/scripts/pr-test-status.js` provides reusable sticky comment rendering/updating and idempotent label reconciliation for queued/building/deploying/deployed/failed/stopped/destroyed states.
- `.github/workflows/pr-test-deploy.yml` now uses the sticky status updater instead of creating deployment result comment spam.
- `Tests/PrTestEnvironments/test_status_comment_script.py` verifies the sticky marker, status content, available commands, VPN/shared-sandbox warnings, state label mapping, and deploy workflow integration.

## Blocked by

- 04-label-triggered-deploy-workflow
