# PR Test Environments: Operator Runbook

**Last verified:** 2026-08-19 · **Audience:** whoever is operating the pipeline, not using it
(developers want the Developer Runbook). Open items and their reasoning live in
`Training/DevOps-Open-Items-Rock-CICD.md`; incidents live under `Incidents/`.

## Infrastructure

- Base branch config: `.github/pr-test-environments.json` controls which PR base branch is eligible for PR test environments. It currently targets `passion-19.3.4` for the Rock version pin. Update this value during Rock upgrades.
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

**Done for staging on 2026-08-18: `STAGING_DB_NAME` is set to `RockStaging`.** Staging has its own catalog and no longer shares with anything. The `pr-*` fleet still shares `RockConnectProd` with itself -- `PR_TEST_DB_NAME` is deliberately unset -- so the mechanism below still applies within the fleet, just not between the fleet and staging.

The mechanism, for whoever meets it next: when environments share a catalog, Rock's startup migrations from one of them rewrite the schema the others depend on. This is what put `pr-3` on a permanent HTTP 500 on 2026-08-11.

**Decided 2026-08-17: staging and the `pr-*` sites move onto the staging catalog together.** **Superseded by what was actually built on 2026-08-18 — read this paragraph as the reasoning, not the current state.** Only staging moved: `STAGING_DB_NAME` is set, `PR_TEST_DB_NAME` is not, so the fleet stayed on `RockConnectProd`. The v19 upgrade forced the staging half early and there was no reason to move the fleet in the same window. The argument below still holds and moving the fleet is still the intended end state; it just has not been done. This paragraph in turn supersedes the earlier half-step of isolating `staging` alone. A shared catalog is not itself the defect -- sharing one *across two Rock minors* is, because Rock migrates the schema at `Application_Start`. Every `pr-*` site builds from a PR based on the branch staging deploys, so they are all the same minor by construction, and `Tests/PrTestEnvironments/test_base_branch_config.py` fails if the two pins drift apart. What this actually buys is that no environment of ours sits on the catalog the prod restore owns.

The cost this looked like it carried turns out to be zero. It appeared to trade away nightly data freshness for the `pr-*` sites -- but as measured on 2026-08-17 there is no nightly refresh to give up (see below). The catalog is already months stale and already accumulating every environment's test data and migrations with no reset, so moving it does not make the data situation worse. Drift from production is a real problem; it is just a pre-existing one, and the fix for it is a deliberate re-seed, not this decision.

Current shared setup, for reference:

| | |
|---|---|
| Instance | `connect-restore-test` (`172.20.0.2`) -- *not* `connect-prod` (`172.20.0.8`) |
| Catalog | `RockConnectProd` -- the name is an artifact of restoring a prod backup, not production data. Still shared by the whole `pr-*` fleet; staging left it on 2026-08-18 |
| Consumed via | secrets `PR_TEST_DB_DATA_SOURCE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` |

To provision:

