# Production Upgrade Runbook

**Last verified:** 2026-09-14 · **Audience:** whoever is running the production cutover.
Nothing on the production host has been executed. It is the checklist for the upgrade,
written while the machinery for it was built.

**The target moved to 19.4.4 on 2026-09-14.** Production had not been deployed yet, so
there was no reason to ship 19.3.4 and upgrade again a week later; `passion-19.4.4` is the
branch this runbook now describes. What that changed, and what it did not, is in
*The 19.4.4 move* below -- the short version is that every measurement this runbook rests on
still holds, because `RockWeb/web.config` is byte-identical across 19.3.4, 19.4.4 and the
fork, and the fork's eight Rock-source edits survived the bump unchanged.

**Steps 1 and 2 are done.** The pipeline changes merged to the default branch on
2026-08-25, so **Production Bootstrap Command Queue** is dispatchable. `productionBranch`
reads `passion-19.4.4` as of 2026-09-14, and the `production` environment allows
`passion-19.4.4`, `passion-19.3.4` and `passion-18.4.1` -- the old two are kept allowed
deliberately, per step 2. **The irreversible step has therefore been taken**: production is
deployable only from the 19.4 line until that commit is reverted. Everything from step 3 on
is outstanding, and step 4 is the one that takes production down.

Re-read live against GCP on 2026-09-14. `connect-srv-prod` is `RUNNING` in `us-east1-d`,
still carries the `devstorage.read_only` scope alongside `logging.write` and
`monitoring.write`, and still has **no** `windows-startup-script-ps1` -- its only metadata
keys are `enable-osconfig`, `enable-windows-ssh` and `serial-port-enable`. So the bootstrap
has not been run and production still cannot be deployed. `scheduling.automaticRestart` is
now **`true`**; it was `false` when this runbook was written, and the warning that used to
stand here has been rewritten rather than deleted, because what it protected against has
changed shape rather than gone away. `connect-prod` is a 418 GB disk with
`storageAutoResize: false`, nightly backups at 01:00 UTC, point-in-time recovery on with 7
days of transaction logs, the last four backups `SUCCESSFUL`, and exactly one user database.
The rollback section's database-name warning did **not** hold and has been rewritten. The PR
test fleet and staging are a different document
(`PR-Test-Environments-Operator-Runbook.md`); the trunk cutover described there has already
happened, and this is the second half of it.

The trunk and `productionBranch` are both `passion-19.4.4` as of 2026-09-14, and production
is still serving the 18.x line -- the pins have caught up with each other, the code has not
moved at all. Production's jump is 18.4.1 -> 19.4.4 in one step: 19.3.4 was proven on staging
and superseded before its own cutover, so it never ran in production and is not a version
this deploy passes through.
Read the values rather than trusting that sentence: `.github/pr-test-environments.json` on
the default branch is the source for both. The two disagreeing is the normal state during an
upgrade and `test_base_branch_config.py` asserts both separately; see the comment above
`EXPECTED_PRODUCTION_BRANCH` for why they are allowed to.

## The 19.4.4 move

Built 2026-09-14 on `passion-19.4.4`. Upstream's `hotfix-19.4` head and the `19.4.4` release
tag are the same tree (`ce30e83d54`), so the branch carries the release and not a moving
target.

This working copy is a shallow clone, so `git merge` against upstream is not usable here --
the merge base resolves to a 2026-07-09 graft commit and the merge replays 18.4 through 19.4,
inventing rename conflicts. The branch was built by applying upstream's 19.3.4 -> 19.4.4 delta
as a patch and then verifying the *result* against the `19.4.4` tree. Compare trees, not
history, on this clone.

**What was measured, and what it means for the rest of this runbook:**

| Question | Answer | Consequence |
|---|---|---|
| `RockWeb/web.config` | byte-identical on 19.3.4, 19.4.4 and the fork (`8fce955535b0b810`) | every number in *What has to be true* below still holds; the merge function needs no change |
| Fork-local Rock-source edits | the same **8** files, derived against 19.4.4 | nothing was resolved towards upstream; the icon migration fix that unblocked v19 survives |
| New EF migrations | **0** | the catalog work is what 19.3.4 already implied, not more |
| New plugin hotfixes | 308 `AddConnectedServices`, 309 `EnableRockIntelligence`, 314 `FixEventItemAttributeCorruption6962` | run at `Application_Start` with the rest; see step 8 |
| Upstream delta | 384 files, 34,404 insertions | large, but confined to files the fork does not touch -- zero overlap with the fork's own set |
| Test suites | 618 Python, 266 Pester, all green on this branch | the same counts as 19.3.4; no suite was weakened to get there |
| Cutover report | `upgrade_diff.py cutover origin/passion-18.4.1 origin/passion-19.4.4` is byte-identical to the 19.3.4 report except its header line -- 14 findings, the same 14 | 19.4 adds nothing to production's cutover surface; every finding already reviewed for 19.3.4 carries over unchanged and there are no new ones |
| Artifact build | green in CI on this branch (run 34905832824), from the same reusable workflow production deploys from | the one open risk the bump raised is closed; see the `Rock.AI.Agent` note below |

**`Rock.AI.Agent` is new in 19.4 and it does reach the artifact.** It was worth checking
because nothing in `RockWeb` references the assembly and hotfix 309 registers six
`Rock.AI.Agent.*` types plus an "AI Chat" page. The answer is that `pr-test-artifact.yml` --
which is what production builds from -- does not use a fixed project list. It globs
`Rock.*\*.csproj` and builds everything outside six exclusion patterns, and the project sets
`<CopyToRockWeb>True</CopyToRockWeb>` like every other shipped assembly, so `Directory.Build.targets`
copies it and its dependency tree into `RockWeb\Bin`. (`ptp-14803-build-artifact.yml` *does*
carry a hardcoded seven-project list, but that workflow is a targeted patch build and no
deploy uses it. Do not read it as the artifact recipe.)

