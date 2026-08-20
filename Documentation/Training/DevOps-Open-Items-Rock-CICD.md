# Rock CI/CD — open items for DevOps

**Audience:** DevOps engineer + Global Engineering. Not part of the training handout.
**As of:** 2026-08-20 · **Repo:** `passiondev/Rock` (public) · **Trunk:** the repository's
default branch, named `passion-<version>` and replaced at every Rock upgrade — read it from
GitHub or from `.github/pr-test-environments.json` rather than from this line

The pull-request path is working and proven end to end. This is the list of what is *not*
done, ordered by what it blocks. Most of these were found by auditing the pipeline this week;
the last section records what has already been fixed so nobody re-diagnoses it.

Read item 7 first if you only read one. It is the shared dependency underneath every
"isolated" test site, and it is the most likely cause of two sites failing at once. Half of it
is now fixed — staging has its own catalog — and the half that remains is the `pr-*` fleet
sharing one catalog with itself.

---

## P0 — blocks the production path

### 1. The production command-queue agent is not installed

Everything upstream of it is proven against staging: build, approval gate, backup, app-pool
stop, file copy, health check, restart. Until the scheduled task exists on the production VM
polling queue `commands-prod`, a production deploy will build, gate, queue — and then time
out waiting for a server that isn't listening.

- **Bootstrap:** `.github/workflows/pr-test-bootstrap-command-queue.yml`, with
  `-QueueName commands-prod`
- **Why a separate queue:** the GCS bucket is shared. One queue prefix per VM, or either box
  can pick up the other's commands.
- **Do this together, not unattended.** The bootstrap stops and starts the VM.
- **Don't collide** with a queued deploy — check the queue is empty first.
- **Run the bootstrap from the trunk, and re-run it after any change under
  `Deployment/PrTestEnvironments/`.** This is the non-obvious part. A deploy workflow uploads
  only a `command.json`; the agent then executes the copy of `Deploy-RockEnvironment.ps1`
  **installed on the VM** (`Invoke-PrEnvironmentCommandQueue.ps1:189`), and it has no
  self-update path. Whatever ref the last bootstrap ran from is the script that runs, however
  old. The bootstrap workflow is the only way to change it.

  A fix for this is in review — see item 18. It does not change the rule yet, and the one
  re-bootstrap that installs it is the last one this should ever need.

  That is a correctness requirement here, not just hygiene. Production is the one environment
  that deploys with `write_connection_string: false` — deliberately, so CI never holds the
  production database credentials — and the code that makes that path safe landed in
  `8e4cfd576e`. Before it, a `DedicatedSite` deploy deleted the site directory without
  carrying `web.ConnectionStrings.config` across, and `web.config` binds `connectionStrings`
  through a `configSource`, so every request 500s, error page included. Bootstrap production
  from a ref at or after `8e4cfd576e` and it also gains a loud `throw` at the cause instead of
  a 300-second health-check timeout. (Production runs `InPlace`, whose robocopy `/XF`
  exclusions were always correct — so this is the belt for the day someone reaches for
  `DedicatedSite`, plus the diagnostic.)

### 2. The `production` gate exists now, but it rests on one person

**Created 2026-08-11.** Until then the environment did not exist, which meant the `approve` job
in `production-deploy.yml` **passed straight through** — the gate was written and wired with
nothing on the other side of it. Referencing an environment that does not exist does not fail;
GitHub creates it with no rules, so the run sails past. Worth remembering as a category: an
approval gate is not self-evidencing, and this one read as present in every review of the YAML.

Current settings:

| Setting | Value | Why |
| --- | --- | --- |
| Required reviewers | `justinpbarnett` | Someone must click Approve; a dispatch alone deploys nothing |
| `can_admins_bypass` | `false` | Deliberately closed. On the default (`true`) a repo admin can skip the gate, which would have made the training's claim false for exactly the people most able to cause harm |
| `prevent_self_review` | `false` | Has to stay false while there is one reviewer, or the only person named could never approve |
| Branch policy | none | The version guard in `production-deploy.yml` already refuses a ref from another Rock minor, which is the risk a branch policy would be covering |

**What's left, and it is the point of this item:** add a second reviewer — the DevOps engineer
— and then set `prevent_self_review` to `true`. Only at that point is production genuinely
two-person. Today it is one deliberate click by one person, which stops an accident but not a
mistake. The reviewer was not chosen on anyone's behalf: several people hold admin on this
repo, and who guards production is a decision, not a default.

Also still needed: repo variables `PRODUCTION_HOST_NAME`, `PRODUCTION_SITE_PATH`,
`PRODUCTION_SITE_NAME`. The workflow falls back to `rock.passion.team`, `C:\inetpub\wwwroot`
and `Default Web Site` if they are absent — **confirm those against the actual VM before the
first real run** rather than trusting the defaults.

### 3. The trunk branch has no protection at all

The trunk is the default branch and **merging into it auto-deploys staging**. It has
`protected: false` and the repo has **0 rulesets** (re-verified 2026-08-19, against the trunk
the cutover created). Anyone with write access can push directly to it — no PR, no review, no
build check. When this does get fixed, see the third note in item 23: protection is bound to a
branch name and will need re-pointing at every upgrade.

(It is *not* always what production runs: during a Rock upgrade the trunk leads and production
deliberately lags. That widens the window this item is about rather than narrowing it — an
unreviewed push to the trunk goes straight onto a staging environment the whole team is using
to qualify the upgrade.)

The training we're delivering tells people "open a PR and get a review." Nothing enforces
that today. Recommended ruleset, re-pointed at the new trunk at every upgrade:

- Require a pull request before merging (1 approval)
- Require the build status check to pass
- Block force pushes
- No deletions

Worth deciding in the same conversation: `delete_branch_on_merge` is currently `false`, so
merged branches accumulate forever. Turning it on prevents the next round of item 9.

---

## P1 — real risk, not blocking

### 4. Every deploy rebound the self-signed placeholder over the real certificate

**Root cause found 2026-08-11, fixed, and proven end-to-end the same night.** An earlier
revision of this document claimed this item was fixed because `pr-4` was measured serving a
real Let's Encrypt certificate at 16:57 UTC on 2026-08-10. That measurement was correct. The
conclusion was not — by 2026-08-11 00:30 UTC `pr-4` was serving a **self-signed** wildcard
again, and so was `staging`. Both hosts presented the same certificate: subject and issuer
both `CN=*.rock-dev.connect.passion.team`, expiring 2028-05-06.

**What proof required, and why the first attempt did not qualify.** A certificate measured
right after a renewal proves only that renewal works — it was never the thing in doubt. The
failure was that *the next deploy took it away*, so nothing short of measuring again on the
far side of a deploy is evidence. The full chain, all on 2026-08-11:

| Step | Evidence |
| --- | --- |
| 1. Fixed selector on the VM | bootstrap run, scripts refreshed from `bootstrap/latest` |
| 2. Renewal issues a real certificate | run `31450951458`; staging gets Let's Encrypt YR2, expires 2026-11-09 |
| 3. A deploy runs afterwards | staging deploy run `31451302897`, green, 02:30:50 → 02:40:29 |
| 4. **Re-measured after the deploy** | **still Let's Encrypt YR2, same expiry, strict TLS 302 in 0.099s** |

Step 4 is the item. Steps 1–3 were true of the 2026-08-10 attempt as well.

**A second copy of the same bug was found while verifying this, on the PR path.**
`Deploy-PrEnvironment.ps1` — which every `pr-*` environment deploys through, including the
training demo host — still sorted on `NotAfter` alone. Because the placeholder expires
2028-05-06 and a Let's Encrypt certificate expires ninety days out, the placeholder would have
won there too: the next `pr-4` deploy would have silently restored the untrusted certificate.
Fixed in `b1e8569ab8` with the same selector. The lesson worth keeping is that the original fix
was applied to the file where the bug was *observed* rather than to every file that shared the
logic, and a duplicated seven-line block is exactly where that goes wrong.

Two independent defects, and the first one is the interesting one:

- **The placeholder outranked every real certificate, permanently.**
  `Deploy-RockEnvironment.ps1` rebinds an SSL certificate on *every* deploy. Its selector
  (`Get-EnvironmentCertificateThumbprint`) took all certificates matching the host or the
  wildcard and picked `Sort-Object NotAfter -Descending | Select-Object -First 1`. The
  self-signed placeholder is minted with `-NotAfter (Get-Date).AddYears(2)`; a Let's Encrypt
  certificate lasts 90 days. **2028 always beats 90 days from now**, so the placeholder won
  every comparison and every deploy silently reverted the site to an untrusted certificate.
  Renewal was never broken — it was being undone. The timeline proves it exactly: renewal
  bound a real certificate to `pr-4` at 16:57, `pr-4` was redeployed at 19:44 (run
  `31425587536`), and it was self-signed afterwards.
  **Fixed:** the selector now ranks CA-issued certificates ahead of self-signed ones
  (a self-signed certificate is its own issuer) and only uses `NotAfter` as the tie-breaker.
  It also skips already-expired certificates. The placeholder is still deliberately
  long-lived — the *ranking*, not a short expiry, is what lets the real certificate win, so a
  run of failed renewals still cannot break HTTPS outright.
- **Renewal could not see `staging` at all.** `Get-DeployedPrEnvironmentManifests` walked only
  `C:\RockTestEnvs`, and in-place environments deliberately keep their manifest elsewhere —
  `Deploy-RockEnvironment.ps1:152` puts it at `C:\RockBackups\<name>\env.json`, with a comment
  explaining that this keeps renewal from stopping and starting the site. That reasoning does
  not hold: renewal stops `W3SVC` **service-wide** for the HTTP-01 challenge (line 189), so
  staging was already taking the full downtime and simply never got a certificate for it.
  **Fixed:** renewal takes `-AdditionalManifestRoots` (default `C:\RockBackups`) and scans
  direct children of those roots only — never `-Recurse`, because the siblings of that
  manifest are timestamped site backups and recursing would bind certificates from stale
  manifests. Hosts are de-duplicated by name.

**Still open — the reporting gap that hid all of this for months.** `succeeded` does not mean
a certificate was issued. The script returns early with a clean exit when it finds no
manifests, and only throws when `$boundCount -eq 0` *after* it had work to do, so a run over
an empty VM is indistinguishable from a run that renewed everything. Run `31416304281`
(2026-08-10 17:53) reported `succeeded` in ~2 minutes — far too fast for win-acme against even
one host — and its result JSON carried nothing but `commandId`, `prNumber`, `command`,
`status`, `completedAtUtc`: no host names, no per-host outcome, and **no log uploaded to
`commands/logs/` at all**. It ran before any environment had been deployed that evening, so it
genuinely had nothing to do. Partially mitigated: the script now emits a loud
`RENEWAL ISSUED NOTHING` warning naming every root it searched, and a `Renewal scope:` line
naming each host it will touch. The real fix is still to return the touched-host list in the
command result, and to upload the renewal log the way deploys do.

> **Both fixes are VM-side scripts, so they take effect only after
> `pr-test-bootstrap-command-queue.yml` runs** — that workflow stops and starts the VM. Until
> then the live VM still has the old selector, and any deploy will keep clobbering the
> certificate. Verify by **measuring**, never by reading a run's conclusion:
> ```bash
> for h in pr-4 staging; do
>   echo "== $h"; echo | openssl s_client -connect $h.rock-dev.connect.passion.team:443 \
>     -servername $h.rock-dev.connect.passion.team 2>/dev/null \
>     | openssl x509 -noout -issuer -subject -dates
> done
> ```
> A real certificate shows `O=Let's Encrypt` in the issuer. If issuer and subject match, it is
> the self-signed placeholder.

- **Workflow:** `.github/workflows/pr-test-renew-certificates.yml` (`schedule: 0 8 * * 1`)
- Note it temporarily opens an ACME HTTP-01 firewall path (tag `pr-test-acme-http`) — confirm
  it closes again on failure, not just on success.
- It stops `W3SVC` service-wide for the HTTP-01 challenge, so every site on the box goes down
  for the duration. Fine on the test VM; worth remembering before this pattern is copied to
  production.

### 5. Two blind spots in the deploy health check

**5a. The PR deploy path has no health check at all.** `Deploy-RockEnvironment.ps1` (staging
and production) polls the site and fails the deploy if it never answers.
`Deploy-PrEnvironment.ps1` — the path every pull request takes — does not: its last act is
`Write-Host "Deployed $SiteName at https://$HostName"` (line 327), and then it exits 0. There
is no `Invoke-WebRequest` anywhere in the file.

That is why the missing-`Google.Protobuf.dll` outage went unnoticed for three months. Every PR
deploy reported success while the site returned a 500 on every request. "Green" on a PR
environment currently means *the files copied*, nothing more.

The fix is to call the same `Test-EnvironmentHealth` from that script. It was deliberately
**not** done before the 2026-08-11 training demo: the demo runs through exactly this path, and
adding a new failure mode to it the night before risks turning the demo red on a projector for
a reason unrelated to the change being demonstrated. Do it immediately after.

**5b. The health check accepts any TLS certificate.**
`Deploy-RockEnvironment.ps1:535` sets
`[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }` before polling
the site.

This is deliberate and correct today — it stops item 4 from failing every deploy — and it is
now *required*, because the probe targets `https://127.0.0.1/` and no certificate for the
public host name will ever match that. The consequence is unchanged: **the on-VM probe can
never tell us a certificate is broken.**

**Partly addressed.** `env-deploy-command.yml` now reads the certificate issuer from the
GitHub runner after every staging and production deploy, prints it in the run summary, and
raises a `::warning::` when the site is presenting a self-signed certificate. It is
deliberately not an error — a certificate due for renewal is not an outage, and folding trust
into reachability means the pipeline cries wolf.

Still to do: report **days to expiry** rather than just the issuer, so renewal is driven by a
number instead of by someone noticing the warning.

**5c. The timeout stack is sized for a patch deploy, not a major-version migration.**
A major-version upgrade runs the whole EF and plugin migration set on the first request. The
current budget cannot absorb that:

| Knob | Where | Now | Agreed for a migration deploy |
|---|---|---|---|
| `HealthCheckTimeoutSeconds` | `Deploy-RockEnvironment.ps1:117` | 900 (15 min) | **1800** (30 min) |
| `RecycleAfterSeconds` | `Deploy-RockEnvironment.ps1:622` | 240 (4 min) | **900** |
| `deploy-environment` cap | `Invoke-PrEnvironmentCommandQueue.ps1` | 1800 | must exceed the above |
| Result poll | `env-deploy-command.yml` | 140 x 15s = 35 min | must exceed the queue cap |
| Job timeout | `env-deploy-command.yml` | 60 min | outermost, unchanged |

The failure mode is not a timeout, it is a **recycle**: at 240s the deploy restarts the app pool
while it is still migrating, up to roughly three times, and only then reports failure. Interrupting
a migration set part-way is materially worse than waiting.

**Decided 2026-08-17: 30-minute health check, 900s recycle.** That figure was chosen because it
fits inside the existing 1800s queue cap and 60-minute job timeout, so only the two inner knobs and
the poll window move — no restructuring of the outer limits.

**Not yet implemented — deliberately deferred.** Both knobs are already proper `[Parameter]`s with
defaults, so this must be a per-deploy override threaded from `env-deploy-command.yml` through the
command JSON to the script, **not** a change to the defaults: PR environments should keep the fast
feedback that a 15-minute ceiling gives them. The comment at `Deploy-RockEnvironment.ps1:105-113`
is the constraint to respect — every layer has to move together or the effective ceiling just
relocates to whichever limit was not raised, which is harder to diagnose than the original.

