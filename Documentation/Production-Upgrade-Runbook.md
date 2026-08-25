# Production Upgrade Runbook

**Last verified:** 2026-08-24 · **Audience:** whoever is running the production cutover.
Nothing in here has been executed. It is the checklist for the upgrade, written while the
machinery for it was built. The PR test fleet and staging are a different document
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
   the agent captured from the deploy's background job, and that capture is not reliable: both
   staging rehearsals of 2026-08-25 stopped it at "Stopping app pool", the first line of the
   window in which the site is offline, and lost every step after it. The deploy also writes
   each step to a file on the VM, and the agent appends that file to the log. On the second
   rehearsal the recovered section carried all eleven steps through to "Done." while the
   capture above it carried five, so this is measured rather than hoped for. If the two
   disagree about where the deploy got to, the recovered section is right. Item 31 in
   `Documentation/Training/DevOps-Open-Items-Rock-CICD.md` has the causes ruled out so far and
   what is still unknown.

8. **Load the site and watch the migrations finish.** This is the request that runs them. The
   deploy's health check waits several minutes for exactly this reason, so a slow first load is
   expected rather than a symptom. Migrations are irreversible; if something is wrong, this is
   the last moment it is cheap to find out.

   **Failed health check attempts in the log are normal here.** Staging on 2026-08-25 logged
   `Health check attempt 1: The operation has timed out`, the same again for attempt 2, then
   passed on attempt 3 -- 2m26s after the app pool started, on a site with no migrations left
   to run. Production is larger and will be running them, so expect more attempts and a longer
   wait. The probe has a 900 second window and recycles the app pool after 240 seconds of
   failures, because a faulted app domain caches its own startup exception and can never
   recover by retrying alone. Only the window expiring is a failure.

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

**Two different databases are called `RockConnectProd`.** Production's is on `connect-prod`.
The sandbox instance `connect-restore-test` holds a copy under the same name, seeded on
2026-04-14 and shared by the whole `pr-*` fleet. Every restore command here names an instance,
and the instance is the only thing distinguishing them -- a command that reads correctly and
names the wrong instance either destroys the fleet's catalog or overwrites production with a
four-month-old copy of itself.

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