The residual risk that left was a build risk, not a runtime one: `Rock.AI.Agent` pulls
`Microsoft.SemanticKernel` 1.67.1 into a `net472` project, and only `*Tests*` projects are
advisory in that sweep. If the dependency tree did not resolve on the runner, the artifact
build would fail loudly in CI -- which is the right place for it to fail, and is what pushing
this branch to staging answered.

**Answered on 2026-09-14: it builds.** Run 34905832824 on `passion-19.4.4` took
`Build Rock Projects (Dependency Order)`, `Ensure Assemblies in RockWeb Bin`,
`Verify Build Artifacts` and `Package RockWeb zip and metadata` green, from the same
`pr-test-artifact.yml` reusable workflow production deploys from. That closes the only open
question the 19.3.4 -> 19.4.4 bump raised. It says nothing about the migrations, which run at
`Application_Start` after the deploy and are proven by loading the site, not by a green run.

## What has to be true before any of this starts

**Production cannot be deployed at all today, and it fails silently.** `production-deploy.yml`
queues its command to `commands-prod` and then polls a GCS prefix for a result object.
No host has ever read that queue. `connect-srv-prod` has no `windows-startup-script-ps1`
and no scheduled task, so the deploy queues work nothing picks up and waits for an answer
nothing writes, until it times out. A green *dry run* proves only that the guards passed;
it never reaches the VM.

`.github/workflows/production-bootstrap-command-queue.yml` is what installs the missing
agent. It has to run, and be verified, before the upgrade is attempted.

**Production restarts once, and it is not avoidable.** Two independent reasons, either of
which alone forces it:

- The queue agent writes results, logs and diagnostics to GCS. `connect-srv-prod` runs with
  `devstorage.read_only`. Scopes are a hard cap above IAM -- no role grant gets past one --
  and Compute Engine only accepts a scope change while the instance is **stopped**.
- A `windows-startup-script-ps1` runs at boot and at no other time. Adding the metadata to a
  running instance stages it; it installs nothing until the next start.

So the bootstrap has two halves and a `restart_vm` checkbox between them. Left unticked it
publishes the scripts and stages the metadata, which changes nothing that is running and can
be done in the open. Ticked, it stops the instance, widens the scope, and starts it again.
Pick the window for the second half deliberately.

**`scheduling.automaticRestart` is now `true`, and it does not cover this step.** It was
`false` -- an AWS lift-and-shift leftover -- and was changed on production deliberately.
Read what it actually does before relying on it here: it brings the instance back after a
host failure or a maintenance event, meaning a crash. It does **not** restart an instance
that was stopped on purpose, which is exactly what step 4 does. A deliberate `gcloud compute
instances stop` stays stopped until something starts it.

So the hazard is unchanged for the one step that matters. The restart step retries the start
six times and fails loudly if the instance is still down, but nothing behind it will try
again. If that step throws, someone starts the instance by hand -- production is off until
they do. What `automaticRestart: true` buys is everything *after* the cutover: an unplanned
host event no longer leaves production off until a human notices.

**The scope change is a union, not a replacement.**
`gcloud compute instances set-service-account --scopes=` overwrites the whole list, and
production's list carries `logging.write` and `monitoring.write` that the Ops Agent needs.
The workflow reads the current scopes, drops `devstorage.read_only`, adds
`devstorage.read_write`, and dedupes. It does not grant `cloud-platform`, which is what
staging runs on and is more than these scripts need: they reach `storage.googleapis.com`
and the metadata server, and nothing else.

**Production's `web.config` is not the artifact's, and four values in it cannot survive a
straight copy.** The deploy copies the site in place with `robocopy /E`, which does not
exclude `web.config`. Measured against the live box on 2026-09-14, every one of these
differs between production's file and the one in the v19 artifact -- compared by hash, never
printed:

| Value | What it does | What replacing it costs |
|---|---|---|
| `PasswordKey` | hashes database-authenticated passwords (`Rock/Security/Authentication/Database.cs`) | **every staff login fails** -- a total lockout, with no error that names the cause |
| `DataEncryptionKey` | decrypts encrypted attribute values (`Rock/Security/Encryption.cs`) | encrypted attributes and stored gateway credentials stop decrypting |
| `machineKey` | signs sessions and ViewState | every session drops; ViewState MAC failures on any open page |
| `RunJobsInIISContext` | `True` on production, `False` in the artifact | **every scheduled job silently stops** -- nothing errors, they just never run |

Two more differ and are benign, confirmed rather than assumed. `OrgTimeZone` is
`Eastern Standard Time` on the box against `Local` in the artifact, and the VM's own time
zone *is* Eastern (`tzutil /g`), so the two agree. `EnableBundling` and
`RedisConnectionString` exist only on the server and are referenced nowhere in 19.3.4.

