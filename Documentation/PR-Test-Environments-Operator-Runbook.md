# PR Test Environments: Operator Runbook

## Infrastructure

- Base branch config: `.github/pr-test-environments.json` controls which PR base branch is eligible for PR test environments. It currently targets `passion-18.4.1` for the Rock version pin. Update this value during Rock upgrades.
- Wildcard DNS: `*.rock-dev.connect.passion.team` points to the Google Windows VM. Cloudflare is configured manually in DNS-only mode.
- TLS: PR hosts use Let's Encrypt certificates installed in LocalMachine `My` and bound in IIS. `.github/workflows/pr-test-renew-certificates.yml` runs weekly and can be dispatched manually; it temporarily applies the `pr-test-acme-http` VM network tag for HTTP-01 validation, queues `renew-certificate`, then removes the tag. A Cloudflare DNS token would allow a future wildcard DNS-01 flow.
- Firewall: **as actually configured, HTTPS/443 is open to the whole internet** via the rule
  `https-from-world`, not restricted to office egress. The `159.63.145.194/32` allowlist covers
  RDP and SQL only. This document previously described the restricted design as though it were
  in force; it is not. These hosts run a sanitized sandbox database, so the exposure is bounded,
  but the gap between intent and reality is worth a decision rather than a surprise.
  A pre-created GCP firewall rule named `pr-test-acme-http` allows HTTP/80 only to VMs with the
  `pr-test-acme-http` network tag, which the renewal workflow applies only during ACME validation.
