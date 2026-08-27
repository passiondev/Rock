# Production Upgrade Runbook

**Last verified:** 2026-08-25 · **Audience:** whoever is running the production cutover.
Nothing in here has been executed. It is the checklist for the upgrade, written while the
machinery for it was built.

**Step 1 is done.** The pipeline changes merged to the default branch on 2026-08-25, so
**Production Bootstrap Command Queue** is dispatchable and step 1's own evidence check passes.
Everything from step 2 on is untouched, and step 2 is the irreversible one.

Re-read live against GCP on 2026-08-25, and all of it still holds: `connect-srv-prod` is
`RUNNING` with `automaticRestart: false` and the `devstorage.read_only` scope alongside
`logging.write` and `monitoring.write`, and carries no `windows-startup-script-ps1`.
`connect-prod` is a 418 GB disk with `storageAutoResize: false`, nightly backups at 01:00 UTC,
point-in-time recovery on with 7 days of transaction logs, the last four backups `SUCCESSFUL`,
and exactly one user database. The rollback section's database-name warning did **not** hold and
has been rewritten. The PR test fleet and staging are a different document
(`PR-Test-Environments-Operator-Runbook.md`); the trunk cutover described there has already
happened, and this is the second half of it.

At the time of writing, the trunk is `passion-19.3.4`, `productionBranch` is `passion-18.4.1`,
and production is serving the 18.x line. Read the two values rather than trusting that
sentence: `.github/pr-test-environments.json` on the default branch is the source for both.

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

**`connect-srv-prod` does not restart itself.** `scheduling.automaticRestart` is `false`, an
AWS lift-and-shift leftover. The restart step retries the start six times and fails loudly if
the instance is still down, but nothing behind it will try again. If that step throws, someone
starts the instance by hand -- production is off until they do.

**The scope change is a union, not a replacement.**
`gcloud compute instances set-service-account --scopes=` overwrites the whole list, and
production's list carries `logging.write` and `monitoring.write` that the Ops Agent needs.
The workflow reads the current scopes, drops `devstorage.read_only`, adds
`devstorage.read_write`, and dedupes. It does not grant `cloud-platform`, which is what
staging runs on and is more than these scripts need: they reach `storage.googleapis.com`
and the metadata server, and nothing else.

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
- **The version guard goes quiet.** Moving `productionBranch` moves the expected version with
  it, so a `passion-19.3.4` deploy matches the pin and never asks for
  `acknowledge_version_change`. The workflow says so in its own comments and points here for
  the backup requirement. **The backup is this runbook's job, not the guard's.** Step 5 below
  is the whole of that control.

## Order of operations

Each step says what proves it worked. A step with no evidence behind it has not been done.

1. **Land the pipeline changes on the default branch.** The bootstrap workflow, the
   `-BootstrapPrefix` parameter on the agent and its installer, and the deploy script's
   progress logging. Confirm with `gh workflow list -R passiondev/Rock` that
   **Production Bootstrap Command Queue** appears.

2. **Repoint `productionBranch`.** One PR, one string, on the default branch. Bump
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

7. **Deploy.** Same dispatch with `apply` ticked. One of the two named reviewers approves
   the `production` environment -- `Record approval` in the run is that gate. Self-review is
   allowed, so it can be the same person who dispatched it. The VM-side script backs the site
   up to `C:\RockBackups\production\<utc>-<sha>` before it copies anything, stops the app pool,
   copies over the site preserving `Content`, `App_Data`, `Logs`, `Uploads` and
   `web.ConnectionStrings.config`, then starts the pool and polls until the site answers.

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

   One consequence of it never having run: the `database-write` environment it names does
   not exist. GitHub creates a missing environment on first use with no protection rules,
   and **an environment with no required reviewers approves itself**, so the apply gate is
   currently decorative. Create the environment and give it a required reviewer before the
   first production apply, or the dry run is the only thing standing between a dispatch and
   a write.

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
  diverging from upstream on a file the fork already patches for layout -- check
  `Documentation/Fork-Local-Changes.md` item 3 before touching it.

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

It is a live repository setting, and changing a live setting quietly is how a control ends up
in place that nobody remembers agreeing to.

**Settled since this was written: `deployment_branch_policy`.** The environment used to accept
a deploy from any branch, with the guard inside the workflow doing all the refusing. On
2026-08-24 it was restricted to a single named branch, `passion-18.4.1`, so GitHub now refuses
a wrong ref before an approver is paged. The cost is the one predicted here: the cutover has to
move the policy as well as the pin. Step 2 carries that, because no test can see this setting.