Production also registers a control prefix the artifact does not:
`<add tagPrefix="Passion" ...>`. Three live `.ascx` pages under
`Plugins\passion\crm\` depend on it, and because ASP.NET compiles `CodeFile=` pages on
first request, losing it does not fail the deploy or the health check. It yellow-screens
for whoever visits one of those pages first.

**The file can be neither preserved nor copied, which is why this is a merge.** Preserving
production's file breaks v19: 19.3.4 changes 376 lines against 18.4.1, nearly all of them
mandatory `bindingRedirect` bumps plus nine new assembly references, and without them v19
cannot load its own assemblies. Copying the artifact's file breaks the box, as above.
Production's `web.config` is hand-maintained on the server and matches no branch in this
repository -- it differs from the 18.4.1 file by 530 lines.

`Merge-ServerOwnedWebConfigSettings` in `Deploy-RockEnvironment.ps1` is what resolves this.
It reads the site's own `web.config` **before** the copy overwrites it, then carries exactly
the named values forward into the artifact's file: the four above, any `OldPasswordKey*`
rotation entries (matched by prefix, because the count is a property of the install), the
`machineKey` element whole, and any control registration the artifact has no entry for. The
artifact wins everything else, which is what keeps the assembly bindings intact. Anything on
the server that it did not carry is reported as a warning rather than dropped in silence.

This is the same idea as `$PreservedDirectories` and the server-owned theme files, one level
further in: the file belongs to the artifact, a handful of values inside it belong to the
box. `Tests/PrTestEnvironments/Pester/ServerOwnedWebConfigSettings.Tests.ps1` covers it,
including against the real shipped `RockWeb/web.config`.

**Staging cannot rehearse any of this.** Staging deploys with `mode: DedicatedSite`, which
deletes the site directory and moves the extracted artifact into its place -- so staging
runs the artifact's stock `web.config` and has never exercised production's keys. A
successful staging login proves nothing about production's `PasswordKey`. Step 6's dry run
is the only check that runs against the real file, and it runs against the real box.

## The ordering is forced, and not by choice

Three guards each read a different ref, and together they leave exactly one order.

1. `production-deploy.yml` refuses any ref that is not on `productionBranch`, and refuses any
   ref whose Rock version differs from the version `productionBranch` declares. There is no
   override for the branch half.
2. The bootstrap's `validate` job refuses any ref that is not **exactly** `productionBranch`.
   It hands `connect-srv-prod` scripts that run as SYSTEM, once a minute, forever. A ref that
   cannot be deployed to production must not be allowed to write production's scripts either.
3. `workflow_dispatch` only lists a workflow that exists on the **default branch**, and the
   bootstrap's own guard only accepts `productionBranch`. While those two branches differ,
   the workflow file has to exist on both.

Point 3 is the one that bites. Repointing `productionBranch` to the trunk first collapses it:
one branch satisfies both conditions, and the file only has to land once.

**Repointing `productionBranch` is the cutover.** It is a reviewed pull request against
`.github/pr-test-environments.json` on the default branch, changing one string. Nothing else
in this runbook is irreversible in the same way, and nothing else announces itself as the
moment of no return, so treat that PR as the decision.

Two consequences to accept before opening it:

- **An 18.4.1 hotfix cannot be deployed once it lands.** The branch guard refuses a ref that
  is not on `productionBranch`, so between the repoint and a successful v19 deploy, production
  is deployable only from the new line. Reverting the PR restores it, which is the escape
  hatch, but it is a PR and a review, not a checkbox.
- **The version guard is now quiet.** Moving `productionBranch` moved the expected version
  with it, so a deploy from `passion-19.4.4` matches the pin and will not ask for
  `acknowledge_version_change`. Before step 2 landed the opposite was true and usefully so: a
  `passion-19.4.4` ref against a `passion-19.3.4` pin was a version change and the guard
  stopped and demanded the acknowledgement. **The deliberate act that guard exists to force
  is now the step 2 commit itself**, which is reviewed and in the history -- not a checkbox
  ticked at dispatch time. Do not read a quiet guard as "no version change is happening":
  production is still on 18.x and this deploy is still a two-minor jump. The workflow says so in its own comments and points here for
  the backup requirement. **The backup is this runbook's job, not the guard's.** Step 5 below
  is the whole of that control.

## Order of operations

Each step says what proves it worked. A step with no evidence behind it has not been done.

1. **Land the pipeline changes on the default branch. — DONE.** The bootstrap workflow, the
   `-BootstrapPrefix` parameter on the agent and its installer, and the deploy script's
   progress logging. Confirm with `gh workflow list -R passiondev/Rock` that
   **Production Bootstrap Command Queue** appears.

2. **Repoint `productionBranch`. — DONE.** Verified 2026-09-14: `productionBranch` reads
   `passion-19.4.4`, so the irreversible move onto the 19.4 line has been made and cannot be
   undone except by reverting that commit. Both halves are done -- the environment policy
   named `passion-19.4.4` earlier the same day, and the pin followed once the staging deploy
   of the 19.4.4 artifact came back green.

   That ordering is the rule, not a detail: sequence the pin after the default branch has
   moved **and after staging has proven the artifact**, never before. `EXPECTED_BASE_BRANCH`
   and the seven trunk pins moved to `passion-19.4.4` first and `EXPECTED_PRODUCTION_BRANCH`
   deliberately lagged behind them for exactly that window. The gap between the two pins is
   the design, not an oversight -- see the comment above `EXPECTED_PRODUCTION_BRANCH`.

   Moving the pin also moves what CI fetches. `deployment-pipeline-tests.yml` derives its
   trunk-fetch list from `baseBranch`, `productionBranch` and `previousProductionBranch`, and
   `test_upgrade_diff.py` names the cutover pair by hand -- so the pair moved to
   `origin/passion-18.4.1 -> origin/passion-19.4.4` in the same commit. Every assertion in
   both real-cutover classes was re-run against the new pair first and came back identical:
   styles-v2 178 -> 1 and newly ignored, `Site` the only table written, and the five emptied
   directories plus two config writes the tests count. The whole report is 14 findings across
   four sections, and it is byte-identical to the 18.4.1 -> 19.3.4 one but for its header line --
   19.4 adds nothing to production's cutover surface.
   `previousProductionBranch` stays `passion-18.4.1`, because that is the branch production is
   coming *from*; it is not the previous value of the key above.

   For the next time: one PR, one string, on the default branch. Bump
   `EXPECTED_PRODUCTION_BRANCH` in `Tests/PrTestEnvironments/test_base_branch_config.py` in
   the same commit -- it is the oracle the pin guard compares against, and
   `PRODUCTION_PIN_SITES` names the other site that has to move with it
   (`production-deploy.yml`'s `ref` default). Run that one test file until it is green; the
   failure names every pin still on the old branch.

   **Then move the environment's branch policy, which no test can check for you.** The
   `production` environment is restricted to one branch by name, set on 2026-08-24 to
   `passion-18.4.1`. It lives in GitHub, not in this repository, so the pin guard above
   cannot see it and will go green while it is still wrong. Left stale, every job that
   declares `environment: production` is refused at the gate -- including the deploy this
   whole runbook is for -- and the error names the environment, not the branch, so it does
   not read as a stale setting.

   ```bash
   # What is allowed today.
   gh api repos/:owner/:repo/environments/production/deployment-branch-policies \
     --jq '.branch_policies[].name'

   # Add the new branch, confirm it, then remove the old one. In that order: deleting
   # first leaves the environment with no allowed branch at all.
   gh api --method POST repos/:owner/:repo/environments/production/deployment-branch-policies \
     -f name=NEW_PRODUCTION_BRANCH -f type=branch
   ```

   Keep the old branch allowed until the deploy has succeeded. It costs nothing and it is
   what lets you re-run the previous release from its own branch if step 8 goes badly.

3. **Stage the bootstrap.** Dispatch **Production Bootstrap Command Queue** against the
   production branch with **restart_vm unticked**. It publishes the deployment scripts to
   `pr-environments/bootstrap/prod/` and writes the startup script into the instance's
   metadata. Production keeps serving throughout.

   **This is the step that puts `Deploy-RockEnvironment.ps1` on the box, so it must run
   after every change to that script.** The `web.config` merge described in the
   preconditions lives in it, and the agent runs whatever is at that prefix -- not what is
   in this repository. A bootstrap dispatched from a ref that predates the merge installs a
   deploy script that will overwrite production's keys, and nothing later in this runbook
   would catch it except step 6's dry run. Confirm the run's resolved SHA carries the fix.

   The startup script is now on the instance, and a startup script runs at every boot --
   not only the one step 5 triggers. That is deliberate and it is safe, because the script
   checks its own storage scope before doing anything and declines to install while the
   scope is still `devstorage.read_only`. It has to: an agent that can read the queue but
   cannot write a result would run a production command, fail to report it, and never
   delete it, so the same command would run again every minute for as long as the box was
   up. If the instance reboots between this step and step 5, expect
   `ROCK-BOOTSTRAP: refusing to install` on the serial console and no agent. That is the
   correct outcome, not a failure to chase.

   Watch the run's `Refuse a ref that is not the production branch` step first -- if the ref
   is wrong, everything after it is moot. Then read `Say what happened` for the prefix, the
   queue name and the VM it resolved.

   The VM is resolved by **name**, from `PRODUCTION_VM_NAME` (default `connect-srv-prod`), not
   by the `GCP_VM_EXTERNAL_IP` secret the staging bootstrap uses. Confirm the name in the log
   before going further. This is the step where a wrong answer restarts the wrong machine.

4. **Apply the bootstrap in a window.** Re-dispatch the same workflow, same ref, with
   **restart_vm ticked**. Production goes down for the length of a Windows stop and start.
   Watch the run's `Restart the production VM to apply it` step to the end; it is the only
   step that can leave production off.

   The run then waits on `Wait for the agent to report in`, which reads the serial console
   for the one line the startup script prints. It is a real check and it can fail the run
   after production is already back up -- that combination means the box is serving and the
   agent is not installed, so read the step log before doing anything else.

   Prove the agent is alive rather than assuming it. On the VM, the scheduled task is
   named `Rock PR Environment Command Queue` -- the installer is shared with the test fleet
   and its default name was never parameterized, so the name says nothing about which queue
   the task reads. Read its command line instead. It has to carry `-QueueName commands-prod`
   and `-BootstrapPrefix pr-environments/bootstrap/prod/`. From outside, a dry-run production
   deploy is the end-to-end check: it round-trips a real command through the queue and comes
   back with a result object. That is step 6, and until it comes back the agent is unproven --
   a production deploy that queues into silence looks exactly like one that is still working.

   The production agent runs only four verbs: `deploy-environment`, `set-theme-customization`,
   `find-legacy-text-columns` and `anonymize-staging`. Anything else queued to `commands-prod`
   -- a PR `deploy`, a `destroy` -- comes back as a failed result naming those four. The list
   lives in the agent, keyed by queue name, not on the task's command line: Windows caps that
   line at 261 characters and production's was already 249. So there is nothing to read for it
   on the VM; it arrives with the agent script this bootstrap installs.

   **The prefix is the whole isolation story.** The queue name keeps the two hosts from taking
   each other's commands. It does not keep them from running each other's code. Both hosts
   re-download their scripts once a minute from whatever prefix their installed task names, so
   a production agent pointed at `bootstrap/latest/` would execute staging's next upload
   within the minute, with no review in between. If the installed command line does not carry
   the production prefix, stop and fix it before anything else.

5. **Back up the production database, and verify the backup.** This is the step the version
   guard delegated here.

   Rock applies its EF and plugin migrations on the first request after a deploy. EF's
   `DbMigrator` commits each migration separately, so a failure part-way through is not a
   rollback -- it leaves the schema between two minors. Measured on staging on 2026-08-18:
   after a failed v19 attempt, **18.4.1 could no longer start against that catalog either**
   (`Invalid column name 'ScheduleReminderSystemEmailId'`). Reinstalling the old binaries is
   not a rollback. The database is.

   `gcloud sql backups create --instance=connect-prod --project=passioncitychurch-com`, then
   list the backups and confirm the new one reports `SUCCESSFUL`. Automated nightly backups
   run at 01:00 UTC and point-in-time recovery is on with 7 days of transaction logs, so there
   is a floor under this even without the on-demand backup -- take it anyway, because a
   restore wants a known instant and not an estimate.

   If a `.bak` in GCS is wanted as well, check the disk first. `connect-prod` has
   `storageAutoResize: false` on a 418 GB disk, and `gcloud sql export bak` preallocates a
   second full copy of the database on the instance's own disk for the duration -- measured at
   138.0 GiB going to 261.9 GiB and back. The failure mode of getting that wrong is a full
   production disk, not a failed export.

6. **Dry-run the deploy.** Dispatch **Deploy Production** with `ref` set to the production
   branch and `apply` unticked. Read `Resolve SHA and summarize the request` for what it
   resolved, then the two guards:
   `Refuse a ref that is not on the production branch`
   and `Refuse a ref from a different Rock version`.
   A dry run reports its plan and changes nothing. Read the plan rather than just checking it
   appeared: it prints the backup root, the site path, the preserved directories and files,
   and the health check target. The site path is the one to check hardest. None of the three
   `PRODUCTION_*` repo variables exists, so the deploy uses the fallback
   `C:\inetpub\wwwroot`, and if production does not live there this is the step that says so
   -- before a copy lands on the wrong directory.

   **Then read the two `web.config` lines, which are the reason this dry run is not
   optional.** The plan prints:

   ```
   Would carry this site's own web.config settings across: ...
   Would carry any of this site's control registrations the artifact does not have: ...
   ```

   The first must name `PasswordKey`, `DataEncryptionKey`, `RunJobsInIISContext`,
   `OrgTimeZone` and `machineKey`. The second must name `Passion`. **A plan that reports
   `none found` for `PasswordKey` is the signal to stop** -- it means the deploy is about to
   overwrite production's key with the artifact's and lock every staff member out, and it is
   the only warning that arrives before rather than after. The preconditions above say what
   each value costs.

   This is also the only step in the runbook that reads production's real `web.config`.
   Staging runs `DedicatedSite` and never had these values, so nothing earlier in the process
   could have caught a fault here.

7. **Deploy.** Same dispatch with `apply` ticked. One of the two named reviewers approves
   the `production` environment -- the run waits at its `Deploy to production` job, the one
   that writes the command to production's queue, until they do. Self-review is
   allowed, so it can be the same person who dispatched it. The VM-side script backs the site
   up to `C:\RockBackups\production\<utc>-<sha>` before it copies anything, stops the app pool,
   copies over the site preserving `Content`, `App_Data`, `Logs`, `Uploads` and
   `web.ConnectionStrings.config`, then starts the pool and polls until the site answers.

   The deploy's header block names that root on a `backups     : C:\RockBackups\production`
   line, and every restore path below assumes it. If `C:` has no room for a second copy of the
   site -- which is what this step fails on, and it fails after the pool is already stopped --
   the root can be moved for one run by queueing the deploy document by hand with
   `"backupRoot": "D:\\RockBackups"`, then reading that header line back and rewriting the
   restore command under **Rollback** against it. No dispatch input sets this, on purpose:
   every restore path below is written out as `C:\RockBackups\production\<utc>-<sha>`, and a
   box that could move it would make all of them wrong for the one run somebody is reading
   them during.

   **Confirm the `web.config` carry actually happened**, in the same log, on the line:

   ```
   Kept this server's own web.config settings: ...
   ```

   It should name the same values the dry run promised. `none found` here means the merge
   read nothing -- stop before loading the site, because step 8 is what runs the migrations
   and there is no cheap moment after it. A `WARNING` naming settings the deploy did not
   carry is not a failure: it lists settings the artifact has no opinion about, and on this
   install those are `EnableBundling` and `RedisConnectionString`, unreferenced in 19.3.4 and
   still unreferenced in 19.4.4. Read it rather than skipping it -- the next one might matter.

   The deploy log is now a timeline: every step carries an absolute UTC stamp and elapsed time,
   and the robocopy job summaries are no longer suppressed. That last part matters more than it
   sounds: `/NJS` used to hide the summary, so a copy of the whole site and a copy of nothing
   printed the same thing and both exited 0. The final line repeats the `robocopy` command that
   restores the backup, because by then it is thousands of characters up a log somebody is
   reading in a hurry.

   **The log is in the `Wait for the VM to report the result` step of the deploy job.** On a
   successful deploy it prints there and nowhere else; on a failure it is also copied into the
   job summary, so a green run needs the step opened by hand.

   **Read the timeline at the bottom of it, under the marker
   `=== deploy timeline recovered from the box ===`.**
   The steps appear twice and the second copy is the one to trust. Everything above it is what
   the agent captured from the deploy's background job, and that capture is not reliable: all
   three staging deploys of 2026-08-25 stopped it at "Stopping app pool", the first line of the
   window in which the site is offline, and lost every step after it. Three for three, so treat
   a capture that ends there as the normal case and not as news. The deploy also writes each
   step to a file on the VM, and the agent appends that file to the log. The recovery existed
   for the last two of those deploys and was complete both times -- eleven steps through to
   "Done." against five in the capture above it -- so this is measured rather than hoped for.
   If the two disagree about where the deploy got to, the recovered section is right. Item 31
   in `Documentation/Training/DevOps-Open-Items-Rock-CICD.md` has the causes ruled out so far
   and what is still unknown.

8. **Load the site and watch the migrations finish.** This is the request that runs them. The
   deploy's health check waits several minutes for exactly this reason, so a slow first load is
   expected rather than a symptom. From this deploy on, IIS preload may get there first and run
   the migrations before anyone browses to the site; that changes who waits, not how long. Migrations are irreversible; if something is wrong, this is
   the last moment it is cheap to find out.

   **Failed health check attempts in the log are normal here.** Both staging deploys of
   2026-08-25 that got far enough to log one did the same thing: attempt 1 timed out, attempt 2
   timed out, attempt 3 passed -- 2m26s and 2m34s after the app pool started, on a site with no
   migrations left to run. Two timeouts before a pass is the pattern, not a warning sign.
   Production is larger and will be running migrations, so expect more attempts and a longer
   wait. The probe has a 900 second window and recycles the app pool after 240 seconds of
   failures, because a faulted app domain caches its own startup exception and can never
   recover by retrying alone. Only the window expiring is a failure.

   **Then check the four things the health check cannot see.** It fetches a page
   anonymously, so it goes green whether or not any of these worked:

   - **Log in as a staff member.** This is the `PasswordKey` check and the only one that
     matters enough to do first. A failure here is a total lockout, and the site will look
     perfectly healthy while it happens.
   - **Open an encrypted attribute value** -- a financial gateway's settings under Admin
     Tools is the direct one. Garbage or a decryption error is `DataEncryptionKey`.
   - **Admin Tools > System Settings > Jobs**: confirm last-run times are advancing. This
     is `RunJobsInIISContext`, and its failure mode is silence -- no error anywhere, the
     jobs simply never fire.
   - **Load one of the three plugin pages** under `Plugins/passion/crm/`
     (`DynamicGroupRegistration`, `PassionChildPreRegistration`,
     `PassionStudentPreRegistration`). These compile on first request, so a missing
     `tagPrefix="Passion"` registration yellow-screens for the first real visitor rather
     than failing the deploy.

   All four are recoverable by hand if they fail -- the values are in the backup the deploy
   took at `C:\RockBackups\production\<utc>-<sha>\web.config`. Finding out now is what
   makes them cheap.

9. **Put the branding back.** The upgrade takes it away, and nothing in the deploy puts
   it back. Migration `202508051740308_Rollup_20250805` repoints the internal site at the
   `RockNextGen` theme unconditionally, and `RockNextGen` arrives unbranded.

   A theme's look comes from two places, and only one of them is the problem here.

   On disk it is two files per theme, `_variable-overrides.less` and `_css-overrides.less`,
   which Rock's own Theme Styler writes. **The deploy preserves whatever the server already
   has in these**, so nothing an administrator has ever set through Admin Tools is at risk
   at cutover. That is worth knowing precisely because it used to be: measured against
   production on 2026-08-26, eight of these files across five themes hold customization the
   artifact does not carry, and before this was fixed the copy would have replaced them
   with upstream's empty pair. `Themes/Rock/Styles/_variable-overrides.less` and the
   RockManager pair are the exception -- someone copied those into the fork, so they match
   either way.

   Eight was a hand count against the themes the fork has folders for, and the real number
   is larger. The deploy discovers these against the server rather than from a list, and its
   first run on staging restored **46 files across 23 themes** -- including
   `PassionCityChurch`, `PassionTeam`, `CONNECT`, `Connect-V2`, `Agency`, `CustomDefault`,
   `KioskStark` and the `Checkin-*` variants, none of which exist in this repository.
   `PassionCityChurch/_css-overrides.less` is 10122 bytes on its own. Expect the cutover to
   report a similar count, and read a much smaller one as the signal that something is wrong.

   Empty is normal in that list. Most themes have never been opened in the Theme Styler, so
   Rock leaves their pair at zero bytes; the staging run reported 14 such files as `empty on
   the base site, so empty here`. Those are not warnings. A warning appears only when the
   server holds bytes and fewer than all of them arrive.

   `RockNextGen` gets none of that protection, and should not. The server has never had the
   theme, so there is nothing of its own to preserve and its files come from the artifact
   empty. That is deliberate: `theme.less` imports `_variable-overrides.less`
   unconditionally, and a theme missing the file does not compile at all.

   Which leaves the second place, one column: `Theme.AdditionalSettingsJson`. It is
   per-catalog, so no deploy has ever carried it anywhere, and on `RockNextGen` it is empty.
   Staging measured what that looks like: correct fonts, correct icons, stock Rock blue.
   This step fills that column in.

   **This step has to come after step 8, and the reason is not the migration.**
   `ThemeService.UpdateThemes()` runs at application startup, scans `RockWeb/Themes` on
   disk, and inserts a row for any theme the catalog does not have.
   `RockWeb/Themes/RockNextGen` is a build output whose `.gitignore` ignores everything in
   it, so the directory arrives with the v19 artifact and the row appears the first time
   the app starts on it. Run this before the site is up and it fails with
   `No theme named RockNextGen`, which is the correct answer and not a fault.

   Dispatch **DB - Set theme customization** with `db_name` set to production's catalog,
   `theme_name` left at `RockNextGen`, and `apply` unticked. The dry run prints the
   before-and-after of every value it would write and generates the rollback; read that,
   then dispatch again with `apply` ticked and approve the `database-write` environment.

   Two properties worth knowing before approving. It **merges** -- the column also holds
   the enabled icon sets and Font Awesome weights, and Rock's own writer preserves siblings,
   so a writer that replaced the document would take the icons out and report success. And
   the rollback is written before anything else happens, restoring the previous string byte
   for byte, so the dry run produces the same undo the apply would.

   ```bash
   gh workflow run "DB - Set theme customization" -R passiondev/Rock \
     -f db_name=PRODUCTION_CATALOG -f theme_name=RockNextGen \
     -f variable_values='base-primary=#00B8E4'
   ```

   **Then clear the cache, or nothing changes on screen.** Editing a theme in Admin Tools
   clears it on the way out: `Theme.SaveHook` publishes `ThemeWasUpdatedMessage` and
   `ThemeWasUpdatedConsumer` calls `CssProcessor.ClearCache()`. Writing the column directly
   runs no save hook and publishes nothing, so the site keeps serving the CSS it already
   built and a correct write reads as having done nothing. **Admin Tools > General Settings
   > Cache Manager > Clear Cache** empties `RockCache`, which is where
   `Rock.Web.CssProcessor.CssCache` lives. An app pool recycle does the same by starting an
   empty process.

   **What proves it worked**, off the box and with no login:

   ```bash
   curl -s https://connect.passion.team/Themes/RockNextGen/Styles/theme.css | grep -c '#00b8e4'
   ```

   A count of zero after a cache clear means the write did not take, or it landed on a theme
   the site is not using. The dry run names the theme and the catalog it read, so compare
   against that rather than re-running the apply.

   **This workflow has never been run.** Checked on 2026-08-26: zero runs, against any
   catalog. Its dry run and its rollback generation are covered by tests and neither has
   executed against a live database, so production must not be the first. Dispatch it
   against staging's catalog first, with `apply` unticked, then with `apply` ticked, and
   confirm staging's theme changes on screen before this step is attempted on production.

   One consequence of it never having run was that the `database-write` environment it names
   did not exist. GitHub creates a missing environment on first use with no protection rules,
   and **an environment with no required reviewers approves itself**, so the apply gate was
   decorative. **Fixed 2026-09-14:** the environment now exists with required reviewers
   `justinpbarnett` and `WoodsonJ`, self-review allowed -- the same shape as `production`.
   Confirm it is still so before the first production apply:

   ```bash
   gh api repos/:owner/:repo/environments/database-write \
     --jq '.protection_rules[] | select(.type=="required_reviewers")
           | [.prevent_self_review, (.reviewers[].reviewer.login)]'
   ```

   **Separately, confirm the deploy preserved the other themes' files.** This checks the
   half of step 9 that is supposed to need no action, which is exactly the half that fails
   quietly. Each of these is customized on production and empty in the artifact, so a zero
   from any of them means the copy overwrote the server's file:

   ```bash
   for f in Rock/_css-overrides Stark/_variable-overrides Stark/_css-overrides \
            LandingPage/_variable-overrides LandingPage/_css-overrides \
            CheckinElectric/_variable-overrides CheckinElectric/_css-overrides \
            DashboardStark/_variable-overrides; do
     n=$(curl -s "https://connect.passion.team/Themes/${f%%/*}/Styles/${f##*/}.less" | wc -c)
     printf '%-44s %s bytes\n' "$f" "$n"
   done
   ```

   Measured on production 2026-08-26, in the same order: 310, 189, 207, 340, 131, 287, 272,
   20. The deploy log carries the other side of it -- one
   `Keeping this site's own copies of N theme override file(s)` line, where N is 8.

   **What is in them is worth knowing, because "theme override" undersells it.**
   `Themes/Rock/Styles/_css-overrides.less` holds `@enable-legacy-badges: true`, the
   profile-image crop rule `.fluid-crop .img-profile { object-fit: contain; }`, a
   `.checkbox-inline` display rule that every form in the site lays out against, and an
   `overflow-y` fix for the side navigation. `Themes/Stark/Styles/_variable-overrides.less`
   is what sets `@fa-edition: 'pro'` for the external site, so it decides whether the login
   page gets Pro icons at all. A zero from any of these is functional breakage on
   production, not a colour that looks slightly off.

