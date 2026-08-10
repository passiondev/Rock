# Implement stop and destroy lifecycle commands

**Type:** AFK  
**Blocked by:** 03-deploy-pr-environment-script, 05-sticky-comment-label-reconciliation  
**User stories covered:** 6, 8, 9, 10

## What to build

Add server scripts and GitHub workflow handling for `rock-test:stop` and `rock-test:destroy`, plus PR close/merge behavior.

## Acceptance criteria

- [x] Adding `rock-test:stop` stops the PR app pool/site but preserves files, IIS config, and environment manifest.
- [x] Adding `rock-test:destroy` removes the PR IIS site, app pool, deployed files, and manifest.
- [x] Stop/destroy command labels are removed after queueing.
- [x] Stop/destroy results update the sticky PR comment.
- [x] Stop/destroy results reconcile state labels.
- [x] Merged PRs destroy their environment immediately.
- [x] Closed-unmerged PRs stop their environment immediately and remain eligible for later timeout-based destruction.
- [x] Reopened PRs can be started again with `rock-test:start`.
- [x] Stop and destroy scripts are idempotent and safe if the environment does not exist.

## Implemented artifacts

- `Deployment/PrTestEnvironments/Stop-PrEnvironment.ps1` stops the PR IIS site/app pool and preserves files/config/manifest.
- `Deployment/PrTestEnvironments/Destroy-PrEnvironment.ps1` removes PR IIS resources and files.
- `.github/workflows/pr-test-lifecycle.yml` handles `rock-test:stop`, `rock-test:destroy`, merged PR destroy, and closed-unmerged PR stop, then updates the sticky PR status comment.
- `Tests/PrTestEnvironments/test_lifecycle_workflow.py` verifies idempotent PR-keyed scripts and lifecycle workflow behavior.

## Blocked by

- 03-deploy-pr-environment-script
- 05-sticky-comment-label-reconciliation