### 6. Nothing reaps abandoned environments

Closing a PR **stops** its environment but never destroys it. An environment on a long-lived
open PR runs indefinitely. The only scheduled workflow in the repo is certificate renewal —
there is no idle timeout and no sweep. Left alone this grows the test VM's disk until it
fills.

Wants a scheduled job that stops environments idle past a threshold and destroys ones whose
PR closed more than a week ago.

> Note: earlier revisions of the training doc claimed a 6-hour idle stop and a 7-day destroy
> already existed. **They never did.** Both claims have been corrected in the handout.
>
> Corrected in the handout was not corrected everywhere — found 2026-08-19. The same claim
> was still live in two other places, stated as fact:
> `Documentation/PR-Test-Environments-Operator-Runbook.md` described the policy in its script
> list, and `Discussion Docs/PR-Test-Environments-Issues/08-scheduled-idle-cleanup.md` had
> every acceptance criterion ticked under the title "Add scheduled idle cleanup". Both now say
> plainly that nothing runs the script.
>
> Why it reads as wired up: `Invoke-PrEnvironmentCleanup.ps1` is real, is tested by
> `test_cleanup_script.py`, and the bootstrap workflow copies it to the VM with the other nine
> deploy scripts. What is missing is only the trigger. Nothing calls `Register-ScheduledTask`
> or `schtasks` for it, and the single task the VM installs is "Rock PR Environment Command
> Queue" running every minute. `test_nothing_schedules_the_cleanup.py` now fails if a trigger
> appears, so whoever adds one is told which documents currently promise it does not exist.
>
> Switching it on is a decision, not a missing commit: it starts destroying PR environments
> after 7 idle days, and the fleet is managed by hand today.

### 7. Staging and every PR environment share one database catalog — staging split out 2026-08-18

> **Half fixed on 2026-08-18: staging is out.** `STAGING_DB_NAME` is now set to `RockStaging`,
> a full copy taken by Cloud SQL export/import from `RockConnectProd` and probed read-only
> before the variable was flipped. Staging no longer shares a catalog with anything, so the
> specific failure this item was opened for — *a staging deploy migrating the schema out from
> under a running `pr-*` site* — cannot happen any more. The `staging-deploy.yml` resolve job
> prints `STAGING_DB_NAME: RockStaging` and the line "staging has its own catalog", which is
> how you confirm it from a run log.
>
> **The fleet is still shared, and that half is still open.** `PR_TEST_DB_NAME` is
> deliberately unset, so every `pr-*` site continues to fall back to `secrets.DB_NAME`
> (`RockConnectProd`) and they still share one catalog *with each other*. Two `pr-*` sites on
> different Rock minors will still break each other exactly as described below. Everything
> from here down is the original finding, kept because the mechanism is unchanged for the
> fleet and because the 2026-08-11 incident is the proof that it is not hypothetical.

`env-deploy-command.yml:121` and `pr-test-deploy.yml:193` build their connection strings from
the same four secrets — `PR_TEST_DB_DATA_SOURCE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` — and
neither deploy script derives a per-environment catalog. So every `pr-*` environment, and
staging too until the split above, points at one catalog on the shared test Cloud SQL
instance. Each side accepts its own override — `STAGING_DB_NAME` for staging,
`PR_TEST_DB_NAME` for the fleet — and only the staging one has been set.

That is one shared mutable dependency behind every isolated-looking test site. Rock runs EF
and plugin migrations at `Application_Start`, writes global attributes such as
`PublicApplicationRoot` into the database, and holds a migration lock there. Two sites of
different versions against one catalog is a genuine way to break both at once, and a Rock
instance that fails during `Application_Start` serves the same generic ASP.NET error page on
every path — including static files — which is a confusing thing to debug.

**This stopped being hypothetical on 2026-08-11.** (The environments named below were torn
down when the fleet was pruned on 2026-08-19 — they are the evidence, not somewhere to go and
look.) `pr-3` served an ASP.NET **"Runtime
Error"** page — HTTP 500 — on every request, and kept doing so across app pool recycles
(measured 500 in 29.3s, then 500 in 71.1s after a recycle). `pr-4` and `staging` on newer
commits answer 302 from the same box at the same moment, so IIS, the binding and the
certificate are all fine; what differs is which build's expectations the one shared schema
currently matches. Meanwhile GitHub still shows PR #3 labelled **`rock:deployed`**,
because the PR deploy path never checks (item 5a) — the two defects compound exactly as
written, and the result is a broken environment that the pipeline reports as good.

**The version split is now measured, not inferred.** `Rock.Version/AssemblySharedInfo.cs` —
one of the two files `production-deploy.yml`'s version guard reads — declares:

Measured 2026-08-10; the trunk has moved since, so read these as a snapshot of the split, not
as current values.