10. **Check the performance settings landed.** This deploy is the first one that configures
   the app pool and turns ASP.NET debug mode off on production. Both were measured as
   missing on 2026-08-26 and neither has ever been set on that box, so neither can be
   assumed.

   **In the deploy timeline,** two lines that did not exist before:

   ```
   Wrote web.config with compilation debug=false and executionTimeout=600.
   Holding <pool> resident: no idle timeout, AlwaysRunning, 5 minute startup limit, recycle at 04:00. Preloading site <site>.
   ```

   A `Could not enable preload` warning beside the second line is not a failed deploy. It
   means the Application Initialization role feature is missing, and the site starts cold
   after a recycle instead of warm. Everything else still applied.

   **Off the box, read-only,** the debug setting has a fingerprint that needs no login.
   ASP.NET serves the debug build of MicrosoftAjax when `debug="true"`:

   ```bash
   resource=$(curl -s -L https://connect.passion.team/ \
     | grep -o 'ScriptResource\.axd[^"]*' | head -1 | sed 's/&amp;/\&/g')
   curl -s "https://connect.passion.team/${resource}" | wc -c
   ```

   Measured at **319,867 bytes** on 2026-08-26, over 7,181 lines, averaging 43.5 characters
   per line with 758 comment markers in it. After the deploy it should be roughly 100,000
   bytes on a handful of lines. A number still near 320,000 means the setting did not take.

   **Then leave the site alone for half an hour and load it again.** The whole point of the
   pool settings is that the second visit of the morning costs what the first one did.
   Staging measured 16.07s cold against 0.25s warm before this change. A slow load after
   thirty idle minutes means `idleTimeout` did not apply.

