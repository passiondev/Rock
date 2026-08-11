# Rock CI/CD — open items for DevOps

**Audience:** DevOps engineer + Global Engineering. Not part of the training handout.
**As of:** 2026-08-10 · **Repo:** `passiondev/Rock` (public) · **Trunk:** `passion-18.4.1`

The pull-request path is working and proven end to end. This is the list of what is *not*
done, ordered by what it blocks. Most of these were found by auditing the pipeline this week;
the last section records what has already been fixed so nobody re-diagnoses it.

Read item 7 first if you only read one. It is the shared dependency underneath every
"isolated" test site, and it is the most likely cause of two sites failing at once.

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

`passion-18.4.1` is the default branch, it is what production runs, and **merging into it
auto-deploys staging**. It currently has `protected: false` and the repo has **0 rulesets**.
Anyone with write access can push directly to it — no PR, no review, no build check.

The training we're delivering tells people "open a PR and get a review." Nothing enforces
that today. Recommended ruleset on `passion-18.4.1`:

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

### 6. Nothing reaps abandoned environments

Closing a PR **stops** its environment but never destroys it. An environment on a long-lived
open PR runs indefinitely. The only scheduled workflow in the repo is certificate renewal —
there is no idle timeout and no sweep. Left alone this grows the test VM's disk until it
fills.

Wants a scheduled job that stops environments idle past a threshold and destroys ones whose
PR closed more than a week ago.

> Note: earlier revisions of the training doc claimed a 6-hour idle stop and a 7-day destroy
> already existed. **They never did.** Both claims have been corrected in the handout.

### 7. Staging and every PR environment share one database catalog

`env-deploy-command.yml:94` and `pr-test-deploy.yml:182` build their connection strings from
the same four secrets — `PR_TEST_DB_DATA_SOURCE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` — and
neither deploy script derives a per-environment catalog. So `staging` and `pr-4` and every
future `pr-*` all point at one catalog on the shared test Cloud SQL instance.

That is one shared mutable dependency behind every isolated-looking test site. Rock runs EF
and plugin migrations at `Application_Start`, writes global attributes such as
`PublicApplicationRoot` into the database, and holds a migration lock there. Two sites of
different versions against one catalog is a genuine way to break both at once, and a Rock
instance that fails during `Application_Start` serves the same generic ASP.NET error page on
every path — including static files — which is a confusing thing to debug.

**This stopped being hypothetical on 2026-08-11.** `pr-3` now serves an ASP.NET **"Runtime
Error"** page — HTTP 500 — on every request, and keeps doing so across app pool recycles
(measured 500 in 29.3s, then 500 in 71.1s after a recycle). `pr-4` and `staging` on newer
commits answer 302 from the same box at the same moment, so IIS, the binding and the
certificate are all fine; what differs is which build's expectations the one shared schema
currently matches. Meanwhile GitHub still shows PR #3 labelled **`rock-test:deployed`**,
because the PR deploy path never checks (item 5a) — the two defects compound exactly as
written, and the result is a broken environment that the pipeline reports as good.

**The version split is now measured, not inferred.** `Rock.Version/AssemblySharedInfo.cs` —
the same file `production-deploy.yml`'s version guard reads — declares:

