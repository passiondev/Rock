# Create PR environment deploy script

**Type:** AFK  
**Blocked by:** 01-bootstrap-server-prerequisites, 02-pr-artifact-packaging  
**User stories covered:** 1, 3, 4, 6, 7, 11

## What to build

Create a server-side PowerShell deploy script that takes a PR number, commit SHA, artifact GCS path, and host name, then idempotently creates or updates that PR's IIS site/app pool from the artifact.

## Acceptance criteria

- [x] Script accepts PR number, SHA, artifact path, and hostname as parameters.
- [x] Script uses PR number as the only environment key.
- [x] Script stops the existing app pool before replacing files.
- [x] Script downloads and extracts the GCS artifact into the PR environment path.
- [x] Script creates or updates the IIS app pool `rock-pr-<number>`.
- [x] Script creates or updates the IIS site `rock-pr-<number>`.
- [x] Script configures the HTTPS host binding for `pr-<number>.<dev-domain>` using the wildcard certificate.
- [x] Script writes the sandbox DB connection config for the PR site.
- [x] Script writes per-PR runtime state to an environment manifest such as `env.json`.
- [x] Script starts the app pool/site after deployment.
- [x] Re-running the script for the same PR is safe and updates the environment in place.

## Implemented artifacts

- `Deployment/PrTestEnvironments/Deploy-PrEnvironment.ps1` is the server-side IIS deployment script.
- `Tests/PrTestEnvironments/test_pr_deploy_script.py` verifies the script contract for required parameters, PR-keyed IIS names/paths, manifest writing, IIS binding management, and avoiding whole-VM/IIS restarts.

## Blocked by

- 01-bootstrap-server-prerequisites
- 02-pr-artifact-packaging