## User-visible changes that arrive with v19

Neither of these is a fault, and both will look like one to whoever reports it first.
They are listed so the answer is already written down.

- **Campus becomes mandatory on workflow person-entry forms.** Upstream added
  `rules="required"` to the Campus dropdown in
  `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/WorkflowEntry/Actions/entryFormPersonEntry.partial.obs`
  between `hotfix-18.4` and `hotfix-19.3`. Every workflow form that shows the campus
  field will refuse to submit without one, where 18.4.1 accepted a blank. This is stock
  Rock 19 behaviour rather than a fork change, so reverting it means deliberately
  diverging from upstream on a file the fork already patches for layout. The fork's edit
  there is layout only -- the primary person editor is full width and the spouse editor
  has a row of its own -- so keep that and take upstream's `rules="required"` at a merge.

- **The first load after the deploy is slow, and some health-check attempts fail.**
  Covered in step 8. Worth repeating here because it is the single most likely thing to
  be escalated during the window.

## Rollback

**Binaries roll back. The database does not.** Once migrations have started, restoring the
site directory gives you 18.x binaries against a schema they cannot read, which is the failure
measured on staging. Decide by where you are:

- **Before the first request** -- nothing has migrated. Restore the site directory
  (`robocopy C:\RockBackups\production\<utc>-<sha> C:\inetpub\wwwroot /E`, printed at the end
  of the deploy log) and start the app pool. The database is untouched.
