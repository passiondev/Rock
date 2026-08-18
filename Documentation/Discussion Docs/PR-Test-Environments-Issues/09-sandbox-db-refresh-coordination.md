# Coordinate sandbox DB refresh with PR app pools

**Type:** HITL  
**Blocked by:** 03-deploy-pr-environment-script  
**User stories covered:** 11, 12, 15

## What to build

Coordinate the daily sanitized sandbox DB refresh with PR environments by stopping PR app pools before refresh and restoring or leaving environments in a known state afterward.

## Operating policy decisions

- The DB refresh wrapper runs on the Windows IIS VM.
- Stop all PR app pools before refresh.
- Restart only PR environments that were running before refresh.
- Write developer-visible maintenance state to `C:\RockTestEnvs\maintenance.json`.
- Log refresh coordination to `C:\RockDeploy\logs\sandbox-refresh-*.log`.
- Leave sticky PR comment updates for a later/manual integration unless GitHub credentials are configured on the server.
- Coordinate shared sandbox file storage through an optional command hook alongside the DB refresh.
- **Non-PR environments are out of scope and are left running.** Decided 2026-08-17. `staging` is excluded from the prod restore, so there is nothing being refreshed underneath it and its app pool must not be stopped. Manifests without a `prNumber` are therefore skipped deliberately, with a message that says so, rather than warned about as invalid — the previous wording described `staging` as an invalid manifest on every run.
- **The refresh this issue coordinates does not run, so none of it has ever been exercised.** Measured against GCP on 2026-08-17: `connect-restore-test` was seeded once on 2026-04-14 by a per-database `.bak` import (`IMPORT`, `database: RockConnectProd`, preceded by `DELETE_DATABASE`) and has had no data load since; the Cloud Scheduler API has never been enabled in the project; nothing invokes this script. The acceptance criteria below are met by the script's implementation, not by a process that runs it. Read them as "ready for when the refresh is built", not as "working today".
- **The `pr-*` sites move onto the staging catalog with it.** Decided 2026-08-17, superseding the earlier plan to isolate `staging` alone. Consequence for this issue: once the move is done, **nothing this coordinator manages is on the catalog the prod restore replaces**, so the nightly path it was built for has no app pool left to stop. The acceptance criteria below stay satisfied as written and become vestigial in practice.
  The operation that still needs coordination is the inverse one — re-seeding the staging catalog from the refreshed prod-derived copy on demand — and `prNumber` is the wrong key for it, because that refresh *does* land under `staging` and its pool would have to be stopped along with every `pr-*` pool. Re-key on "does this environment's catalog match the one being refreshed" before pointing the script at a re-seed. Not done here: the fix depends on confirming what the refresh mechanism actually is, which is still unverified — see open item 7 in `Documentation/Training/DevOps-Open-Items-Rock-CICD.md`.

## Acceptance criteria

- [x] The DB refresh process can identify all PR app pools/sites managed by this system.
- [x] PR app pools are stopped before the sandbox DB refresh/sync starts.
- [x] The refresh process runs the required sanitization and post-refresh configuration steps.
- [x] PR app pools are restarted or left stopped according to the agreed operating policy.
- [x] Refresh activity is logged with start/end timestamps and failures.
- [x] Developers have a clear signal when the sandbox DB is in maintenance.
- [x] Failed refreshes do not leave app pools in an unknown state.
- [x] The process accounts for shared sandbox file storage matching the refreshed DB.

## Implemented artifacts

- `Deployment/PrTestEnvironments/Invoke-SandboxRefreshWithPrEnvironments.ps1` discovers PR environments from manifests, writes `maintenance.json`, stops managed PR app pools, invokes refresh/post-refresh/shared-file-storage command hooks, logs with transcripts, and restarts only previously running app pools.
- `Tests/PrTestEnvironments/test_sandbox_refresh.py` verifies the agreed operating policy and refresh wrapper contract.

## Blocked by

- 03-deploy-pr-environment-script
