# PR Test Environments: Developer Runbook

**Last verified:** 2026-08-19

PR test environments let internal PRs run Rock on the shared Windows/IIS test host without building locally on macOS.

The currently enabled PR base branch is configured in `.github/pr-test-environments.json`. For the current Rock version pin, PR test environments run for PRs targeting `passion-19.4.4`. When Rock is upgraded, update that config and branch new work from the new pinned base branch.

## URL

Each PR uses:

```text
https://pr-<number>.staging.connect.passion.team
```

Example: `https://pr-123.staging.connect.passion.team`.

## Access

No VPN or office network is required: HTTPS/443 on the test VM is open to the internet
(firewall rule `https-from-world`). The `159.63.145.194` allowlist applies to RDP and SQL only.

## Labels

- `rock:start` — build and deploy the latest PR head. Use this for initial deploys, redeploys, or to restart stale environments. If an environment is stopped, re-add `rock:start` to rebuild/redeploy and start it again.
- `rock:stop` — stop the IIS site/app pool but preserve files, config, and environment state.
- `rock:destroy` — remove the IIS site, app pool, files, and manifest.
- `rock:auto` — opt into automatic redeploy on every new commit pushed to the PR.
- `rock:full-build` — always do a full build, never a repackage (see below). Adding it does not start anything on its own; it changes what the next `rock:start` or `rock:auto` deploy does. Remove it when you are done, or every push builds.

The bot maintains state labels such as `rock:queued`, `rock:building`, `rock:deploying`, `rock:deployed`, `rock:stopped`, and `rock:failed`.

## Changes that skip the build

A full build takes about half an hour. Most changes do not need one: Lava, `.ascx`
markup and its code-behind, theme `.less`, images and scripts under `RockWeb/` are
copied into the artifact as they are. When every file your PR changed since an
earlier artifact is like that, the pipeline **repackages** that artifact with your
files swapped in, and the deploy starts within minutes. The same applies to staging
after a merge and to production promoting what staging already built.

It is automatic. The run's summary says which it did: *Artifact plan* names the base
artifact and lists the files patched in, or says why it built. A change anywhere a
build writes -- C# outside `RockWeb/`, `RockWeb/Bin`, plugins, Obsidian, the
`Rock.Frontend.Styles` themes, the webpack bundles -- always builds. The full list is
`.github/scripts/artifact-paths.json`.

A warning in the summary naming a file as **server-owned** means the deploy keeps the
server's copy of it, so your change is in the artifact but may not reach the site.
It appears whether the run built or repackaged. Theme override files edited through
Admin Tools are the usual case.

## Data model

PR environments isolate code/runtime only. They share one shared sandbox database and shared sandbox file storage, so data can change underneath a PR environment at any time -- another environment's activity is the usual cause. The sandbox is **not** refreshed on a schedule: measured 2026-08-17, it was seeded once on 2026-04-14 and has had no data load since, so nothing resets what accumulates there.

**The catalog is not sanitized.** It is a straight copy of a production backup -- real names, addresses and giving history -- and every PR environment serves it on a public URL behind nothing but Rock's login. The runbooks called it "sanitized" until 2026-08-19; the sanitization step that word referred to has never existed (see open item 24). Treat what you see in a PR environment as live congregant data.

## Status comment

A sticky PR comment shows the current status, URL, deployed SHA, logs, and command reminders. The comment also notes that the URL is reachable without a VPN, that the first request is slow while migrations run, and that data is shared/sandboxed.

## Troubleshooting

- Failed build: open the linked GitHub Actions run from the sticky comment.
- Failed repackage, or a site that does not reflect a change the run repackaged: add
  `rock:full-build`, then `rock:start`. A repackage never falls back to a build on its
  own. Tell an operator too -- the second case means `artifact-paths.json` is wrong
  about a path.
- Failed deploy: check the deploy job logs and ask an operator to inspect `C:\RockDeploy\logs` and IIS.
- Stopped environment: add `rock:start` again.
- Certificate warning: expected only on a **brand-new** host. Established hosts hold a real
  Let's Encrypt certificate and show a normal padlock; staging was re-confirmed on 2026-08-19
  (issuer `O=Let's Encrypt`, expires 2026-11-09). A host created since the last renewal serves
  a self-signed placeholder until the weekly job runs -- Monday 08:00 UTC -- so a site created
  on a Tuesday waits almost a week. Clicking through is safe for
  `*.staging.connect.passion.team` only. There is no VPN involved in reaching any of them:
  port 443 is open to the internet.
- DNS failure (host does not resolve at all): ask an operator to verify the wildcard record.