- **After migrations have run or failed part-way** -- the only rollback is a database restore,
  and then the old binaries. Restore the backup from step 5, or use point-in-time recovery to
  an instant before the deploy.

**A lost `web.config` value is not a rollback.** If step 8's checks find a staff lockout, a
decryption failure, jobs not firing or a missing `tagPrefix`, and everything else is
healthy, the fix is one file and not a restore -- the migrations have already run and
rolling the binaries back would leave 18.x against a 19.x schema. Take the value out of the
backup the deploy took at `C:\RockBackups\production\<utc>-<sha>\web.config`, put it into
the live `C:\inetpub\wwwroot\web.config`, and recycle the app pool. Edit the one element;
do not copy the whole file over, or v19 loses the assembly bindings it needs -- that is the
same trap the preconditions describe, taken from the other direction.

Then find out why the merge did not carry it, because it will not carry it on the next
deploy either.

`connect-prod` carries exactly one user database, `RockConnectProd`, so a Cloud SQL restore
takes back only what you intend even though it is instance-level. That is not true of the
sandbox instance, which holds several -- do not carry the habit across.

**The name collision that used to be here is gone, and the hazard behind it is not.** This
section used to warn that `connect-restore-test` held its own `RockConnectProd`, so the instance
name was the only thing telling the two apart. Re-read live on 2026-08-25, the sandbox holds
`RockStaging` and `RockStaging20260824` and no `RockConnectProd` at all -- item 7's database
split renamed it. Verify before relying on either version of this paragraph:

