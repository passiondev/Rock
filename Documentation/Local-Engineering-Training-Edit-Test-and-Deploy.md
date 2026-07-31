# Local Engineering: How to Edit, Test, and Deploy Rock

**Audience:** Local Engineering team (no prior GitHub experience assumed)
**Covers:** `connect.passion.team` (Rock RMS) — the code and files behind the site
**Last verified:** 2026-07-31 (see [Facts that go stale](#facts-that-go-stale))

This is the training doc for making a change to Rock, testing it on a private copy of the
site, and getting it live. Read Parts 0–2 before your first change. Parts 3–6 are
reference — come back to them.

If you only remember one thing: **you never edit files on the live server.** You propose a
change in GitHub, a robot builds it, you test it on a private copy, then it ships.

---

## Table of contents

- [Part 0 — The big picture](#part-0--the-big-picture)
- [Part 1 — GitHub primer](#part-1--github-primer)
- [Part 2 — Your first change, start to finish](#part-2--your-first-change-start-to-finish)
- [Part 3 — Label reference](#part-3--label-reference)
- [Part 4 — What the test environment is NOT (read this one)](#part-4--what-the-test-environment-is-not-read-this-one)
- [Part 5 — Deploying to production](#part-5--deploying-to-production)
- [Part 6 — Troubleshooting](#part-6--troubleshooting)
- [Part 7 — Who to ask](#part-7--who-to-ask)
- [Appendix A — Working from a local clone (optional)](#appendix-a--working-from-a-local-clone-optional)
- [Appendix B — Glossary](#appendix-b--glossary)
- [Appendix C — Known issues](#appendix-c--known-issues)

---

## Part 0 — The big picture

### First question: is this even a file change?

This is the most common wasted afternoon. A lot of what looks like "editing the website" in
Rock is **not** a file at all — it is a record in the database that you change through the
Rock admin UI on the live site. This pipeline only handles **files**.

| You want to change… | Where it lives | How to change it |
| --- | --- | --- |
| Text/HTML inside an HTML Content block | Database | Rock admin UI on the live site. **Not GitHub.** |
| A page's name, route, layout, or which blocks are on it | Database | Rock admin UI. **Not GitHub.** |
| Lava in a block's settings, a workflow, a report, a shortcode body | Database | Rock admin UI. **Not GitHub.** |
| Theme markup, theme CSS/LESS, theme Lava templates | Files (`RockWeb/Themes/…`) | GitHub — this doc |
| A custom Passion block's behavior | Files (`RockWeb/Plugins/org_passion/…`) | GitHub — this doc |
| A core Rock block's behavior | Files (`RockWeb/Blocks/…`, `Rock/…`) | GitHub — this doc |
| Site-wide stylesheets or static images shipped with the app | Files (`RockWeb/Styles/`, `RockWeb/Assets/`) | GitHub — this doc, but **see [Trap 1](#trap-1-changes-to-themes-content-assets-and-styles-do-not-show-up)** |

If you are not sure which side of the line you are on, ask before you start. Changing a
file when you needed the admin UI produces a change that appears to do nothing.

### The four places code lives

```
   YOUR BROWSER                GITHUB                    GOOGLE CLOUD
   ────────────                ──────                    ────────────

   1. You edit a file  ──►  2. GitHub stores it     3. A Windows robot
      in GitHub's web         on a "branch" and        builds Rock from
      editor                  opens a "pull            your branch (~20-30
                              request" (PR)            min) and packages it

                                    │                         │
                                    ▼                         ▼

   5. You open your PR's  ◄──  4. The package is installed on a private
      private copy of the        copy of the site, just for your PR:
      site and test it          https://pr-<number>.rock-dev.connect.passion.team

                                    │
                                    ▼

   6. Someone reviews and merges the PR. Production follows (Part 5).
```

### Vocabulary you need before Part 1

| Term | Plain meaning |
| --- | --- |
| **Repository** ("repo") | The folder of all Rock's files, with full history. Ours is `passiondev/Rock` on GitHub. |
| **Branch** | A private copy of all the files that you can change without affecting anyone. Yours might be `fix/homepage-typo`. |
| **Commit** | One saved change, with a message describing it. Like a save point. |
| **Pull request** ("PR") | A request to merge your branch's changes into a shared branch. It's also the page where testing, discussion, and review all happen. |
| **Base branch** | The shared branch you want your change to end up in. Picking the wrong one is the #1 reason nothing happens. |
| **Label** | A tag you stick on a PR. Here, labels are **buttons** — they start and stop your test environment. |
| **GitHub Actions** | The robot. Runs the build automatically and reports back on the PR. |
| **Artifact** | The zip file the robot produces — a fully built copy of the site, ready to install. |

---

## Part 1 — GitHub primer

### Before your first change: three prerequisites

1. **A GitHub account, added to the `passiondev` organization with write access.**
   You need write access to create branches and to add labels. Ask DevOps. Without it, the
   "Commit changes" button will offer to fork the repo instead — see the warning below.
2. **Two-factor authentication (2FA) turned on.** Required by the organization.
3. **VPN or office network.** The test environments are firewalled to the office/VPN
   egress IP (`159.63.145.194`). From home without VPN, the URL simply will not load.

> ### ⚠️ This repository is PUBLIC
>
> `passiondev/Rock` is a public fork of the open-source Rock project. **Anything you
> commit is visible to the entire internet, permanently**, including in history after you
> "delete" it.
>
> Never commit: passwords, API keys, connection strings, `.env` files, database backups,
> exports containing member names/emails/phone numbers/giving data, or screenshots showing
> real member data. PR comments and the automated status comments are public too.
>
> If you commit a secret by accident, do not just delete it in a new commit — tell DevOps
> immediately so the credential can be rotated.

### Where things are in the repo

You will mostly live in `RockWeb/`.

| Path | What it is |
| --- | --- |
| `RockWeb/Themes/<ThemeName>/` | Theme markup, LESS/CSS, theme Lava. ⚠️ [Trap 1](#trap-1-changes-to-themes-content-assets-and-styles-do-not-show-up) |
| `RockWeb/Plugins/org_passion/` | Passion's custom blocks (`.ascx` + `.ascx.cs`) |
| `RockWeb/Plugins/team_passion/` | More Passion custom blocks |
| `RockWeb/Blocks/` | Core Rock blocks (WebForms) |
| `RockWeb/Styles/`, `RockWeb/Assets/` | Shipped stylesheets and images. ⚠️ [Trap 1](#trap-1-changes-to-themes-content-assets-and-styles-do-not-show-up) |
| `Rock/` | Core C# library — models, services. Changing this needs care and review. |
| `Rock.Migrations/` | Database migrations. ⚠️ [Trap 3](#trap-3-a-migration-in-your-pr-changes-the-shared-database-for-everyone) |
| `Documentation/` | This doc and the runbooks |
| `.github/workflows/` | The robot's instructions |

### Reading a PR page

When you open a pull request you'll see:

- **Conversation** — the description, comments, and the automated status comment. This is
  where you'll watch your build.
- **Commits** — every save point on your branch.
- **Files changed** — the actual diff: red lines removed, green lines added. **Always
  check this tab before asking for review.** It is how you catch the stray file you
  didn't mean to touch.
- **Right sidebar** — Reviewers, **Labels** (your buttons), Assignees.
- **Checks** — the robot's progress and logs.

### The one habit worth building

Before you ask anyone to look at your PR, open **Files changed** and read every line. If
you see something you don't recognize — a whitespace-only change across a whole file, a
`.csproj` you didn't open, `package-lock.json` — stop and ask. Accidental changes are
normal and easy to fix; the trick is catching them before review.

---

## Part 2 — Your first change, start to finish

This is the golden path, entirely in the browser. No terminal, no Windows machine, no
local build. (For bigger work, see [Appendix A](#appendix-a--working-from-a-local-clone-optional).)

### Step 1 — Confirm which base branch is eligible

**Do this every time.** Only PRs targeting one specific branch get a test environment, and
that branch changes when Rock is upgraded.

Open this file on the default branch and read it:

<https://github.com/passiondev/Rock/blob/develop/.github/pr-test-environments.json>

```json
{
  "baseBranch": "develop-17.6.1",
  "environmentDomain": "rock-dev.connect.passion.team"
}
```

As of 2026-07-31 the eligible base branch is **`develop-17.6.1`**. Whatever `baseBranch`
says is what you must branch **from** and target **into**. If you target anything else, the
robot will quietly do nothing — no error, no comment. (A Rock 18.3 upgrade is in progress,
so expect this value to change. Re-read the file, don't trust your memory.)

### Step 2 — Find the file

Go to <https://github.com/passiondev/Rock>, press <kbd>t</kbd>, and type part of the
filename to search. Or navigate the folders using the map in Part 1.

Make sure you are viewing the file **on the base branch from Step 1**. The branch selector
is the button at the top-left of the file list. If it says `develop`, click it and switch
to `develop-17.6.1`.

### Step 3 — Edit it

1. Click the **pencil icon** (Edit this file) at the top-right of the file view.
2. Make your change.
3. Click **Commit changes…**.
4. In the dialog:
   - **Commit message:** short and specific. `fix: correct service time on homepage hero`
     is good. `update` is not. If there's a JIRA ticket, put the key in:
     `PTP-12345: correct service time on homepage hero`.
   - Select **Create a new branch for this commit and start a pull request.**
   - **Branch name:** `fix/service-time-typo` or `feat/…`. Lowercase, dashes, no spaces.
5. Click **Propose changes**.

> If the dialog offers to "fork this repository" instead of creating a branch, you don't
> have write access yet. Stop and ask DevOps — **a PR from a fork will never get a test
> environment** (see [Trap 8](#trap-8-prs-from-forks-never-deploy)).

### Step 4 — Open the pull request

You'll land on the "Open a pull request" form.

1. **Check the base branch.** At the top it reads `base: <something> ← compare: <your
   branch>`. If base is not the branch from Step 1, click it and change it. **This is the
   step people get wrong.**
2. **Title:** the commit message is fine.
3. **Description:** the template that auto-fills is inherited from the upstream open-source
   Rock project and is mostly irrelevant to internal work. You can delete it. What we
   actually want:

   ```markdown
   ## What changed
   One or two sentences.

   ## Why
   JIRA ticket link, or the request this came from.

   ## How to test
   Where to click on the PR environment to see it. Be specific —
   the reviewer should not have to guess.
   ```

4. Click **Create pull request**. Note your PR number (e.g. `#42`) — your test
   environment URL is built from it.

### Step 5 — Start your test environment

In the PR's right sidebar, click the gear next to **Labels** and select:

```
rock-test:start
```

That's it. That label is the button. Within a minute the robot adds `rock-test:queued` and
posts a status comment.

> **Do not** use the "Run workflow" button on the Actions tab. That path is currently
> broken and will fail immediately ([Appendix C](#appendix-c--known-issues)). Labels are
> the only supported way to start an environment.

### Step 6 — Watch it build

The robot keeps **one** status comment on your PR and rewrites it in place, so there's no
comment spam. It looks like this:

| Field | Value |
| --- | --- |
| Status | **deployed** |
| URL | https://pr-42.rock-dev.connect.passion.team |
| Deployed SHA | `aea0dba…` |
| Artifact | `gs://…/RockWeb-pr-42-aea0dba.zip` |
| Last updated | 2026-05-05T14:33:21Z |
| Logs | GitHub Actions run |

The label on the PR tracks the same thing: `queued` → `building` → `deploying` →
`deployed`, or `failed`.

**Budget about 30 minutes.** The build is the slow part — it compiles all of Rock plus
three JavaScript bundles on a fresh Windows machine every time. This is normal, not stuck.
Go do something else; the comment updates itself.

### Step 7 — Open your environment

```
https://pr-<your PR number>.rock-dev.connect.passion.team
```

**You must be on VPN or the office network.** Otherwise the page won't load at all.

Two things to expect on first visit:

- **A certificate warning.** Right now this is expected — see
  [Trap 6](#trap-6-expect-a-certificate-warning-right-now). Confirm you're on VPN first,
  then proceed.
- **A very slow first page load.** Rock compiles and warms up on the first request; a
  minute or more is normal. Subsequent pages are fast. If it times out, reload once
  before reporting a problem.

### Step 8 — Test it

Click through your change. Then read
[Part 4](#part-4--what-the-test-environment-is-not-read-this-one) — it lists the things
this environment deliberately cannot do (no email, no texts, no payments), so you don't
file a bug against a disabled integration.

Write what you find in a PR comment. Screenshots help — drag them into the comment box.
(No real member data in screenshots; the repo is public.)

### Step 9 — Make another change

Edit the file again on **your branch** (the branch selector will now offer it) and commit.
Then either:

- **Add `rock-test:start` again** to rebuild with your new commit. If the label is already
  on the PR, remove it and re-add it. Or
- **Add `rock-test:auto` once**, and every future push to your branch rebuilds
  automatically. Convenient while iterating; remember each rebuild is another ~30 minutes
  of build time, and pushing again cancels the in-flight run.

### Step 10 — Review and merge

1. Add a reviewer in the sidebar. They can open the same PR URL and check your work.
2. Once approved, click **Merge pull request**.

**Merging your PR into the base branch from Step 1 (`develop-17.6.1`) is safe** — it
deploys nothing and reboots nothing. It just parks your change on the shared branch.

Getting from there to the live site is a second, separate step: someone promotes
`develop-17.6.1` into `develop`, and **a push to `develop` automatically triggers a deploy
that reboots a server.** That promotion is DevOps-owned — don't do it yourself. See
[Part 5](#part-5--deploying-to-production) for what it does and why the timing matters.

### Step 11 — Cleanup happens for you

- **Merged PR** → environment destroyed immediately.
- **Closed without merging** → environment stopped, then destroyed after 7 days.
- **Idle 6 hours** → stopped automatically (files kept). Re-add `rock-test:start` to bring
  it back — which is a full rebuild, so budget ~30 minutes rather than expecting it to pop
  straight back up.

You don't need to clean up by hand. If you want to free the server sooner, add
`rock-test:destroy`.

---

## Part 3 — Label reference

**You apply these:**

| Label | What it does |
| --- | --- |
| `rock-test:start` | Build the PR's latest commit and deploy it. Use for the first deploy, for redeploys, and to wake a stopped environment. **Always a full rebuild (~30 min)** — there is no quick-start path. |
| `rock-test:stop` | Stop the site but keep all files and state on the server. Note that waking it back up still means `rock-test:start`, so budget the full rebuild. |
| `rock-test:destroy` | Delete the site, app pool, files, and state. Use when fully done. |
| `rock-test:auto` | Opt in to automatic rebuild on every push to this PR. Apply once. |

**The robot applies these — don't touch them:**

`rock-test:queued` · `rock-test:building` · `rock-test:deploying` · `rock-test:deployed` ·
`rock-test:stopped` · `rock-test:failed`

Your environment is always at a predictable address: `pr-<number>.rock-dev.connect.passion.team`,
IIS site `rock-pr-<number>`, files at `C:\RockTestEnvs\pr-<number>\site` on the test host.

---

## Part 4 — What the test environment is NOT (read this one)

Each PR gets its **own code**. It does **not** get its own data, its own uploads, or
working integrations. These are the specific ways that bites.

### Trap 1: Changes to Themes, Content, Assets, and Styles do not show up

After your build is installed, the deploy script copies these four directories from a shared
source on the server over the top of your copy:

```
Themes/   Content/   Assets/   Styles/
```

It uses `robocopy /MIR`, which **overwrites files that differ and deletes files that aren't
in the source.** So if your PR edits `RockWeb/Themes/PassionTheme/style.css`, your version
can be replaced by the shared copy before you ever see it, and new files you added under
those paths can be deleted.

This exists for a good reason — it pulls in uploaded content and server-side theme state
that isn't in git, so PR environments resemble the real site.

**Whether it actually bites depends on server state that isn't visible from GitHub.** The
source defaults to the IIS "Default Web Site" folder on the test VM, and each of the four
directories is skipped if it isn't present there. So the overlay may be clobbering your
theme edits, or may be doing nothing at all. The deploy script logs which happened, but
only to `C:\RockDeploy\logs` on the VM — the PR status comment and Actions log don't carry
it.

What to do:

- **If a change under `Themes/`, `Content/`, `Assets/`, or `Styles/` doesn't appear on your
  PR environment, suspect this first.** It is much more likely than a caching bug.
- Ask DevOps to check the deploy log for `Overlaying shared site assets` versus
  `skipping`. That answer is the same for everyone, so **it only has to be established
  once** — when it is, record it here.
- Until then, don't assume a theme change is verified just because the deploy went green.

### Trap 2: The database is shared, and it resets

Every PR environment points at **one** shared, sanitized sandbox database and shared file
storage. That means:

- Data you create (a test person, a registration) is visible in **everyone's** PR
  environment.
- Someone else's test data shows up in yours. A record that "appeared out of nowhere"
  probably came from a colleague.
- The sandbox is refreshed daily, so **your test data disappears overnight.** Don't build
  up a scenario over two days and expect it to survive.
- It's sanitized, not fake-from-scratch — still treat it as sensitive. No screenshots of
  it in public places.

### Trap 3: A migration in your PR changes the shared database for everyone

Rock runs pending Entity Framework and plugin migrations **automatically on startup**
(`Rock.WebStartup/RockApplicationStartupHelper.cs:130`). Because all PR environments share
one database, starting your environment applies your migration to the database everyone
else is using — and it can't be undone by stopping your environment.

**If your change touches `Rock.Migrations/` or adds a plugin migration, talk to DevOps
before applying `rock-test:start`.** This is the one case where the self-service path is
not self-service.

### Trap 4: No email, no texts, no payments, no jobs

Deliberately disabled or neutered on PR environments:

| Off | Consequence for testing |
| --- | --- |
| SMTP / email | Nothing is delivered. Confirmation emails will never arrive. |
| Twilio / SMS | No texts. |
| Payment gateway | Set to `SandboxDisabled`. Giving/registration payment steps won't complete. |
| Webhooks | Not delivered. |
| Background jobs (Quartz) | `RunJobsInIISContext=False` — scheduled jobs never run. Anything that depends on a job having run will not happen. |
| Spark API | Blank. |

This is intentional: several PR sites pointing at one database must not all process real
queues or contact real services. **Do not file a bug because an email didn't send.** If
your change *is* about email or jobs, that needs a different testing plan — ask DevOps.

### Trap 5: A green build does not prove your code shipped

The build step is configured to keep going when an individual project fails to compile. It
logs `Warning: Failed to build <project>, continuing...` and finishes successfully. The
only hard gate is that `Rock.dll` exists.

So a PR can reach **deployed** while the specific project you changed failed to compile —
and the site runs the previous version of that piece. If your change seems to have no
effect:

1. Open the **Logs** link in the status comment.
2. Open the "Build Rock Projects" step.
3. Search the log for `Warning: Failed to build`.

If your project is in that list, the deployment doesn't contain your change. Bring the log
to DevOps.

### Trap 6: Expect a certificate warning right now

The weekly certificate renewal job has been failing since 2026-05-18 (last success
2026-05-11), so the TLS certificates on `pr-*.rock-dev.connect.passion.team` are likely
expired.

Practically: **confirm you're on VPN, then click through the browser warning.** It is not
evidence that your deploy failed. It is tracked in
[Appendix C](#appendix-c--known-issues).

### Trap 7: Plugin code errors appear in the browser, not in the build

All 84 plugin blocks under `RockWeb/Plugins/` use `CodeFile=`, which means their `.ascx.cs`
code-behind is **shipped as source and compiled by the web server on first request** — not
by the build robot.

Consequence: a syntax error or bad reference in a plugin `.ascx.cs` produces a **green
build and a green deploy**, then a compiler error page ("yellow screen") when you open the
page in the browser. That's expected behavior, not a broken pipeline. Read the error page —
it names the file and line. Fix, commit, redeploy.

### Trap 8: PRs from forks never deploy

Only branches in `passiondev/Rock` itself can deploy, because these environments sit on
shared infrastructure with sanitized data. A PR opened from your personal fork is skipped
with no environment and no error on the PR. If this happens, you need write access on the
repo — see Part 1.

### Trap 9: The wrong base branch fails silently

Covered in Step 1, repeated because it costs the most time: if your PR's base branch isn't
the one in `.github/pr-test-environments.json`, applying `rock-test:start` does
**nothing**. No comment, no failure, no label change. If you apply the label and nothing at
all happens within a couple of minutes, check your base branch first.

You can fix it without redoing your work: on the PR, click **Edit** next to the title, then
change the base branch dropdown.

---

## Part 5 — Deploying to production

> ### ⚠️ Read before you merge anything
>
> There are two ways code reaches a live server today. **One of them fires automatically on
> any push or merge to `develop`, and it reboots a server.** Nobody presses a "deploy"
> button — the merge *is* the button.
>
> Your own PRs target `develop-17.6.1`, so merging them is safe. The dangerous merge is the
> later promotion of `develop-17.6.1` into `develop`. That one is DevOps-owned. Always check
> which branch you're merging into.

### Path A — The automatic pipeline (fires on merge to `develop`)

The workflow is `.github/workflows/build-develop.yml`, displayed in the Actions tab as
**"Rock Build Pipeline."** On `develop` it is configured as:

```yaml
on:
  push:
    branches: [develop]
  workflow_dispatch:
```

So **any** push or merge to `develop` starts it. What it does, in order:

1. Builds Rock on a Windows runner (~20 minutes).
2. Writes a `web.ConnectionStrings.config` pointing at the Cloud SQL database.
3. Uploads the built `RockWeb/` to `gs://rock-deployments-<project>/<run number>/`.
4. Sets the target VM's `windows-startup-script-ps1` metadata to a script that copies that
   folder into `C:\inetpub\wwwroot\` and runs `iisreset`.
5. **Stops the VM. Waits 10 seconds. Starts the VM.** The copy happens on boot, because
   that's when the startup script runs.
6. Creates a health check.

Step 5 is the part to understand: **the deploy mechanism is a reboot.** Everything on that
VM goes down for the duration of a Windows restart, and the new files only land if the
startup script runs correctly on boot. There is no health gate before traffic returns and
no automated rollback.

> #### 🛑 Verify this before relying on Path A
>
> Which server this touches depends on the repository secret `GCP_VM_NAME`, which cannot be
> read from the repo — only DevOps can confirm it. Two possibilities, with very different
> consequences:
>
> - If it points at the **shared dev/test VM**, this pipeline maintains the shared reference
>   site (the same one [Trap 1](#trap-1-changes-to-themes-content-assets-and-styles-do-not-show-up)
>   mirrors `Themes/Content/Assets/Styles` from), and a merge to `develop` reboots the test
>   host — which will interrupt any PR environments in use.
> - If it points at **production**, a merge to `develop` reboots `connect.passion.team`
>   during whatever hours you merged.
>
> Evidence it is **not** currently deploying production: as of 2026-07-29, no
> `gs://rock-deployments-*` bucket existed in the production GCP project, so step 3 could
> never have delivered files there. Treat Path A as unproven for production until DevOps
> confirms the target.
>
> **Ask DevOps to confirm `GCP_VM_NAME` before you merge to `develop`.** Until then, treat
> every merge to `develop` as "reboots a shared server."

**How to watch it**

1. Actions tab → **Rock Build Pipeline** → your run.
2. Watch **Trigger Deployment (VM Restart)**.
3. Then wait for the site to answer. Rock's cold start is slow (roughly 1–2 minutes after
   the VM is up), so a few minutes of errors right after the restart is expected.
4. Load the site and confirm your change is actually present. A green pipeline only means
   the robot finished its steps — recall [Trap 5](#trap-5-a-green-build-does-not-prove-your-code-shipped).

**If it goes wrong:** re-running the workflow means another full build and another reboot.
Ask DevOps rather than repeatedly re-running — a faster targeted fix usually exists
(Path B).

### Path B — Operator hot-deploy (how urgent fixes actually ship)

For a fix to a plugin block, a full pipeline run and reboot is overkill. Because plugin
`.ascx`/`.ascx.cs` files compile at runtime (see
[Trap 7](#trap-7-plugin-code-errors-appear-in-the-browser-not-in-the-build)), copying the
two files onto the server is a complete deploy — no MSBuild, no `iisreset`.

This is **operator-only** (it requires RDP/SSH access to the production VM) and it is the
mechanism used for recent urgent fixes. It is not self-service, and you should not attempt
it. Know that it exists so you can ask for it.

What a well-run hot-deploy includes, so you know what to expect when you request one:

- A drift check that the live file matches what we think is there
- A hash-verified backup of the file being replaced, to `C:\RockDeployBackups\`
- The copy, then a post-deploy hash verification with automatic rollback on mismatch
- The rollback command printed for a human to keep

Note that writing either file **recycles the app domain for the whole site** — sessions
reset and in-process jobs restart briefly. It's fast, but it isn't invisible.

### Pre-flight checklist for any production change

Before your change goes to a live server:

- [ ] It was deployed to a PR environment and actually tested there — not just
      "it compiles"
- [ ] You confirmed your change is really present (not silently skipped —
      [Trap 5](#trap-5-a-green-build-does-not-prove-your-code-shipped))
- [ ] If it touches `Themes/Content/Assets/Styles`, you verified it some other way,
      because the PR environment could not show it
      ([Trap 1](#trap-1-changes-to-themes-content-assets-and-styles-do-not-show-up))
- [ ] If it includes a migration, DevOps has reviewed it
      ([Trap 3](#trap-3-a-migration-in-your-pr-changes-the-shared-database-for-everyone))
- [ ] Someone reviewed the PR
- [ ] The timing is deliberate. Both paths interrupt the site. Don't deploy during a
      service, an event, or a giving push. Prefer mid-morning weekdays with people around.
- [ ] Someone other than you knows it's happening

### Rollback

There is no rollback button.

- **Path A:** revert the commit on `develop` and let the pipeline run again — another full
  build and another reboot, so roughly 30 minutes to recover.
- **Path B:** restore the backup file the operator saved before the deploy.

Because recovery is slow, the pre-flight checklist matters more here than the deploy
instructions do.

---

## Part 6 — Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| Applied `rock-test:start`, nothing happened at all | Wrong base branch ([Trap 9](#trap-9-the-wrong-base-branch-fails-silently)), or PR is from a fork ([Trap 8](#trap-8-prs-from-forks-never-deploy)) | Check base branch against `.github/pr-test-environments.json`; edit the PR's base if wrong |
| Label `rock-test:failed` | Build or deploy error | Open **Logs** in the status comment; find the red step |
| Build succeeded but my change isn't there | A project failed to compile ([Trap 5](#trap-5-a-green-build-does-not-prove-your-code-shipped)) or the file is in a mirrored directory ([Trap 1](#trap-1-changes-to-themes-content-assets-and-styles-do-not-show-up)) | Search the build log for `Warning: Failed to build`; check whether your file is under `Themes/Content/Assets/Styles` |
| URL doesn't load at all | Not on VPN/office network | Connect to VPN, retry. If still failing, ask DevOps to confirm DNS |
| Certificate warning | Renewal job failing since 2026-05-18 ([Trap 6](#trap-6-expect-a-certificate-warning-right-now)) | Confirm VPN, click through. Report only if it's new information |
| First page load times out | Cold start | Reload once. Report if it fails twice |
| Yellow-screen compiler error on a plugin page | Plugin code-behind compiles at runtime ([Trap 7](#trap-7-plugin-code-errors-appear-in-the-browser-not-in-the-build)) | Read the file/line on the error page, fix, commit, redeploy |
| Environment was working, now says `stopped` | Idle 6+ hours | Add `rock-test:start` again |
| Test data vanished | Nightly sandbox refresh ([Trap 2](#trap-2-the-database-is-shared-and-it-resets)) | Recreate it; don't build multi-day scenarios |
| Data I didn't create | Shared sandbox DB ([Trap 2](#trap-2-the-database-is-shared-and-it-resets)) | Expected. Ask in team chat if it's blocking |
| Email/text/payment didn't happen | Disabled by design ([Trap 4](#trap-4-no-email-no-texts-no-payments-no-jobs)) | Not a bug. Ask DevOps for a testing plan if that's the change |
| Stuck on `deploying` for a long time | Stale Actions run | Ask DevOps: cancel the run, then re-add `rock-test:start` |
| "Run workflow" button failed instantly | Manual dispatch is broken ([Appendix C](#appendix-c--known-issues)) | Use labels instead |

When you report a problem, include: **PR number**, the **Logs** link from the status
comment, what you expected, and what happened. That turns a 20-minute back-and-forth into
one message.

---

## Part 7 — Who to ask

| Situation | Who |
| --- | --- |
| No repo access, no write access, 2FA problems | DevOps |
| VPN or network access | DevOps |
| Build failed and the log doesn't make sense | DevOps |
| My change is under `Themes/Content/Assets/Styles` and I can't verify it | DevOps |
| My PR includes a migration | DevOps — **before** applying `rock-test:start` |
| I need a production deploy | DevOps |
| I need to test email, SMS, payments, or a scheduled job | DevOps |
| Is this a file change or an admin-UI change? | Ask before starting — see Part 0 |

Deeper reference, if you want it:

- `Documentation/PR-Test-Environments-Developer-Runbook.md` — condensed version of Parts 2–3
- `Documentation/PR-Test-Environments-Operator-Runbook.md` — server side: paths, scripts,
  DNS, certificates, recovery
- `Documentation/Discussion Docs/PR-Test-Environments-PRD.md` — why this was built.
  Note: its "deploy over SSH" design was replaced by a Cloud Storage command queue; the
  operator runbook is current, the PRD is not.

---

## Appendix A — Working from a local clone (optional)

The browser path in Part 2 handles single-file edits well. Once you're changing several
files at once, a local copy is easier. **You still can't build or run Rock on a Mac** —
that's the whole reason the PR environments exist — so this only changes how you *edit*.
The build and test steps are identical.

One-time setup:

1. Install [GitHub Desktop](https://desktop.github.com) and sign in.
2. **File → Clone repository → passiondev/Rock.** It's a large repo; expect a wait.
3. Install [VS Code](https://code.visualstudio.com).

Each change:

1. In GitHub Desktop, **Current Branch → the base branch from Step 1**, then **Fetch
   origin** and **Pull** so you're current.
2. **Current Branch → New Branch**, name it `fix/…`.
3. **Repository → Open in Visual Studio Code**, make your edits, save.
4. Back in GitHub Desktop: review the diff in the left pane, write a summary, **Commit to
   `fix/…`**.
5. **Publish branch**, then **Create Pull Request** — that opens the browser at Step 4 of
   Part 2. Continue from there.

Two cautions:

- **Don't commit build output.** If GitHub Desktop shows hundreds of changed files in
  `bin/`, `obj/`, or `node_modules/`, don't commit — ask first.
- **Check your base branch when creating the PR**, same as Step 4. Cloning doesn't save you
  from Trap 9.

---

## Appendix B — Glossary

| Term | Meaning |
| --- | --- |
| **App pool** | The Windows process that runs a site. Each PR gets its own (`rock-pr-<n>`). |
| **Artifact** | The built zip the robot produces — `RockWeb-pr-42-aea0dba.zip`. |
| **Base branch** | The shared branch your change is destined for. |
| **Cold start** | The slow first request after a site starts, while Rock compiles and warms caches. |
| **Commit** | One saved change with a message. |
| **GitHub Actions** | GitHub's automation. The robot. |
| **IIS** | The Windows web server that runs Rock. |
| **Lava** | Rock's templating language. Some lives in files, most lives in the database. |
| **Migration** | A scripted database change that Rock applies automatically at startup. |
| **Obsidian** | Rock's newer Vue.js-based block framework. |
| **PR / pull request** | A request to merge a branch, and the page where testing and review happen. |
| **SHA** | The unique ID of a commit, e.g. `aea0dba`. The status comment shows which one is deployed. |
| **Sandbox DB** | The shared, sanitized, daily-refreshed database all PR environments use. |
| **Sticky comment** | The single automated status comment the robot keeps rewriting on your PR. |
| **VM** | The Windows virtual machine in Google Cloud that hosts the sites. |
| **WebForms** | The older ASP.NET framework most of Rock is built on. `.ascx` files are its building blocks. |

---

## Appendix C — Known issues

Not trainee tasks — these are for DevOps, listed so the team recognizes them instead of
re-diagnosing them. All verified 2026-07-31.

1. **Certificate renewal has been failing weekly since 2026-05-18** (last success
   2026-05-11). Users see TLS warnings on `pr-*` hosts. Workflow:
   `.github/workflows/pr-test-renew-certificates.yml`.

2. **Manual `workflow_dispatch` on the PR deploy and lifecycle workflows is broken.** Both
   read their input with `core.getInput('pr_number')` inside `actions/github-script`, which
   returns empty for `workflow_dispatch` inputs. It becomes PR `0` and the run dies with
   `GET /repos/passiondev/Rock/pulls/0 → 404` (see runs `25452191061`, `25452160173`).
   Labels are unaffected. Fix: read `context.payload.inputs.pr_number`, or pass the value
   through the action's `with:` block.

3. **The shared-asset overlay can silently discard PR changes** to `Themes`, `Content`,
   `Assets`, and `Styles` (`Deploy-PrEnvironment.ps1`, `robocopy /MIR`). Two parts:
   - **Unconfirmed:** nothing passes `-SharedAssetSourcePath` and nothing sets
     `PR_TEST_SHARED_ASSET_SOURCE_PATH`, so the source falls back to the test VM's IIS
     "Default Web Site" path. Whether the four directories exist there — i.e. whether the
     overlay is live or a no-op — needs one look at `C:\RockDeploy\logs`. Worth settling,
     since it decides whether theme work can be tested at all.
   - **Design:** if it is live, copy-if-absent semantics would be safer than `/MIR`, so
     server-only uploaded content still lands but git-tracked edits survive.
   - The command-queue result JSON carries only `status`/`error`, so no overlay diagnostics
     reach the PR or the Actions log. Surfacing them would make this self-diagnosable.

4. **`build-develop.yml` deploys by rebooting the VM** and has no health gate or rollback.
   Whether it targets production or the shared test VM depends on the `GCP_VM_NAME` secret
   and needs confirming; as of 2026-07-29 no `gs://rock-deployments-*` bucket existed in
   the production project, so it appears never to have delivered to production.

5. **Build failures are swallowed.** `continue-on-error: true` on the build step plus
   per-project warnings mean a deploy can be green while a changed project didn't compile.
   Only `Rock.dll`'s existence is enforced.

6. **The PR template is the upstream Rock one** — license agreement, `Fixes: #`,
   single-commit rule — none of which applies to internal work. An internal template would
   remove a real point of confusion for new contributors.

7. **`.env` is not in `.gitignore`.** On a public repo, one careless `git add .` publishes
   credentials.

8. **The pilot doc is stale.** `Documentation/Discussion Docs/PR-Test-Environments-Issues/12-pilot-rollout.md`
   still says deployment fails at an SSH step. That was fixed by the Cloud Storage command
   queue; PR #3 deployed successfully on 2026-05-05 (run `25381134573`). Its unchecked
   acceptance criteria are the QA run-through this training enables.

---

## Facts that go stale

Re-verify these before trusting this document:

| Fact | Value as of 2026-07-31 | Where to check |
| --- | --- | --- |
| Eligible base branch | `develop-17.6.1` | `.github/pr-test-environments.json` on `develop` |
| Environment domain | `rock-dev.connect.passion.team` | same file |
| Office/VPN allowlisted IP | `159.63.145.194` | Operator runbook / GCP firewall |
| Certificate renewal health | Failing since 2026-05-18 | Actions → PR Test Environment Certificate Renewal |
| What `GCP_VM_NAME` points to | **Unconfirmed** | Ask DevOps |
| Mirrored directories | `Themes,Content,Assets,Styles` | `Deploy-PrEnvironment.ps1` |
| Whether the overlay is live or a no-op | **Unconfirmed** | `C:\RockDeploy\logs` on the test VM |
| Typical build+deploy time | ~30 minutes | Recent Actions runs |

A Rock 17.6.1 → 18.3 upgrade is in progress, so the base branch is the most likely value to
change first.
