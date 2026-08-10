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