```bash
gcloud sql databases list --instance=connect-restore-test --project=passioncitychurch-com
```

What has not changed is the thing that actually bites. `gcloud sql backups restore` restores a
whole **instance**; it never names a database. So a command that reads correctly and names the
wrong `--instance` still overwrites everything on it, and the differing database names give no
protection at all -- nothing in the command mentions them. The collision was never the hazard.
The instance argument was.

A restore of production's data is the largest action in this document. Read the `--instance`
back out loud before running it.

## Left as a decision, not done

- **`prevent_self_review`.** Not enabled, and that is the decision rather than an oversight.
  One approval is required and either of the two named reviewers can give it, including
  whoever started the run. The trade was made knowingly: requiring a genuine second pair of
  eyes would mean a cutover waits on whoever is away from their desk, and a cutover is exactly
  when that fails. So the gate stops an accident, not a bad decision -- worth being clear
  about which of those you are relying on. Read the current list with
  `gh api repos/passiondev/Rock/environments/production --jq '.protection_rules'` rather than
  trusting a name written down here.

  The `database-write` environment created on 2026-09-14 was given the same shape for the
  same reason. If that trade is ever revisited, it applies to both.

It is a live repository setting, and changing a live setting quietly is how a control ends up
in place that nobody remembers agreeing to.

**Settled since this was written: `deployment_branch_policy`.** The environment used to accept
a deploy from any branch, with the guard inside the workflow doing all the refusing. On
2026-08-24 it was restricted to a single named branch, `passion-18.4.1`, so GitHub now refuses
a wrong ref before an approver is paged. The cost is the one predicted here: the cutover has to
move the policy as well as the pin. Step 2 carries that, because no test can see this setting.

As of 2026-09-14 the policy names `passion-18.4.1`, `passion-19.3.4` and `passion-19.4.4`.
That is step 2 done for the first two and deliberately not finished: an old branch stays
allowed until the deploy that replaces it has succeeded, because it is what lets the previous
release be re-run from its own branch. `passion-19.4.4` was added the same day the branch was
built -- adding an allowed branch is additive and reversible and gates nothing on its own,
since the required-reviewer rule still stands in front of every deploy. Prune down to the one
branch production is actually serving once it is up and has stayed up.
