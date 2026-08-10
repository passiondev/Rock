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

### 2. The `production` GitHub Environment does not exist

Without it, the `approve` job in `production-deploy.yml` **passes straight through**. The gate
is written and wired, but there is currently nothing on the other side of it. This is the
single highest-value 10-minute task on the list.

Needs:

- Environment `production`, with **required reviewers** (at least two people named, so a
  deploy never waits on one person's availability)
- Repo variables: `PRODUCTION_HOST_NAME`, `PRODUCTION_SITE_PATH`, `PRODUCTION_SITE_NAME`

The workflow falls back to `rock.passion.team`, `C:\inetpub\wwwroot` and `Default Web Site`
if the variables are absent — **confirm those against the actual VM before the first real
run** rather than trusting the defaults.

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

### 4. Certificate renewal works now, but it reports success when it does nothing

**This one is fixed.** Run `31416304281` succeeded on 2026-08-10 at 17:53 UTC and
`pr-4.rock-dev.connect.passion.team` now serves a genuine Let's Encrypt certificate —
issuer `CN=YR1`, issued 2026-08-10, valid to 2026-11-08. Verified against the live host, not
inferred from the run's exit code. The three earlier failures (`31370584850`, `30800092986`,
`30252661509`) were the terminated VM and the MSBuild path, both since fixed.

What is left is a reporting gap, and it is the reason this looked broken for so long:

- **`succeeded` does not mean a certificate was issued.** `Invoke-PrEnvironmentCertificateRenewal.ps1`
  returns early with a clean exit when it finds no manifests, and only throws when
  `$boundCount -eq 0` *after* it had work to do. A run over an empty VM is indistinguishable
  from a run that renewed everything. **Still unmitigated in practice.** Run `31416304281`
  (2026-08-10 17:53) reported `succeeded`, and its result JSON carried nothing but
  `commandId`, `prNumber`, `command`, `status`, `completedAtUtc` — no host names, no
  per-host outcome. It finished in 90 seconds, which is far too fast for win-acme to have
  self-hosted a challenge against even one host. So the run log does *not* currently name the
  hosts it touched, and a clean green run remains compatible with "issued nothing." Worth
  fixing by returning the touched-host list in the command result.
- **The scope is name-agnostic, which is worth knowing.** `Get-DeployedPrEnvironmentManifests`
  walks *every* `env.json` under `C:\RockTestEnvs` with `status = 'deployed'` — it does not
  filter on `pr-*`. `staging` is a `DedicatedSite` under that same root, so it is in scope
  automatically — *provided it has a manifest*. Measured 2026-08-10: `pr-4` serves a valid
  Let's Encrypt certificate (issued 16:57 UTC, expires 2026-11-08, verifies cleanly), so the
  renewal path itself works. `staging` was still untrusted, having never been picked up while
  its deploys were failing. **Re-run renewal once staging is healthy**, then verify by
  measuring rather than by reading the run's conclusion:
  `curl -v https://staging.rock-dev.connect.passion.team/ 2>&1 | grep -E "issuer|expire"`.

- **Workflow:** `.github/workflows/pr-test-renew-certificates.yml` (`schedule: 0 8 * * 1`)
- Note it temporarily opens an ACME HTTP-01 firewall path (tag `pr-test-acme-http`) — confirm
  it closes again on failure, not just on success.
- It stops `W3SVC` service-wide for the HTTP-01 challenge, so every site on the box goes down
  for the duration. Fine on the test VM; worth remembering before this pattern is copied to
  production.

### 5. The deploy health check accepts any TLS certificate

`Deployment/PrTestEnvironments/Deploy-RockEnvironment.ps1:353` sets
`[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }` before polling
the site.

This is deliberate and correct today — it stops item 4 from failing every deploy — but the
consequence is that **CI can never tell us a certificate is broken.** A deploy is green
whether the cert is valid, expired, or self-signed.

Once renewal is green, split this into a separate non-blocking check that reports days to
expiry in the run summary.

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

The fix is a catalog per environment. It needs a decision from Justin first, because it means
a new repo variable (`STAGING_DB_NAME`, say) and a real database to point it at:

- Sandbox refresh restores prod into one catalog today; per-environment catalogs need either
  N restores or a template-plus-copy step.
- Cheapest useful half-step: give `staging` its own catalog and leave the `pr-*` sites sharing
  one. Staging is the one that must be trustworthy during a demo.

### 8. `build-develop.yml` still deploys by rebooting a VM

**Fixed 2026-08-10 — deleted from `passion-18.4.1`.** Details in the Fixed table below. The
build-only copy on `develop` is a different file and was left alone.

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

- `develop` is **489 commits ahead of upstream tag `18.4.1`** and tracks all **276** files
  under `RockWeb/Plugins/`. It is not a mirror of anything; it is where Passion's plugin work
  lives. It is also the branch the last production build came from — run on 2026-05-06 from
  `dd6d189b`, which is `origin/develop` HEAD today.