1. ~~**Decide where the catalog lives, and check the refresh mechanism first.**~~ **Resolved 2026-08-17 — `RockStaging` on `connect-restore-test` is fine.** The refresh is a per-database `.bak` import (`IMPORT` with `database: RockConnectProd`, preceded by a `DELETE_DATABASE`), not an instance-level backup restore, so a second catalog beside it survives. No `RESTORE_VOLUME` has ever run on this instance. **Check the disk first, though:** the instance is `db-custom-2-8192` with a 418 GB disk, and the production backup is ~127 GB striped, so a second full copy is marginal. `storageAutoResize` was **disabled** when this was written and was **enabled with no limit on 2026-08-18** before the copy was taken — which is what made step 2 safe. It now holds two ~108 GiB catalogs and is over half full, so check used bytes again before any third copy.
2. **Create the catalog** and seed it from the current shared one so staging starts from the same sanitized data it has today.
3. **Grant the existing `DB_USER`** access to it, so no new credential is introduced and `DB_USER` / `DB_PASSWORD` keep working unchanged.
4. **Exclude it from the refresh** -- if one is ever built. This is a no-op today: there is no refresh to exclude it from (see below). Keep the requirement recorded, because staging not resetting is what makes a version upgrade durable and staging trustworthy during a demo.
5. **Set the repository variable** `STAGING_DB_NAME` to the catalog name. A variable, not a secret: a catalog name is not a credential, and keeping it visible lets the deploy log state which database was used. This moves **staging only**. The `pr-*` fleet reads its own variable, `PR_TEST_DB_NAME`, and both fall back to the shared prod-derived catalog while unset -- so setting one leaves the other exactly where it is. Staging does not move until it is redeployed.

   Until 2026-08-18 `pr-test-deploy.yml` read `STAGING_DB_NAME` as well, so this one variable moved staging and every `pr-*` site together. That is what made a staging-first version bump impossible, and it is why the split exists; see the [2026-08-18 incident record](Incidents/2026-08-18-staging-v19-shared-catalog.md).

Then redeploy staging and check the run's `Report which catalog this deploy will use` step. It prints `Catalog source: caller-supplied` when the variable resolved, and emits a warning naming the shared catalog when it did not. An unset or misspelled variable falls back silently to the shared catalog otherwise -- the deploy still succeeds, so this step is the only place that difference is visible. `pr-*` deploys have no equivalent step: they inline the connection string, so the only way to confirm one moved is to redeploy it and check the site works.

## Trunk cutover (bumping the Rock version)

Flipping the trunk branch -- from one `passion-<version>` to the next -- is the one routine operation that can break every environment at once, and it does it quietly. Read this before starting one. It was last done on 2026-08-19, moving the trunk to `passion-19.3.4`.

**Why it is dangerous.** The flip points staging at a new Rock minor, and the first request after that deploy runs the new minor's EF and plugin migrations against whatever catalog staging is on. Any site sharing that catalog and still serving the old minor's binaries is then old code against a newly-migrated schema -- which is precisely `pr-3` on 2026-08-11, reproduced once per live environment.

Since 2026-08-18 staging has its own catalog, so the *staging-to-fleet* version of this is closed and step 1 below is already done. It is written out in full anyway, because the `pr-*` fleet still shares one catalog with itself and because the next person to provision a catalog will need the ordering. What has not changed is that **the cutover is still the moment you find out whether the new minor migrates cleanly** -- and that risk is now confined to staging rather than shared out across every environment.

**Prove the new minor on staging first.** Everything below assumes the cutover is the moment you find out whether the new minor migrates cleanly. It does not have to be, and on 2026-08-18 finding out that way cost the whole fleet: the v19 migration set died part-way through on a legacy `text` column, and because staging was on the shared catalog it stranded that catalog mid-migration for every environment at once. EF's `DbMigrator` commits each migration separately, so a failure half way is not a rollback -- it is a database on neither version.

Give staging its own catalog and the risk moves off the critical path:

1. Provision `RockStaging` and set `STAGING_DB_NAME` (see *Staging catalog*, above). This moves staging alone; `PR_TEST_DB_NAME` stays unset and the fleet stays where it is. **Already done on 2026-08-18** -- skip unless you are rebuilding the catalog. Confirm rather than assume: `gh variable list -R passiondev/Rock` should show `STAGING_DB_NAME`.
2. Run `Deployment/Database/Find-LegacyTextColumns.ps1` against the new catalog. It is read-only. `text`, `ntext` and `image` were removed in SQL Server 2016 and Rock's own schema uses `nvarchar` throughout, so anything it finds is local drift -- and a v19 migration that compares such a column with `=` fails with "The data types text and nvarchar are incompatible in the equal to operator". Remediate with `Convert-LegacyTextColumns.ps1` before deploying, not after.
3. Deploy the new minor to staging **by `workflow_dispatch` with `ref:` set to the new branch** -- not by flipping the trunk. Staging's push trigger still names the old branch at this point, which is what you want: one environment moves, on demand, and the fleet is untouched.
4. Load the site to trigger `Application_Start`, and watch it through. This is where a bad migration surfaces, now against a database only staging is using.
5. Only once staging is serving the new minor, do the cutover below. Step 4 of it is then a formality rather than the experiment.

