# Pilot rollout on one internal PR

**Type:** HITL  
**Blocked by:** 01-bootstrap-server-prerequisites, 04-label-triggered-deploy-workflow, 06-stop-destroy-lifecycle, 10-runtime-config-integration-lockdown, 11-runbooks  
**User stories covered:** 1, 2, 3, 4, 6, 7, 13, 14, 15, 16

## What to build

Run the complete PR test environment workflow against one internal PR and verify the end-to-end developer experience before broader team rollout.

## Pilot attempt

- First pilot PR: https://github.com/passiondev/Rock/pull/2
  - Branch: `pilot/pr-test-env-doc-smoke`
  - Result: closed because it targeted `develop` instead of the configured base branch.
- Current pilot PR: https://github.com/passiondev/Rock/pull/3
  - Branch: `pilot/pr-test-env-doc-smoke-v1761`
  - Base branch: `develop-17.6.1`
  - Change type: documentation-only smoke change
  - Applied label: `rock-test:start`
  - Current result: no GitHub Actions run started yet because `pull_request_target` workflows are loaded from the base branch, so the PR test environment implementation and `.github/pr-test-environments.json` must exist on `develop-17.6.1` before the label-triggered pilot can execute.

## Acceptance criteria

- [x] An internal PR can be labeled with `rock-test:start`.
- [ ] GitHub Actions builds the latest PR head and uploads a PR/SHA-specific artifact to GCS.
- [ ] The Google Windows server deploys the artifact into a PR-specific IIS site/app pool.
- [ ] The sticky PR comment shows the correct URL, SHA, status, and instructions.
- [ ] The PR URL is reachable over VPN and not reachable from an unapproved network.
- [ ] Rock loads successfully in a browser and can be functionally tested.
- [ ] Re-adding `rock-test:start` redeploys or restarts as expected.
- [ ] `rock-test:stop` stops the environment while preserving files/site state.
- [ ] `rock-test:destroy` tears down the environment cleanly.
- [ ] Merging a test PR destroys the environment automatically.
- [ ] The team reviews pilot feedback and decides whether to enable the workflow for all internal PRs.

## Blocked by

- 01-bootstrap-server-prerequisites
- 04-label-triggered-deploy-workflow
- 06-stop-destroy-lifecycle
- 10-runtime-config-integration-lockdown
- 11-runbooks
