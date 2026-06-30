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

## Implemented artifacts

- `Deployment/PrTestEnvironments/Invoke-PrEnvironmentCleanup.ps1` reads `env.json` manifests, stops deployed environments after 6 idle hours, destroys stopped/stale environments after 7 idle days, supports `-WhatIf`, and skips corrupt manifests safely.
- `Tests/PrTestEnvironments/test_cleanup_script.py` verifies manifest-driven policy, manual verification support, optional GitHub credential hook, and PR-only safety.

## Blocked by

- 06-stop-destroy-lifecycle