The guard in `staging-deploy.yml` enforces the ordering: while `STAGING_DB_NAME` is unset it refuses any staging deploy whose Rock minor differs from the fleet's pin, dispatch included. So step 3 cannot be done before step 1, and the failure is a refused deploy naming the reason rather than a stranded catalog. With the variable now set the guard is satisfied and stays quiet -- which means **it will not protect a future fleet catalog**. If `PR_TEST_DB_NAME` is ever introduced, the guard needs the mirror-image condition or this ordering goes unenforced.

**What closes the door is moving the default branch, not flipping the pins.** The deploy gate fetches `.github/pr-test-environments.json` with `ref: context.payload.repository.default_branch` (`pr-test-deploy.yml`), so every PR is judged against one config -- the trunk's -- no matter what it is based on. Move the default branch and the retired branch's PRs start failing the `pull.base.ref !== configuredBaseBranch` comparison on their own, with no per-branch cleanup.

It used to read `ref: pull.base.ref`, and that is worth knowing because it is the failure people still expect: a PR based on `passion-18.4.1` read the config **from `passion-18.4.1`**, which still named itself, so the comparison passed and the retired fleet went on deploying indefinitely. Flipping the pins rejected nothing.

The consequence of the fix is that **"move the default branch" is now a required cutover step** (step 3), not repository housekeeping to get to later. Miss it and the gate keeps reading the retired branch's config, exactly as before. It fails safe in the other direction, at least: move it before the pins are committed and *every* PR is refused until they land, which is loud rather than silent.

**`pr-test-lifecycle.yml` still reads `ref: pull.base.ref`, deliberately.** It only runs `stop` and `destroy`, and those have to keep working on retired-branch PRs -- that is the teardown path. If lifecycle also read the trunk's config, moving the default branch would strand every old environment with no way to remove it. The asymmetry between the two workflows is load-bearing; `CutoverGateFailClosedTests` in `Tests/PrTestEnvironments/test_base_branch_config.py` pins both halves so neither gets "tidied up" into matching the other.

**`rock:stop` is not enough** for the old fleet either; it leaves the files for someone to start later. Destroy them.

**Order of operations:**

0. **Protect the trunk**, once, before any of this: `./Deployment/Repository/set-trunk-protection.sh` (dry run) then `--apply`. It blocks force-pushes and deletion on whatever the default branch currently is, and nothing else -- no review requirement, so it cannot block the cutover commits below. The ruleset targets `~DEFAULT_BRANCH`, so it follows the trunk in step 3 rather than being left behind guarding the retired branch -- which also means it does not need running again after the cutover. To confirm it afterwards, read it back instead: `gh api repos/passiondev/Rock/rulesets`. Re-running with `--apply` would rewrite the ruleset to exactly the two rules it knows about, dropping anything added to it since.

1. **Destroy every live `pr-*` environment.** Dispatch `.github/workflows/pr-test-destroy-all.yml` with the confirmation phrase and **apply** left unticked; it lists every open PR carrying a `rock:` state label, with each one's base branch so the retired fleet is distinguishable from current work. Read the list, then re-run with **apply** ticked.

   The base-branch column is there to be read, not obeyed: **apply** destroys everything in the list. If some of those PRs are current work you want to keep, copy the retired ones' numbers into the `pr_numbers` input and it will act on those alone. It queues the ordinary `destroy` command once per PR, serially, and does not stop at the first failure.

   The list is built from GitHub labels, and `C:\RockTestEnvs` on the VM is what is actually deployed. An environment whose PR was deleted, or whose label was cleared by a run that failed halfway, will not appear and will survive the teardown -- so list that directory afterwards. For anything left over: `rock:destroy` on the PR if it still has one, `Destroy-PrEnvironment.ps1 -PrNumber <n>` on the VM if it does not. Ordering against the other steps is not enforced by anything; the only thing making this step first is you doing it first.
