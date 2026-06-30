# PR Test Environments: Developer Runbook

PR test environments let internal PRs run Rock on the shared Windows/IIS test host without building locally on macOS.

The currently enabled PR base branch is configured in `.github/pr-test-environments.json`. For the current Rock version pin, PR test environments run for PRs targeting `develop-17.6.1`. When Rock is upgraded, update that config and branch new work from the new pinned base branch.

## URL

Each PR uses:

```text
https://pr-<number>.rock-dev.connect.passion.team
```

Example: `https://pr-123.rock-dev.connect.passion.team`.

## Access

VPN/office access is required. The current office/VPN public IP allowlist includes `159.63.145.194`.

## Labels

- `rock-test:start` — build and deploy the latest PR head. Use this for initial deploys, redeploys, or to restart stale environments. If an environment is stopped, re-add `rock-test:start` to rebuild/redeploy and start it again.
- `rock-test:stop` — stop the IIS site/app pool but preserve files, config, and environment state.
- `rock-test:destroy` — remove the IIS site, app pool, files, and manifest.
- `rock-test:auto` — opt into automatic redeploy on every new commit pushed to the PR.

The bot maintains state labels such as `rock-test:queued`, `rock-test:building`, `rock-test:deploying`, `rock-test:deployed`, `rock-test:stopped`, and `rock-test:failed`.

## Data model

PR environments isolate code/runtime only. They share one shared sanitized sandbox database and shared sandbox file storage. The sandbox DB/file state is refreshed daily, so data can change underneath a PR environment.

## Status comment

A sticky PR comment shows the current status, URL, deployed SHA, logs, and command reminders. The comment also notes that VPN access is required and that data is shared/sandboxed.

## Troubleshooting

- Failed build: open the linked GitHub Actions run from the sticky comment.
- Failed deploy: check the deploy job logs and ask an operator to inspect `C:\RockDeploy\logs` and IIS.
- Stopped environment: add `rock-test:start` again.
- DNS/certificate warning: confirm VPN access first, then ask an operator to verify wildcard DNS/TLS.