- `staging` is 73 commits ahead of `develop` and holds **five plugin files that are newer than
  `develop`'s copies** — `org_passion/RSVP/RsvpDetailBETA.ascx`,
  `org_passion/RSVP/RsvpResponse.ascx.cs`, `org_passion/RSVP/RsvpResponseBETA.ascx.cs` (all
  2026-02-24 vs. develop's 2026-01-09), plus `org_secc/Authentication/Arena.cs` and
  `org.secc.Authentication.csproj` (2026-01-28 vs. 2026-01-09). Two of its commits
  (`fix datetime issue in plugin`, `Optimizations`) exist nowhere else.

Neither branch can be pruned until item 15 is settled, because between them they are the only
copy of some of this code.

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

### 15. Nothing establishes which branch production is supposed to deploy from

**Priority: P0 despite the number** — this list is append-only so the numbers stay stable
across revisions and the cross-references above keep working. This is the largest unresolved
question in the repository and it should be settled before the first real production deploy.

`production-deploy.yml` defaults its `ref` input to `passion-18.4.1`. That is a defensible
default — it is the trunk, it matches the version production runs, and it is the branch this
pipeline was built on. But it is a default that was chosen for pipeline reasons, and nobody has
confirmed it is the right *source* for production. The measured situation:

| Branch | Ahead of upstream `18.4.1` | Files under `RockWeb/Plugins/` | Last commit |
| --- | --- | --- | --- |
| `passion-18.4.1` (trunk) | 20 commits | **2** | 2026-08-10 |
| `develop` | 489 commits | **276** | 2026-05-06 |
| `staging` | 72 commits | **276** | 2026-02-24 |

The last production build ran on **2026-05-06 from `develop`** (`dd6d189b`), and the copy of
`build-develop.yml` on `develop` is build-only — it produces a downloadable artifact and stops.
So production has been updated by hand from that artifact, which is consistent with the
production `bin` being a mixed-version assembly set rather than the output of any single build.

Two things follow, and they are independent:

1. **Production is not at risk of losing its plugins.** The `InPlace` deploy path uses
   `robocopy /E` with no `/MIR` and no `/PURGE` (`Deploy-RockEnvironment.ps1:647-659`), so
   files present on the server and absent from the artifact are left untouched. A trunk-based
   deploy overwrites core Rock files and leaves `RockWeb\Plugins\` alone. Verified by reading
   the script, not by deploying.
2. **But a trunk-based deploy is still a version change, not a no-op.** Trunk is the 18.4.1
   release line plus this pipeline; `develop` carries 489 commits of drift, some upstream and
   some Passion's. Whether replacing production's core assemblies with trunk's is an upgrade,
   a downgrade, or a mix cannot be determined from the repository — it needs the assembly
   versions actually on the production box.

**What to do, in order:** read the assembly versions off `connect-srv-prod` and compare them
against what trunk builds; decide whether trunk, `develop`, or a reconciliation of the two is
production's source of truth; then reconcile the plugin files (item 14) so one branch holds all
of it. Until that is done, the production workflow is proven mechanically — it builds, gates,
backs up, copies, and health-checks — but the question of *what* it should be shipping is open.

This is why the production path is deliberately unfired. The gate is not the only thing
standing between this pipeline and production; this item is.

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

The `startup_failure` one is worth remembering specifically: a called workflow can only
**narrow** the caller's `GITHUB_TOKEN`, never widen it. If a callee's `permissions:` requests
a scope the caller didn't grant, GitHub kills the entire run before any job starts. There are
no logs to read and `actionlint` does not catch it. Same class of trap: the `inputs` context
does not exist on a `push` event — use `github.event.inputs`, which is simply `null` there.

---

## Suggested order

1. Item 2 — create the `production` Environment (~10 min, unblocks the gate)
2. Item 3 — protect `passion-18.4.1` (~10 min, makes the training true)
3. Item 15 — establish what production should deploy *from*, starting by reading the assembly
   versions off `connect-srv-prod`. This gates the first real production deploy, and it is a
   decision rather than a task
4. Item 7 — decide the staging database question (a decision, then a restore)
5. Item 1 — install the production agent, together (~1 hour, needs a VM stop/start window)
6. Item 4 — re-run renewal once staging is healthy, then leave the schedule to it
7. Item 14 — decide whether test sites should render plugin pages (a config line, then a
   decision about version control that is bigger than this pipeline), and reconcile it with
   item 15 — they are the same reconciliation seen from two ends
8. Items 9–13 — cleanup, any time. Note item 9's warning: `develop` and `staging` are **not**
   safe to prune yet
9. Items 5 and 6 — the two "CI can't see this" gaps, once the above is stable

Items 2 and 3 are twenty minutes of clicking and they close the two largest holes: an
approval gate with nothing behind it, and a trunk anyone can push to. Item 15 is the one that
needs a conversation rather than a keyboard.