2. **Flip every pin in the same commit.** Bump `EXPECTED_BASE_BRANCH` in `Tests/PrTestEnvironments/test_base_branch_config.py` first and on its own -- that constant is the oracle the guard compares everything against, not a pin. Then run that one file. `BASE_BRANCH_PIN_SITES` enumerates the eight real pins, spread over seven other files, and the failure message names every one still on the old branch; work it until green. That list is the checklist -- do not rebuild it by hand. Nothing else will tell you: no build fails if you miss one. A missed `deployment-pipeline-tests.yml` stops running on pushes altogether, silently.

   **The two production pins are not on that list, and must not be flipped here.** `production-deploy.yml`'s `ref` default and `productionBranch` in `.github/pr-test-environments.json` track the branch **production actually runs**, which lags the trunk until production is itself upgraded. They live in `PRODUCTION_PIN_SITES` with their own oracle, `EXPECTED_PRODUCTION_BRANCH`, and flipping them at trunk cutover would point a production deploy at a Rock minor production is not on.

   This is not hypothetical: the 2026-08-19 cutover moved the trunk to `passion-19.3.4` while production stayed on `passion-18.4.1`, and the production deploy guard -- which read the *default branch* as its oracle -- began refusing `passion-18.4.1` as `diverged`, with "there is no override for this one". Production was undeployable, rollback included, and every test stayed green because they asserted the mechanism rather than the outcome. The guard now reads `productionBranch`, and `test_the_workflows_own_default_ref_is_one_the_guard_accepts` checks that the workflow accepts its own default.
3. **Move the default branch to the new trunk.** Settings > General > Default branch, or `gh api --method PATCH repos/passiondev/Rock -f default_branch=passion-19.3.4`. This is the step that actually stops the old fleet, and it is easy to skip because nothing prompts for it and nothing fails when it is missed. Do it *after* step 2's commit has landed on the new branch: the deploy gate reads the config from whatever the default branch is, so moving it first means every PR is refused until the pins arrive.

   Once it moves, retired-branch PRs fail the gate automatically and stop deploying -- no per-branch edit, and nothing to remember to undo. Deleting the retired branch is still an option if you want its PRs closed outright, and nothing stands in the way: step 0's ruleset targets `~DEFAULT_BRANCH`, and that token has just followed the default onto the new trunk, so the retired branch is no longer the one being protected. **Leave the ruleset alone.** From this point it is the only thing standing between the branch everyone now works from and a force-push.

   Check it took: open any PR still based on the retired branch, add `rock:start`, and confirm the deploy job resolves `should_deploy=false`. A skipped deploy is a `core.info` line, not a failure, so read the log rather than the PR's check marks.
4. **Deploy staging and let the migrations finish.** Watch the run's `Report which catalog this deploy will use` step, then load the site once to trigger `Application_Start`. Migrations are irreversible; if the catalog is wrong, this is the last moment it is cheap to find out.
5. **Rebase the open PRs onto the new trunk**, then re-add `rock:start` per PR. Each redeploys from an artifact built against the new minor.

**If you migrate staging before clearing the fleet,** every live `pr-*` site is serving old binaries against the new schema, and each one keeps re-breaking itself on redeploy until its PR is rebased or its environment destroyed. Reverting the pins does not undo it: the catalog has already moved forward and the old minor cannot run against it.

**Nothing in the pipeline reports any of this.** The gate skip is a `core.info` line and `should_deploy=false`, not a failure -- a skipped deploy and a healthy one look the same on the PR. Verify by loading the sites.

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
