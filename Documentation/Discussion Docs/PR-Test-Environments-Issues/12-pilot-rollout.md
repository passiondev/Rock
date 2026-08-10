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
  - Base branch: `passion-18.4.1` as configured in `.github/pr-test-environments.json`
  - Change type: documentation-only smoke change
  - Applied label: `rock-test:start`
  - Current result: GitHub Actions now triggers from `rock-test:start`, builds the latest PR head, packages and uploads the PR/SHA-specific artifact to GCS, updates the sticky PR comment, and fails at the SSH deployment step because the Google Windows VM is not reachable from GitHub-hosted runners on port 22.
  - Latest run: https://github.com/passiondev/Rock/actions/runs/25059249875
  - Artifact: `gs://rock-deployments-connect-test-471613/pr-environments/pr-3/aea0dba5c8aea556e62fb2767d4e5260360a48d7/RockWeb-pr-3-aea0dba.zip`

## Acceptance criteria

- [x] An internal PR can be labeled with `rock-test:start`.
- [x] GitHub Actions builds the latest PR head and uploads a PR/SHA-specific artifact to GCS.
- [ ] The Google Windows server deploys the artifact into a PR-specific IIS site/app pool.
- [x] The sticky PR comment shows the correct URL, SHA, status, and instructions.
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
