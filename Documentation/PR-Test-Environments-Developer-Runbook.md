# PR Test Environments: Developer Runbook

PR test environments let internal PRs run Rock on the shared Windows/IIS test host without building locally on macOS.

The currently enabled PR base branch is configured in `.github/pr-test-environments.json`. For the current Rock version pin, PR test environments run for PRs targeting `passion-18.4.1`. When Rock is upgraded, update that config and branch new work from the new pinned base branch.

## URL

Each PR uses:

```text
https://pr-<number>.rock-dev.connect.passion.team
```

Example: `https://pr-123.rock-dev.connect.passion.team`.

## Access

No VPN or office network is required: HTTPS/443 on the test VM is open to the internet
(firewall rule `https-from-world`). The `159.63.145.194` allowlist applies to RDP and SQL only.

## Labels

- `rock-test:start` — build and deploy the latest PR head. Use this for initial deploys, redeploys, or to restart stale environments. If an environment is stopped, re-add `rock-test:start` to rebuild/redeploy and start it again.
- `rock-test:stop` — stop the IIS site/app pool but preserve files, config, and environment state.
- `rock-test:destroy` — remove the IIS site, app pool, files, and manifest.
- `rock-test:auto` — opt into automatic redeploy on every new commit pushed to the PR.

The bot maintains state labels such as `rock-test:queued`, `rock-test:building`, `rock-test:deploying`, `rock-test:deployed`, `rock-test:stopped`, and `rock-test:failed`.

## Data model

PR environments isolate code/runtime only. They share one shared sanitized sandbox database and shared sandbox file storage. The sandbox DB/file state is refreshed daily, so data can change underneath a PR environment.

## Status comment

A sticky PR comment shows the current status, URL, deployed SHA, logs, and command reminders. The comment also notes that the URL is reachable without a VPN, that the first request is slow while migrations run, and that data is shared/sandboxed.

## Troubleshooting

- Failed build: open the linked GitHub Actions run from the sticky comment.
- Failed deploy: check the deploy job logs and ask an operator to inspect `C:\RockDeploy\logs` and IIS.
- Stopped environment: add `rock-test:start` again.
- Certificate warning: currently expected. These hosts serve a self-signed certificate
  (measured 2026-08-11); the fix is written but not yet on the VM. There is no VPN involved
  in reaching them -- port 443 is open to the internet.
- DNS failure (host does not resolve at all): ask an operator to verify the wildcard record.