- Deployment control plane: GitHub Actions uploads artifacts/commands to GCS; the Windows VM polls the command queue. Do not expose SSH publicly for PR environment deployment.
- GCP/GCS: artifacts and commands use `PR_TEST_GCS_BUCKET`.
- GitHub secrets/vars used by workflows: `GCP_PROJECT_ID`, `GCP_SA_KEY`, `GCP_VM_NAME`, `GCP_VM_EXTERNAL_IP`, `GCP_ZONE`, `PR_TEST_GCS_BUCKET`, `PR_TEST_DB_DATA_SOURCE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.

## Paths and naming

- PR environment root: `C:\RockTestEnvs`
- Deploy script root: `C:\RockDeploy`
- Logs: `C:\RockDeploy\logs`
- IIS site/app pool: `rock-pr-<number>`
- Environment path: `C:\RockTestEnvs\pr-<number>`
- Site path: `C:\RockTestEnvs\pr-<number>\site`
- Manifest: `env.json`
- Maintenance signal: `C:\RockTestEnvs\maintenance.json`

## Scripts

- `Deploy-PrEnvironment.ps1` creates/updates a PR environment from a GCS artifact.
- `Set-PrEnvironmentRuntimeConfiguration.ps1` writes sandbox DB/runtime config and disables outbound integrations/background jobs.
- `Stop-PrEnvironment.ps1` stops a PR site/app pool without deleting files.
- `Destroy-PrEnvironment.ps1` removes PR IIS resources and files.
- `Invoke-PrEnvironmentCleanup.ps1` stops deployed environments after 6 idle hours and destroys stale stopped environments after 7 days. Use `-WhatIf` for manual verification.
- `Invoke-SandboxRefreshWithPrEnvironments.ps1` stops PR app pools before DB refresh and restarts only previously running app pools afterward.
- `Invoke-PrEnvironmentCertificateRenewal.ps1` issues/renews Let's Encrypt certs for deployed PR environments and rebinds IIS HTTPS bindings. Run through the scheduled/manual certificate renewal workflow so the `pr-test-acme-http` network tag is present only during ACME validation.

## Sandbox DB refresh coordination

Run the refresh through `Invoke-SandboxRefreshWithPrEnvironments.ps1` on the Windows VM. Provide the existing sanitized DB refresh command via `-RefreshCommand`. Optional hooks:

- `-PostRefreshCommand` for post-refresh sanitization/configuration.
- `-SharedFileStorageCommand` for shared sandbox file storage refresh.

The script writes maintenance state to `C:\RockTestEnvs\maintenance.json` and logs to `C:\RockDeploy\logs\sandbox-refresh-*.log`.

Note that this script only *coordinates* the refresh -- `-RefreshCommand` is mandatory and the restore itself lives outside this repository.

**Measured 2026-08-17: there is no refresh, so this script has never run.** The sandbox catalog was
seeded once, on 2026-04-14, by a per-database `.bak` import from a 2026-04-09 production backup, and
has had no data load since -- `gcloud sql operations list --instance=connect-restore-test` shows
`UPDATE` and `RESTART` only after that date, and its whole history is 13 operations. The Cloud
Scheduler API has never been enabled in the project, and the only `cron:` in `.github/workflows/` is
certificate renewal. `connect-prod`'s own nightly Cloud SQL backups *do* run reliably, but those are
instance-level and cannot be restored into a single catalog, which is why the one load that happened
went through an export/import.

Consequences worth knowing before you plan around this script:

- The sandbox data is months old, not nightly-fresh, and it accumulates every environment's test
  data and migrations indefinitely. Anything that assumes an overnight reset is wrong.
- Building the refresh for real means producing a fresh `.bak` (the bucket holds exactly one set,
  from 2026-05-12) and importing it per-database, then invoking this script around it.
- Nothing here is a data-loss risk today. It is a staleness and drift problem.

### Staging is deliberately out of scope

The coordinator stops app pools only for manifests carrying a `prNumber`, which `Deploy-PrEnvironment.ps1` is the only writer to emit. `staging` is deployed by `Deploy-RockEnvironment.ps1` in `DedicatedSite` mode, so its manifest at `C:\RockTestEnvs\staging\env.json` has no PR number and the coordinator now logs `Leaving non-PR environment 'staging' running` and moves on. That message replaced a `Skipping invalid PR manifest` warning that read like a defect on every run.

That is correct, and for a simpler reason than this section used to give: **no refresh runs at all**, so nothing is being replaced under any app pool. Earlier revisions warned that the nightly restore was overwriting the database beneath a live `rock-staging`; that was inherited from design intent and is not what the instance's operation history shows.

`prNumber` is nonetheless the wrong key for the operation that *would* need coordination. Re-seeding the staging catalog on demand lands squarely under `staging`, so its pool would have to stop along with every `pr-*` pool -- the one case `prNumber` cannot express. Re-key the coordinator on "does this environment's catalog match the one being refreshed" before pointing it at a re-seed; see open item 7.

## Provisioning the staging catalog

Staging and every `pr-*` site currently share one catalog -- the prod-derived one a restore would target, if one ran -- so Rock's startup migrations from one environment rewrite the schema the others depend on. This is what put `pr-3` on a permanent HTTP 500 on 2026-08-11.

**Decided 2026-08-17: staging and the `pr-*` sites move onto the staging catalog together.** This supersedes the earlier half-step of isolating `staging` alone. A shared catalog is not itself the defect -- sharing one *across two Rock minors* is, because Rock migrates the schema at `Application_Start`. Every `pr-*` site builds from a PR based on the branch staging deploys, so they are all the same minor by construction, and `Tests/PrTestEnvironments/test_base_branch_config.py` fails if the two pins drift apart. What this actually buys is that no environment of ours sits on the catalog the prod restore owns.

The cost this looked like it carried turns out to be zero. It appeared to trade away nightly data freshness for the `pr-*` sites -- but as measured on 2026-08-17 there is no nightly refresh to give up (see below). The catalog is already months stale and already accumulating every environment's test data and migrations with no reset, so moving it does not make the data situation worse. Drift from production is a real problem; it is just a pre-existing one, and the fix for it is a deliberate re-seed, not this decision.

Current shared setup, for reference:

| | |
|---|---|
| Instance | `connect-restore-test` (`172.20.0.2`) -- *not* `connect-prod` (`172.20.0.8`) |
| Catalog | `RockConnectProd` -- the name is an artifact of restoring a prod backup, not production data |
| Consumed via | secrets `PR_TEST_DB_DATA_SOURCE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` |

To provision:

1. ~~**Decide where the catalog lives, and check the refresh mechanism first.**~~ **Resolved 2026-08-17 — `RockStaging` on `connect-restore-test` is fine.** The refresh is a per-database `.bak` import (`IMPORT` with `database: RockConnectProd`, preceded by a `DELETE_DATABASE`), not an instance-level backup restore, so a second catalog beside it survives. No `RESTORE_VOLUME` has ever run on this instance. **Check the disk first, though:** the instance is `db-custom-2-8192` with a 418 GB disk and `storageAutoResize` **disabled**, and the production backup is ~127 GB striped, so a second full copy is marginal and may need a disk bump before step 2.
2. **Create the catalog** and seed it from the current shared one so staging starts from the same sanitized data it has today.
3. **Grant the existing `DB_USER`** access to it, so no new credential is introduced and `DB_USER` / `DB_PASSWORD` keep working unchanged.
4. **Exclude it from the refresh** -- if one is ever built. This is a no-op today: there is no refresh to exclude it from (see below). Keep the requirement recorded, because staging not resetting is what makes a version upgrade durable and staging trustworthy during a demo.
5. **Set the repository variable** `STAGING_DB_NAME` to the catalog name. A variable, not a secret: a catalog name is not a credential, and keeping it visible lets the deploy log state which database was used. Note the blast radius: this one variable moves **staging and every `pr-*` site**, since `pr-test-deploy.yml` reads it too. Existing sites do not move until each is redeployed, so expect a window where some sites are on the new catalog and some are still on the old one.

Then redeploy staging and check the run's `Report which catalog this deploy will use` step. It prints `Catalog source: caller-supplied` when the variable resolved, and emits a warning naming the shared catalog when it did not. An unset or misspelled variable falls back silently to the shared catalog otherwise -- the deploy still succeeds, so this step is the only place that difference is visible. `pr-*` deploys have no equivalent step: they inline the connection string, so the only way to confirm one moved is to redeploy it and check the site works.

## Manual recovery

- Stuck deploying: cancel stale GitHub Actions runs, then rerun with `rock:start`.
- IIS state mismatch: run `Destroy-PrEnvironment.ps1 -PrNumber <n>`, then re-add `rock:start`.
- Cleanup dry run: `Invoke-PrEnvironmentCleanup.ps1 -WhatIf`.
- Certificate/DNS issues: verify Cloudflare wildcard record, IIS certificate binding on `*:443:<host>`, and the weekly renewal workflow. No VPN allowlist is involved -- 443 is public via `https-from-world`.

## Troubleshooting

- Failed builds: inspect `.github/workflows/pr-test-artifact.yml` logs.
- Failed deploys: inspect `.github/workflows/pr-test-deploy.yml`, command queue results, GCS artifact path, and `C:\RockDeploy` scripts.
- Stopped environments: developers can re-add `rock:start`.
- Certificate warnings: expected until the certificate-selection fix reaches the VM -- every
  deploy used to rebind the self-signed placeholder over the real certificate (see open item 4).
  Measure the issuer with `openssl s_client`; a real certificate shows `O=Let's Encrypt`. If the
  fix is deployed and the issuer is still self-signed, dispatch
  `.github/workflows/pr-test-renew-certificates.yml` and confirm the log names the host.
- DNS failures: confirm `*.rock-dev.connect.passion.team` resolves to `GCP_VM_EXTERNAL_IP`. This is public DNS; no VPN is required.