| Ref | Rock version |
| --- | --- |
| `passion-18.4.1` (trunk, staging) | **18.4.1** |
| `demo/ptp-cicd-training-walkthrough` (PR #4) | **18.4.1** |
| `pilot/pr-test-env-doc-smoke-v1761` (PR #3) | **17.6.1** |
| `develop` | 19.0.3 |

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
`AssemblySharedInfo.cs` minor differs from the default branch's — the same comparison
`production-deploy.yml` already makes, pointed at PR environments. That converts this from a
silent mutual corruption into a refused deploy with a clear reason.

The fix is a catalog per environment. It needs a decision from Justin first, because it means
a new repo variable (`STAGING_DB_NAME`, say) and a real database to point it at:

- Sandbox refresh restores prod into one catalog today; per-environment catalogs need either
  N restores or a template-plus-copy step.
- Cheapest useful half-step: give `staging` its own catalog and leave the `pr-*` sites sharing
  one. Staging is the one that must be trustworthy during a demo.

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

---

## P2 — hygiene

### 9. Stale branches — but two of them are not safe to delete

`develop-17.6.1`, `deploy/ptp-14803-18.4.1`, `bump`, `fix/group-sync`, and
`pilot/pr-test-env-doc-smoke-v1761` are superseded by `passion-18.4.1`. Pruning them removes
several ways to target the wrong base branch. Confirm `fix/group-sync` is genuinely abandoned
before deleting; the rest are safe.

**Do not delete `develop` or `staging`.** An earlier revision of this list called `develop` a
"pristine upstream mirror" and put `staging` in the safe-to-prune set. Both were wrong, and
measurably so:

- `develop` declares **Rock 19.0.3** — it is the v19 line, not a mirror and not an ancestor of
  the trunk (the two diverged 2026-01-07). It tracks all **276** files under
  `RockWeb/Plugins/`, 78 of them `org_passion`/`team_passion`. It is simultaneously where
  Passion's plugin work lives *and* the only in-repo starting point for the eventual v19
  upgrade. It is also the branch the last production build came from — 2026-05-06 from
  `dd6d189b`, which is `origin/develop` HEAD today. See item 15 for why that build must never
  be installed on production.
- `staging` declares **Rock 17.6.1** and is 73 commits ahead of `develop`, holding **five
  plugin files newer than `develop`'s copies** — `org_passion/RSVP/RsvpDetailBETA.ascx`,
  `org_passion/RSVP/RsvpResponse.ascx.cs`, `org_passion/RSVP/RsvpResponseBETA.ascx.cs` (all
  2026-02-24 vs. develop's 2026-01-09), plus `org_secc/Authentication/Arena.cs` and
  `org.secc.Authentication.csproj` (2026-01-28 vs. 2026-01-09). Two of its commits
  (`fix datetime issue in plugin`, `Optimizations`) exist nowhere else.

Neither branch can be pruned until the plugin files are reconciled onto the trunk (item 14),
because between them they are the only copy of some of this code. The branch names are also
misleading enough to be worth renaming once that is done: `develop` is a v19 branch and
`staging` is a v17 branch, and neither name says so.

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

### 12. The pilot doc is stale

`Documentation/Discussion Docs/PR-Test-Environments-Issues/12-pilot-rollout.md` still says
deployment fails at an SSH step. That was replaced by the Cloud Storage command queue.

### 13. The test VM sends nothing to Cloud Logging

The production VM ships Windows event logs to Cloud Logging; the test VM does not — the Ops
Agent is installed per VM and was never installed there. So when a test site fell over on
2026-08-10 there was no server-side log to read from outside the box at all.

Largely worked around: a deploy whose health check fails now uploads its own diagnostic
report — IIS state, deployed assembly versions, the last hour of ASP.NET and .NET Runtime
events, the tail of `App_Data\Logs`, and the response body — to
`gs://<bucket>/pr-environments/diagnostics/<environment>/`. Installing the agent would still
be better for anything that isn't a deploy.

### 14. Plugin blocks are outside version control, so no test environment has them

**Priority: P1 despite the number** — this list is append-only so the numbers stay stable
across revisions and the cross-references above keep working.

`RockWeb/Plugins/.gitignore` is a single rule, `*/*`, so every plugin subfolder is ignored.
That is upstream Rock's convention — plugins are installed packages, not source. The
consequence for *us* is that Passion's own customizations are not in this repository:
measured 2026-08-10, git tracks two files under `RockWeb/Plugins/` (`.gitignore`,
`readme.txt`) and **zero** paths matching `org_passion` or `team_passion`, against 448 tracked
core blocks under `RockWeb/Blocks/`.

So:

- No `pr-*` site or `staging` renders a plugin block. `DedicatedSite` replaces the site
  directory with the artifact, and the artifact has no plugins; the shared-asset overlay
  backfills only `Themes`, `Content`, `Assets`, `Styles`.
- A plugin-block change cannot go through this pipeline at all — there is no tracked file to
  commit. Today that work is manual and server-side.
- Production is not at risk. `InPlace` copies with robocopy `/E` and no `/PURGE`, so plugin
  folders already on the box survive an artifact that lacks them. Worth stating explicitly,
  because the opposite would have been catastrophic and it is one line of script away.

Two things worth deciding, and they are independent:

1. **Should test environments render plugin pages?** Cheap if yes — `Sync-SharedSiteAssets`
   takes its directory list from `PR_TEST_SHARED_ASSET_DIRECTORIES`, so adding `Plugins`
   backfills them from the default site with no script change. The copy is
   only-if-absent, so it cannot clobber a branch.
2. **Should Passion's plugins be version-controlled at all?** A larger question, and a real
   trade-off against upstream's convention and against this repo being public. Not something
   to decide in a training session, but the team should know it is currently *unanswered*
   rather than *answered no*.

---

### 15. Which branch production deploys from — settled, plus the migration it implies

**Priority: P0 despite the number** — this list is append-only so the numbers stay stable across
revisions and the cross-references above keep working. Opened as "nothing establishes which
branch production deploys from." Measured and answered on 2026-08-10; what remains is one
migration step that has to be taken deliberately, and one guard to add to the workflow.

`production-deploy.yml` defaults its `ref` input to `passion-18.4.1`. Nothing in the repository
stated *why* that is the right source, so it was measured. **The default is correct**, and the
reason is worth writing down, because the obvious alternative is actively dangerous.

Each branch declares its own Rock version in `Rock.Version/AssemblySharedInfo.cs`. They are not
three points on one line — they are three different Rock majors:

| Branch | Declares | Descends from upstream tag `18.4.1`? | Commits the tag has that it lacks | Files under `RockWeb/Plugins/` |
| --- | --- | --- | --- | --- |
| `passion-18.4.1` (trunk) | **18.4.1** | yes | 0 | 2 |
| `develop` | **19.0.3** | no — diverged 2026-01-07 | 218 | 276 |
| `staging` | **17.6.1** | no | 2,238 | 276 |

Production's own `bin`, inventoried 2026-07-30, is a patchwork within the 18.x line: 17
assemblies at 18.1.0, 8 at 18.3.1, and 3 at 18.4.1 (`Rock.dll`, `Rock.Blocks.dll`,
`Rock.Version.dll`, hot-swapped 2026-07-20). Nothing on the box is 19.x. So:

1. **Production is 18.4.1 at the core and behind it everywhere else.** `Rock.dll` and
   `Rock.Version.dll` are 18.4.1, which is why Rock's own about-page reports 18.4 — but most of
   the site is still 18.1.0/18.3.1. A trunk deploy builds every assembly at 18.4.1, so it
   brings the stragglers *forward*. That is the reconciliation production needs, not a risk to
   avoid.
2. **`develop` must never be deployed to production.** It is the 19.0 line. A v19 artifact on
   production is a major-version jump whose migrations run at startup and cannot be walked
   back. The last production *build* ran 2026-05-06 from `develop` (`dd6d189b`) — and the
   absence of any 19.x assembly on the box is the evidence that artifact was never actually
   installed. That was luck, not a control. `production-deploy.yml` should reject any ref that
   is not the trunk.
3. **Production cannot lose its plugins.** The `InPlace` path uses `robocopy /E` with no `/MIR`
   and no `/PURGE` (`Deploy-RockEnvironment.ps1:647-659`), so server-only files survive. Trunk
   carries 2 plugin files and production carries hundreds; the deploy leaves them alone.
   Verified by reading the script, not by deploying.

**The one real risk, and it is specific:** `Rock.Migrations.dll` on production is **18.3.1**,
and trunk builds it at **18.4.1**. Rock runs pending migrations on first startup, so the first
trunk deploy will apply the 18.3.1 → 18.4.1 migrations against the production database. That is
a normal patch-level upgrade, but it is a one-way door. It needs a verified database backup
taken immediately before, and it should be the *only* change in that deploy.

**What to do, in order:** re-confirm the assembly inventory on `connect-srv-prod` (the numbers
above are from 2026-07-30 and predate any 18.4.1 work since); take and *verify* a database
backup; deploy the trunk to production during a window, with DevOps present; then reconcile the
plugin files (item 14) so one branch holds all of it. Add the ref guard from point 2 before the
first real run.

This is why the production path is deliberately unfired — not because the source branch was
unknown, but because the migration step above has to happen deliberately and with a backup.

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
| `build-develop.yml` was a second, worse production deploy path: it set a `windows-startup-script-ps1` on the production VM, then stopped and started the VM to run it. The script copied the package over `C:\inetpub\wwwroot\` — not the site path this pipeline uses — and mixed cmd.exe syntax (`%errorlevel%`, `2>nul`, `if (…) (…) else (…)`) into PowerShell. It was gated on `branches: [staging]`, dormant since 2026-02-24, and one push away from firing | Deleted from `passion-18.4.1`; `production-deploy.yml` supersedes it. The separate build-only copy on `develop` was left alone |
| The `DedicatedSite` deploy path deleted the site directory wholesale and never consulted `$PreservedFiles` — only the `InPlace` path did. A deploy that supplied no connection string therefore destroyed `web.ConnectionStrings.config`, and since `web.config` binds it through a `configSource`, the site 500'd on every request including its own error page | Preserved files are stashed and restored across the replace, and `Write-RuntimeConfiguration` now throws when no connection string was supplied *and* none exists, instead of reporting that it is "leaving the existing" file in place |
| A syntax error in a deployment script surfaced as a scheduled task dying quietly on the VM | The bootstrap workflow parses every `Deployment/PrTestEnvironments/*.ps1` before uploading any of them |
| The one failure in the other direction: the staging deploy reported "did not become healthy within 300 seconds" three times over while the site was serving Rock normally minutes later. ASP.NET caches an `Application_Start` failure for the lifetime of the app domain, so once one probe lands on a faulted domain, every later probe re-reads that same cached exception — retrying alone can never recover. 300 seconds also fits only about four probes at `-TimeoutSec 60` plus a 10-second sleep, which is not enough to distinguish "still running migrations" from "broken" | The window is 900 seconds (still under the queue agent's 1800s command timeout and the deploy job's 60 minutes), the probe recycles the app pool after 4 minutes of failures so a poisoned domain costs one interval instead of the whole window, each attempt logs its own error, and `SecurityProtocol` is pinned to TLS 1.2 so a protocol mismatch cannot masquerade as a dead site |
| …and the widened window still could not pass, because the probe was aimed somewhere the VM cannot reach. `Test-EnvironmentHealth` requested the environment's **public** host name from **on the VM**, and this VM cannot reliably reach its own external address. `staging-deploy.yml` had therefore never once succeeded — 0 green in 8 runs — on deploys that were serving fine. The deploy's own diagnostics caught both sides at the same instant: on-box, `https://staging.rock-dev.connect.passion.team/` → *"The underlying connection was closed: An unexpected error occurred on a send"*; off-box, the same URL → **HTTP 302 in 0.115s**. Production CD would have hit this identically on its first real run, since both go through `env-deploy-command.yml` | The probe targets `https://127.0.0.1/` with the public name in the `Host` header — same IIS site, same app pool, same app domain, so it still answers the only question a deploy can be blamed for, without DNS or the route back in. That needs `HttpWebRequest` (`Invoke-WebRequest` refuses to set the restricted `Host` header) and `AllowAutoRedirect = $false` (Rock's 302 carries an absolute `Location`, and following it would leave the loopback for the very name being avoided). Reachability from the internet is now checked from the **GitHub runner**, which can see it. Diagnostics record both vantage points, labelled — loopback failing means the application is broken; loopback passing while the public name fails means the application is fine and the problem sits in front of it |

The `startup_failure` one is worth remembering specifically: a called workflow can only
**narrow** the caller's `GITHUB_TOKEN`, never widen it. If a callee's `permissions:` requests
a scope the caller didn't grant, GitHub kills the entire run before any job starts. There are
no logs to read and `actionlint` does not catch it. Same class of trap: the `inputs` context
does not exist on a `push` event — use `github.event.inputs`, which is simply `null` there.

---

## Suggested order

1. Item 2 — the Environment now exists and the gate is real (verified against the API on
   2026-08-11: one required reviewer, `can_admins_bypass: false`). What's left is adding the
   DevOps engineer as a second reviewer and then flipping `prevent_self_review` to `true`
   (~5 min, and only then is production two-person)
2. Item 3 — protect `passion-18.4.1` (~10 min, makes the training true)
3. Item 15 — the source branch is settled (the trunk). What's left: add the ref guard so
   `develop` can never be deployed, re-confirm production's assembly inventory, and plan the
   18.3.1 → 18.4.1 migration with a verified backup. This gates the first real production deploy
4. Item 7 — decide the staging database question (a decision, then a restore)
5. Item 1 — install the production agent, together (~1 hour, needs a VM stop/start window)
6. Item 4 — re-run renewal once staging is healthy, then leave the schedule to it
7. Item 14 — decide whether test sites should render plugin pages (a config line, then a
   decision about version control that is bigger than this pipeline), and reconcile it with
   item 15 — they are the same reconciliation seen from two ends
8. Item 17 — move the database password out of the command JSON and into Secret Manager. Do it
   in the same pass as item 7; both are about how an environment gets its database, and
   rotating the password before this change just re-exposes the new one
9. Items 9–13 — cleanup, any time. Note item 9's warning: `develop` and `staging` are **not**
   safe to prune yet
10. Items 5, 6 and 18 — the "CI can't see this" gaps, once the above is stable. Item 18's guard
    and item 16's are the same GCS list written twice; build them together

Items 2 and 3 are twenty minutes of clicking and they close the two largest holes: an
approval gate with nothing behind it, and a trunk anyone can push to. Item 15 is the one that
needs a conversation rather than a keyboard — specifically the database backup and the
migration window, now that the branch question itself is answered.
