# Add reusable PR artifact packaging

**Type:** AFK  
**Blocked by:** None - can start immediately  
**User stories covered:** 1, 4

## What to build

Extend the existing GitHub Actions build so PR test deployments produce a deterministic deployable `RockWeb` artifact named and stored by PR number and commit SHA.

## Acceptance criteria

- [x] The workflow builds the same deployable `RockWeb` output currently produced by the existing build.
- [x] The package name includes PR number and short commit SHA, for example `RockWeb-pr-123-abcdef.zip`.
- [x] The artifact is uploaded to GitHub Actions artifacts for debugging.
- [x] The artifact is uploaded to GCS under a PR/SHA-specific prefix.
- [x] The artifact excludes production secrets.
- [x] The workflow records enough output metadata for later deploy steps: PR number, SHA, artifact GCS path, and intended host name.

## Implemented artifacts

- `.github/workflows/pr-test-artifact.yml` builds `RockWeb`, packages `RockWeb-pr-<pr>-<sha>.zip`, uploads the zip and `pr-test-artifact.json` to GitHub Actions artifacts, and uploads both files to `gs://rock-deployments-${{ secrets.GCP_PROJECT_ID }}/pr-environments/pr-<pr>/<sha>/`.
- `Tests/PrTestEnvironments/test_pr_artifact_workflow.py` verifies the externally important workflow contract: PR/SHA-scoped artifact naming, GCS prefix, GitHub artifact upload, GCS upload, and no sandbox database secret injection during packaging.

## Blocked by

None - can start immediately