| Ref | Rock version |
| --- | --- |
| `passion-18.4.1` (trunk at the time) | **18.4.1** |
| `demo/ptp-cicd-training-walkthrough` (PR #4) | **18.4.1** |
| `pilot/pr-test-env-doc-smoke-v1761` (PR #3) | **17.6.1** |
| `develop` | 19.0.3 |

Note for the upgrade: **Rock 19 deleted that file.** From 19.x the version lives in
`Directory.Build.props` as `<Version>19.3.4</Version>` (`Rock.Version/` keeps only
`VersionInfo.cs` and the `.csproj`). The guard reads both locations, historical path first,
so it spans the upgrade — see item 15.

So `pr-3`'s 500 is not a vague "collision" — it is Rock **17.6.1** running against a catalog
that Rock **18.4.1** has already migrated forward. PR #3's base branch is `develop-17.6.1`;
PR #4's is the trunk. One shared catalog, two minor lines, and the newer one won.

The corollary matters for the demo: `staging` and `pr-4` are **both 18.4.1**, so a staging
deploy runs the identical migration set `pr-4` has already run. Staging deploys are safe for
`pr-4` specifically because their versions match — not because the environments are isolated.
They are not isolated. That safety lasts exactly as long as every live `pr-*` sits on the same
minor line as the trunk.

Do not "fix" `pr-3` by redeploying it and move on. Redeploying makes `pr-3` match the schema
again and is very likely to break whichever environment currently matches instead. That is
the whole point: there is one schema and N sites that each believe they own it.

A cheap guard that needs no new database: have the PR deploy path refuse a head whose
declared minor differs from the default branch's — the same comparison
`production-deploy.yml` already makes, pointed at PR environments. That converts this from a
silent mutual corruption into a refused deploy with a clear reason.

The fix is a catalog per environment. It needs a decision from Justin first, because it means
a new repo variable (`STAGING_DB_NAME`, say) and a real database to point it at:

- Sandbox refresh restores prod into one catalog today; per-environment catalogs need either
  N restores or a template-plus-copy step.
- Cheapest useful half-step: give `staging` its own catalog and leave the `pr-*` sites sharing
  one. Staging is the one that must be trustworthy during a demo.

**Decided 2026-08-17: take the half-step, and exclude staging's catalog from the prod
restore.** Isolating staging without excluding it from the refresh would be nearly pointless —
a prod restore puts prod's 18.x schema back, so a staging site on a newer Rock line would
re-run its whole migration set against every fresh restore, or fail the way `pr-3` did.
Not being reset underneath is what makes staging trustworthy and a version upgrade durable.
It also means staging's data drifts from prod over time, which is the accepted cost.

That decision was taken believing the restore ran nightly. It does not run at all — see
*The refresh mechanism* below, measured the same day. The decision stands anyway: a refresh
that is dormant rather than deleted is still loaded, and the exclusion has to be in place
before someone turns it back on. What changes is the price, which is zero rather than a
day's freshness.

Repo-side work is done and is a no-op until the catalog exists:

- `env-deploy-command.yml` takes an optional `db_name` input and builds the connection string
  from `inputs.db_name || secrets.DB_NAME`. Unset arrives as the empty string, which is falsy
  in a GitHub expression, so every `pr-*` site keeps exactly its current behaviour.
- `staging-deploy.yml` passes `db_name: ${{ vars.STAGING_DB_NAME }}`.
- A `Report which catalog this deploy will use` step names the *source* (never the value, which
  has to stay redacted) and warns when an environment lands on the shared catalog. Without it a
  misspelled variable falls back silently and the deploy still reports success.
- `Invoke-SandboxRefreshWithPrEnvironments.ps1` now skips non-PR manifests deliberately instead
  of calling them invalid. Staging's manifest lives at `C:\RockTestEnvs\staging\env.json` with
  no `prNumber` — only `Deploy-PrEnvironment.ps1` writes one — so it has been logged as an
  invalid manifest on every refresh. Leaving `rock-staging` running is correct *once the catalog
  is separate*; while staging is still on the shared catalog, that catalog is being restored out
  from under a live app pool. Once the move below is done the `prNumber` test becomes the wrong
  test rather than an incomplete one — see issue 09 for why a re-seed needs a different key.

**Decided 2026-08-17: the `pr-*` sites follow staging** — same catalog, same Rock version. This
supersedes the earlier half-step of isolating `staging` alone. `pr-test-deploy.yml` was pointed at
`Initial Catalog=${{ vars.STAGING_DB_NAME || secrets.DB_NAME }}`, the same variable with the same
falsy-empty-string fallback staging uses, so it was a no-op until the catalog exists.

The reasoning is worth keeping, because it inverts what this item originally said. A shared
catalog is not the defect; sharing one across two Rock *minors* is. Every `pr-*` site builds from
a PR based on the branch staging deploys, so they are the same minor by construction — and
`Tests/PrTestEnvironments/test_base_branch_config.py` now fails if `.github/pr-test-environments.json`
and `staging-deploy.yml`'s push filter ever name different branches. GitHub Actions cannot read a
JSON file to build `on: push: branches:`, so a test is the only thing that can hold that pin
together. What the move buys is that no environment of ours is left on the catalog the prod
restore owns. What it costs, on paper: `pr-*` sites stop getting fresh prod data from
that restore, so they drift from production indefinitely and need an occasional deliberate
re-seed. In practice the restore never runs, so the drift and the re-seed are both pre-existing
conditions this decision inherits rather than creates.

**Amended 2026-08-18 after the v19 staging deploy: same *minor*, not necessarily same catalog.**
The paragraph above is right about what the danger is and wrong about what follows from it. Making
`pr-test-deploy.yml` read `vars.STAGING_DB_NAME` did not just express the coupling, it enforced it:
the variable documented as staging's could not be set without moving every `pr-*` site in the same
act. Staging is the environment a version bump is meant to be tried on first, so that left nowhere
to try one — and on 2026-08-18 a v19 artifact was deployed to staging against the shared catalog,
which stranded it part-way through the v19 migration set and took the whole fleet down with it
(`Documentation/Incidents/2026-08-18-staging-v19-shared-catalog.md`).

`pr-test-deploy.yml` now reads its own `vars.PR_TEST_DB_NAME`. Both variables are unset and both
fall back to `secrets.DB_NAME`, so today's arrangement is unchanged to the byte; what changes is
that setting one moves one environment. The invariant the 2026-08-17 decision was protecting is
kept by the guard in `staging-deploy.yml`, which refuses a staging deploy whose Rock minor differs
from the fleet's pin while `STAGING_DB_NAME` is unset. That is the same rule, checked against the
variable as it actually is at deploy time rather than assumed from the wiring.

#### The refresh mechanism — measured 2026-08-17, and there is no nightly refresh

This was the one step that could silently undo the change, so it was verified against GCP rather
than assumed. Both answers came back, and the second one is the surprise.

Everything lives in project **`passioncitychurch-com`** — the resources are all named `connect-*`,
which is what makes the project easy to misremember. Confirmed by the CI bucket: `PR_TEST_GCS_BUCKET`
is `connect-file-storage`, and that bucket is owned by this project alongside `connect-mssql-backups`
and both SQL instances.

**1. The mechanism is a per-database `.bak` import.** From `gcloud sql operations describe` on the
last load:

```
operationType: IMPORT
importContext:
  database: RockConnectProd
  fileType: BAK
  bakImportOptions: { bakType: FULL, striped: true, noRecovery: true }
  uri: gs://connect-mssql-backups/RockConnectProd/full/1775749763/
```

Preceded by a `DELETE_DATABASE`, so the procedure is drop-then-import, scoped to one named catalog.
**A second catalog on `connect-restore-test` therefore survives it, and staging does not need its
own instance.** No `RESTORE_VOLUME` operation has ever run on this instance, which also rules out
the worry that `DB_USER` might be a production login surviving an instance-level restore.

**2. There is no nightly refresh, and there never was.** The instance's *complete* operation
history is 13 entries since it was created on 2026-04-13. The last data load of any kind was
**2026-04-14**. Everything after that is `UPDATE` (configuration) and one `RESTART`. Corroborating:

- `gs://connect-mssql-backups` holds exactly **one** backup set, dated **2026-05-12** (6 stripes,
  ~127 GB). The April 14 import used a different set that is no longer there. So the one backup
  that does exist was never imported.
- The **Cloud Scheduler API has never been enabled** in the project, so no scheduler job drives it.
- The only `cron:` in `.github/workflows/` is the weekly certificate renewal, and
  `-RefreshCommand` on `Invoke-SandboxRefreshWithPrEnvironments.ps1` has no caller anywhere.

Cloud SQL for SQL Server does not permit `RESTORE DATABASE` from a client — a load has to go
through the import API — so the operations list is authoritative. **The sandbox catalog was seeded
once from a 2026-04-09 production backup and has not been refreshed in four months.**

What *is* running daily is `connect-prod`'s own automated Cloud SQL backup (`BACKUP_VOLUME` every
night around 01:00–03:00, unbroken through 2026-08-17). Those are instance-level backups: useful,
but restorable only onto a whole instance, which is why the April load went through a `.bak`
export/import instead.

##### What this changes

- **The provisioning blocker is cleared — and the catalog now exists.** `RockStaging` was
  created on `connect-restore-test` on 2026-08-18 by export/import from `RockConnectProd`; no
  new instance was required. `gcloud sql databases list --instance=connect-restore-test` shows
  both catalogs.
- **"Exclude it from the refresh" is a no-op today.** There is nothing to exclude. Keep the note
  for whoever eventually builds the refresh.
- **A Rock upgrade on the shared catalog would *not* be reverted overnight.** Earlier revisions of
  this document said it would. That was inherited from the PRD's design intent, not measured, and
  it is wrong. The ordering constraint it implied — provision the catalog *before* upgrading or
  lose the upgrade — does not exist.
- **The migration-collision risk is untouched and is the actual blocker.** It is what put `pr-3` on
  a permanent 500, and it has nothing to do with refreshes.
- **The stale-data cost of moving `pr-*` onto the staging catalog is not a cost.** There is no
  nightly freshness to give up. The sandbox is already four months old and already accumulating
  every PR's data and migrations with no reset.
- **The refresh coordinator has never run.** Its acceptance criteria in issue 09 are checked
  because the script implements them, not because the process exercises it.
- **The sizing question is answered.** It was real: `connect-restore-test` is `db-custom-2-8192`
  with a 418 GB disk, and at the time `storageAutoResize` was **disabled**, so a second full copy
  beside the first was marginal. Autoresize was turned on with no limit before the copy was
  taken (2026-08-18), and the copy then completed. Both catalogs are ~108 GiB, so the instance
  now sits over half full. Autoresize covers growth, but **check used bytes before any further
  in-place copy** — the operation that fills that disk is the one that copies a catalog beside
  itself.

### 8. `build-develop.yml` still deploys by rebooting a VM

**Fixed 2026-08-10 — deleted from `passion-18.4.1`.** Details in the Fixed table below. The
build-only copy on `develop` is a different file and was left alone.

### 16. A queue with no agent looks like a 60-minute hang

*(Numbered 16 rather than 9 so the existing references in this document stay valid. It belongs
here, in P1.)*

This is the shape the **first production deploy will take** if the agent isn't installed yet,
so it is worth knowing before it happens rather than during.

`env-deploy-command.yml` queues a `command.json` and then polls for a result. Nothing checks
that anything is listening on the other end. With no agent on `commands-prod`, the run holds at
the poll until `timeout-minutes: 60` kills it, and the failure it reports is a timeout — which
reads like a slow or broken deploy rather than an absent agent. `apply: false` does not avoid
this: a dry run still queues a real command and still waits for a real result. The dry-run
logic that makes it safe lives on the VM (`Deploy-RockEnvironment.ps1:597` — `InPlace` without
`-Apply` prints its plan and returns before it downloads anything), so a dry run needs the
agent every bit as much as a real deploy does.

**Corrected 2026-08-11 — the liveness signal described here before does not work.** The earlier
version of this item said each agent run moves the command from `pending/` to `processing/`, so
a command still in `pending/` after two or three minutes proves nothing is listening. Reading
the agent rather than the prefix names shows both halves of that are wrong:

- `$ProcessingPrefix` is assigned at `Invoke-PrEnvironmentCommandQueue.ps1:21` and **never used
  again**. Nothing is ever written to `processing/`; that prefix is dead. The command object is
  deleted from `pending/` at line 305, at the *end* of the run, after the result is written.
- So a command sits in `pending/` for the whole command — up to the 1800-second
  `deploy-environment` timeout. A guard that fails a run because `pending/` is non-empty after
  three minutes would abort healthy deploys roughly every time.
- The agent is also not free of a single-instance guard: `schtasks /SC MINUTE /MO 1` takes the
  Windows default `MultipleInstances: IgnoreNew`, so a firing is *skipped* while the previous
  one is still running. The comment at line 137 says this outright.

A real liveness signal has to come from the agent, not from the queue's shape. Cheapest version:
have the agent write `heartbeat.json` on every firing, before it looks at the queue, and have the
queueing workflow fail when that object is older than a few minutes. That distinguishes the three
states this item cares about — nobody listening, listening and busy, listening and idle — which
no amount of listing `pending/` can do.

This correction matters beyond the guard, because that skipped-firing behaviour is a live failure
mode, not a footnote. See item 19.

Deliberately not built on 2026-08-10: it changes the shared deploy path, and the staging deploy
being validated that night runs through it. Same reasoning as item 5a — don't add a new failure
mode to the path a demo depends on, hours before the demo.

### 19. Commands are never claimed, so two agent runs can execute the same one

This is the finding underneath item 16's correction, and it is the more serious half.

The agent's whole command-selection logic is two lines
(`Invoke-PrEnvironmentCommandQueue.ps1:206-207`):

```powershell
$commands = Get-GcsObjectList -Prefix $PendingPrefix | Where-Object { $_ -like '*.json' }
foreach ($commandObject in $commands) {
```

It lists `pending/` and executes what it finds. **There is no claim** — no move to
`processing/`, no lease, no marker, no conditional write. The object is deleted at line 305,
after the command finishes. `$ProcessingPrefix` is assigned at line 21 and never referenced
again, which reads like the claim step was designed and then not implemented.

So two overlapping agent runs both list the same object and both run it. Two things partly
mask this, and neither is a fix:

- **Windows `IgnoreNew`.** `schtasks /SC MINUTE /MO 1` will not start a second instance of the
  *scheduled task* while one is running. But the boot path is a different process: the Windows
  startup script runs the agent synchronously itself, and the scheduled task it just installed
  fires a minute later regardless. Those two can and do overlap — on the 2026-08-11 restart the
  task was installed at 00:47:43 and the inline run began a ~15-minute staging deploy at
  00:47:44.
- **The per-environment mutex** (`Deploy-RockEnvironment.ps1:594`, `Global\RockEnvironment-<name>`,
  15-minute wait). This prevents corruption, which is the important part — it does not prevent
  the duplicate. The second run blocks on the mutex and then deploys the same artifact to the
  same site again, doubling the outage window for no benefit. If it waits out the full 15
  minutes it throws "Timed out waiting for deployment lock" and writes a *failed* result for a
  command that actually succeeded.

**Status: confirmed in production on 2026-08-11, trigger removed, root fix still open.**

It was caught in the act within the hour:

```
00:47:43  scheduled task installed by the Windows startup script
00:47:44  the startup script's own inline agent run claimed
          deploy-staging-31444814051-1, took Global\RockEnvironment-staging,
          and deployed staging -- successfully
00:48:5x  the scheduled task fired, listed pending/, found the same command
          still there, claimed it too, and blocked on the mutex
01:03:53  it gave up after the full 15-minute wait and wrote:
            "status": "failed",
            "error":  "Timed out waiting for deployment lock
                       Global\\RockEnvironment-staging."
01:04     GitHub reported the staging deploy as FAILED while
          https://staging.rock-dev.connect.passion.team was serving
          HTTP 302 in 0.105s, warm and correct
```

01:03:53 minus the 15-minute wait is 00:48:53 — one minute after the task was installed, which
is the first firing. The uploaded log is one line long, the mutex message and nothing else.

**Trigger removed.** The startup script in `pr-test-bootstrap-command-queue.yml` ran the agent
inline immediately after installing the every-minute task. Since `IgnoreNew` stops the task
overlapping *itself*, that inline run was the only way to get two agents at once. It is gone;
a pending command is now picked up by the task within 60 seconds instead. That closes the
observed failure, and it is a mitigation, not the fix.

**The fix is still the claim that was designed and never written:** copy the object to
`processing/` and delete it from `pending/` *before* running it, with the move made conditional
(`ifGenerationMatch`) so exactly one run wins. Until that exists, any second agent process from
any source reintroduces this. It also makes item 16's heartbeat cheaper, because `processing/`
would finally mean what its name says.

> **The diagnostic lesson is worth more than the bug.** On the night of 2026-08-10 this same
> "command sitting in `pending/`" observation was read as *the agent is dead*, and the response
> was to reboot the VM. Nothing supports that conclusion: a claimed, actively-running command
> looks identical, because nothing is removed from `pending/` until it finishes. The agent was
> probably fine. Worse, the reboot is what created the overlap that produced the false failure
> above — the diagnosis caused the outage it thought it was fixing. If you find yourself
> reasoning from the contents of `pending/`, stop; that is the exact inference item 16 retracts.

### 17. Every queued command carries the database password in cleartext

`env-deploy-command.yml:94` assembles `CONNECTION_STRING` from `PR_TEST_DB_DATA_SOURCE`,
`DB_NAME`, `DB_USER` and `DB_PASSWORD`, and `:129-130` writes it into the command JSON that gets
uploaded to `gs://connect-file-storage/pr-environments/commands/pending/`. The password is not
encrypted, hashed or referenced indirectly — it is a literal `Password=...` inside a plain JSON
object in a bucket. `pr-test-deploy.yml` does the same thing for PR environments.

Scope it correctly before reacting, because two things make this *not* an emergency:

- **The bucket is not public.** Uniform bucket-level access is on and
  `public_access_prevention` is `enforced`. Reading these objects requires an IAM grant on the
  project or bucket, so the exposure is to project members, not the internet.
- **The catalog is not production.** The connection string points at `172.20.0.2`, which is
  `connect-restore-test`, not `connect-prod` (`172.20.0.8`). The `RockConnectProd` catalog name
  on that instance is an artifact of how the sandbox is restored, not production data. Verified
  by listing the Cloud SQL instances and matching IPs, not by reading the name.

And one thing that makes it worse than it first looks: **the bucket has a seven-day soft-delete
retention** (`retentionDurationSeconds: 604800`). The agent deletes the command file when it
finishes, so the queue looks clean — but every command JSON written in the last week is still
recoverable, password included. "It's only there for a few seconds while in flight" is not true.

The real fix is to stop shipping the secret through the queue at all. The VM already
authenticates to GCP; it can read the password from Secret Manager itself at deploy time, and
the command JSON can carry a secret *name* instead of a secret *value*. That is the change worth
making. Rotating `DB_PASSWORD` without it just re-exposes the new password on the next deploy.

Deliberately not changed on 2026-08-10: it touches the deploy path that the next morning's demo
runs through, and the credential in question guards a restore sandbox on a private IP. Worth
doing in the same pass as item 7, since both are about how environments get their database.

### 18. Dispatching the bootstrap reboots the VM, with nothing checking what it interrupts

`pr-test-bootstrap-command-queue.yml` is the only way for a change to
`Deployment/PrTestEnvironments/*.ps1` to reach the VM — the VM has no self-update path. It
delivers the change by uploading the scripts to GCS and then **stopping and starting
`connect-srv-test`**, because the Windows startup script is what re-downloads them and
reinstalls the scheduled task.

**A fix for the self-update half is in review.** `Sync-DeploymentScripts` pulls
`pr-environments/bootstrap/latest/*.ps1` into `$DeployRoot` at the top of each poll, before the
queue is drained — the upload half already existed, and both the bootstrap and the
certificate-renewal workflows already publish there. It parses each download before replacing
anything (the agent is overwriting the scripts it runs, so an unparseable file would be
unrecoverable), isolates failures per file, and never blocks the queue on a GCS error.

That does not retire the reboot problem described below, which is about the bootstrap workflow
itself. What it retires is the *reason* to run the bootstrap for an ordinary script change —
which is most of them. It needs one manual re-bootstrap to install, because it is itself one of
the scripts that only arrives that way; after that, script fixes land on their own.

How this went unnoticed is the part worth keeping: three separate teardown bugs sat fixed in the
repository and broken on the VM at the same time, and nothing about the repository state showed
it. The scripts looked deployed.

That means a bootstrap is not a deploy-a-script operation, it is a reboot. Everything on that
VM goes down with it: staging, every live PR environment, and any deploy currently mid-flight.
Nothing in the workflow checks whether a deploy is running before it pulls the floor out.

This bit us on 2026-08-10. A push at 00:05:41Z started a staging deploy; a bootstrap dispatched
at 00:05:45Z rebooted the VM underneath it; the staging deploy's queued command was left
unclaimed in `pending/` and the run sat waiting on a result that could never arrive. Worth being
explicit that this was **operator sequencing, not a broken trigger** — the workflow is
`workflow_dispatch` only and does not fire on push, so nothing does this to you automatically.
Until there is a guard, the rule is: *never dispatch the bootstrap while a deploy is in flight,
and expect roughly five minutes of downtime on every site on the box when you do.*

The guard here is genuinely a `pending/` list, unlike item 16's: refuse to reboot while any
command object exists, with an override input for the case where the queue is stuck precisely
because the VM needs rebooting. The difference is what the signal means. A non-empty `pending/`
does not tell you an agent is *alive* (item 16's mistake), but it does tell you a command is
either running or waiting — and either one is a bad thing to reboot on top of. Same list, sound
inference this time.

### 21. The N→E machine family move already happened, and it is not the risk it was raised as

**The question was whether moving the Rock VMs from N-series to E-series breaks anything. It does
not, and it is already done.** Measured against project `passioncitychurch-com` on 2026-08-17:

| VM | Machine type | Role | Family history |
|---|---|---|---|
| `connect-srv-test` | `e2-highmem-4` — 4 vCPU, 32 GB | staging + every `pr-*` site | `n2-standard-4` on 2026-05-06, then `e2-highmem-4` on 2026-08-12 19:46 PDT |
| `connect-srv-prod` | `e2-standard-8` — 8 vCPU, 32 GB | production Rock | created 2026-05-11 already on E2; **zero** operations since |
| `intermediary-host` | `e2-small` | bastion | — |

`gcloud logging read 'protoPayload.methodName:"setMachineType"' --freshness=400d` returns exactly
two changes in the retained window, both on `connect-srv-test`, and the 2026-08-12 one was a clean
stop → change → start inside six minutes. Production was never migrated because it was never on
N-series to begin with. So there is no pending cutover to plan and no rollback to hold open.

**It was an upgrade, not a sidegrade.** `n2-standard-4` is 4 vCPU / 16 GB; `e2-highmem-4` is 4 vCPU
/ 32 GB. Same core count, double the memory, on the one host that runs staging and every `pr-*` app
pool at once — which is the resource the IIS worker processes actually contend for. Windows Server
licensing on GCE is billed per vCPU and is family-independent, so holding at 4 vCPU means the
license cost did not move either.

**What actually differs on E2, and whether Rock cares:**

- **CPU platform is not pinnable.** E2 rejects `minCpuPlatform`, and the fleet is mixed — `connect-srv-prod` is on AMD Rome, `connect-srv-test` on Intel Broadwell — so the platform can change under a restart or a live migration. Irrelevant here: Rock is .NET Framework on CLR JIT with no AVX-512 or platform-specific path, and both machines already run different platforms without incident.
- **Dynamic resource management.** E2 vCPUs are not pinned to physical cores the way N2's are. Steady-state throughput is fine; the exposure is burst latency, which lands on Rock's heaviest moment — `Application_Start`, where EF migrations, Lava, and block compilation all run at once. This does not create a new failure, but it plausibly makes **item 20** (sites going cold and reading as a broken deploy) a little worse. Treat any regression in cold-start time as an item 20 symptom, not a machine-family defect.
- **Ceilings.** E2 tops out at 32 vCPU / 128 GB, and supports no local SSD, GPUs, sole tenancy, or nested virtualization. Nothing here is close to any of those; both VMs boot from 150 GB `pd-ssd`.
- **Cloud SQL is unaffected.** `connect-prod` and `connect-restore-test` are Cloud SQL instances on their own `db-custom-*` tiers. GCE machine families do not apply to them, so nothing in item 7's catalog work interacts with this.

Two incidental findings came out of the same investigation, and both outrank the question that
prompted it:

**`automaticRestart: false` on both Rock VMs, production included.** With
`onHostMaintenance: MIGRATE` set, *planned* Google maintenance live-migrates and nothing restarts —
that part is healthy. But on an unplanned host failure the instance stops and **stays stopped until
a human starts it**. On the production Rock web server that is an unbounded outage waiting on
someone noticing. This is almost certainly a leftover default from the AWS lift-and-shift: both
boot disks still carry `vmmigration-license` and `vmmigration-aws-license`. Flipping it to `true`
is a one-line change requiring a stop/start. **Recommend doing this on `connect-srv-prod` at the
next maintenance window**, and on `connect-srv-test` whenever convenient.

**Nothing has exercised the test VM with a real deploy since the family changed.** Between
2026-08-12 and 2026-08-17 the only workflow runs touching it were a certificate renewal (succeeded,
which does at least prove the command-queue transport still works post-change) and two v19 artifact
builds, which run entirely on GitHub's Ubuntu runners and never touch the VM. So "nothing broke" is
an argument from the absence of a plausible mechanism, not from observed traffic. The first staging
deploy after the catalog work is the real test; it is expected to be uneventful.

---

### 24. The test fleet is on the open internet, carrying a copy of prod data

**Found 2026-08-19, while re-checking the pilot doc's acceptance criteria.** Issue 12 has
always carried the line *"the PR URL is reachable over VPN and not reachable from an
unapproved network."* It is unchecked because it has never been true, and nothing in the
pipeline was ever built to make it true.

What is actually in place:

| | Value |
|---|---|
| Firewall rule | `https-from-world` — INGRESS, `0.0.0.0/0`, `tcp:443` |
| Applies to tag | `prod-passion-compute` |
| `connect-srv-test` tags | `prod-passion-compute` |
| `connect-srv-prod` tags | `prod-passion-compute` — *the same tag* |

So staging and every `pr-*` site sit behind exactly the same world-open rule as production,
and the test VM is not distinguished from the production VM in any network policy.

**The firewall rule is the evidence, not a reachability test.** Staging answers
`https://staging.rock-dev.connect.passion.team/` with HTTP 302 in 0.371s on a valid
certificate (`ssl_verify_result=0`, from `34.24.168.219` = `connect-srv-test-ip`) — but that
measurement was taken from `159.63.145.194`, which is the office address, so on its own it
proves only that the *office* can reach it. What makes it a world-open finding is
`https-from-world` itself: source range `0.0.0.0/0`, no VPN gateway in front, and the office
allowlist covering only RDP (3389) and SQL (1433). Nothing in the path narrows 443.

Worth being clear about what is *not* wrong here: the rule is correct for
`connect-srv-prod`, which has to serve the public church site. The finding is that the test
VM shares its tag and therefore inherits a policy written for a public web server.

**Why this is a P1 and not hygiene.** Since 2026-08-18 the staging catalog `RockStaging` is a
full export/import copy of `RockConnectProd`. Staging is therefore a publicly-addressable Rock
instance holding real congregant data — names, addresses, giving history — protected by
nothing but Rock's own login. The `pr-*` fleet is the same data through `RockConnectProd`
directly. This was less alarming when the sandbox was thought of as scratch; it is not
scratch, and the catalog split is what made the exposure worth writing down, not what caused
it.

**And the docs said the opposite, in the place developers actually read.** Corrected
2026-08-19. The sticky PR comment posted on every pull request described the catalog as a
"shared **sanitized** sandbox database", as did the developer runbook. There is no
sanitization step and there never has been: the PRD's own status note records that the
"existing sanitization/sync process" the requirement assumed does not exist, and
`-RefreshCommand` on `Invoke-SandboxRefreshWithPrEnvironments.ps1` still has no caller
anywhere. So the one sentence a developer read before opening a public URL full of real
giving history told them it had been scrubbed.

Two tests were holding the word in place — `test_status_comment_script.py` and
`test_runbooks.py` both asserted the literal string `shared sanitized sandbox database`.
That is the same failure this document keeps recording in other forms: **a test that pins
the wording rather than the claim will defend a false statement as readily as a true one.**
Both now assert that the copy tells the reader the data is unsanitized, and fail if the
reassuring phrasing comes back.

Nothing about the exposure changed here — only that it is no longer contradicted by the
copy. Options 1–3 below are still the decision.

It also quietly contradicts the pipeline's own story elsewhere: item 5's health check was
reworked specifically because *the VM cannot reach its own public address*, which reads as
though something is closed. Nothing is. That was a route problem on the VM, not a policy.

**What to decide.** Three options, cheapest first, and this is DevOps's call rather than a
change to make unilaterally:

1. **Split the tag.** Give `connect-srv-test` its own tag and a rule that allows `tcp:443`
   only from the office/VPN ranges plus the ACME challenge source. One rule, one tag change,
   no application involvement. Note `pr-test-acme-http` already opens `tcp:80` from
   `0.0.0.0/0` for the Let's Encrypt HTTP-01 challenge — that one has to stay open, or
   certificate renewal breaks, so scope any restriction to 443 and leave 80 alone.
2. **Accept it deliberately and write down why**, with the compensating control named (Rock
   login, no anonymous surface). If this is the answer, say so in the pilot doc too, and close
   the acceptance criterion as *won't do* rather than leaving it looking unfinished.
3. **Stop putting prod-derived data on the test instance.** Much more work, and it fights the
   whole point of a prod-shaped sandbox.

Do not simply drop the criterion from issue 12. It has been sitting unchecked for months and
was read as an incomplete pilot step rather than an open exposure; deleting it is how that
happens again.

---

### 25. Merging a deploy-script fix does nothing until someone dispatches the bootstrap

**Found 2026-08-19, and it is why the app-pool ACL fix appeared to be merged while staging
stayed broken.** The deploy scripts do not execute from the repository. They execute from
`C:\RockDeploy` on `connect-srv-test`, and the agent's `Sync-DeploymentScripts` refreshes that
directory from `gs://<bucket>/pr-environments/bootstrap/latest/*.ps1` at the top of every poll.
So the VM does track the bucket closely. The gap is one step earlier: **the only thing that
publishes to that prefix is `pr-test-bootstrap-command-queue.yml`, and it is
`workflow_dispatch`-only.** Merging to `Deployment/PrTestEnvironments/*.ps1` therefore has no
effect on any deploy until a human remembers to dispatch it.

The measurement:

| | |
|---|---|
| ACL grant merged (`71064b2e61`, PR #18) | 2026-08-19 14:36 UTC |
| Last bootstrap before that | 2026-08-18 19:35 UTC, from `passion-18.4.1` |
| `icacls` occurrences in the copy the VM was running | **0** |
| Staging `theme.css` after a successful deploy | still the 2026-01-22 build, 430,153 bytes, 0 `ti-` rules |

The staging deploy that ran in between reported success at every step, because nothing in it
looks at the script version it just executed.

**What makes it hard to see.** The failure is silent in both directions. A deploy using a stale
script still succeeds, and a theme that fails to compile still serves the previous `theme.css`
with HTTP 200 — so the health check passes, the run is green, and the only symptom is that the
site looks wrong to a human. That is the same shape as item 24's wording problem and item 23's
oracle problem: the check passes because it is not measuring the thing that broke.

**Worth separating from a related fact**, or the fix will be aimed wrong: the agent cannot
update *itself* (`Invoke-PrEnvironmentCommandQueue.ps1` is the one file the sync cannot replace,
because Windows holds it open), and that genuinely needs the bootstrap's VM restart. Every other
script only needs the *upload*. So this item is about publishing, not about rebooting.

**Options, cheapest first:**

1. **Publish on merge.** Give the upload step its own workflow triggered by `push` on
   `Deployment/PrTestEnvironments/**`, doing the `gsutil cp` and nothing else — no metadata
   change, no stop/start. The bootstrap keeps the reboot path for agent changes.
2. **Report the version at deploy time.** Have the deploy print the hash of each script it is
   about to run alongside the hash in the repo at that commit, and warn on mismatch. Does not
   fix the drift, but makes it visible in the run log rather than in the rendered page.
3. **Fail closed on drift.** As above but `exit 1`. Correct in principle; risks blocking a
   deploy for a script change that has nothing to do with it, so probably only worth it for
   `Deploy-RockEnvironment.ps1`.

Option 1 is the actual fix and is small. Option 2 is worth doing regardless, because it is the
thing that would have turned three hours of diagnosis into one line of log.

> **Option 2 is built, 2026-08-19.** `env-deploy-command.yml` now sparse-checks out
> `Deployment/PrTestEnvironments`, downloads the published copies, and compares them with line
> endings normalised, before it queues the command. A mismatch prints a `::warning::` naming the
> stale scripts and a `STALE ON THE VM` row in the run summary. Three things about it are
> deliberate and should survive edits: it runs **before** the queue step, so the warning arrives
> while the deploy can still be abandoned rather than as a post-mortem; it is
> `continue-on-error: true`, so a diagnostic can never fail the deploy it is only observing; and
> an empty local directory reports *not checked* rather than *in sync*, because "zero differences
> found against nothing" is the exact failure this check exists to catch. `DeployScriptDriftTests`
> in `Tests/PrTestEnvironments/test_environment_deploy.py` pins all three, and pins the GCS prefix
> against the one the bootstrap actually publishes to -- the two could otherwise drift apart and
> the check would report "in sync" forever against an empty prefix.
>
> **It shipped with the bug it was built to catch, which is worth recording.** The first version
> compared `Deployment/PrTestEnvironments` only. Smoke-testing it against the live bucket showed
> 10 local scripts and 12 published ones: the bootstrap globs *two* directories into that one flat
> prefix, and the check was blind to `Deployment/Database` -- the scripts an operator reaches for
> mid-cutover. A drift check that covers most of the scripts reports "in sync" with authority it
> has not earned. The directory list is now derived from the bootstrap's own publish line by
> regex rather than written out again, so adding a third directory fails the test until the
> comparison and its sparse checkout follow. A second test forbids the same `.ps1` basename in
> two published directories, because the prefix is flat: the name is the whole identity once a
> script lands on the VM, and a collision would let one copy overwrite the other silently and
> pin the loser as permanently drifted.
>
> **Options 1 and 3 are still open**, and option 2 does not substitute for either. This tells you
> the scripts are stale; it does not publish them, and it does not stop the deploy. Somebody still
> has to dispatch the bootstrap and deploy again.
>
> **First live catch, on the very next deploy — run `32282066731`, 2026-08-19 17:31 UTC.** It
> warned, correctly, that three scripts on the VM are not the ones in the commit being deployed:
> `Invoke-PrEnvironmentCommandQueue.ps1`, `Convert-LegacyTextColumns.ps1` and
> `Find-LegacyTextColumns.ps1`. The check works. Two things follow from *which* three:
>
> - The queue agent is one of them, and it is the file the sync cannot replace while Windows
>   holds it open. That one needs the bootstrap's restart, not just an upload — the distinction
>   drawn above, now with a concrete instance.
> - `Find-LegacyTextColumns.ps1` is stale, and the operator runbook's legacy-column step was
>   rewritten this same day to tell operators to dispatch that finder. **A runbook step can be
>   correct about which workflow to dispatch and still run a stale script on the far side.** The
>   drift warning is the only thing that would say so, and it prints on deploys, not on a
>   `workflow_dispatch` of the finder.
>
> Nothing on the ACL fix's path was stale, which is consistent with it being live.

**How to apply, generally:** verify at the receiving end, not the publishing end. Both existing
tests around the bootstrap assert that the upload step exists, and both were green throughout.

---

### 26. The v19 cutover dropped a working feature, and every test stayed green

**Found and fixed 2026-08-19.** The runbook's v19 pre-flight step is "dispatch **DB - Find legacy
text columns** and read the output". On the new trunk that was not a thing you could do. Three of
the four pieces it needs had not been carried across the cutover:

| Piece | State on the new trunk |
|---|---|
| `Deployment/Database/Find-LegacyTextColumns.ps1` | present |
| `Deployment/Database` in the bootstrap's publish glob | **missing** — the script never reached the VM |
| `find-legacy-text-columns` branch in the queue agent | **missing** — the command returned "Unknown command" |
| `.github/workflows/db-find-legacy-text-columns.yml` | **missing** — nothing to dispatch |

All three were added on `passion-18.4.1` on 2026-08-18, the day before the trunk moved. There is
no commit deleting them; the branches simply diverged and the merge did not carry them. Confirmed
by counting `+` lines when restoring: the bootstrap needed two (both shortened variants of lines
already there) and the agent needed none, so the trunk files were strict subsets — a wholesale
restore, not a merge.

**The part worth internalising is that `test_legacy_text_columns.py` was green the entire time.**
It asserted the scripts exist, the runbook names them, and the finder performs no writes. All
still true. The ability to *run* the thing was not among the things it was looking at, so its
disappearance was invisible. This is the same failure shape as item 24's wording tests and item
25's "the upload step exists" tests: the assertion is pinned next to the feature rather than on it.

The chain is now pinned end to end by `TheFinderCanActuallyBeRunTests` — bootstrap publishes the
script, agent has a command that invokes it, a `workflow_dispatch` workflow queues that command,
and the `-Apply`-gated converter is deliberately *not* reachable from the queue. Each was
mutation-tested by breaking that link alone and confirming that test and only that test fails.

**Two facts that make this class of loss more likely here than it looks.** `workflow_dispatch`
runs the workflow file from the repository's **default branch**, so a workflow left behind on the
old trunk is not merely stale, it is unreachable. And Cloud SQL here is Private Service Connect
only, so the finder has exactly one place it can run — the deploy VM — and no local fallback
exists to paper over a broken publish path.

**What to do about it, and it is not "write more tests".** Item 23 already said "diff the two
trunks before flipping the default", and it was done — it is how the ACL fix was caught. It was
read as a list of commits rather than a list of files, which is why this slipped through. At the
*next* upgrade, diff the two trunks for whole files present on the old one and absent on the new
before renaming the default branch, and treat `.github/workflows/*` and `Deployment/**` as the high-risk set. A file that
exists on only one side is either a deliberate deletion with a commit behind it or an unported
fix, and the difference is one `git log` away. Nothing currently performs that check.

---

### 27. The guard added to catch the silent CSS failure blocked the next deploy instead

**Found and fixed 2026-08-19, about three hours after the guard it is about.** Item 25 and the
theme-CSS work produced a completeness gate in `pr-test-artifact.yml`: after the styles build,
fail the artifact if `RockWeb\Styles\styles-v2` looks empty. The reasoning was sound — a build
that emits `tabler-icon.css` and nothing else would satisfy the existing check while still
shipping a broken stylesheet set. The implementation was `if ($stylesV2.Count -lt 10)`.

It failed the first build it ever gated, on output that was complete and correct:

| | |
|---|---|
| Guard merged (`6df00c490d`) | 2026-08-19 16:49 UTC |
| Next staging deploy (`32279379727`) | 2026-08-19 17:02 UTC — **failed**, `styles-v2 holds only 7 files` |
| Rewritten to measure bytes (`d4cde07c55`) | 2026-08-19 17:30 UTC |
| The first two builds it gated after that (`32282066731`, `32286995341`) | both **passed** — `All essential assemblies present ✓`, `styles-v2 files: 7` |

**Why 7 is right.** `Rock.Frontend.Styles/src/styles/styles-v2` holds 189 SCSS partials, one
non-partial entry point (`core.scss`), and five plain `.css` files. Partials compile *into*
`core.css` and emit nothing of their own, so a complete build emits six files plus a map. The
build log confirms it: steps 1–6 of 98 are the whole of styles-v2, and the other 92 are themes
and layouts.

**Where 10 came from.** The 18.4.1 line commits that folder as *source* — 178 files. The 19.x
line generates it as *output* — 7 files. Both numbers are correct for their branch and no
threshold separates a good build from a bad one across both. The guard's own comment said it was
"deliberately unguarded — it has to hold either way", which is the right instinct aimed at the
wrong quantity: what has to hold either way is that the stylesheets have content, not that there
is a particular number of them.

**The fix is to measure the payload rather than the layout.** Every one of those 189 partials
lands in `core.css` — 705,722 bytes on 18.4.1 and the same order on 19.x — so its size separates
a real compile from a stub identically on both lines. The gate now requires `core.css` to exist
and clear 100 KB, and `tabler-icon.css` to clear 50 KB, because `Test-Path` is satisfied by a
zero-byte file and an empty stylesheet compiles perfectly well — it just renders nothing. That
last point is not hypothetical; presence-without-content is the shape of the original silent
failure this whole thread started from.

**The lesson is narrower than "test your guards" and worth stating exactly.** A guard is code
that runs in a place the author cannot see, on branches the author is not building. This one was
written while reading the 19.x tree and reasoning about the 18.4.1 tree, and the number came from
the tree that was *not* in front of it. When a check has to hold across two branch lines, derive
its expectation from something both lines actually agree on — here, "the stylesheet has bytes in
it" — and never from a count of files, which is a property of how a branch stores things rather
than of whether the build worked.

`StylesGateCompletenessTests` in `Tests/PrTestEnvironments/test_pr_artifact_workflow.py` pins the
fix, including a regression test that fails if a `$stylesV2.Count` threshold is ever reintroduced
as a build failure, and a test that reads the source tree to confirm `core.scss` is still the only
entry point — so the day someone adds a second one, the gate is told to name it.

---

### 28. Rock 19 moved theme customization into the database, and the upgrade repoints the internal site

**Found 2026-08-20 on staging, after the CSS work above was already verified green.** The
dashboard rendered in stock Rock orange with none of Passion's branding while the login page was
correctly branded. Nothing was broken, no stylesheet was stale, and no deploy needed repeating —
two upstream changes combine to produce it, and both land on production at cutover.

**The upgrade repoints the internal site.** `202508051740308_Rollup_20250805`, in a region
named "JE: Rock Theme Change", runs

```sql
UPDATE [Site] SET [Theme] = 'RockNextGen'
WHERE [Guid] = 'c2d29296-6a87-47a9-a753-ee4e9159c4c4'
```

and that Guid is `SystemGuid.Site.SITE_ROCK_INTERNAL`. Site 1, "Rock RMS", is on `RockNextGen`
now rather than `Rock`. The statement is unconditional, so it will do the same thing to
production.

**And v19 moved where customization lives.** `ThemeService.BuildTheme` is
`[RockObsolete( "19.0" )]`, annotated "Themes are no longer compiled on disk, they will be
processed at request time". The values come from `Theme.AdditionalSettingsJson` and are injected
per request instead. On staging **all 26 theme rows had an empty `AdditionalSettingsJson`**, so
`RockNextGen` served its `theme.json` defaults — the computed `--color-primary` was `#FF791D`,
exactly the default that file declares.

**Why the login page looks fine, which is the part that misleads.** The themes that kept their
branding — `CONNECT`, `PassionCityChurch`, `PassionTeam`, `Agency` — are LESS themes whose
customization sits in their own on-disk `_variables.less`, and the build never regenerates those
folders. `RockNextGen` is generated from `Rock.Frontend.Styles/src/themes/` on every build, so it
cannot hold customization on disk and has none in the database. Login is served by the external
CONNECT site, the dashboard by the internal one: same instance, two different mechanisms. Anyone
checking "is the CSS deployed" will find it deployed and correct, because it is.

**Resolved on staging 2026-08-20 — Passion's blue, set on `RockNextGen`.** The internal site keeps
Rock 19's new admin theme and takes Passion's brand colour from the database. Admin Tools → CMS
Configuration → Themes → RockNextGen → Edit → Primary Color, set to `#00B8E4` — the blue the
`CONNECT` theme already compiles to. `Theme.AdditionalSettingsJson` now reads

```json
{"ThemeCustomizationSettings":{"CustomOverrides":"","EnabledIconSets":3,
"DefaultFontAwesomeWeight":0,"AdditionalFontAwesomeWeights":[],
"VariableValues":{"base-primary":"#00B8E4"}}}
```

and the dashboard's computed `--base-primary` and `--color-primary` are both `#00B8E4`. Because
that lives in the database rather than on disk, it survives every deploy — which is the whole
point of the v19 change.

**Do not reach for the `Rock` theme as the "restore the old look" lever.** It is stock orange too:
`RockWeb/Themes/Rock/Styles/_variables.less` sets `@brand-color: #ee7725`, and the deployed copy
compiles to exactly that, so swapping `RockNextGen` → `Rock` trades one orange for another. Every
Passion theme that *is* branded is already claimed by a public-facing site — `CONNECT` by sites 9
and 11, `PassionCityChurch` by 13, `PassionTeam` by 16, `Agency` by 17 — so there is no branded
theme free to hand to the internal site wholesale. Setting the colour on `RockNextGen` is the only
option that produces Passion branding.

**Also set: the link colour.** Production's `Rock` theme compiles `--link-color` to `#599AC2`
rather than Bootstrap's `#006DCC`, so `RockNextGen`'s Link Color is set to `#599AC2` to match. On
`RockNextGen` the variable is named `base-link` and resolves to `--base-link` / `--color-link`;
`--link-color` is a LESS-theme name and reads empty there, which makes for a confusing probe.

**Resolved on staging 2026-08-20 — the logo, by way of a file in the artifact rather than an
upload.** The corner brand is not conditional. `Site.Master` emits
`<a class="navbar-brand-corner no-logo">` with that class hardcoded, and `.no-logo::after` paints
`var(--logo-image)`, so the theme variable is required even on a site that already has a
`SiteLogoBinaryFileId`. Only the sidebar reads the binary file (`PageNav.lava` branches on
`Site.Layout.Site.SiteLogoBinaryFileId`); the corner never does, and the login page's
`#logo::before` paints the variable too. Setting the site logo alone leaves Rock's mark in the
corner.

The theme's own Site Logo field could not supply it on staging, for a reason that is its own entry
below — the uploader targets the `Unsecured` binary file type, which is backed by a storage
provider this server does not have. What works in both environments, and needs no upload during
the production window, is a file in the artifact plus a CSS override:

```css
:root { --logo-image: url('/Assets/Images/passion-logo-white.png'); }
```

`RockWeb/Assets/Images/passion-logo-white.png` is committed to the repository and is a byte-for-byte
copy of what production already serves as its internal site logo — binary file 124872,
`pcc_logo.png`, 150x150, the Passion "P" in pure white on transparency, which is what a coloured
sidebar needs. CSS overrides are emitted *after* the `:root` variable block, so the rule wins
whatever the Site Logo field holds.

**Verified on staging 2026-08-20** after the deploy that carried the file: the asset serves 200 at
3516 bytes, the corner shows the Passion "P" on Passion blue, and the theme's three values
survived a `DedicatedSite` deploy that wipes the site directory — which is the database-backed
customization doing exactly what v19 intended.

One symptom does remain on staging, and it is item 29's, not this one's. `PageNav.lava`'s sidebar
logo is a real `<img>` pointed at `GetImage.ashx`, and staging cannot retrieve that file, so the
element is broken there — hidden at desktop width, visible as a gap when the side nav is expanded.
Production retrieves it fine. Do not "fix" it with a staging-only CSS rule: it is the storage gap
showing through, and masking it removes the signal.

One thing worth knowing before it surprises someone: at 150x150 that file is smaller than v19 asks
of it. The old `Rock` theme drew it at 42x42 and never upscaled it, but `RockNextGen` paints it at
200px on the login page, where it will look soft. `theme.json` asks for "a white SVG file".
Replacing the PNG with a vector is a branding decision rather than a deploy one, and nothing is
blocked on it.

**Production inherits none of this.** `AdditionalSettingsJson` is a row in the production
database and the staging edit does not touch it, so all three settings have to be made again in
the production window, after the migration has run: Primary Color `#00B8E4`, Link Color `#599AC2`,
and the `--logo-image` CSS override above. The logo file itself arrives with the artifact.
Production could also upload through the Site Logo field, because its storage provider works —
but the override behaves identically in both environments and costs no manual step.

**Two measurement traps here, both of which produce a confident wrong answer.** Check-in themes
compile `checkin-theme.less`, not `theme.less`, so probing `Themes/<name>/Styles/theme.css`
returns 404 for all six and reads as a fleet of broken themes; they are healthy at roughly 260 KB
each under the right filename. And the three NextGen themes are legitimately ~30 KB, because Sass
leaves an `@import` of a `.css` file as a literal CSS `@import` rather than inlining it — the
browser then fetches the 824 KB `core.css` separately. Neither size means what it appears to.
Check the configuration, not the files:

```js
await ( await fetch( '/api/Sites?$select=Id,Name,Theme' ) ).json()
await ( await fetch( '/api/Themes?$select=Name,AdditionalSettingsJson' ) ).json()
```

---

### 29. On staging, only database-backed files work — every image in cloud storage 404s, and new uploads fail

**Found 2026-08-20, while trying to upload a logo through the theme editor** (item 28). The upload
returned "A storage provider has not been registered for this file type or the current storage
provider is inactive." That string comes from `BinaryFile.SaveHook`, which throws it when
`Entity.StorageProvider` resolves to null.

These look like one fault and are two, with different causes and different fixes.

**Reads fail because the bytes are in cloud buckets staging cannot read.** Every `BinaryFile` row
carries its own `StorageEntityTypeId` — deliberately, so a file stays retrievable after its type
is repointed. Probing `GetImage.ashx?guid=` across a sample of each:

| Per-file provider | Result |
|---|---|
| `Rock.Storage.Provider.Database` (51) | **200** — bytes are in the catalog, so they came with the restore |
| `Rock.Storage.Provider.GoogleCloudStorageProvider` (758) | **404** |
| `rocks.pillars.AmazonStorageProvider.S3BlobStorage` (900) | **404** |

The catalog is a copy of production's, so it references objects in production's buckets. Whether
staging is missing credentials, is pointed at a bucket it has no permission on, or both, was not
determined — that needs the server's `ExceptionLog`, and it does not change the conclusion.

**Writes fail for a separate reason: the provider component does not exist in the build.** 19 of
staging's 22 binary file *types* point at entity type 900,
`rocks.pillars.AmazonStorageProvider.S3BlobStorage`. That is a third-party plugin, and
`git ls-files | grep -i pillars` returns nothing — it is not in the repository, so it is not in the
artifact. `ProviderContainer.GetComponent` cannot resolve it, `StorageProvider` is null, and the
save hook throws. `Unsecured` is one of the 19, and `Unsecured` is what the Obsidian
`ImageUploader` targets whenever a block does not name a type — which is why an unrelated theme
field could not accept a file.

**Why production is not in this state, and the part of that worth watching.**
`Deploy-RockEnvironment.ps1` behaves differently in its two modes. Staging is `DedicatedSite`:
`Remove-Item $SitePath -Recurse -Force`, then the artifact is moved into place, so anything on the
server that is not in the artifact is gone — the Pillars assembly included. `$PreservedDirectories`
is `Content, App_Data, Logs, Uploads`; `Bin` is not on it. Production is `InPlace`: robocopy over
the existing tree with no `/MIR` and no `/PURGE`, so files the server owns survive.

That asymmetry cuts both ways, and the second direction is the one to watch:

- **Production keeps its plugin through a deploy.** The v19 upgrade will not break production's
  images. Worth stating plainly, because the staging symptom invites exactly the opposite
  conclusion.
- **Production does not keep its theme edits.** `InPlace` still *overwrites* every file the
  artifact does contain, and `RockWeb/Themes/Rock/Styles/_variables.less` is one of them.
  Production's copy carries Passion's blue; the artifact's carries `@brand-color: #ee7725`. Any
  deploy reverts it, with nothing reporting that it did. For the v19 window this is moot — the
  migration moves the internal site off that theme anyway — but a site left on any git-tracked
  theme loses its branding on the next deploy. This is the same mechanism that made staging's
  `Rock` theme orange while production's stayed blue, and it is the reason item 28 puts the fix in
  the database rather than in a `.less` file.

**What this costs as a rehearsal.** Anything touching a binary file behaves differently on
staging: person photos, uploaded documents, check-in labels, merge templates, and any block that
uploads. A production rehearsal there cannot exercise those paths. Two honest options — put the
plugin in the repository so the artifact carries it and give staging its own bucket, or record
that staging is knowingly image-blind so a broken image there stops being re-investigated as a
finding.

---

### 22. `connect-restore-test` had no automated backups — fixed 2026-08-18

> **Done.** Automated backups, point-in-time recovery with 7-day log retention, and unlimited
> `storageAutoResize` are all enabled on `connect-restore-test` as of 2026-08-18. Re-verified
> 2026-08-19 — the instance reports `True / True / 7 / True` for those four settings. Kept here
> because the finding explains why the settings were changed, and because the asymmetry is an
> easy one to reintroduce when someone next builds a sandbox instance.

As found on 2026-08-18, and it is worth stating which half was already fine:

| | `connect-prod` | `connect-restore-test` (as found) |
|---|---|---|
| Automated backups | **on** — nightly 01:00 UTC, most recent `1787014800000` succeeded 2026-08-18 | **off** |
| Point-in-time recovery | **on**, 7-day transaction log retention | **off** |
| Retained backups | 7 | — |
| `storageAutoResize` | off, 418 GB disk | off, 418 GB disk |

**Production was never the exposed side.** An earlier reading of this suggested otherwise; it
was wrong, and the table above is the verified state as found.

The autoresize half mattered as much as the backups. The instance holds a 418 GB disk and a
~108 GiB catalog, so any operation that copies a catalog in place — which is exactly what
seeding `RockStaging` did the same day — can fill the disk. Both were changed before that copy
was attempted, not after.

The gap is `connect-restore-test`, and it is not a spare box. It holds the shared sandbox
catalog that staging and every `pr-*` site run against — item 7 is the same instance seen from
the isolation angle. Until 10:04 UTC on 2026-08-18 it had **zero** backups of any kind, and the
only restore point in existence was a striped `.bak` from 2026-05-12. The first was
`1787047442610`, taken by hand immediately before the v19 staging migration, precisely because
there was nothing else to fall back to; the nightly schedule has been running since.

One manual backup is not a backup policy. Rock runs its EF and plugin migrations at
`Application_Start`, so the first request after any deploy rewrites the schema irreversibly — the
failure mode this protects against is not an operator typo, it is a routine deploy of a build
whose migrations do something unexpected. That is the same mechanism that gave `pr-3` a permanent
HTTP 500 on 2026-08-11.

This is what was done on 2026-08-18, and the instance now matches prod: backups on, PITR on,
7 retained backups, 7 days of transaction logs. The window is **08:00 UTC** — an earlier draft
of this item proposed 03:00, and either satisfies the only actual requirement, which is not
landing on top of prod's 01:00.

**Timing matters, and it is the one caveat — kept here because it applies to the next instance
somebody builds, not because this one is outstanding.** Turning PITR on can force an instance
restart. Do not do it while a migration is in flight: a restart part-way through a schema
migration is how you get a half-applied catalog, which is strictly worse than the missing
backup. Apply it in a quiet window, with no deploy running and the queue empty.

**One piece is still open, and it is on the other instance.** `connect-prod` has
`storageAutoResize` **disabled** on a 418 GB disk — the sizing question already raised at the end
of item 7. `connect-restore-test` was flipped on 2026-08-18 and prod was not, so the two now
disagree. Enabling it is a no-downtime change and removes a failure mode — a full disk stops the
instance — that no alert currently covers:

```
gcloud sql instances patch connect-prod --project=passioncitychurch-com --storage-auto-increase
```

Read live on 2026-08-19, which is where the split above comes from:

| | `connect-prod` | `connect-restore-test` |
|---|---|---|
| Automated backups / PITR | on / on | on / on |
| Retained backups / log days | 7 / 7 | 7 / 7 |
| Backup window | 01:00 UTC | 08:00 UTC |
| `storageAutoResize` | **off** | on |

### 23. Every trunk cutover has repo-side steps that are easy to miss

**Done for the 19.3.4 cutover on 2026-08-19.** Kept here because each step recurs verbatim at
the next upgrade, and all are cheap in advance and expensive to discover live. The fourth
was not caught in advance — it was found on 2026-08-19 with production already undeployable.

**`.github/pr-test-environments.json` pins `baseBranch` to the outgoing trunk.**
`pr-test-lifecycle.yml` compares `pull.base.ref` against it and quietly sets `should_run=false`
on a mismatch — it logs and exits successfully. So the morning PRs start targeting the new
branch, every stop and destroy silently stops working and nothing reports an error. The same
value gates the deploy path. Flip it in the same change that moves the trunk, and flip the
`push:` trigger and the `workflow_dispatch` ref default in `staging-deploy.yml` with it.

**Anything merged to the outgoing trunk after the new branch was cut is lost unless it is
carried over.** For this cutover that was the teardown fixes and the app-pool ACL fix
(`71064b2e61`, cherry-picked). Such fixes are based on the *outgoing* trunk deliberately —
`workflow_dispatch` and `schedule` both run the workflow file from the **default** branch, so a
fix that only exists on the incoming branch fixes nothing until the cutover — but that is
exactly what makes them easy to leave behind. Diff the two trunks before flipping the default.

That advice was already written here on the day it failed. **Item 26 is what it missed**, and the
reason is worth carrying: the diff was read as a list of *commits* to cherry-pick, which found the
ACL fix, and not as a list of *files present on one side and absent on the other*, which is what
would have found the legacy-column workflow. The second reading is the one to do — it is
`git diff --name-status old..new --diff-filter=D` and it takes a minute.

**A third one, once item 3 is actually done: branch protection does not follow the cutover.**
Rules and rulesets are bound to a branch *name*, so the moment the default moves, the new trunk
is unprotected and the rules that still exist are guarding a branch nobody targets any more.
Today that costs nothing because there is no protection to lose (item 3, verified still
`protected: false` on 2026-08-19) — which is precisely why it is worth writing down now, before
the first cutover that happens *after* somebody sets the rules up. Re-point the ruleset in the
same change that flips the default, and re-check with
`gh api repos/passiondev/Rock/branches/$(gh api repos/passiondev/Rock --jq .default_branch)/protection`.

**A fourth one, and this one bit: moving the trunk broke the production deploy outright.**
`production-deploy.yml` has two guards — is this ref on the branch production deploys from, and
does it declare the Rock minor production runs — and both read
`github.event.repository.default_branch` as their oracle. That was deliberate. The reasoning,
written into the test that asserted it: a pin is one more thing to flip at cutover, and a missed
one would refuse every legitimate deploy. What it assumed was that the default branch and the
branch production runs are the same branch.

They stopped being on 2026-08-19. The trunk moved to `passion-19.3.4`; production stayed on
`passion-18.4.1`. GitHub's compare API calls those two `diverged`, which lands in the branch
guard's catch-all:

> Refused. `passion-18.4.1` is `diverged` relative to the trunk. There is no override for this
> one — merge the change into `passion-19.3.4` and deploy that.

So **production could not be deployed at all**, including an emergency rollback, and the only
documented way out was to ship v19 to production. The version guard was inverted the same way:
it would have waved the dangerous deploy through and demanded `acknowledge_version_change` for
the safe one — a guard that fires on routine work is one that gets ticked without being read.

Nothing reported it. `production-deploy.yml` is `workflow_dispatch`-only and has never been
fired, so there was no run to fail, and `test_production_deploy.py` was green the whole time
because it asserted *that the guard reads the default branch* — the mechanism, which was intact
— rather than *that the guard accepts the ref the workflow itself offers*, which was not.

Fixed by giving production its own pin: `productionBranch` in
`.github/pr-test-environments.json`, read over the API from the default branch rather than from
the checkout — the checkout is `ref: inputs.ref`, so reading it there would let a branch ship a
config naming itself and approve its own production deploy. Both guards use it. The lesson
generalises past this one workflow: **an oracle that is correct because two things happen to be
equal needs a test that fails when they stop being.** That test is now
`test_the_workflows_own_default_ref_is_one_the_guard_accepts`, and it compares the workflow's
own `ref` default against the pin, so a half-done cutover fails CI rather than waiting to be
discovered during an incident.

## P2 — hygiene

### 9. Stale branches — but two of them are not safe to delete

`develop-17.6.1`, `deploy/ptp-14803-18.4.1`, `bump`, `fix/group-sync`, and
`pilot/pr-test-env-doc-smoke-v1761` no longer serve a purpose. Pruning them removes several
ways to target the wrong base branch. Confirm `fix/group-sync` is genuinely abandoned before
deleting.

**They are not equally safe, and "superseded by the trunk" — how this item read until
2026-08-19 — was too loose a word for four of them.** Measured that day against
`passion-19.3.4`, `passion-18.4.1`, `develop` and `feat/PTP-16122` together, counting files
whose blob matches nothing at the same path on any of them:

**On `feat/PTP-16122` in that baseline — checked 2026-08-19.** It is a **local branch only**; it
is not on `origin` and never was pushed, so it resolves in one clone and nowhere else. Two
consequences, and they pull in opposite directions:

- *It does not weaken the table.* Of the 276 files it carries under `RockWeb/Plugins/`, **zero**
  hold a blob that is absent from `origin`. It contributed nothing to the second column, which
  is why the recount command below — which omits it — is still comparable to the table rather
  than a different measurement. Drop it from the baseline mentally and the plugin numbers stand.
- *It is itself a single-clone dependency.* It has one commit on no `origin` branch at all:
  `283c41f1` (2026-04-01), "build on all branches and add local dev setup script". Nothing in
  this item needs it, but it exists in exactly one place, and a clone is not a backup. Push it or
  tag it, or decide out loud that the local dev setup script is not worth keeping.

This is also why the escalation below says the branch no longer exists on `origin` while the
baseline above names it — both are true, and the distinction is the whole point.

| Branch | Unique files | Of those, under `RockWeb/Plugins/` | Prunable on its own? |
|---|---|---|---|
| `deploy/ptp-14803-18.4.1` | 3 | 0 | **Yes** — 0 unique commits; fully contained in `passion-18.4.1` |
| `fix/group-sync` | 3371 | 0 | Yes, once confirmed abandoned |
| `bump` | 3376 | 5 | **No** — see the escalation below |
| `pilot/pr-test-env-doc-smoke-v1761` | 3381 | 7 | **No** — see the escalation below |
| `develop-17.6.1` | 3384 | 8 | **No** — see the escalation below |

Read the first column with care: it is dominated by Rock core sitting at a 17.6.1-era
revision, which is an old Rock version rather than anything of ours worth keeping. The column
that decides anything is the second one, because `RockWeb/Plugins/` is where our code lives.
That is also the column that ties this item to the escalation immediately below — the plugin
files stranded by the `staging` deletion are exactly these.

Recount before pruning rather than trusting the table; it is a measurement, not a rule:

```bash
git fetch origin --prune
for b in develop-17.6.1 bump fix/group-sync pilot/pr-test-env-doc-smoke-v1761 deploy/ptp-14803-18.4.1; do
  echo "== $b"
  git rev-list --count "origin/$b" --not origin/passion-19.3.4 origin/passion-18.4.1 origin/develop
done
```

One caveat on `deploy/ptp-14803-18.4.1` even though it is clean: it is the `push` trigger of
`.github/workflows/ptp-14803-build-artifact.yml`. Deleting the branch leaves that workflow
reachable only by `workflow_dispatch`, which is in fact how it was last used (run
`32120334971`, 2026-08-18, dispatched against `fix/forward-port-to-19`). Fine to do, but do it
knowingly.

> **Escalated 2026-08-19 — this prune list is no longer safe as written.** `staging` was
> deleted from `origin` on 2026-08-18 (a `DeleteEvent` at 09:17 UTC; the branch survives only
> in local clones). Its five unique plugin files and its two unique commits — `d3119b5103`
> "fix datetime issue in plugin" and `0fe0175651` "Optimizations" — are still reachable, but
> only from `feat/PTP-16122` **and from `bump`, `develop-17.6.1`, and
> `pilot/pr-test-env-doc-smoke-v1761`, three of the branches listed directly above as safe to
> prune.** Deleting the list today leaves one feature branch as the sole remote copy.
> **Do item 14 first,** or tag the content, before any pruning happens.

> **Re-measured 2026-08-19, later the same day, and it is worse than the paragraph above
> says. Read this one instead.** Two things moved.
>
> **`feat/PTP-16122` no longer exists on `origin`.** So the safety margin that paragraph
> describes — one feature branch still holding the content after the prune — is already gone.
> Both unique commits are now reachable from exactly three remote branches, and all three are
> on the safe-to-prune list:
>
> ```
> d3119b5103, 0fe0175651 -> origin/bump, origin/develop-17.6.1,
>                           origin/pilot/pr-test-env-doc-smoke-v1761
> ```
>
> **And `develop` is not the backstop it is being treated as.** Comparing blobs rather than
> commit dates, the five plugin files sit at two or three versions each, and `develop` holds the
> oldest of them in every case:
>
> | File | `bump` | `develop-17.6.1`, `pilot/…` | `develop` |
> |---|---|---|---|
> | `org_passion/RSVP/RsvpDetailBETA.ascx` | `f5d0a5458` | `f5d0a5458` | `7e3472a23` |
> | `org_passion/RSVP/RsvpResponse.ascx.cs` | `9db5b4b36` | **`a5b64c4b0`** | `5efd2ccef` |
> | `org_passion/RSVP/RsvpResponseBETA.ascx.cs` | `6b88881e1` | **`b0c637db0`** | `b1a6af931` |
> | `org_secc/Authentication/Arena.cs` | `dad198cc0` | `dad198cc0` | `1df50645c` |
> | `org_secc/Authentication/org.secc.Authentication.csproj` | `5687c33d0` | `5687c33d0` | `211bd5436` |
>
> Every row's newest blob is one `develop` does not have. The two bolded ones are the starkest —
> the current content of those files, existing on
> **`develop-17.6.1` and `pilot/pr-test-env-doc-smoke-v1761` only** — not on `bump`, and not on
> the branch this item spends a paragraph telling you to protect. Pruning the list as written
> destroys the newest copy of all five and keeps January copies on `develop` that will look
> plausible to whoever finds them next.
>
> That is the actual correction here: **"do not delete `develop`" was aimed at the wrong
> branch.** `develop` is worth keeping for the reasons given below, but it is not what is
> holding this code. Before anything is pruned, tag the three holders — a tag is a ref, it
> costs nothing, and it survives the branch deletion that is the whole risk:
>
> ```
> git tag archive/plugins-bump            origin/bump
> git tag archive/plugins-develop-17.6.1  origin/develop-17.6.1
> git tag archive/plugins-pilot-v1761     origin/pilot/pr-test-env-doc-smoke-v1761
> git push origin --tags
> ```
>
> Nothing here has been deleted or tagged — this is a measurement, and the pruning decision is
> still open.

**Do not delete `develop`.** An earlier revision of this list called it a
"pristine upstream mirror" and put `staging` in the safe-to-prune set. Both were wrong, and
measurably so:

- `develop` declares **Rock 19.0.3** — not a mirror and not an ancestor of the trunk. It tracks
  all **276** files under `RockWeb/Plugins/`, 78 of them `org_passion`/`team_passion`, and all
  78 are absent from the trunk. It is also the branch the last production build came from —
  2026-05-06 from `dd6d189b`, still `origin/develop` HEAD. See item 15 for why that build must
  never be installed on production. *(Re-measured 2026-08-19 against the new trunk: 276, 78, 78
  and `dd6d189b` all still hold.)*

  **One of the two reasons this item gave for keeping it has expired.** Until the cutover,
  `develop` was the v19 line and therefore "the only in-repo starting point for the eventual v19
  upgrade". That upgrade has happened, and it did not start here — the trunk took 19.3.4 from
  upstream and is now **three minors ahead** of `develop`, which is 1,537 commits behind it and
  35 ahead. Of those 35, four are the January plugin import and most of the rest are the
  original PR-test-environment automation that has since been re-landed on the trunk. So the
  case for keeping `develop` now rests on the plugin files and the build provenance alone, and
  once item 14 reconciles the plugins onto the trunk, only the provenance is left — which a tag
  holds just as well as a branch.

  Do not copy the divergence date out of here. The two diverged in early January 2026, but the
  exact merge base moves every time the trunk does: it was `daea3ce6` (2026-01-07) against
  `passion-18.4.1` and is `faffd264` (2026-01-08) against `passion-19.3.4`. Measure it with
  `git merge-base origin/develop origin/<trunk>` rather than trusting a copy.
- `staging` (now deleted from `origin`, see above) declares **Rock 17.6.1** and is 73 commits
  ahead of `develop`, holding **five plugin files newer than `develop`'s copies** — `org_passion/RSVP/RsvpDetailBETA.ascx`,
  `org_passion/RSVP/RsvpResponse.ascx.cs`, `org_passion/RSVP/RsvpResponseBETA.ascx.cs` (all
  2026-02-24 vs. develop's 2026-01-09), plus `org_secc/Authentication/Arena.cs` and
  `org.secc.Authentication.csproj` (2026-01-28 vs. 2026-01-09). Two of its commits
  (`fix datetime issue in plugin`, `Optimizations`) exist nowhere else.

Neither branch can be pruned until the plugin files are reconciled onto the trunk (item 14),
because between them they are the only copy of some of this code. The branch names are also
misleading enough to be worth renaming once that is done: `develop` is a v19 branch and
`staging` is a v17 branch, and neither name says so.

**A second, easier class of branch, added 2026-08-19.** Everything above is a branch stale
since January. The week of the v19 cutover added ten more, and they are not the same problem:
each was a short-lived working branch, none carries a file under `RockWeb/Plugins/`, and none
is entangled with the deleted `staging`. Nine are fully merged — zero commits ahead of the
trunk they targeted — and can be deleted without reconciling anything:

| Merged into | Branches |
|---|---|
| `passion-18.4.1` | `fix/pr-env-teardown-tooling`, `docs/staging-catalog-disk-check`, `fix/commit-verify-artifact-script`, `feat/pr-env-agent-hardening`, `fix/staging-shared-catalog-version-guard`, `fix/scan-database-scripts-for-ps7` |
| `passion-19.3.4` | `fix/pr-env-tooling-v19`, `fix/forward-port-to-19`, `fix/v19-icon-cursor-type-guard` |

Confirm with the same shape of check the table above uses:

```bash
git fetch origin --prune
for b in fix/pr-env-teardown-tooling docs/staging-catalog-disk-check \
         fix/commit-verify-artifact-script feat/pr-env-agent-hardening \
         fix/staging-shared-catalog-version-guard fix/scan-database-scripts-for-ps7; do
  echo "$b -> $(git rev-list --count origin/passion-18.4.1..origin/$b)"
done
```

`fix/pr-env-teardown-tooling` is worth a note because it reads as unmerged and is not. It sits
one commit ahead of `passion-19.3.4`, which looks like a forward-port that never happened. The
forward-port did happen — the same change is on the trunk as `fe94885237` rather than the
branch's `b84e255c86`, because it was re-applied on the v19 line instead of merged across.
Count against the branch's own base, not against the current trunk, or every 18.4.1 branch
looks unmerged.

**The tenth one is stale and should be deleted.** `fix/ci-frontend-styles-build` is an
abandoned first attempt at the CSS fix, cut from `passion-18.4.1` when the fix belonged on the
v19 line; the work shipped instead as PR #19, from the since-deleted
`fix/v19-frontend-styles-ci`. Its single commit is already on the v19 trunk in patch-equivalent
form as `dad41842df` — `git cherry origin/passion-19.3.4 origin/fix/ci-frontend-styles-build
origin/passion-18.4.1` reports it `-`. Nothing is lost by deleting it.

**Correcting what this item said until 2026-08-19:** it claimed merging the branch would
silently revert the app-pool ACL grant, on the grounds that the branch is behind=1 against its
base and that one commit is the grant. The first half is true and the conclusion does not
follow. The branch's diff touches exactly one file, `.github/workflows/pr-test-artifact.yml`;
a three-way merge leaves `Deploy-RockEnvironment.ps1` untouched, because being *behind* a
commit is not the same as reverting it. Verified with
`git diff --name-only origin/passion-18.4.1...origin/fix/ci-frontend-styles-build`.

There is a real risk in the vicinity, and it is a different one: the branch's *tree* predates
the grant, so **deploying from this branch** — not merging it — puts a `Deploy-RockEnvironment.ps1`
without the `icacls` call on the box and reproduces the theme-compile failure. That is a
plausible mistake to make with a branch named for the CSS build while debugging CSS, which is
the other reason to delete it rather than leave it discoverable.

### 10. `GCP_COMPUTE_PROJECT_ID` is a dead secret

No workflow references it. Remove it so the secret list reflects reality; an unused secret is
one nobody audits.

### 11. Action version drift, and Node 20 deprecation

Runs are emitting: *"Node.js 20 is deprecated. The following actions target Node.js 20 but
are being forced to run on Node.js 24: `google-github-actions/auth@v2`,
`google-github-actions/setup-gcloud@v2`, `actions/checkout@v4`, `actions/github-script@v7`."*

Currently forced to Node 24 automatically, so nothing is broken — but it will break when the
shim is removed. Also inconsistent across the repo:

| Action | Versions in use |
| --- | --- |
| `actions/checkout` | `@v4` × 9, `@v5` × 1 |
| `actions/setup-node` | `@v4` × 3, `@v6` × 1 |
| `google-github-actions/auth` | `@v2` × 8 |
| `google-github-actions/setup-gcloud` | `@v2` × 8 |

Pin one version per action across all workflows and bump the Node-20 ones.

### 12. The pilot doc was stale — rewritten 2026-08-19

> **Done.** `Documentation/Discussion Docs/PR-Test-Environments-Issues/12-pilot-rollout.md`
> said deployment failed at an SSH step, which the Cloud Storage command queue replaced long
> ago. It now separates the current pin from a frozen historical record of the pilot, and its
> acceptance criteria are re-marked against what has actually been observed rather than what
> the code is believed to do.

Two things worth carrying forward from the rewrite:

- **A mechanical branch bump had falsified a historical fact.** The doc recorded PR #3's base
  branch as the *then-current* trunk, because each cutover found-and-replaced the branch name
  through the whole file. PR #3 was actually based on `develop-17.6.1` (confirmed against the
  API). The frozen-history banner now in that document exists to stop the next cutover doing
  it again — see also item 23.
- **Re-marking the criteria surfaced item 24.** The "not reachable from an unapproved network"
  box had been unread for months as an unfinished pilot step. It is an open exposure.

### 13. The test VM sends nothing to Cloud Logging

The production VM ships Windows event logs to Cloud Logging; the test VM does not — the Ops
Agent is installed per VM and was never installed there. So when a test site fell over on
2026-08-10 there was no server-side log to read from outside the box at all.

Largely worked around: a deploy whose health check fails now uploads its own diagnostic
report — IIS state, deployed assembly versions, the last hour of ASP.NET and .NET Runtime
events, the tail of `App_Data\Logs`, and the response body — to
`gs://<bucket>/pr-environments/diagnostics/<environment>/`. Installing the agent would still
be better for anything that isn't a deploy.

### 14. Plugin blocks are outside version control, so no test environment had a login page

**Priority: was P1 despite the number; the P1 part is fixed** — this list is append-only so the
numbers stay stable across revisions and the cross-references above keep working. What remains
is the open question at the end, which is a decision rather than a defect.

`RockWeb/Plugins/.gitignore` is a single rule, `*/*`, so every plugin subfolder is ignored.
That is upstream Rock's convention — plugins are installed packages, not source. The
consequence for *us* is that Passion's own customizations are not on the trunk:
measured 2026-08-10, the trunk tracks two files under `RockWeb/Plugins/` (`.gitignore`,
`readme.txt`) and **zero** paths matching `org_passion` or `team_passion`, against 448 tracked
core blocks under `RockWeb/Blocks/`.

They are not absent from the *repository*, though — only from the trunk. `develop` tracks all
276 files under `RockWeb/Plugins/`, 78 of them `org_passion`/`team_passion`, because a file
already tracked stays tracked when an ignore rule appears later. That is why neither `develop`
nor `staging` can be pruned (item 9), and it is how the login block below could be read and
diagnosed without touching a server.

So:

- A plugin-block change cannot go through this pipeline at all — there is no tracked file on
  the trunk to commit. Today that work is manual and server-side.
- Production is not at risk. `InPlace` copies with robocopy `/E` and no `/PURGE`, so plugin
  folders already on the box survive an artifact that lacks them. Worth stating explicitly,
  because the opposite would have been catastrophic and it is one line of script away.

**This was worse than "plugin pages don't render", and that is how it was found.** Passion's
login page *is* a plugin block, `org_passion/Security/Login.ascx`. With no plugins on a test
site, `staging` and every `pr-*` site served

```
Error Loading Block: Login
The file '/Plugins/org_passion/Security/Login.ascx' does not exist.
```

as their **landing page**. `/Login` and `/page/3` both rendered the error and the admin pages
302 into it, so nobody could sign in to a test environment at all. A deploy reported green
while the site was unusable, because a health check that accepts HTTP 200 or 302 cannot tell a
rendered page from a rendered error. Two demo steps depended on logging in.

**Fixed 2026-08-11** (`63cd0a7719`): `Plugins` added to the shared-asset overlay default in
both deploy scripts, so it is the shipped behaviour rather than a variable someone has to know
to set. The copy is only-if-absent (`/E /XC /XN /XO`) and the artifact ships nothing under
`Plugins`, so for this directory the overlay can only add. The plugin build-artifact strip now
runs *after* the overlay in both scripts; it used to run only on the extracted artifact, which
was sufficient while the overlay could not carry `Plugins` at all.

Production could not be affected by that change, and the reason is structural rather than
careful: `Sync-SharedSiteAssets` is reachable only from the `DedicatedSite` branch, and
production deploys `InPlace`. A test pins that now, by brace nesting — after the first version
of the test turned out to be vacuous. It matched an unrelated `if ($Mode -eq 'DedicatedSite')`
block near the top of the script, so it passed even with the overlay hoisted onto the
production path, which was the one thing it existed to catch. The suite also runs in CI now
(`deployment-pipeline-tests.yml`); it never had before, so every guard in it was effectively a
comment until something executed it.

**Changing a deploy script is not enough on its own, and this bit is easy to lose.** The VM
runs its own installed copy of these scripts, so the fix reached `connect-srv-test` only after
a bootstrap run (`31487969492`) — item 1's rule to re-bootstrap after any change under
`Deployment/PrTestEnvironments/` applies here in full. Separately, the overlay runs at deploy
time, so an environment that already exists keeps its broken site until it is redeployed.
Fixing the script does not reach back into a site deployed before the fix.

The residual risk is worth naming: `Login.ascx` uses `CodeFile="Login.ascx.cs"`, so the
code-behind is compiled by ASP.NET at runtime against whatever Rock assemblies the artifact
shipped. Its dependencies are all `Rock.*` and framework namespaces — no Passion assembly is
needed in `bin` — but a plugin written against a different Rock line can still fail to compile
against 18.4.1. That failure mode is a compile error on the page rather than a missing file,
and it is why this was verified by rendering the page and not by reading the script.

**It is not only `Plugins`, and that is the part with the wider consequences.** Chasing why the
demo PR's change would not appear on the landing page turned up the same gap in `Themes`.
Measured 2026-08-11 against `pr-4`: `/page/3` is not drawn by the repo's
`Themes/Rock/Layouts/Splash.aspx` — the rendered markup has no `<div id="content">` and carries
a `login-background` class that appears nowhere in this repository — and `/checkin` loads
`/Themes/Checkin-Guest/Styles/checkin-theme.css`. Neither `CONNECT` nor `Checkin-Guest` appears
in `git ls-files RockWeb/Themes` at all — the trunk tracks 13 themes and every one of them is a
stock Rock theme name. Both of Passion's arrive by overlay, exactly like the plugins.

The practical consequence is the one to remember: **every page an anonymous visitor can reach
on this install is rendered by a file outside version control.** The front door, the check-in
kiosk, and the login box are all server-side assets. A branch can change core blocks, the
upstream themes, `RockWeb`'s own pages, and the compiled assemblies — but it cannot change what
a signed-out visitor sees, and the only page in this repository that a signed-out visitor
reaches at all is `RockWeb/Http404Error.aspx`. That is why the demo's visible proof is a
deliberate 404 rather than the home page. It is also a caution for anyone reviewing a PR by
eye on a test URL: seeing no change is not evidence the change did not deploy.

One thing still worth deciding:

- **Should Passion's plugins be version-controlled on the trunk?** A larger question, and a
  real trade-off against upstream's convention and against this repo being public — 78 files
  currently sit on `develop` only. Not something to decide in a training session, but the team
  should know it is currently *unanswered* rather than *answered no*. Until it is answered,
  test sites get their plugins by overlay from the base site, which means they show the
  *server's* copy of a plugin, never a branch's.

---

### 15. Which branch production deploys from — settled, plus the migration it implies

**Priority: P0 despite the number** — this list is append-only so the numbers stay stable across
revisions and the cross-references above keep working. Opened as "nothing establishes which
branch production deploys from." Measured and answered on 2026-08-10; what remains is one
migration step that has to be taken deliberately, and one guard to add to the workflow.

`production-deploy.yml` defaults its `ref` input to the branch **production** runs — currently
`passion-18.4.1`. Nothing in the repository stated *why* that is the right source, so it was
measured. **The default is correct**, and the reason is worth writing down, because the obvious
alternative is actively dangerous.

Note this pin is deliberately *separate* from the repository default. During a Rock upgrade the
trunk moves first and production stays put, so folding the two together would hand a no-argument
production dispatch a newer artifact than production is qualified for. `Tests/PrTestEnvironments/
test_base_branch_config.py` asserts them separately for exactly that reason.

Each branch declares its own Rock version — in `Rock.Version/AssemblySharedInfo.cs` through
18.x, and in `Directory.Build.props` as `<Version>` from 19.x, which deleted the older file.
They are not three points on one line — they are three different Rock majors. The cutover added
a fourth: the trunk is `passion-19.3.4` today, three minors ahead of `develop`, so "the v19
branch" is no longer a unique description of anything. The exact divergence commit moves with the
trunk — measure it, per item 9 — and the row below is the 2026-08-10 reading against
`passion-18.4.1`.

| Branch | Declares | Descends from upstream tag `18.4.1`? | Commits the tag has that it lacks | Files under `RockWeb/Plugins/` |
| --- | --- | --- | --- | --- |
| `passion-18.4.1` (trunk when measured; production's pin today) | **18.4.1** | yes | 0 | 2 |
| `develop` | **19.0.3** | no — diverged early January 2026 | 218 | 276 |
| `staging` (deleted from `origin` since; see item 9) | **17.6.1** | no | 2,238 | 276 |

**Read "trunk" below as "the production branch" -- corrected 2026-08-19.** This section was
written when production's source branch *was* the trunk, and it used the two words
interchangeably. The cutover moved the trunk to `passion-19.3.4` and left production on
`passion-18.4.1`, so every "trunk deploy" sentence here would now send Rock 19 to production.
The branch is named explicitly below wherever it matters; the pin itself is `productionBranch`
in `.github/pr-test-environments.json`.

Production's own `bin`, inventoried 2026-07-30, is a patchwork within the 18.x line: 17
assemblies at 18.1.0, 8 at 18.3.1, and 3 at 18.4.1 (`Rock.dll`, `Rock.Blocks.dll`,
`Rock.Version.dll`, hot-swapped 2026-07-20). Nothing on the box is 19.x. So:

1. **Production is 18.4.1 at the core and behind it everywhere else.** `Rock.dll` and
   `Rock.Version.dll` are 18.4.1, which is why Rock's own about-page reports 18.4 — but most of
   the site is still 18.1.0/18.3.1. A `passion-18.4.1` deploy builds every assembly at 18.4.1,
   so it brings the stragglers *forward*. That is the reconciliation production needs, not a
   risk to avoid.
2. **`develop` must never be deployed to production.** It is the 19.0 line. A v19 artifact on
   production is a major-version jump whose migrations run at startup and cannot be walked
   back. The last production *build* ran 2026-05-06 from `develop` (`dd6d189b`) — and the
   absence of any 19.x assembly on the box is the evidence that artifact was never actually
   installed. That was luck, not a control. **Done 2026-08-19:** `production-deploy.yml`
   refuses any ref that is not on `productionBranch`. It measured against the *default* branch
   until then, which broke the moment the trunk moved -- see item 23.
3. **Production cannot lose its plugins.** The `InPlace` path uses `robocopy /E` with no `/MIR`
   and no `/PURGE` (`Deploy-RockEnvironment.ps1:647-659`), so server-only files survive. Trunk
   carries 2 plugin files and production carries hundreds; the deploy leaves them alone.
   Verified by reading the script, not by deploying. (The 2-file count is `passion-18.4.1`'s;
   the trunk's is not what this deploy would copy.)

**The one real risk, and it is specific:** `Rock.Migrations.dll` on production is **18.3.1**,
and `passion-18.4.1` builds it at **18.4.1**. Rock runs pending migrations on first startup, so
the first deploy from that branch will apply the 18.3.1 → 18.4.1 migrations against the
production database. That is a normal patch-level upgrade, but it is a one-way door.
Deploying the *trunk* instead is not a patch-level anything -- it is the Rock 19 jump described
in point 2, which is why the guard now measures against the pin rather than the default branch. It needs a verified database backup
taken immediately before, and it should be the *only* change in that deploy.

**What to do, in order:** re-confirm the assembly inventory on `connect-srv-prod` (the numbers
above are from 2026-07-30 and predate any 18.4.1 work since); take and *verify* a database
backup; deploy `passion-18.4.1` to production during a window, with DevOps present; then reconcile the
plugin files (item 14) so one branch holds all of it. The ref guard from point 2 is in place.

This is why the production path is deliberately unfired — not because the source branch was
unknown, but because the migration step above has to happen deliberately and with a backup.

---

### 20. Test sites go cold after 20 minutes, and it reads as a broken deploy

The highest-value item in P2, because it is the thing the team will hit every single day and
consistently misdiagnose. Nothing in this repo ever sets `idleTimeout`, `startMode` or
`preloadEnabled` on an app pool — confirmed by grepping all of `Deployment/` and
`.github/workflows/` — so IIS defaults apply: the worker process shuts down after **20 minutes**
with no requests, and `startMode` is `OnDemand`.

Rock makes that default unusually expensive. Its first request after a start rebuilds caches and
applies pending migrations before it renders anything, so the cost is not the ~1s a typical
ASP.NET app pays.

Measured 2026-08-11:

| Situation | First request | Second |
| --- | --- | --- |
| `pr-4`, idle ~32 min, nothing deployed or restarted | **62.2s** | 0.10s |
| `staging`, 33s after deploy `31453111607` finished | **0.10s** | 0.10s |
| `pr-4` / `staging`, first request after a VM restart | 95s / 107s | <0.4s |

The second row is the useful one: a site you just deployed to is *already warm*, because the
deploy's health check makes a real request as its last step. So the slow load never correlates
with deploying — it correlates with *not* using the site — which is exactly backwards from what
someone debugging their own change will assume. Expect "my PR environment is broken" reports
that are really just a cold start.

Two ways to fix it, in increasing order of cost:

1. Set `idleTimeout=0` and `startMode=AlwaysRunning` on the test app pools, plus
   `preloadEnabled=true` on the sites. Keeps the worker process alive so the 20-minute cliff
   disappears. Costs idle RAM per environment on a box that already hosts staging plus every
   `pr-*` site — so measure before applying it to all of them rather than assuming it is free.
2. Leave the defaults and warm on a schedule (a request every ~15 min). Cheaper in memory,
   but it is a moving part that can fail silently, and a failure looks identical to the bug.

Option 1 for `staging` alone is the obvious first move: it is the one host that is always
supposed to be up, there is exactly one of it, and it is the one most likely to be opened by
someone senior with no patience for a white screen.

**Do not change this the day of the training** — it touches the app pools underneath the demo
environment. Until it is fixed, the workaround is in the facilitator script and the handout:
open the page a few minutes before you show it to anyone.

---

## Fixed since the last revision — recorded so nobody re-diagnoses these

Five of these each independently reported **green** while being broken, which is why the
pipeline appeared to work for three months and didn't. The `.refresh` one is the sharpest
example: a build cannot verify what it never attempted, and nothing in the job ever looked at
`RockWeb\bin` to ask whether the assemblies were actually there.

| Was | Now |
| --- | --- |
| The test VM had been `TERMINATED` since 2026-05-11, so every deploy timed out | Running; the queue agent round-trips a command in under a minute |
| MSBuild pinned to the VS `2022` install folder in 5 places; the runner image moved it to `18` | Located at run time via `vswhere.exe`, the only stable path |
| `continue-on-error: true` plus a trailing `exit 0` forced the build step green, so a failed compile still packaged and deployed | Build failures fail the run; verification gates on the six core assemblies and on `*.obs.js` |
| `Rock.JavaScript.Obsidian.Blocks` was **never built**, and no `.obs.js` is tracked in git — so every deployed PR site had zero working Obsidian blocks | Both Vue workspaces build, in dependency order, and the run fails if the output is missing |
| `robocopy /MIR` mirrored the base site over the PR site, destroying branch edits under `Themes`, `Content`, `Assets`, `Styles` | `robocopy /E /XC /XN /XO` — copies only files *absent* at the destination |
| A caller granting only `contents: read` while `pr-test-artifact.yml` requests `actions: read` — a token escalation GitHub kills as `startup_failure`, with **no jobs, no logs, and `actionlint` reporting clean** | `actions: read` granted in both callers, plus a repo-wide test that walks every local `uses:` edge and fails if any caller under-grants |
| `core.getInput('pr_number')` in a `github-script` step that received no such input | Reads the resolved value from the job context |
| A shared command-queue prefix let either VM pick up either environment's commands | One prefix per VM: `commands`, `commands-prod` |
| `.env` files were not git-ignored — in a public repo | Ignored (`.gitignore` 57–59), with `!*.example.env` preserved |
| A deploy that failed on the VM reached GitHub as one sentence, and diagnosing it meant an RDP session | The queue agent uploads each command's redacted output to `pr-environments/<queue>/logs/`, and the workflows print it. Redaction happens on the VM because a deploy command carries a database password and this repo is public |
| Nothing captured the application's own error when a site deployed but would not start | The health-check failure path uploads a diagnostic report to the private bucket and prints only its object name — an application log can carry someone's email address |
| **`RockWeb` is a Web Site project, not a `.csproj`,** so the per-project build never built it and never resolved its 84 `*.dll.refresh` pointers. The 20 packages that reach `bin` *only* that way were absent from every artifact ever produced. `Application_Start` loads `Google.Protobuf` through the Google/Firebase stack, so **staging and every PR environment returned 500 on every request** — while the build reported green, because nothing looked | A step resolves each `.refresh` pointer out of `packages\` into `RockWeb\bin`, filling gaps only so a project-built DLL still wins. `Google.Protobuf.dll` joined the artifact gate as the canary, and the run summary reports resolved and unresolved counts |
| The resolver above then found `packages\` **empty**, because nothing restored it. Rock's `.csproj` projects use `PackageReference`, whose packages land in the global `~/.nuget/packages` cache; the 84 `.refresh` pointers are written in the older packages.config convention, `..\packages\<Id>.<Version>\lib\<tfm>\`. `nuget restore Rock.sln` walks projects, and a Web Site project has none to walk, so `RockWeb\packages.config` was never restored. All 20 pointers still failed — the run reported `RESOLVED_REFRESH_COUNT: 0` and `UNRESOLVED_REFRESH_COUNT: 20` and the artifact gate caught it | `nuget restore RockWeb\packages.config -PackagesDirectory packages` runs alongside the solution restore, which is what Visual Studio does for a Web Site project. All 20 packages are declared there at exactly the versions the pointers name |
| `build-develop.yml` was a second, worse production deploy path: it set a `windows-startup-script-ps1` on the production VM, then stopped and started the VM to run it. The script copied the package over `C:\inetpub\wwwroot\` — not the site path this pipeline uses — and mixed cmd.exe syntax (`%errorlevel%`, `2>nul`, `if (…) (…) else (…)`) into PowerShell. It was gated on `branches: [staging]`, dormant since 2026-02-24, and one push away from firing | Deleted from the trunk (on `passion-18.4.1`, the trunk at the time); `production-deploy.yml` supersedes it. The separate build-only copy on `develop` was left alone |
| The `DedicatedSite` deploy path deleted the site directory wholesale and never consulted `$PreservedFiles` — only the `InPlace` path did. A deploy that supplied no connection string therefore destroyed `web.ConnectionStrings.config`, and since `web.config` binds it through a `configSource`, the site 500'd on every request including its own error page | Preserved files are stashed and restored across the replace, and `Write-RuntimeConfiguration` now throws when no connection string was supplied *and* none exists, instead of reporting that it is "leaving the existing" file in place |
| A syntax error in a deployment script surfaced as a scheduled task dying quietly on the VM | The bootstrap workflow parses every `Deployment/PrTestEnvironments/*.ps1` before uploading any of them |
| The one failure in the other direction: the staging deploy reported "did not become healthy within 300 seconds" three times over while the site was serving Rock normally minutes later. ASP.NET caches an `Application_Start` failure for the lifetime of the app domain, so once one probe lands on a faulted domain, every later probe re-reads that same cached exception — retrying alone can never recover. 300 seconds also fits only about four probes at `-TimeoutSec 60` plus a 10-second sleep, which is not enough to distinguish "still running migrations" from "broken" | The window is 900 seconds (still under the queue agent's 1800s command timeout and the deploy job's 60 minutes), the probe recycles the app pool after 4 minutes of failures so a poisoned domain costs one interval instead of the whole window, each attempt logs its own error, and `SecurityProtocol` is pinned to TLS 1.2 so a protocol mismatch cannot masquerade as a dead site |
| …and the widened window still could not pass, because the probe was aimed somewhere the VM cannot reach. `Test-EnvironmentHealth` requested the environment's **public** host name from **on the VM**, and this VM cannot reliably reach its own external address. `staging-deploy.yml` had therefore never once succeeded — 0 green in 8 runs — on deploys that were serving fine. The deploy's own diagnostics caught both sides at the same instant: on-box, `https://staging.rock-dev.connect.passion.team/` → *"The underlying connection was closed: An unexpected error occurred on a send"*; off-box, the same URL → **HTTP 302 in 0.115s**. Production CD would have hit this identically on its first real run, since both go through `env-deploy-command.yml` | The probe targets `https://127.0.0.1/` with the public name in the `Host` header — same IIS site, same app pool, same app domain, so it still answers the only question a deploy can be blamed for, without DNS or the route back in. That needs `HttpWebRequest` (`Invoke-WebRequest` refuses to set the restricted `Host` header) and `AllowAutoRedirect = $false` (Rock's 302 carries an absolute `Location`, and following it would leave the loopback for the very name being avoided). Reachability from the internet is now checked from the **GitHub runner**, which can see it. Diagnostics record both vantage points, labelled — loopback failing means the application is broken; loopback passing while the public name fails means the application is fine and the problem sits in front of it |
| **A Rock upgrade moved a directory from committed to generated, and CI never noticed.** `RockWeb/Styles/styles-v2/` holds 178 tracked files on 18.4.1; on 19.3.4 its `.gitignore` is `*` and `Rock.Frontend.Styles` generates it. No workflow referenced that project, so the v19 artifact shipped without `styles-v2/icons/tabler-icon.css`. `_rock-core.less:243` imports it, so the LESS compile failed at startup and staging kept serving the 18.4.1 `theme.css` — 430,153 bytes, zero `ti-` rules — while the icon migration had already rewritten every `IconCssClass` in the database to Tabler. Login page fine, everything behind it unstyled | `pr-test-artifact.yml` builds `Rock.Frontend.Styles`, guarded on its lockfile so it no-ops on the 18.4.1 line. All three deploy paths share that workflow, so production's v19 cutover is covered (PR #19) |

The `startup_failure` one is worth remembering specifically: a called workflow can only
**narrow** the caller's `GITHUB_TOKEN`, never widen it. If a callee's `permissions:` requests
a scope the caller didn't grant, GitHub kills the entire run before any job starts. There are
no logs to read and `actionlint` does not catch it. Same class of trap: the `inputs` context
does not exist on a `push` event — use `github.event.inputs`, which is simply `null` there.

---

## Suggested order

1. Item 2 — the Environment now exists and the gate is real (verified against the API on
   2026-08-11 and unchanged when re-read on 2026-08-19: one required reviewer
   `justinpbarnett`, `can_admins_bypass: false`, `prevent_self_review: false`). What's left is adding the
   DevOps engineer as a second reviewer and then flipping `prevent_self_review` to `true`
   (~5 min, and only then is production two-person)
2. Item 3 — protect the trunk (~10 min, makes the training true). Still unprotected: the
   branch protection API returned `404 Branch not protected` for `passion-19.3.4` on
   2026-08-19, so the cutover carried the gap across rather than closing it
3. Item 15 — the source branch is settled (production is pinned, and during an upgrade it
   deliberately lags the trunk). What's left: add the ref guard so `develop` can never be
   deployed, re-confirm production's assembly inventory, and plan production's next version
   move with a verified backup. This gates the first real production deploy
4. Item 28 — restore the internal site's branding in the production window, right after the
   migration runs. The decision is made and proven on staging: keep `RockNextGen` and set three
   things in Admin Tools → CMS Configuration → Themes → RockNextGen → Edit — Primary Color
   `#00B8E4`, Link Color `#599AC2`, and a CSS override of
   `:root { --logo-image: url('/Assets/Images/passion-logo-white.png'); }`. None of it carries
   over from staging, because it is a row in each database. The logo file itself ships in the
   artifact. Skipping this leaves every staff member looking at stock Rock orange, under Rock's
   logo, on the morning after the cutover
5. Item 29 — decide what staging is worth as a rehearsal. Only database-backed files work
   there: everything in Google Cloud Storage or behind the Pillars S3 plugin 404s, and new
   uploads fail outright because that plugin is not in the repository and so not in the
   artifact. Either fix it (ship the plugin, give staging its own bucket) or write down that
   staging is image-blind, so the next person does not re-investigate a broken image as a
   finding. Worth settling before the production window, because it bounds what a rehearsal
   there can actually prove
6. Item 7 — **the staging half is done** (`RockStaging`, split 2026-08-18). What's left is the
   `pr-*` fleet, which still shares one catalog with itself: decide whether to give the fleet
   `PR_TEST_DB_NAME` too, or to accept the risk while only one PR site runs at a time
7. Item 24 — decide the test fleet's network exposure. It is a decision plus, if the answer
   is option 1, a single firewall rule and a tag; the reason it sits this high is that the
   data behind it became prod-derived on 2026-08-18 and the decision has never actually been
   made by anyone
8. Item 1 — install the production agent, together (~1 hour, needs a VM stop/start window).
   Do item 21's `automaticRestart` flip on `connect-srv-prod` in the same window: it needs the
   same stop/start, takes about a minute, and until it is done an unplanned host failure leaves
   production off until a human notices and starts it
9. ~~Item 4~~ — **done 2026-08-11.** Both copies of the selector are fixed, renewal has run,
   and both hosts were re-measured on real certificates *after* a subsequent deploy and a VM
   restart. Nothing left but to let the weekly schedule run. Read item 4 anyway before touching
   either deploy script — the bug existed in two places and only one of them was obvious
10. Item 14 — decide whether test sites should render plugin pages (a config line, then a
    decision about version control that is bigger than this pipeline), and reconcile it with
    item 15 — they are the same reconciliation seen from two ends
11. Item 17 — move the database password out of the command JSON and into Secret Manager. Do it
   in the same pass as item 7; both are about how an environment gets its database, and
   rotating the password before this change just re-exposes the new one
12. Item 25 — **option 1, publish deploy scripts on merge.** Option 2 landed 2026-08-19 and
    caught three stale scripts on the very next deploy, so the drift is no longer silent — but
    it is still a `::warning::` somebody has to read, on a step that is `continue-on-error` by
    design. Option 1 is a `push`-triggered workflow doing one `gsutil cp`, and it removes the
    manual dispatch entirely for every script except the agent itself, which genuinely needs
    the reboot. Small, and it retires a whole class of "the deploy ran the old script"
13. Item 20 — the 20-minute cold start. Cheap, and it removes the support burden of people
    reporting a cold start as a broken environment. `staging` first; measure the memory before
    doing it to every `pr-*` site
14. Items 10–13 — cleanup, any time. **Item 9 is not "any time" and no longer says what this
    line used to say.** `staging` is already deleted, so there is nothing left to protect by not
    pruning it; what needs protecting is `bump`, `develop-17.6.1` and
    `pilot/pr-test-env-doc-smoke-v1761`, which between them hold the newest remote copy of five
    plugin files and the only copy of two commits — and all three are on that item's own safe-to-prune list. Tag
    them first (the commands are in item 9), or do item 14, before deleting anything
15. Items 5, 6 and 18 — the "CI can't see this" gaps, once the above is stable. Item 18's guard
    and item 16's are the same GCS list written twice; build them together
16. ~~Item 22~~ — **the backup half is done** (2026-08-18, re-verified live 2026-08-19).
    `connect-restore-test` now matches prod on backups, PITR and retention. What is left is one
    command: `storage-auto-increase` on **`connect-prod`**, which was missed when the same flip
    was applied to the sandbox instance. No downtime, and it closes a failure mode — a full disk
    stops the instance — that nothing alerts on
17. Item 23 — the cutover checklist. The 19.3.4 cutover is done; this is now pre-work for the
    *next* upgrade, and it is four steps rather than the two this line used to name. The fourth
    was found live on 2026-08-19 with production undeployable, which is the argument for reading
    the item before the next cutover rather than during it

Items 2 and 3 are twenty minutes of clicking and they close the two largest holes: an
approval gate with nothing behind it, and a trunk anyone can push to. Item 15 is the one that
needs a conversation rather than a keyboard — specifically the database backup and the
migration window, now that the branch question itself is answered.
