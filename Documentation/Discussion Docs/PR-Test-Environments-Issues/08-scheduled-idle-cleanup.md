# Add scheduled idle cleanup

**Type:** AFK  
**Blocked by:** 06-stop-destroy-lifecycle  
**User stories covered:** 8, 9, 10

## What to build

Add a scheduled cleanup process on the Windows server that reads PR environment manifests and applies lifecycle policies for idle and closed environments.

## Acceptance criteria

- [x] Cleanup reads all PR environment manifests under the environment root.
- [x] Cleanup stops running environments after 6 hours of lifecycle inactivity.
- [x] Cleanup destroys idle or closed-unmerged environments after 7 days.
- [x] Cleanup never destroys active environments before the configured timeout.
- [x] Cleanup logs all stop/destroy actions.
- [x] Cleanup can be run manually for verification.
- [x] Cleanup can optionally update PR comments/labels when GitHub credentials are available.
- [x] Cleanup handles missing/corrupt manifests safely.
- [x] Cleanup does not affect non-PR IIS sites or app pools.

## What is still missing — added 2026-08-19

Every box above is ticked and none of them is the one this issue is named for. They all
describe what the script does *when it is run*; not one says anything runs it. Nothing does:

- No workflow has a `schedule:` trigger for it. The only cron in `.github/workflows` is
  `pr-test-renew-certificates.yml` (`0 8 * * 1`).
- No script calls `Register-ScheduledTask` or `schtasks` for it.
  `Install-PrEnvironmentCommandQueueTask.ps1` installs exactly one task, "Rock PR Environment
  Command Queue", running `Invoke-PrEnvironmentCommandQueue.ps1` every minute.
- The bootstrap workflow copies `Invoke-PrEnvironmentCleanup.ps1` to the VM, which is why it
  looks wired up. Being present on disk is not being scheduled.

So the acceptance criteria are honestly met and the issue is still not done. Closing it needs
either a scheduled trigger or an explicit decision that reaping stays manual — and that is a
decision, not an oversight to quietly fix: switching it on starts destroying PR environments
after 7 idle days, and the fleet is currently managed by hand.

Tracked as open item 6 in `Documentation/Training/DevOps-Open-Items-Rock-CICD.md`.

## Implemented artifacts

- `Deployment/PrTestEnvironments/Invoke-PrEnvironmentCleanup.ps1` reads `env.json` manifests, stops deployed environments after 6 idle hours, destroys stopped/stale environments after 7 idle days, supports `-WhatIf`, and skips corrupt manifests safely.
- `Tests/PrTestEnvironments/test_cleanup_script.py` verifies manifest-driven policy, manual verification support, optional GitHub credential hook, and PR-only safety.

## Blocked by

- 06-stop-destroy-lifecycle
