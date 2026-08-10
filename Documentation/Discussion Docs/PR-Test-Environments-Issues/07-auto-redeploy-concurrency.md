# Implement auto-redeploy and latest-commit-wins concurrency

**Type:** AFK  
**Blocked by:** 04-label-triggered-deploy-workflow  
**User stories covered:** 4, 5

## What to build

Add optional auto-redeploy behavior for PRs labeled `rock-test:auto`, and ensure concurrent deploys for the same PR use latest-commit-wins semantics.

## Acceptance criteria

- [x] PRs with `rock-test:auto` rebuild/redeploy when new commits are pushed.
- [x] PRs without `rock-test:auto` do not auto-redeploy on push.
- [x] Manual `rock-test:start` still redeploys latest PR head regardless of `rock-test:auto`.
- [x] GitHub Actions concurrency is scoped by PR number.
- [x] In-progress deploy runs for a PR are cancelled when a newer run starts.
- [x] The server-side deploy path uses a per-PR lock or equivalent guard to avoid simultaneous IIS/file changes.
- [x] The sticky PR comment and labels reflect the latest run, not a cancelled stale run.

## Implemented artifacts

- `.github/workflows/pr-test-deploy.yml` now also handles PR `synchronize` events, deploys only when `rock-test:auto` is present, and keeps PR-scoped `cancel-in-progress` concurrency.
- `Deployment/PrTestEnvironments/Deploy-PrEnvironment.ps1` now uses a named per-PR mutex while mutating IIS and files.
- `Tests/PrTestEnvironments/test_auto_redeploy.py` verifies auto-label gating, PR-scoped latest-commit-wins concurrency, and server-side locking.

## Blocked by

- 04-label-triggered-deploy-workflow
