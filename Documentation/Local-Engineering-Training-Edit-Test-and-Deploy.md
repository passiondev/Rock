# Local Engineering: How to Edit, Test, and Deploy Rock

**Audience:** Local Engineering team (no prior GitHub experience assumed)
**Covers:** `connect.passion.team` (Rock RMS) — the code and files behind the site
**Last verified:** 2026-08-19 (see [Facts that go stale](#facts-that-go-stale))

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

Open this file and read it. The `HEAD` in the URL always resolves to whatever the default
branch is today, so the link never needs updating:

<https://github.com/passiondev/Rock/blob/HEAD/.github/pr-test-environments.json>

```json
{
  "baseBranch": "passion-<version>",
  "environmentDomain": "rock-dev.connect.passion.team"
}
```

Whatever `baseBranch` says is what you must branch **from** and target **into**. If you
target anything else, the robot will quietly do nothing — no error, no comment.

That value is also the repository's **default branch**, so it is what you get by default when
you open the repo. The two are kept in step deliberately, and a test asserts it. Re-read the
file rather than trusting your memory — the value is replaced at every Rock upgrade, and it
is named after the Rock version, not after the environment.

### Step 2 — Find the file

Go to <https://github.com/passiondev/Rock>, press <kbd>t</kbd>, and type part of the
filename to search. Or navigate the folders using the map in Part 1.

Make sure you are viewing the file **on the base branch from Step 1**. The branch selector
is the button at the top-left of the file list. It should already show that branch, because
it is the repository default; if it shows anything else, click it and switch.

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
rock:start
```

That's it. That label is the button. Within a minute the robot adds `rock:queued` and
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

**Budget about 40 minutes.** The build is the slow part — it compiles all of Rock plus
three JavaScript bundles on a fresh Windows machine every time. This is normal, not stuck.
Go do something else; the comment updates itself.

### Step 7 — Open your environment

```
https://pr-<your PR number>.rock-dev.connect.passion.team
```

This works from anywhere — no VPN, no office network.

Two things to expect on first visit:

- **A certificate warning only on a brand-new environment.** As of 2026-08-11, `staging` and
  the existing `pr-*` hosts hold real Let's Encrypt certificates and show a normal padlock —
  measured after a deploy, so it is not a one-off. A *newly created* PR environment is the
  exception: it starts on a self-signed placeholder until the weekly renewal issues a
  certificate for its host name, so a warning on a site you just spun up is expected and not a
  sign that anything is wrong. Click through it once for these
  `*.rock-dev.connect.passion.team` hosts — and nowhere else.

- **A very slow first page load.** Rock compiles and warms up on the first request; a
  minute or more is normal. Subsequent pages are fast. If it times out, reload once
  before reporting a problem.

  This happens *again* after **20 minutes** with nobody using the site — the server shuts the
  site down when it is idle and has to start it back up on the next request. So a test site
  that was quick this morning can be slow again this afternoon. Measured 2026-08-11: a site
  answered in 0.2 seconds, sat untouched for about half an hour, and then took 62 seconds.
  Nothing was wrong with it. If you are about to demo your change to somebody, open the page a
  few minutes beforehand so they never see the slow load.

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

- **Add `rock:start` again** to rebuild with your new commit. If the label is already
  on the PR, remove it and re-add it. Or
- **Add `rock:auto` once**, and every future push to your branch rebuilds
  automatically. Convenient while iterating; remember each rebuild is another ~40 minutes
  of build time, and pushing again cancels the in-flight run.

### Step 10 — Review and merge

1. Add a reviewer in the sidebar. They can open the same PR URL and check your work.
2. Once approved, click **Merge pull request**.

**Merging your PR into the default branch deploys it to staging automatically.** It does not
touch production, it does not reboot anything, and it does not need anyone's permission —
but roughly 40 minutes later your change is live on
<https://staging.rock-dev.connect.passion.team> for the whole team to see. That is the
point: staging is the shared "does it work on a real server" copy, and it always shows
what is on the trunk branch.

Getting from staging to **production** is a separate, deliberate act that a person has to
perform and a named reviewer has to approve. Merging never triggers it. See
[Part 5](#part-5--deploying-to-staging-and-production).

### Step 11 — Cleanup, and the part you have to do yourself

Closing the PR is the only thing that triggers cleanup:

- **Merged PR** → environment destroyed immediately.
- **Closed without merging** → environment **stopped**, files kept.

That is the entire list. **Nothing reaps environments on a timer.** There is no idle
timeout and no scheduled sweep — the only scheduled job in the repo is certificate
renewal. A stopped environment keeps its files on the test VM until a person destroys it,
and an environment on an open PR stays running indefinitely.

So when you are finished with a PR's environment, add `rock:destroy` yourself. If you
stopped one and want it back, `rock:start` is a full rebuild — budget ~40 minutes
rather than expecting it to pop straight back up.

---

## Part 3 — Label reference

**You apply these:**

| Label | What it does |
| --- | --- |
| `rock:start` | Build the PR's latest commit and deploy it. Use for the first deploy, for redeploys, and to wake a stopped environment. **Always a full rebuild (~30 min)** — there is no quick-start path. |
| `rock:stop` | Stop the site but keep all files and state on the server. Note that waking it back up still means `rock:start`, so budget the full rebuild. |
| `rock:destroy` | Delete the site, app pool, files, and state. Use when fully done. |
| `rock:auto` | Opt in to automatic rebuild on every push to this PR. Apply once. |

**The robot applies these — don't touch them:**

`rock:queued` · `rock:building` · `rock:deploying` · `rock:deployed` ·
`rock:stopped` · `rock:failed`

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
- The sandbox **is not** refreshed on a schedule, despite what this section said until
  2026-08-17. Measured against GCP: it was seeded once on 2026-04-14 and has had no data
  load since. Your test data persists — which sounds better than it is. Nothing resets it,
  so it accumulates everyone's leftovers and every PR's migrations, and it drifts further
  from production every week. Don't treat "it worked in a PR environment" as "it works
  against production-like data."
- It's sanitized, not fake-from-scratch — still treat it as sensitive. No screenshots of
  it in public places.

### Trap 3: A migration in your PR changes the shared database for everyone

Rock runs pending Entity Framework and plugin migrations **automatically on startup**
(`Rock.WebStartup/RockApplicationStartupHelper.cs:130`). Because all PR environments share
one database, starting your environment applies your migration to the database everyone
else is using — and it can't be undone by stopping your environment.

**If your change touches `Rock.Migrations/` or adds a plugin migration, talk to DevOps
before applying `rock:start`.** This is the one case where the self-service path is
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

### Trap 7: Plugin blocks and our themes are not on this branch at all

`RockWeb/Plugins/.gitignore` consists of exactly one rule — `*/*` — so every plugin subfolder
is ignored. That is an upstream Rock convention: plugins are treated as installed packages,
not as source. Verified 2026-08-10: on the trunk git tracks precisely two files under
that directory (`.gitignore` and `readme.txt`) and **zero** paths matching `org_passion` or
`team_passion`. (They do exist on the old `develop` branch — 78 of them — which is why that
branch cannot be deleted yet. They are just not on the branch you work from.) The 448 core
blocks under `RockWeb/Blocks/` are tracked normally.

**The same is true of our themes, which is the part that catches people out.** Verified
2026-08-11: `RockWeb/Themes/` tracks 13 themes and every one is a stock Rock theme. `CONNECT`
and `Checkin-Guest` — the themes that actually draw Passion's pages — are not there. So the
sign-in page at `/page/3` and the kiosk at `/checkin` are rendered by files this branch does
not contain, and neither does your branch. **Every page a signed-out visitor can reach on a
test site comes from a file outside version control**, with one exception: `Http404Error.aspx`,
Rock's "page not found". If you want a two-second check that a test URL is really running your
branch, put a nonsense path on the end of it and look at *that* page.

Two consequences, and both will surprise you:

- **You cannot ship a plugin-block change through this pipeline.** There is nothing to
  commit, because the file is not tracked. Changing one is a separate, manual, server-side
  job. Ask DevOps before you start.
- **A test site shows the _server's_ copy of a plugin or a Passion theme, never your
  branch's.** Since 2026-08-11 the shared-asset overlay backfills `Plugins` alongside
  `Themes`, `Content`, `Assets`, and `Styles`, so plugin pages do render on `pr-*` and
  `staging`. What renders is whatever is installed on the test server, though. Your branch
  cannot change it, and two open PRs cannot show two different versions of it. The practical
  version: **if you changed something and the test site looks identical, that is not evidence
  your change failed to deploy** — check whether the page you are looking at is even one this
  repository owns before you go hunting.

That backfill was not a nicety. Passion's login page *is* a plugin block, so until it existed
every test site opened on

```
Error Loading Block: Login
The file '/Plugins/org_passion/Security/Login.ascx' does not exist.
```

and nobody could sign in to a test site at all. If you see that error again, it is not your
change — say so in the PR and ask DevOps to check the overlay.

Production keeps its plugins regardless, because a production deploy copies with robocopy
`/E` and **no `/PURGE`** — files already on the server that the artifact does not contain are
left untouched. That is deliberate, and it is why plugin folders survive a deploy that never
contained them. Nothing about the test-site overlay reaches production: it runs only for a
site that owns its whole directory, which production is not.

### Trap 8: PRs from forks never deploy

Only branches in `passiondev/Rock` itself can deploy, because these environments sit on
shared infrastructure with sanitized data. A PR opened from your personal fork is skipped
with no environment and no error on the PR. If this happens, you need write access on the
repo — see Part 1.

### Trap 9: The wrong base branch fails silently

Covered in Step 1, repeated because it costs the most time: if your PR's base branch isn't
the one in `.github/pr-test-environments.json`, applying `rock:start` does
**nothing**. No comment, no failure, no label change. If you apply the label and nothing at
all happens within a couple of minutes, check your base branch first.

You can fix it without redoing your work: on the PR, click **Edit** next to the title, then
change the base branch dropdown.

---

## Part 5 — Deploying to staging and production

> ### ⚠️ The one thing to remember
>
> **Merging to the default branch deploys to staging automatically. Nothing deploys to
> production without a person choosing it and a named reviewer approving it.**
>
> There is no way to reach production by merging, by pushing, or by adding a label. The
> only door is a manual run of the **Deploy Production** workflow, and that run stops and
> waits for an approver before it touches anything.

Code reaches a live server by three routes. Two are self-service; the third is not.

| | Trigger | Target | Who | Downtime |
| --- | --- | --- | --- | --- |
| **Path A** | merge to the default branch | staging | anyone | none |
| **Path B** | manual + approval | production | DevOps / Global Eng | app pool recycle |
| **Path C** | operator, by hand | production | operator only | app domain recycle |

### Path A — Staging (automatic on merge to the trunk branch)

Workflow: `.github/workflows/staging-deploy.yml`, shown in Actions as **"Deploy Staging."**

```yaml
on:
  push:
    branches: [passion-<version>]   # the trunk — renamed at every Rock upgrade
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
2. **Ref** — leave it at the default it offers unless you are rolling back to an older
   commit. Note the production workflow is pinned to the branch **production** runs, which
   during a Rock upgrade is deliberately *not* the repository default.
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
5. Starts the app pool and polls the site until it answers — over the server's own loopback,
   with the public host name in the `Host` header. Same site, same app pool, same app domain,
   so it proves the application started without depending on DNS or the route in from
   outside. GitHub then loads the public URL itself, from the internet, which is the only
   vantage point that can honestly answer "can a person actually open this".

Two design decisions worth knowing:

- **It never mirrors.** Uploaded content, the Rock cache, and the logs are server-owned
  data, not build output, so the copy cannot delete them.
- **CI never writes production's connection string.** The file already on the box is left
  alone, which means the production database credentials do not have to exist as a GitHub
  secret and a deploy cannot point production at the wrong server.

Downtime is an app pool recycle plus Rock's cold start — Rock applies its EF and plugin
migrations on the first request afterward, which is why step 5 waits several minutes before
calling the site unhealthy.

> **Status as of 2026-08-19:** every step above is built, tested, and proven end to end
> against staging. The one remaining piece is installing the command-queue agent on the
> production VM, which is deliberately being done together with DevOps rather than
> unattended. Until that is installed, a production run will build, gate, queue — and then
> time out waiting for a server that isn't listening yet. That is the expected failure and
> it changes nothing on production.

### Path C — Operator hot-deploy (how urgent plugin fixes ship)

For a fix to a plugin block, a full pipeline run and reboot is overkill. Because plugin
`.ascx`/`.ascx.cs` files compile at runtime (see
[Trap 7](#trap-7-plugin-blocks-and-our-themes-are-not-on-this-branch-at-all)), copying the
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
| Applied `rock:start`, nothing happened at all | Wrong base branch ([Trap 9](#trap-9-the-wrong-base-branch-fails-silently)), or PR is from a fork ([Trap 8](#trap-8-prs-from-forks-never-deploy)) | Check base branch against `.github/pr-test-environments.json`; edit the PR's base if wrong |
| Label `rock:failed` | Build or deploy error | Open **Logs** in the status comment; find the red step |
| Build succeeded but my change isn't there | A project failed to compile ([Trap 5](#trap-5-a-green-build-does-not-prove-your-code-shipped)) or, before 2026-08-10, the file was under an overlaid directory ([Trap 1](#trap-1-themes-content-assets-and-styles-used-to-get-overwritten--fixed-2026-08-10)) | Search the build log for `Warning: Failed to build`. Build failures now fail the run, so a green build really did compile |
| URL doesn't load at all | Environment never deployed, or DNS | It is *not* VPN — these hosts are public. Confirm the status comment says `deployed`, then ask DevOps to check DNS |
| Every page returns a 500 | Usually platform-wide, not your change ([Trap 6](#trap-6-a-500-on-every-page-is-probably-not-your-change)) | Open staging. If it is broken too, report both with your PR number |
| Certificate warning | Expected only on a **brand-new** environment, which starts self-signed until the weekly renewal covers its host name. `staging` and existing `pr-*` hosts hold real Let's Encrypt certificates (measured 2026-08-11, after a deploy) | Click through for `*.rock-dev.connect.passion.team` only. Report it if you see it on an established host, or on any *other* domain |
| First page load times out | Cold start | Reload once. Report if it fails twice |
| The page looks exactly the same as before my change | Very likely the page is drawn by a file this branch does not contain — the sign-in page, `/checkin`, and anything on the `CONNECT` theme all are ([Trap 7](#trap-7-plugin-blocks-and-our-themes-are-not-on-this-branch-at-all)) | Add a nonsense path to the test URL and look at the 404 page. It is the one page a signed-out visitor sees that comes from this branch, so it tells you whether your build actually deployed |
| A plugin page looks wrong on a test site, or shows `Error Loading Block` | Plugin blocks are not in the repo; test sites borrow the server's copy through the overlay ([Trap 7](#trap-7-plugin-blocks-and-our-themes-are-not-on-this-branch-at-all)) | Not a bug in your PR, and your branch cannot fix it. Verify that page in production instead, and talk to DevOps |
| Environment was working, now says `stopped` | Someone added `rock:stop`, or the PR was closed without merging — nothing stops it on a timer | Add `rock:start` again (full rebuild, ~30 min) |
| Test data vanished | Someone else's change, not a refresh -- the sandbox has no scheduled reset ([Trap 2](#trap-2-the-database-is-shared-and-it-resets)) | Ask in the channel before recreating it |
| Data I didn't create | Shared sandbox DB ([Trap 2](#trap-2-the-database-is-shared-and-it-resets)) | Expected. Ask in team chat if it's blocking |
| Email/text/payment didn't happen | Disabled by design ([Trap 4](#trap-4-no-email-no-texts-no-payments-no-jobs)) | Not a bug. Ask DevOps for a testing plan if that's the change |
| Stuck on `deploying` for a long time | Stale Actions run | Ask DevOps: cancel the run, then re-add `rock:start` |
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
| My PR includes a migration | DevOps — **before** applying `rock:start` |
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

1. **Every deploy rebound the self-signed certificate over the real one.** Renewal was never
   broken; it was being undone. Deploys rebind a certificate on every run and picked whichever
   matching certificate expired latest — and the self-signed placeholder is minted for two
   years while a Let's Encrypt certificate lasts ninety days, so the placeholder won every
   time. The timeline shows it exactly: renewal put a real certificate on `pr-4` at 16:57 UTC
   on 2026-08-10, `pr-4` was redeployed at 19:44, and it was self-signed again afterwards.
   Renewal also could not see `staging` at all, because in-place environments keep their
   manifest outside the tree renewal walked.
   Both are fixed in code — the selector now ranks CA-issued certificates above self-signed
   ones, and renewal scans the additional manifest root — but the fixes are VM-side scripts
   and take effect only after the bootstrap workflow runs. Until then, expect the warning.
   Verify by measuring the issuer, never by reading a run's conclusion; a run that finds
   nothing to do now says `RENEWAL ISSUED NOTHING` instead of passing quietly.
   Workflow: `.github/workflows/pr-test-renew-certificates.yml`.

2. **The production command-queue agent is not installed yet.** Everything upstream of it —
   build, approval gate, backup, copy, health check — is proven against staging. Until the
   scheduled task exists on the production VM against queue `commands-prod`, a production
   deploy will build, gate, queue, and then time out. Being done with DevOps rather than
   unattended.

3. **Production deploys from the production branch, and only that.** Note the wording: it read
   "from the trunk, and only the trunk" until 2026-08-19, and the cutover made that wrong.
   Each branch declares its own Rock version — `passion-18.4.1` is **18.4.1**, the trunk
   `passion-19.3.4` is **19.3.4**, `develop` is **19.0.3**, `develop-17.6.1` is **17.6.1** — and
   production's own assemblies are 18.x, a mix of 18.1.0, 18.3.1, and 18.4.1. So production's
   branch is `passion-18.4.1`, not the trunk, and deploying the trunk today would be the same
   irreversible jump to Rock 19 that deploying `develop` would be.

   That pin is now written down rather than inferred: `productionBranch` in
   `.github/pr-test-environments.json`, which is what `production-deploy.yml`'s two guards
   measure against. **Both guards read the repository's default branch until 2026-08-19**, on
   the reasoning that the trunk and production's branch were the same thing — and when the
   cutover separated them, the branch guard began refusing `passion-18.4.1` as `diverged` with
   no override, so production could not be deployed at all, rollback included. Worth knowing
   as a pattern rather than as one bug: the guard was correct, its tests were green, and the
   assumption underneath both had quietly stopped being true.

   The remaining real risk is narrower than the branch question: production's
   `Rock.Migrations.dll` is 18.3.1 and `passion-18.4.1`'s is 18.4.1, so the first deploy runs
   the 18.3.1 → 18.4.1 migrations at startup. That needs a verified database backup taken
   immediately beforehand, which is why the production path is built and proven but
   deliberately unfired.

4. **`GCP_COMPUTE_PROJECT_ID` is a dead secret** — no workflow references it. Worth removing
   so the secret list reflects reality.

5. **The `production` Environment exists now; its variables still do not.** Re-checked
   2026-08-19: the Environment is there with a required reviewer, so the approval gate in
   `production-deploy.yml` is real rather than passing through unchallenged — which is how
   this item read until now. Two things are still outstanding:

   - **None of `PRODUCTION_HOST_NAME`, `PRODUCTION_SITE_PATH`, `PRODUCTION_SITE_NAME` is
     set**, at either environment or repository scope. The workflow supplies a fallback for
     each (`rock.passion.team`, `C:\inetpub\wwwroot`, `Default Web Site`), so a production
     deploy does not fail on the missing values — it quietly targets those defaults. Confirm
     they match the live site before the first real run, because a wrong site path here
     deploys Rock over the wrong directory without complaining.
   - **The gate is self-approvable,** and cannot stop being so yet. There is one required
     reviewer and `prevent_self_review` is `false`, so whoever pushes the deploy can approve
     it. The flag has to stay `false` while there is only one reviewer, or the single person
     named could never approve anything. The fix is a second reviewer first, then flip the
     flag — open item 3 in `Training/DevOps-Open-Items-Rock-CICD.md` tracks it.

   Re-check both with:

   ```bash
   gh api repos/passiondev/Rock/environments/production \
     --jq '[.protection_rules[] | select(.type=="required_reviewers")
            | {reviewers: [.reviewers[].reviewer.login], prevent_self_review}]'
   gh api repos/passiondev/Rock/environments/production/variables --jq '.variables[].name'
   ```

6. **Stale branches — do not prune this list yet.** `develop-17.6.1`,
   `deploy/ptp-14803-18.4.1`, `bump`, `fix/group-sync`, and `pilot/pr-test-env-doc-smoke-v1761`
   no longer serve a purpose, and pruning them would remove several ways to target the wrong
   base branch. They are not equally safe to delete, though — only `deploy/ptp-14803-18.4.1`
   and `fix/group-sync` carry no unique plugin files. Open item 9 in
   `Training/DevOps-Open-Items-Rock-CICD.md` has the per-branch measurement and the command to
   recount it; do not prune from this list alone.

   **The safety margin this paragraph used to describe is already spent — re-measured
   2026-08-19.** `staging` was deleted from `origin` on 2026-08-18, and it held five plugin
   files: three RSVP (`RsvpDetailBETA.ascx`, `RsvpResponse.ascx.cs`, `RsvpResponseBETA.ascx.cs`)
   and two SECC authentication (`Arena.cs`, `org.secc.Authentication.csproj`). This step used to
   say they stayed reachable from `feat/PTP-16122` plus three branches below. **`feat/PTP-16122`
   no longer exists on `origin` either.**

   And `develop` is not the fallback it looks like. Comparing blobs rather than commit dates,
   the five files sit at two or three versions each, and **`develop` holds the oldest of every
   one** — 2026-01-09 across the board. The newest `RsvpResponse.ascx.cs` and
   `RsvpResponseBETA.ascx.cs` (2026-04-21) exist only on `develop-17.6.1` and
   `pilot/pr-test-env-doc-smoke-v1761`; `bump` holds a third, distinct 2026-02-24 version of
   both; and the newest `Arena.cs` and `org.secc.Authentication.csproj` (2026-01-28) are on
   those three branches and nowhere else. Every one of those holders is on the prune list above.

   So pruning this list as written does not narrow the margin — it discards the newest copy of
   all five files and leaves January 9 copies on `develop` that will look perfectly plausible to
   whoever finds them next. **Tag the three holders before deleting anything** (item 9 has the
   `git tag archive/...` commands; a tag is a ref, it costs nothing, and it survives the branch
   deletion that is the whole risk). Then land the files somewhere durable, then prune.
   `develop` must not be pruned regardless — it carries the other 78 plugin files.

7. ~~**The pilot doc is stale.**~~ **Fixed 2026-08-19.**
   `Documentation/Discussion Docs/PR-Test-Environments-Issues/12-pilot-rollout.md` said
   deployment failed at an SSH step, which the Cloud Storage command queue had already
   replaced. It now records the queue as the live mechanism, keeps the SSH attempt as clearly
   labelled history, and has had its acceptance criteria re-marked against observed evidence —
   several of which came back unmet, so read the boxes rather than assuming the pilot passed.

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
   deploy of any environment (exactly staging's situation in item 1). It is now also
   unavoidable: the probe goes to `127.0.0.1`, and no certificate issued for the public host
   name will ever match that address.

   **Partly addressed.** After every staging and production deploy, GitHub reads the
   certificate from the internet side and prints its issuer in the run summary, warning when
   the site is presenting a self-signed one. That is a warning and not an error on purpose —
   a certificate due for renewal is not an outage, and a pipeline that reports it as one
   teaches people to ignore red. Still to do: report days remaining rather than just who
   issued it.

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

| Fact | Value as of 2026-08-19 | Where to check |
| --- | --- | --- |
| Eligible base branch / repo default branch | read it, don't memorise it — named `passion-<version>` | `.github/pr-test-environments.json` |
| Environment domain | `rock-dev.connect.passion.team` | same file |
| Staging URL | `staging.rock-dev.connect.passion.team` | `.github/workflows/staging-deploy.yml` |
| Staging database catalog | `RockStaging` — its own, split from the fleet 2026-08-18 | `gh variable list -R passiondev/Rock` |
| `pr-*` database catalog | shared: all `pr-*` sites use `RockConnectProd` together | `PR_TEST_DB_NAME` unset ⇒ falls back to `secrets.DB_NAME` |
| Office allowlisted IP — **RDP (3389) and SQL (1433) only**, never HTTPS | `159.63.145.194` | GCP firewall rules |
| Public reachability of test URLs | 443 and 80 open to `0.0.0.0/0` (`https-from-world`, `pr-test-acme-http`); the test VM shares production's `prod-passion-compute` tag | GCP firewall rules; open item 24 |
| Certificate health, `pr-*` | Valid Let's Encrypt when a site exists. Renewal runs weekly, Monday 08:00 UTC, so a host created after the last run serves a self-signed placeholder until then | `curl -v https://pr-<n>.rock-dev.connect.passion.team` |
| Certificate health, `staging` | **Valid** — Let's Encrypt YR2, `CN=staging.rock-dev.connect.passion.team`, expires 2026-11-09 (verified 2026-08-19). An earlier revision of this table said "Untrusted"; that was true before the renewal selector was fixed | same command against the staging URL |
| Overlaid directories | `Themes,Content,Assets,Styles`, copy-if-absent only | `Deploy-PrEnvironment.ps1` |
| Directories a deploy never touches | `Content`, `App_Data`, `Logs`, `Uploads`, `web.ConnectionStrings.config` | `Deploy-RockEnvironment.ps1` |
| Typical build+deploy time | ~30 minutes | Recent Actions runs |

The base branch changes on every Rock upgrade and is the most likely value here to go stale.
When it does, `.github/pr-test-environments.json` is the single place that decides it.
