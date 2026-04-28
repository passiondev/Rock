# Harden PR runtime configuration and integration lockdown

**Type:** AFK  
**Blocked by:** 03-deploy-pr-environment-script  
**User stories covered:** 11, 13, 15

## What to build

Ensure deployed PR environments use sandbox-safe runtime configuration, shared sandbox DB/file storage, and disabled or sandboxed external integrations/background jobs.

## Acceptance criteria

- [x] PR deployments write a sandbox DB connection string, not production credentials.
- [x] PR environments use shared sandbox file storage compatible with the sandbox DB.
- [x] Production email/SMS/payment/webhook credentials are not present in PR deployments.
- [x] Background jobs are disabled or constrained so multiple PR sites do not process shared queues unexpectedly.
- [x] Any required app settings are generated per PR where appropriate.
- [x] Logs/temp paths are PR-specific.
- [x] The configuration approach is documented in the operator runbook.
- [x] A deployed PR environment can load Rock and perform basic browser testing without contacting real external systems.

## Implemented artifacts

- `Deployment/PrTestEnvironments/Set-PrEnvironmentRuntimeConfiguration.ps1` writes sandbox DB config, PR-specific logs/temp metadata, shared sandbox file storage metadata, disabled background job settings, and inert outbound integration settings.
- `Deployment/PrTestEnvironments/Deploy-PrEnvironment.ps1` invokes the runtime lockdown script during deployment.
- `.github/workflows/pr-test-deploy.yml` copies the runtime lockdown script to the Windows host with the deploy script.
- `Tests/PrTestEnvironments/test_runtime_lockdown.py` verifies the sandbox runtime configuration contract and basic browser-testing safety documentation.

## Operator runbook notes

- Shared sandbox file storage is configured through `SharedFileStorageRoot` and should match the sanitized sandbox DB.
- Production integration credentials are intentionally not deployed. Email/SMS/payment/webhook/Spark API settings are blank, disabled, or sandbox-disabled.
- Background jobs remain disabled with `RunJobsInIISContext=False` to prevent multiple PR sites from processing shared queues.
- Each PR gets PR-specific `Logs` and `Temp` directories under `C:\RockTestEnvs\pr-<number>`.

## Blocked by

- 03-deploy-pr-environment-script
