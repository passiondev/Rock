# PR Test Environments: Developer Runbook

PR test environments let internal PRs run Rock on the shared Windows/IIS test host without building locally on macOS.

The currently enabled PR base branch is configured in `.github/pr-test-environments.json`. For the current Rock version pin, PR test environments run for PRs targeting `passion-19.3.4`. When Rock is upgraded, update that config and branch new work from the new pinned base branch.

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

- `rock:start` — build and deploy the latest PR head. Use this for initial deploys, redeploys, or to restart stale environments. If an environment is stopped, re-add `rock:start` to rebuild/redeploy and start it again.
- `rock:stop` — stop the IIS site/app pool but preserve files, config, and environment state.
- `rock:destroy` — remove the IIS site, app pool, files, and manifest.
- `rock:auto` — opt into automatic redeploy on every new commit pushed to the PR.

The bot maintains state labels such as `rock:queued`, `rock:building`, `rock:deploying`, `rock:deployed`, `rock:stopped`, and `rock:failed`.

## Data model

PR environments isolate code/runtime only. They share one shared sanitized sandbox database and shared sandbox file storage, so data can change underneath a PR environment at any time -- another environment's activity is the usual cause. The sandbox is **not** refreshed on a schedule: measured 2026-08-17, it was seeded once on 2026-04-14 and has had no data load since, so nothing resets what accumulates there.

## Status comment

A sticky PR comment shows the current status, URL, deployed SHA, logs, and command reminders. The comment also notes that the URL is reachable without a VPN, that the first request is slow while migrations run, and that data is shared/sandboxed.

## Troubleshooting

- Failed build: open the linked GitHub Actions run from the sticky comment.
- Failed deploy: check the deploy job logs and ask an operator to inspect `C:\RockDeploy\logs` and IIS.
- Stopped environment: add `rock:start` again.
- Certificate warning: expected only on a **brand-new** host. Established hosts hold a real
  Let's Encrypt certificate and show a normal padlock; staging was re-confirmed on 2026-08-19
  (issuer `O=Let's Encrypt`, expires 2026-11-09). A host created since the last renewal serves
  a self-signed placeholder until the weekly job runs -- Monday 08:00 UTC -- so a site created
  on a Tuesday waits almost a week. Clicking through is safe for
  `*.rock-dev.connect.passion.team` only. There is no VPN involved in reaching any of them:
  port 443 is open to the internet.
- DNS failure (host does not resolve at all): ask an operator to verify the wildcard record.
