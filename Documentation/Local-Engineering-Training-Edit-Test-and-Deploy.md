# Local Engineering: How to Edit, Test, and Deploy Rock

**Audience:** Local Engineering team (no prior GitHub experience assumed)
**Covers:** `connect.passion.team` (Rock RMS) — the code and files behind the site
**Last verified:** 2026-08-10 (see [Facts that go stale](#facts-that-go-stale))

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
- [Part 5 — Deploying to staging and production](#part-5--deploying-to-staging-and-production)
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
| Site-wide stylesheets or static images shipped with the app | Files (`RockWeb/Styles/`, `RockWeb/Assets/`) | GitHub — this doc. Historical note: [Trap 1](#trap-1-themes-content-assets-and-styles-used-to-get-overwritten--fixed-2026-08-10) |

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

### Before your first change: two prerequisites

1. **A GitHub account, added to the `passiondev` organization with write access.**
   You need write access to create branches and to add labels. Ask DevOps. Without it, the
   "Commit changes" button will offer to fork the repo instead — see the warning below.
2. **Two-factor authentication (2FA) turned on.** Required by the organization.

That is the whole list. In particular **you do not need VPN or the office network** to open a
test environment: port 443 on the test VM is open to `0.0.0.0/0` (firewall rule
`https-from-world`), so the URLs work from home, a phone tether, or a hotel. The allowlisted
office IP `159.63.145.194` restricts only Remote Desktop (3389) and direct SQL Server (1433)
— DevOps paths you will never use from a browser.

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
| `RockWeb/Themes/<ThemeName>/` | Theme markup, LESS/CSS, theme Lava. See [Trap 1](#trap-1-themes-content-assets-and-styles-used-to-get-overwritten--fixed-2026-08-10) |
| `RockWeb/Plugins/org_passion/` | Passion's custom blocks (`.ascx` + `.ascx.cs`) |
| `RockWeb/Plugins/team_passion/` | More Passion custom blocks |
| `RockWeb/Blocks/` | Core Rock blocks (WebForms) |
| `RockWeb/Styles/`, `RockWeb/Assets/` | Shipped stylesheets and images. See [Trap 1](#trap-1-themes-content-assets-and-styles-used-to-get-overwritten--fixed-2026-08-10) |
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

<https://github.com/passiondev/Rock/blob/passion-18.4.1/.github/pr-test-environments.json>

```json
{
  "baseBranch": "passion-18.4.1",
  "environmentDomain": "rock-dev.connect.passion.team"
}
```

As of 2026-08-10 the eligible base branch is **`passion-18.4.1`**. Whatever `baseBranch`
says is what you must branch **from** and target **into**. If you target anything else, the
robot will quietly do nothing — no error, no comment.

`passion-18.4.1` is also the repository's **default branch**, so it is what you get by
default when you open the repo, and it is the Rock version production runs. Re-read the file
rather than trusting your memory — this value changes on every Rock upgrade.

### Step 2 — Find the file

Go to <https://github.com/passiondev/Rock>, press <kbd>t</kbd>, and type part of the
filename to search. Or navigate the folders using the map in Part 1.

Make sure you are viewing the file **on the base branch from Step 1**. The branch selector
is the button at the top-left of the file list. It should say `passion-18.4.1`; if it says
anything else, click it and switch.

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

This works from anywhere — no VPN, no office network. It is ordinary public HTTPS with a real
Let's Encrypt certificate, so you should see a normal padlock and no browser warning.

One thing to expect on first visit:

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

**Merging your PR into `passion-18.4.1` deploys it to staging automatically.** It does not
touch production, it does not reboot anything, and it does not need anyone's permission —
but roughly 30 minutes later your change is live on
<https://staging.rock-dev.connect.passion.team> for the whole team to see. That is the
point: staging is the shared "does it work on a real server" copy, and it always shows
what is on the trunk branch.

Getting from staging to **production** is a separate, deliberate act that a person has to
perform and a second person has to approve. Merging never triggers it. See
[Part 5](#part-5--deploying-to-staging-and-production).

### Step 11 — Cleanup, and the part you have to do yourself

Closing the PR is the only thing that triggers cleanup:

- **Merged PR** → environment destroyed immediately.
- **Closed without merging** → environment **stopped**, files kept.

That is the entire list. **Nothing reaps environments on a timer.** There is no idle
timeout and no scheduled sweep — the only scheduled job in the repo is certificate
renewal. A stopped environment keeps its files on the test VM until a person destroys it,
and an environment on an open PR stays running indefinitely.

So when you are finished with a PR's environment, add `rock-test:destroy` yourself. If you
stopped one and want it back, `rock-test:start` is a full rebuild — budget ~30 minutes
rather than expecting it to pop straight back up.

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

### Trap 1: Themes, Content, Assets, and Styles used to get overwritten — fixed 2026-08-10

*Keeping this trap on the list because you may have been told the old behaviour, and because
it explains why a theme change might not have appeared for you in the past.*

After your build is installed, the deploy script copies these four directories from a shared
source on the server over the top of your copy:

```
Themes/   Content/   Assets/   Styles/
```

The point of the overlay is to pull in uploaded content and server-side theme state that
isn't in git, so a PR environment resembles the real site.

**The bug:** it used `robocopy /MIR` — mirror — which overwrites files that differ and
deletes files that aren't in the source. Any edit your PR made under those four
directories was replaced by the shared copy before you ever saw it, and new files you added
there were deleted. A theme change could not be tested at all, and the deploy still went
green.

**The fix:** the overlay now runs `robocopy /E /XC /XN /XO`, which copies only files that
are *absent* at the destination. Server-only uploaded content still lands; anything your
branch changed survives. `/MIR` appears in the script today only inside the comment
explaining why it isn't used.

So theme and asset edits **do** show up now. If one doesn't:

- Confirm the file is actually in your PR's diff, on the right path under `RockWeb/`.
- LESS is compiled by Rock's theme compiler, not by the build. If you edited `.less`, check
  Admin → CMS → Themes and recompile.
- Hard-refresh. Rock fingerprints most assets, but not all of them.

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

### Trap 6: A 500 on every page is probably not your change

If *every* page of your environment returns a 500 — not one broken block, the whole site —
the odds are it has nothing to do with your PR. A platform-level fault looks exactly like
"I broke it," and the error page is deliberately unhelpful about the difference.

**How to tell in thirty seconds:** open <https://staging.rock-dev.connect.passion.team>.
Staging runs trunk with none of your changes in it. If staging is broken too, it is not you.

Worth knowing why the error page is useless here. Rock's `web.config` sets
`customErrors defaultRedirect="/Error.aspx"`, so a failure is supposed to render a friendly
Rock error page. But when the fault happens at *application startup*, `/Error.aspx` cannot
start either, so IIS gives up and returns a generic 1,789-byte page that says only that
"another exception occurred while executing the custom error page." That page is the same
for a missing assembly, a bad connection string, and a dozen other causes — so never try to
read the cause off it.

This is not hypothetical. On 2026-08-10 a single missing framework assembly
(`Google.Protobuf.dll`, absent from every build artifact) took down staging and every PR
environment at once, and the builds all stayed green. Diagnosing it needed the Windows
event log on the VM, which is a DevOps task.

Practically: **check staging, then report it** with your PR number. If both are down, say so
— that one sentence saves an hour.

### Trap 7: Plugin blocks are not in this repository at all

`RockWeb/Plugins/.gitignore` consists of exactly one rule — `*/*` — so every plugin subfolder
is ignored. That is an upstream Rock convention: plugins are treated as installed packages,
not as source. Verified 2026-08-10: git tracks precisely two files under that directory
(`.gitignore` and `readme.txt`), and **zero** files matching `org_passion` or `team_passion`
anywhere in the repository. The 448 core blocks under `RockWeb/Blocks/` are tracked normally,
so this applies only to plugins.

Two consequences, and both will surprise you:

- **A `pr-*` environment shows no plugin blocks.** The build packages what git has, and the
  shared-asset overlay backfills only `Themes`, `Content`, `Assets`, and `Styles`. A page
  built from an `org_passion` or `team_passion` block will not render on a test site.
- **You cannot ship a plugin-block change through this pipeline.** There is nothing to
  commit, because the file is not tracked. Changing one is a separate, manual, server-side
  job. Ask DevOps before you start.

Production keeps its plugins regardless, because a production deploy copies with robocopy
`/E` and **no `/PURGE`** — files already on the server that the artifact does not contain are
left untouched. That is deliberate, and it is why plugin folders survive a deploy that never
contained them.

If you need plugin pages to work on test sites, that is a config change, not a rewrite: the
overlay list is read from `PR_TEST_SHARED_ASSET_DIRECTORIES`. It is on the open-items list.

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

## Part 5 — Deploying to staging and production

> ### ⚠️ The one thing to remember
>
> **Merging to `passion-18.4.1` deploys to staging automatically. Nothing deploys to
> production without a person choosing it and a second person approving it.**
>
> There is no way to reach production by merging, by pushing, or by adding a label. The
> only door is a manual run of the **Deploy Production** workflow, and that run stops and
> waits for an approver before it touches anything.

Code reaches a live server by three routes. Two are self-service; the third is not.

| | Trigger | Target | Who | Downtime |
| --- | --- | --- | --- | --- |
| **Path A** | merge to `passion-18.4.1` | staging | anyone | none |
| **Path B** | manual + approval | production | DevOps / Global Eng | app pool recycle |
| **Path C** | operator, by hand | production | operator only | app domain recycle |

### Path A — Staging (automatic on merge to the trunk branch)

Workflow: `.github/workflows/staging-deploy.yml`, shown in Actions as **"Deploy Staging."**

```yaml
on:
  push:
    branches: [passion-18.4.1]
  workflow_dispatch:
```

Merging your PR is the trigger. Roughly 30 minutes later your change is live at
<https://staging.rock-dev.connect.passion.team>. What it does, in order:

1. Resolves the commit that was just merged.
2. Builds Rock on a Windows runner — the same build the PR environments use (~25 min).
3. Writes a `web.ConnectionStrings.config` pointing at the **sandbox** database.
4. Queues a deploy command for the test VM, which unpacks the artifact into its own IIS
   site and waits for the site to answer.

Staging is **its own IIS site on the test VM**, on the **sandbox** database. It cannot
reach production data and it cannot take production down. Documentation-only commits are
skipped — a 30-minute Windows build per typo fix isn't a good trade.

If two merges land close together the newer one supersedes the older; you'll see the first
run cancelled. That's intended, not a failure.

### Path B — Production (manual, approved, dry run by default)

Workflow: `.github/workflows/production-deploy.yml`, shown in Actions as
**"Deploy Production."** It has exactly one trigger: `workflow_dispatch`. No push, no
schedule, no label.

Running it:

1. Actions tab → **Deploy Production** → **Run workflow**.
2. **Ref** — leave it at `passion-18.4.1` unless you are rolling back to an older commit.
3. **Apply** — leave it **unchecked** the first time. Unchecked is a dry run: it reports
   exactly what it would copy and changes nothing.
4. The run builds first, then **stops at an approval gate** and waits. The `production`
   GitHub Environment carries the required-reviewer rule, and the reviewer gets a
   notification.
5. Once approved, the deploy runs.

The gate sits **after** the build on purpose — nobody should be asked to approve a commit
that turns out not to compile.

What the deploy does on the server, in order:

1. Downloads and unpacks the artifact.
2. **Backs up the current site** to `C:\RockBackups\production\<utc>-<sha>`.
3. Stops the app pool and waits for the worker process to release its file handles.
4. Copies the new files over the site, **preserving** `Content`, `App_Data`, `Logs`,
   `Uploads` and `web.ConnectionStrings.config`.
5. Starts the app pool and polls the site until it answers.

Two design decisions worth knowing:

- **It never mirrors.** Uploaded content, the Rock cache, and the logs are server-owned
  data, not build output, so the copy cannot delete them.
- **CI never writes production's connection string.** The file already on the box is left
  alone, which means the production database credentials do not have to exist as a GitHub
  secret and a deploy cannot point production at the wrong server.

Downtime is an app pool recycle plus Rock's cold start — Rock applies its EF and plugin
migrations on the first request afterward, which is why step 5 waits several minutes before
calling the site unhealthy.

> **Status as of 2026-08-10:** every step above is built, tested, and proven end to end
> against staging. The one remaining piece is installing the command-queue agent on the
> production VM, which is deliberately being done together with DevOps rather than
> unattended. Until that is installed, a production run will build, gate, queue — and then
> time out waiting for a server that isn't listening yet. That is the expected failure and
> it changes nothing on production.

### Path C — Operator hot-deploy (how urgent plugin fixes ship)

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
      ([Trap 1](#trap-1-themes-content-assets-and-styles-used-to-get-overwritten--fixed-2026-08-10))
- [ ] If it includes a migration, DevOps has reviewed it
      ([Trap 3](#trap-3-a-migration-in-your-pr-changes-the-shared-database-for-everyone))
- [ ] Someone reviewed the PR
- [ ] The timing is deliberate. Both paths interrupt the site. Don't deploy during a
      service, an event, or a giving push. Prefer mid-morning weekdays with people around.
- [ ] Someone other than you knows it's happening

### Rollback

- **Path A (staging):** merge a revert, or re-run **Deploy Staging** against an older
  commit. Nobody outside the team sees staging, so this is never urgent.
- **Path B (production):** re-run **Deploy Production** with **Ref** set to the previous
  good commit. This is the intended rollback — the workflow takes any ref, not just the
  trunk, so rolling back is the same operation as rolling forward. Budget another full
  build (~30 min).
  For a faster recovery, the deploy also left a copy of the previous site at
  `C:\RockBackups\production\<utc>-<sha>` on the VM, which an operator can restore without
  waiting for a build.
- **Path C:** restore the backup file the operator saved before the hot-deploy.

Recovery still costs a build, so the pre-flight checklist matters more than the deploy
instructions do.

---

## Part 6 — Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| Applied `rock-test:start`, nothing happened at all | Wrong base branch ([Trap 9](#trap-9-the-wrong-base-branch-fails-silently)), or PR is from a fork ([Trap 8](#trap-8-prs-from-forks-never-deploy)) | Check base branch against `.github/pr-test-environments.json`; edit the PR's base if wrong |
| Label `rock-test:failed` | Build or deploy error | Open **Logs** in the status comment; find the red step |
| Build succeeded but my change isn't there | A project failed to compile ([Trap 5](#trap-5-a-green-build-does-not-prove-your-code-shipped)) or, before 2026-08-10, the file was under an overlaid directory ([Trap 1](#trap-1-themes-content-assets-and-styles-used-to-get-overwritten--fixed-2026-08-10)) | Search the build log for `Warning: Failed to build`. Build failures now fail the run, so a green build really did compile |
| URL doesn't load at all | Environment never deployed, or DNS | It is *not* VPN — these hosts are public. Confirm the status comment says `deployed`, then ask DevOps to check DNS |
| Every page returns a 500 | Usually platform-wide, not your change ([Trap 6](#trap-6-a-500-on-every-page-is-probably-not-your-change)) | Open staging. If it is broken too, report both with your PR number |
| Certificate warning | Unexpected — `pr-*` hosts carry real Let's Encrypt certificates | Report it. Do not click through as a matter of course; on these hosts a warning is new information |
| First page load times out | Cold start | Reload once. Report if it fails twice |
| A plugin page is missing or broken on a test site | Plugin blocks are not in the repo, so no test environment has them ([Trap 7](#trap-7-plugin-blocks-are-not-in-this-repository-at-all)) | Not a bug in your PR. Verify that page in production instead, and talk to DevOps |
| Environment was working, now says `stopped` | Someone added `rock-test:stop`, or the PR was closed without merging — nothing stops it on a timer | Add `rock-test:start` again (full rebuild, ~30 min) |
| Test data vanished | Nightly sandbox refresh ([Trap 2](#trap-2-the-database-is-shared-and-it-resets)) | Recreate it; don't build multi-day scenarios |
| Data I didn't create | Shared sandbox DB ([Trap 2](#trap-2-the-database-is-shared-and-it-resets)) | Expected. Ask in team chat if it's blocking |
| Email/text/payment didn't happen | Disabled by design ([Trap 4](#trap-4-no-email-no-texts-no-payments-no-jobs)) | Not a bug. Ask DevOps for a testing plan if that's the change |
| Stuck on `deploying` for a long time | Stale Actions run | Ask DevOps: cancel the run, then re-add `rock-test:start` |
| "Run workflow" button failed instantly | Wrong `pr_number`, or the PR does not target the eligible base branch | Check the number, then [Trap 9](#trap-9-the-wrong-base-branch-fails-silently) |

When you report a problem, include: **PR number**, the **Logs** link from the status
comment, what you expected, and what happened. That turns a 20-minute back-and-forth into
one message.

---

## Part 7 — Who to ask

| Situation | Who |
| --- | --- |
| No repo access, no write access, 2FA problems | DevOps |
| Remote Desktop or direct SQL access to the test VM (needs the office IP) | DevOps |
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
re-diagnosing them. All verified 2026-08-10.

### Still open

1. **Certificate renewal works for `pr-*` but has not yet issued one for `staging`.**
   Measured 2026-08-10: `pr-4` serves a valid Let's Encrypt certificate issued that day
   (expires 2026-11-08) and verifies cleanly, so the renewal path is functional — the earlier
   revision of this document, which said renewal was failing and told readers to click
   through warnings on every host, was wrong. `staging` is a newer host and still serves an
   untrusted certificate. Renewal only covers environments that have an `env.json` manifest
   marked `deployed` under `C:\RockTestEnvs`, and staging's deploys have been failing, so it
   has not been picked up yet. Re-dispatch renewal once a staging deploy actually succeeds,
   and confirm from the run log that it names `staging` — the run on 2026-08-10 at 17:53
   reported `succeeded` after 90 seconds with no per-host output, which is what "found nothing
   to do" looks like. Workflow: `.github/workflows/pr-test-renew-certificates.yml`.

2. **The production command-queue agent is not installed yet.** Everything upstream of it —
   build, approval gate, backup, copy, health check — is proven against staging. Until the
   scheduled task exists on the production VM against queue `commands-prod`, a production
   deploy will build, gate, queue, and then time out. Being done with DevOps rather than
   unattended.

3. **Production deploys from the trunk, and only the trunk.** Each branch declares its own Rock
   version: the trunk is **18.4.1**, `develop` is **19.0.3**, `staging` is **17.6.1**.
   Production's own assemblies are 18.x — a mix of 18.1.0, 18.3.1, and 18.4.1 — so a trunk
   deploy brings the older ones forward, which is what production needs. Deploying `develop`
   would be a jump to Rock 19 whose database migrations cannot be walked back; the workflow
   should refuse any ref but the trunk. The remaining real risk is narrower than the branch
   question: production's `Rock.Migrations.dll` is 18.3.1 and the trunk's is 18.4.1, so the
   first deploy runs the 18.3.1 → 18.4.1 migrations at startup. That needs a verified database
   backup taken immediately beforehand, which is why the production path is built and proven
   but deliberately unfired.

4. **`GCP_COMPUTE_PROJECT_ID` is a dead secret** — no workflow references it. Worth removing
   so the secret list reflects reality.

5. **The `production` GitHub Environment and its repo variables do not exist yet.** Without
   the Environment, the approval gate in `production-deploy.yml` passes through
   unchallenged. Needs: Environment `production` with required reviewers, plus variables
   `PRODUCTION_HOST_NAME`, `PRODUCTION_SITE_PATH`, `PRODUCTION_SITE_NAME`.

6. **Stale branches.** `develop-17.6.1`, `deploy/ptp-14803-18.4.1`, `bump`, `fix/group-sync`,
   and `pilot/pr-test-env-doc-smoke-v1761` are superseded by `passion-18.4.1`. Pruning them
   removes several ways to target the wrong base branch. `develop` and `staging` are **not**
   in that set and must not be pruned — between them they hold the only copy of some plugin
   code, including five RSVP and authentication files where `staging`'s version is newer than
   `develop`'s.

7. **The pilot doc is stale.** `Documentation/Discussion Docs/PR-Test-Environments-Issues/12-pilot-rollout.md`
   still says deployment fails at an SSH step. That was fixed by the Cloud Storage command
   queue.

8. **Nothing reaps abandoned environments.** Closing a PR stops its environment but never
   destroys it, and an environment on a long-lived open PR runs forever. The only scheduled
   workflow in the repo is certificate renewal — there is no idle timeout and no sweep. Left
   alone this grows the test VM's disk until it fills. Wants a scheduled job that stops
   environments idle past some threshold and destroys ones whose PR closed more than a week
   ago. *(Earlier revisions of this document claimed both behaviours already existed. They
   never did.)*

9. **The deploy health check accepts any TLS certificate.**
   `Deploy-RockEnvironment.ps1` sets `ServerCertificateValidationCallback = { $true }`
   before polling the site, so a deploy is green whether the certificate is valid, expired,
   or self-signed. That is deliberate — a brand-new host has no certificate until its first
   successful ACME run, so gating the health check on TLS would deadlock the very first
   deploy of any environment (exactly staging's situation in item 1) — but it
   means CI will never tell us the certificate is broken. Once renewal is green, this should
   become a separate non-blocking check that reports certificate expiry.

### Fixed since the last revision — recorded so nobody re-diagnoses them

| Was | Now |
| --- | --- |
| The test VM had been `TERMINATED` since 2026-05-11, so every deploy timed out | Running, and the queue agent round-trips a command in under a minute |
| MSBuild was pinned to the VS `2022` install folder in 5 places; the runner image moved it to `18` | Located at run time via `vswhere.exe`, the only stable path |
| `continue-on-error: true` plus a trailing `exit 0` forced the build step green, so a failed compile still packaged and deployed | Build failures fail the run; verification gates on `Rock.dll`, `Rock.Blocks.dll`, `Rock.Rest.dll`, `Rock.Migrations.dll`, `Rock.WebStartup.dll`, `Rock.ViewModels.dll`, and `*.obs.js` |
| `Rock.JavaScript.Obsidian.Blocks` was never built and no `.obs.js` is tracked in git, so **every deployed PR site had zero working Obsidian blocks** | Built in CI, after the framework bundle it imports, and verified in the artifact |
| The shared-asset overlay ran `robocopy /MIR`, destroying any PR edit under `Themes/Content/Assets/Styles` | `robocopy /E /XC /XN /XO` — copies only what is absent, so branch edits survive |
| `workflow_dispatch` on the PR deploy and lifecycle workflows read `core.getInput('pr_number')`, which is always empty there, so manual redeploys 404'd on PR `0` | Reads `context.payload.inputs.pr_number` |
| All PR environments and both new environments polled one shared GCS queue prefix, so a second VM would have raced for every command | One queue prefix per VM (`commands`, `commands-prod`) |
| The PR template was upstream Rock's — CLA, `Fixes: #`, single-commit rule | Internal template, with upstream's available at `?template=upstream-contribution.md` |
| `.env` was not ignored | `.env` and `*.env` ignored; `!*.example.env` kept |

---

## Facts that go stale

Re-verify these before trusting this document:

| Fact | Value as of 2026-08-10 | Where to check |
| --- | --- | --- |
| Eligible base branch / repo default branch | `passion-18.4.1` | `.github/pr-test-environments.json` |
| Environment domain | `rock-dev.connect.passion.team` | same file |
| Staging URL | `staging.rock-dev.connect.passion.team` | `.github/workflows/staging-deploy.yml` |
| Office allowlisted IP — **RDP (3389) and SQL (1433) only**, never HTTPS | `159.63.145.194` | GCP firewall rules |
| Public reachability of test URLs | 443 and 80 open to `0.0.0.0/0` (`https-from-world`, `pr-test-acme-http`) | GCP firewall rules |
| Certificate health, `pr-*` | Valid Let's Encrypt; `pr-4` issued 2026-08-10, expires 2026-11-08 | `curl -v https://pr-<n>.rock-dev.connect.passion.team` |
| Certificate health, `staging` | **Untrusted** as of 2026-08-10 — renewal not yet run for this new host | same command against the staging URL |
| Overlaid directories | `Themes,Content,Assets,Styles`, copy-if-absent only | `Deploy-PrEnvironment.ps1` |
| Directories a deploy never touches | `Content`, `App_Data`, `Logs`, `Uploads`, `web.ConnectionStrings.config` | `Deploy-RockEnvironment.ps1` |
| Typical build+deploy time | ~30 minutes | Recent Actions runs |

The base branch changes on every Rock upgrade and is the most likely value here to go stale.
When it does, `.github/pr-test-environments.json` is the single place that decides it.
