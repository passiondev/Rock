# Create GitHub label-triggered deploy workflow

**Type:** AFK  
**Blocked by:** 02-pr-artifact-packaging, 03-deploy-pr-environment-script  
**User stories covered:** 1, 4, 14

## What to build

Create a GitHub Actions workflow that responds to `rock:start` on internal PRs, builds the deployable artifact, uploads it to GCS, and invokes the server-side deployment script over SSH.

## Acceptance criteria

- [x] Adding `rock:start` to an internal PR triggers the workflow.
- [x] The workflow refuses to deploy PRs from forks or external repositories.
- [x] The workflow removes the one-shot `rock:start` command label after queueing.
- [x] The workflow applies transient state labels such as queued/building/deploying.
- [x] The workflow builds and uploads the PR artifact.
- [x] The workflow SSHes to the Google Windows server using GitHub Actions secrets.
- [x] The workflow invokes the deploy script with PR number, SHA, GCS artifact path, and hostname.
- [x] On success, the workflow marks the PR as deployed.
- [x] On failure, the workflow marks the PR as failed and preserves a link to logs.

## Implemented artifacts

- `.github/workflows/pr-test-deploy.yml` handles `rock:start`, rejects forked PRs, reconciles command/state labels, calls the reusable artifact workflow, copies `Deploy-PrEnvironment.ps1` to `C:\RockDeploy`, and invokes it over SSH.
- `Tests/PrTestEnvironments/test_label_deploy_workflow.py` verifies the externally important workflow contract: label trigger, fork refusal, artifact workflow reuse, SSH deployment, domain convention, state labels, and PR log comments.

## Blocked by

- 02-pr-artifact-packaging
- 03-deploy-pr-environment-script
