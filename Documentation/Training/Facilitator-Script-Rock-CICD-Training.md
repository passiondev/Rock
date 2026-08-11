# Facilitator script — Rock CI/CD Training

**For the presenter only. Not a handout.**

**Slot:** 60 minutes · **Deck:** `Documentation/Training/rock-cicd-training-deck.html`
**Handout:** `Documentation/Local-Engineering-Training-Edit-Test-and-Deploy.md`
**One-pager:** `Documentation/Training/rock-cicd-cheat-sheet.html` (print 8 copies)
**Last verified:** 2026-08-10

---

## Room read

| Who | What they know | What they need from this hour |
| --- | --- | --- |
| Local engineering lead | Little or no git | Confidence that he cannot break production, and that this is learnable |
| 2× local engineering staff | Some git, not much | The mechanics: base branch, PR, labels, where it lands |
| Technology Director | Strategic | Why this exists, what risk it removes, what's still open |
| 2× Ops | No git — here to observe and comment | Enough to follow along; the labels/tags nuance is the one new thing |
| DevOps engineer | Knows all of it | To be treated as co-owner, not audience. The open items are *his* list, not a confession |

**Two framing decisions.** Open with the MacBook problem, because it makes the pipeline feel
inevitable rather than imposed. And say early that **nothing in the browser can reach
production** — the lead will hold that anxiety through the whole hour otherwise, and stop
listening.

**Expect interruptions.** Ops is explicitly there to comment. The plan below is ~45 minutes
of material in a 60-minute slot. Let it get interrupted; that's the slack being used
correctly.

---

## Timing plan

| Clock | Min | Segment | Slides | Land this one point |
| --- | --- | --- | --- | --- |
| 0:00 | 4 | Open — why this exists | 1–2 | Rock only builds on Windows; we're all on Macs. That's the whole reason. |
| 0:04 | 8 | Git in five minutes | 3–5 | A branch is a copy you can't break. |
| 0:12 | 6 | The fork | 6–7 | We didn't write Rock. We keep our changes next to theirs. Repo is **public**. |
| 0:18 | 4 | Version branches | 8–9 | The trunk is named after the version production runs. |
| 0:22 | 8 | Making changes | 10–12 | Base branch `passion-18.4.1`, or nothing happens. |
| 0:30 | 5 | Why GitHub builds it | 13–14 | Half an hour of compiling on a Windows machine none of us owns. |
| 0:35 | 7 | Three doors | 15–16 | Merging deploys **staging**. Production takes a deliberate run *and* an approval. |
| 0:42 | 10 | **Demo** | 17 | It's real, and here's the URL. |
| 0:52 | 8 | Q&A + asks | 18–20 | Two things for the team, two for DevOps. |

**If you're at 0:35 and only on slide 9:** cut slide 9 (next upgrade), cut slide 12 (why a
PR for a typo — it's on the cheat sheet), and compress "Three doors" to the table only. Never
cut the demo; it's the thing they'll remember. Never cut the "public repo" warning.

## Slide map

The deck is one linear pass, no builds or hidden slides. Numbers below are what the
segment notes refer to. **If a heading here does not match the deck, the numbers in this
script are stale** — that has happened once already, when a slide was cut from "Git in
five minutes" and every reference after it silently pointed one slide too far.

| # | Section | Heading |
| --- | --- | --- |
| 1 | *(title slide)* | Rock CI/CD Training |
| 2 | Why any of this exists | Everyone here has a MacBook. Rock only builds on Windows. |
| 3 | Git in five minutes | A branch is a copy of everything that you cannot break. |
| 4 | Git in five minutes | A pull request is the request, the conversation, and the button. |
| 5 | Git in five minutes | Branching strategy: one trunk, many short branches. |
| 6 | The fork | We didn't write Rock. We forked it. |
| 7 | The fork | A fork is a two-way street. Both directions have rules. |
| 8 | Version branches | The trunk is named after the Rock version it runs. |
| 9 | Version branches | How the next upgrade happens. |
| 10 | Making changes | One decision matters more than all the rest: the base branch. |
| 11 | Making changes | Labels are buttons. That's the whole control panel. |
| 12 | Making changes | Why a pull request, even for a one-word typo. |
| 13 | Why GitHub builds it | What "build" actually means for Rock. |
| 14 | Why GitHub builds it | Four reasons it can't be your laptop. |
| 15 | Three doors | Three places code can land. Only one of them is production. |
| 16 | Three doors | Merging deploys staging. Nothing merges to production. |
| 17 | Demo | Let's go look at a real one. |
| 18 | Questions you're about to ask | Anticipated questions. |
| 19 | Questions you're about to ask | And the harder ones. |
| 20 | Where we go from here | Four things, and then it's yours. |

*Verified against the deck on 2026-08-11: 20 slides, every heading and number above matches,
and every slide range in the segment notes below resolves to the right headings.*

---

## Segment notes

### 0:00 — Open (slides 1–2, 4 min)

Don't start with git. Start with the wall.

> "Every one of us has a MacBook. Rock is .NET Framework — it can only be compiled on
> Windows. Not 'it's easier on Windows.' It does not build on a Mac at all. So either we all
> get Windows machines, or a Windows machine somewhere else does the building for us. That's
> what this is."

Then defuse the fear immediately, before anyone's had time to build it up:

> "Second thing up front: nothing I show you today can take down the live site. There is no
> branch you can push and no button you can click in a browser that reaches production.
> We'll get to exactly why."

### 0:04 — Git in five minutes (slides 3–5, 8 min)

Aimed at the lead. Use the analogy and then drop it — don't extend it past where it holds.

> "A branch is your own complete copy of every file. You can edit anything in it. Nobody else
> sees it, and nothing you do there touches what's running."

The two things that make git feel strange are worth naming out loud, because both are the
point: nothing is ever overwritten, and you work on a copy and then *ask* for it to be
merged. There's no "save to the server."

On slide 4, say the words **"pull request is a bad name"** — read it as *please pull my
changes in*. Everyone nods; nobody had been told.

On slide 5, keep the branching-strategy discussion to the two boxes. If the DevOps engineer
wants to discuss trunk-based vs. GitFlow, park it: *"Worth a conversation, not this one."*

### 0:12 — The fork (slides 6–7, 6 min)

Slide 6's diagram is the answer to "where does our code come from." Numbers to say out loud —
these are measured against Spark's **`18.4.1` tag**, and they split cleanly:

> "Our trunk differs from Rock's own 18.4.1 in 68 files. Sixty-one of those are files that
> don't exist in Rock at all — the workflows, the deploy scripts, the runbooks, the tests. This
> pipeline. Only **seven** files that Rock ships have been edited by us, and five of those are
> one feature: the header image upload in Form Builder. Nothing has been deleted."

The point of saying it that way: we have barely touched Rock, and almost everything we've added
is plumbing. It also pre-answers the upgrade fear — a fork that mostly *adds* files is a fork
that merges cleanly.

If someone asks which five: `FormBuilderDetail.cs`, `FormGeneralViewModel.cs`,
`generalSettings.partial.obs`, `types.partial.ts`, `entryFormPersonEntry.partial.obs`. The
other two edited files are `.gitignore` and the PR template — both ours, not Rock's behaviour.

> Recount before you present if the trunk has moved:
> `git fetch upstream --tags && git diff --diff-filter=A --name-only 18.4.1..HEAD | wc -l`
> for the added count, `--diff-filter=M` for the edited one. The earlier version of this script
> called all 68 "files that don't exist upstream," which was wrong for the seven edited ones.

Slide 7 is the most important non-demo slide in the deck. Two directions, then the warning.

If anyone asks about `develop` being a "mirror" — the deck used to say that and it was wrong.
`develop` carries 276 files under `RockWeb/Plugins/`, 78 of them ours; upstream's 18.4.1 tag
carries 2. The clean reference is Spark's **tag**, not a branch of ours. Say it as a
correction if it comes up; don't volunteer it, because the rule people need is unchanged:
never open a PR against `develop`.

**Do not soften the public-repo warning.** Say it plainly, and give the recovery path so it
doesn't read as a threat:

> "Because Rock is open source, our fork is public. Anyone on the internet can read it. If
> you ever commit a password or a connection string or an export with member data, deleting
> it in the next commit does not remove it — it's in the history permanently. Tell DevOps
> immediately and we rotate the credential. Nobody's in trouble for telling us fast."

Ops will likely ask whether member data is exposed *today*. The honest answer: no member data
is in the repo, `.env` files are ignored, and the connection strings live in GitHub secrets
and on the servers — never in the code.

### 0:18 — Version branches (slides 8–9, 4 min)

Short segment. The one thing they must take away: **don't memorize `passion-18.4.1`.** Read
the default branch, or read `.github/pr-test-environments.json`. It changes at every upgrade.

Slide 9 is cuttable. It exists so next year's branch names aren't a surprise.

### 0:22 — Making changes (slides 10–12, 8 min)

This is the segment the two staff engineers came for. Slow down.

Slide 10's right-hand box is the single highest-value warning in the hour:

> "If you get the base branch wrong, you don't get an error. You get *nothing*. No comment,
> no site, no red X. It looks like the pipeline is broken, and it isn't — it's ignoring you.
> That's a GitHub limitation, not a choice."

Slide 11 — labels-as-buttons. This is the bit Ops won't have seen before, so it's worth an
extra beat. Emphasize the split: **four labels you press, six the robot sets.** People break
things by editing the state labels by hand.

Also say the cleanup truth plainly, because the earlier version of the docs got this wrong:

> "Merging destroys your environment. Closing without merging just stops it. Nothing else
> cleans up on a timer — so when you're done, destroy it yourself."

Slide 12's exception matters more than the rest of the slide: **a lot of "editing the
website" in Rock is database content, not files.** HTML Content blocks, page names, routes,
Lava in block settings, workflows, reports. Those are admin-UI changes on the live site and
this pipeline never touches them. If they take one thing from this slide, it's *ask which
side of that line you're on.*

### 0:30 — Why GitHub builds it (slides 13–14, 5 min)

Slide 13's table answers "why does it take so long" before it's asked. The line that lands:

> "The compiled JavaScript for the newer Rock blocks isn't in the repo at all — it only
> exists after a build. That's why 'just copy the files up' doesn't work. Half the site isn't
> in the files."

**Promise them the receipt here, then pay it off in the demo.** Say that at 0:42 you will show
them the compiled file that a MacBook cannot produce, and leave it at that — don't open the tab
yet. It is step 5b of the demo runbook: one line changed in a `.obs` Vue component, and the
string comes back out of
`pr-4.rock-dev.connect.passion.team/Obsidian/Blocks/security/login.obs.js`. Setting it up here
and closing it there is what turns this slide from an assertion into a demonstration.

Slide 14, reason 3 is for the Technology Director: credentials live in GitHub secrets and are
only ever read by a build. They never land on anyone's laptop.

Set the expectation explicitly: **~40 minutes, label to live site.** Better they hear it from
you than discover it while staring at a PR.

Measured from the two most recent successful PR deploys, so quote it with confidence — and
quote the range, not a single number, because the spread is real:

| Run | Build | Deploy on the VM | Total |
| --- | --- | --- | --- |
| `31425587536` (2026-08-10 19:44) | 24m32s | 17m01s | **42m33s** |
| `31412537693` (2026-08-10 17:08) | 33m14s | 6m44s | **40m56s** |

Two things worth saying out loud if anyone asks why it varies. The build is slower on a cold
GitHub runner cache and faster on a warm one. The VM half depends on whether it waits behind
another deploy — `Deploy-RockEnvironment.ps1` takes a per-environment mutex, so two deploys of
the same site queue rather than collide. Neither is a fault; both are the system working.

If you would rather round, say "about forty minutes" and never "about half an hour." The old
version of this line said 30 minutes and no recent run has come in under 40.

### 0:35 — Three doors (slides 15–16, 7 min)

> ⚠️ **First, before you say anything: open `pr-4` in a background tab.** The app pool idles
> out after 20 minutes, so whatever warming you did before the meeting has already expired by
> now. Loading it here means it is warm when you switch to it at 0:42 instead of showing the
> room a 60-second white screen. It loads while you talk through this segment. See the
> morning-of checklist for the measurement behind this.
>
> Warm the two tabs the demo actually uses, not just the home page — the same app pool serves
> all of them, so one request warms the site, but having them already open saves fumbling:
> `pr-4.rock-dev.connect.passion.team/this-page-does-not-exist` and
> `staging.rock-dev.connect.passion.team/this-page-does-not-exist`.

Slide 15's table is the mental model for the whole hour. Walk the rows in order — PR,
staging, production — and note that the first two share a sandbox database.

Then the red box: test environments isolate *code*, not *data*. Shared DB, gets reset, no
email/texts/payments/jobs.

Slide 16 is the production story, and it's where you earn the Director's trust. The two locks:
someone runs it deliberately (and the default run is a **dry run** that changes nothing), then
a named reviewer approves — **after** the build, so nobody approves a commit that doesn't
compile.

Then the two design decisions, in your own words:

> "It never mirrors. Uploaded content, logs and cache belong to the server, and a deploy
> can't delete them. And CI never writes production's connection string — the production
> database password doesn't exist as a secret in GitHub at all, so a deploy physically can't
> point production at the wrong database."

**If the Director asks "who approves?"** — and it is the obvious question — answer it exactly:

> "Today, me. The gate is real: GitHub holds the run and deploys nothing until a named reviewer
> clicks Approve, and I turned off the setting that lets a repo admin skip it. But one name on
> that list is a control against an accident, not against a bad decision. Adding [DevOps] as a
> second reviewer is a two-minute settings change and it's on the handoff list — that's the
> version I'd want before we're deploying to production regularly."

That answer is worth more than a claim of two-person control would be, and the Director is the
person in the room most likely to notice the difference.

**Be straight about where production stands.** Don't oversell and don't apologize:

> "Every step of the production path is built and proven against staging — the build, the
> approval gate, the backup, the copy, the health check. The one piece left is installing the
> queue agent on the production VM, and I'm doing that with [DevOps] rather than alone on a
> Sunday. So today, production is proven up to the last inch, and deliberately not fired."

This is now literally true rather than aspirational, and you can cite the evidence if DevOps
presses. Staging and production share the same deploy workflow (`env-deploy-command.yml`), and
until 2026-08-11 it had **never once succeeded** — eight runs, eight failures, because the
health check ran on the VM and asked for the site's public URL, which the box cannot resolve
back to itself. Production would have failed identically on its first run. Run
**`31449260144`** is the first green one: deploy job 01:48:20 → 01:57:38, zero non-success
steps, and the site verified reachable from the runner afterwards.

If someone asks what actually changed: the health check now requests `https://127.0.0.1/` with
an explicit `Host:` header instead of the public name. Worth having ready, because "we fixed
the health check" invites the question and the real answer is short and specific.

### 0:42 — Demo (slide 17, 10 min)

See the runbook below. Narrate the baking-show framing as you go: the half-hour build is
already done, so you're taking the finished one out of the oven.

### 0:52 — Q&A + asks (slides 18–20, 8 min)

Slides 18–19 are prepared answers — use them as a safety net if the room goes quiet, don't
read them aloud in order.

The one to volunteer even if nobody asks is **"was this working before today?"** Getting
ahead of it is what makes the rest credible:

> "Parts of this were reporting green while being broken. The test server had been powered
> off for three months. The build was looking for Visual Studio in a folder that no longer
> existed. Failures were being forced green. The compiled block JavaScript was never built at
> all — so every test site had zero working Obsidian blocks. The deploy was overwriting
> the exact theme files people were trying to test. And until this morning no test site had a
> working login page at all, because our login block is a plugin and plugins aren't in the
> repository — the deploy reported success while the landing page said *Error Loading Block*.
> Six separate bugs, all fixed, all with tests that fail if they come back. There's a written
> list of what's still open, and DevOps has it."

That last one is the strongest item on the list, so don't rush past it. It is the clearest
example of the thing this whole hour is arguing for: a health check that accepts any HTTP 200
cannot tell a page from an error message, which is why "the deploy went green" is not the same
claim as "the site works." If someone asks whether the health check has been tightened — no,
not yet, and it is on the open list rather than quietly forgotten.

Close on slide 20: two asks for the team, three for DevOps. End on the last line — *the
pipeline's job is to make a change boring.*

**Land the second-approver ask while the Director is still in the room.** It is the only one
of the five that needs someone else's authority rather than someone else's calendar, and it is
five minutes of clicking. Say the uncomfortable version out loud — *"the production gate is
real, admins can't bypass it, and right now I'm the only name on it, which means production is
one person"* — and ask for the name in the room rather than in a follow-up. Asking for a
control on yourself is the most credible thing you will say all hour. If you get a yes, you
can have it configured before the room stands up.

---

## Demo runbook

**Pre-warmed:** PR #4 — <https://github.com/passiondev/Rock/pull/4>
Branch `demo/ptp-cicd-training-walkthrough` · deployed SHA `aaceb67c8e`
Live: <https://pr-4.rock-dev.connect.passion.team>
Staging: <https://staging.rock-dev.connect.passion.team>

**Nothing in this section builds anything.** Every artifact below was built and deployed before
the room sat down. You are not starting a build in front of anyone, and you should say so
early — *"a build takes twenty-five minutes, so I ran it this morning"* — because it converts
the one thing that could read as a limitation into the exact point you are making. A pipeline
you wait on is a pipeline that is doing real work.

**If you show only one thing, show the PR.** <https://github.com/passiondev/Rock/pull/4> is the
whole hour in one page, and it needs no live site and no network beyond GitHub: four changed
files against `passion-18.4.1`, the label you applied, the labels the robot applied back, a bot
comment carrying the live URL and the deployed SHA, and a Checks tab where every build step is
named. Steps 1–4 below are that page. Steps 5 and 6 open live sites, which is stronger but
depends on a warm app pool; step 7 is the only one that starts anything, and it is optional.
If the room is running long or the projector is fighting you, land steps 1–4 and describe the
rest — the argument survives intact.

> "Pre-warmed" means the environment is **built and deployed**, not that it will still be warm
> when you get here. The app pool idles out after 20 minutes. If you did not load pr-4 during
> the 0:35 segment, load it *now* and talk over the first slide of this section — do not open
> it cold on the projector and wait.

`aaceb67c8e` is a merge of the trunk into the demo branch, not one of the three demo commits
below. That is deliberate and worth a sentence if anyone asks: the branch was brought up to
date with `passion-18.4.1` and redeployed, which is the same thing they will do to any branch
that has fallen behind. **Files changed** still shows only the four demo files, because GitHub
diffs against the merge base rather than the branch tip.

The three demo commits each prove a different thing, and one of them deliberately proves it by
being invisible. Read this before the demo — *where* each change surfaces is not obvious:

1. `a16b5b2c3b` — relabels the core Obsidian login block (`login.obs`) to
   "Log In — CI/CD Training Build". This one is the **build** proof, not a visual one.
2. `f605feb801` — a green banner in `Themes/Rock/Layouts/Site.Master`, so every internal Rock
   page carries it — but only once you have signed in.
3. `b29c0a912d` — the same banner in `RockWeb/Http404Error.aspx`, the one page a *signed-out*
   visitor can reach that this repository actually owns.

Commit 2 is the one that matters technically, and it is the one you cannot show on the
projector: `Themes/` is the directory the old deploy used to overwrite, so a banner surviving
in `Themes/Rock/Layouts/Site.Master` is what proves the `/MIR` bug is dead — and that file
only renders after a sign-in. If you are signed in on the demo machine anyway, show it; if not,
don't improvise a login in front of the room. The overlay leaves a quieter fingerprint you can
point at instead: view source on the login page and you will find it loading
`/Themes/CONNECT/Styles/theme.css` *and* `/Themes/Rock/Styles/theme.css`, with different `?v=`
stamps — CONNECT's is the older file the overlay backfilled from the server, Rock's is the one
this build produced. Two themes, two timestamps, one site directory: that is the overlay adding
without overwriting. (Don't quote the numbers from this script; the artifact's stamp changes
every build. The point is that they differ.)

Commit 3 exists because of something worth saying out loud in the room: **Passion's Rock is
not all in this repository.** The landing page at `/page/3` is drawn by
`Themes/CONNECT/Layouts/Splash.aspx`, `/checkin` by `Themes/Checkin-Guest`, and the login box
itself is `Plugins/org_passion/Security/Login.ascx`. None of those three are version
controlled here. So nothing on this branch can change what a signed-out visitor sees on the
front door, and commit 1's label never appears on screen at all, because this site does not
use the core block that commit edits. `Http404Error.aspx` is different: it sits at the RockWeb
root, so it rides in the build artifact and the shared-asset overlay never touches it. Asking
for an address that does not exist is the fastest honest proof that the branch is what is
running on that host.

**Sequence:**

1. **The PR page.** Files changed → four files. One is a one-line Vue change, two are the theme
   `Site.Master` layouts, one is `Http404Error.aspx`. Point out the base branch reads
   `passion-18.4.1`.
2. **The sidebar.** The label *you* added, and the state labels the robot set in response.
3. **The bot comment.** Status table: `deployed`, the URL, the SHA, the artifact path. Note
   it also lists the commands — the PR documents itself. The "Access and data notes" section
   is the one to read aloud: reachable from anywhere with no VPN, first request after a deploy
   is slow because Rock migrates at startup, and the sandbox database is shared, so the
   environment isolates code and runtime but **not** data.
4. **The Checks tab.** Open the build job, scroll the step list. Don't read it; just let them
   see that every step is named and logged. This is where "it's a black box" dies.
5. **The live site.** Two tabs, in this order.

   **a. The banner.** <https://pr-4.rock-dev.connect.passion.team/this-page-does-not-exist> —
   a green bar across the top of Rock's "We Can't Find That Page". That bar exists in my branch
   and nowhere else: not on staging, not in production. Say the quiet part rather than hoping
   nobody notices it: *"I asked for a page that doesn't exist on purpose — it's the one page a
   signed-out visitor can see that this repository actually owns."*

   **b. The thing a MacBook cannot make.**
   <https://pr-4.rock-dev.connect.passion.team/Obsidian/Blocks/security/login.obs.js>, then ⌘F
   for `CI/CD Training Build`. That file is *compiled output*. I edited one line of a Vue
   single-file component; a Windows runner on GitHub turned it into that bundle. This is the
   whole argument of the previous section made physical — nobody in this room could have
   produced that file on their laptop. It is also why the label never shows up on screen:
   Passion's login page is a plugin block, not this core one.

   > **Both hosts now hold real certificates — but still check the morning of.** Measured
   > 2026-08-11 02:40Z, after a deploy: `staging` presents Let's Encrypt YR2 (expires
   > 2026-11-09) and `pr-4` presents Let's Encrypt YR1 (expires 2026-11-08), each chaining to
   > ISRG Root X1, and both answer HTTP 302 under strict TLS validation. No warning, on a
   > laptop or a phone.
   >
   > This is worth re-checking rather than assuming, because an earlier version of this script
   > got it wrong in both directions — first claiming a valid certificate that had never been
   > measured, then recording a self-signed one that had since been fixed. One command:
   > `echo | openssl s_client -connect pr-4.rock-dev.connect.passion.team:443 -servername pr-4.rock-dev.connect.passion.team 2>/dev/null | openssl x509 -noout -issuer -subject`
   > — if the issuer names Let's Encrypt you are fine; if issuer and subject are identical it
   > has reverted to self-signed. Compare the two fields; do not grep for `CN=`, because the
   > printed format varies between OpenSSL builds (`/CN=*.x`, `CN=*.x` and `CN = *.x` have all
   > been observed on this same certificate).
   >
   > If it has somehow reverted, own it in one sentence and move on: *"These test hosts are on
   > an internal certificate today — the real site isn't."* Click through once, deliberately,
   > and say you're doing it. Do **not** teach the room that clicking through warnings is
   > routine.
   >
   > A **brand-new** PR environment is a different case and is still expected to warn: it gets
   > the self-signed placeholder until the weekly renewal issues a certificate for its host
   > name. Say that if someone spins one up and asks.
6. **Staging.** <https://staging.rock-dev.connect.passion.team/this-page-does-not-exist> —
   the same page, on the same server, with **no green bar**, because staging builds the trunk
   and the banner only exists on the branch. Two tabs side by side is the entire argument for
   PR environments in one screen: staging shows what is merged, the PR site shows what is
   proposed. Then open the staging home page, so nobody leaves thinking staging is a 404.
7. **Skip this by default.** Pushing a trivial extra commit and watching `deployed` flip to
   `building` within seconds is a genuinely good moment, but it is the one step that starts a
   twenty-five-minute build you then cannot show the end of, and it puts the projector on a
   robot's reaction time. Do it only if you are at 0:46 or earlier and pr-4 is already warm,
   and if you do, narrate that you are showing the *transition* and nothing further.

   The cheaper substitute, which needs no push: on the Checks tab of the run already open in
   step 4, the step timings are right there. Point at the build job's duration and say the
   number out loud — *"that is why this happens on GitHub and not on your laptop, and why I
   ran it before you got here."* Same lesson, no live wait, and it reinforces rather than
   apologises for the build time.

   > **This only works because PR #4 carries `rock:auto`.** A push to a PR without that
   > label is deliberately ignored: `pr-test-deploy.yml` handles the `synchronize` event, checks
   > for `rock:auto`, and logs *"PR does not have rock:auto; skipping automatic
   > redeploy"* if it is missing. Rebuilding a Windows artifact on every push to every branch is
   > 26 minutes of runner time nobody asked for, so opting in is the default. PR #4 has the
   > label; a PR someone opens in the room will not, and the answer to "why didn't mine deploy?"
   > is either add `rock:auto` or apply `rock:start` once. Worth knowing before someone
   > pushes and nothing happens on the projector.

**Fallbacks, in order:**

- **Cert warning on the *staging* URL** → possible; `pr-4` is fine. Staging is a host I stood
  up this week and the certificate job only picks up environments that have recorded a
  successful deploy, so it hasn't been issued one yet. Say that plainly and move on. Don't
  describe it as normal, and don't teach the room to click through TLS warnings.
- **Site won't load** → it is not the network. Port 443 on the test VM is open to
  `0.0.0.0/0` (rule `https-from-world`), so these hosts work from anywhere — a hotel, a phone
  tether, an attendee's laptop. The `159.63.145.194` office-egress restriction applies only to
  RDP and SQL. Don't spend demo time blaming VPN.
- **First load times out** → reload once. Rock applies migrations on first request. Measured
  cold on 2026-08-11 after a VM restart: **55 seconds** to the first response on `pr-4`, then
  instant. This is why the checklist warms both sites; see below.
- **Site is genuinely down** → fall back to the Checks tab and the bot's status comment.
  The build log is real evidence and it's just as convincing. Say what happened.
- **Everything is down** → screenshots (take them the morning of, see checklist).

---

## Morning-of checklist

Do this at least 90 minutes before, so a rebuild is still possible.

- [ ] <https://pr-4.rock-dev.connect.passion.team> loads, and the login box actually renders —
      no "Error Loading Block". No VPN needed; 443 is open to the world on the test VM.
- [ ] <https://pr-4.rock-dev.connect.passion.team/this-page-does-not-exist> shows the green
      banner. This is the demo's money shot; check it, don't assume it.
- [ ] <https://pr-4.rock-dev.connect.passion.team/Obsidian/Blocks/security/login.obs.js>
      contains `CI/CD Training Build`.
- [ ] <https://staging.rock-dev.connect.passion.team> loads, and its
      `/this-page-does-not-exist` has **no** banner — that contrast is step 6.
- [ ] PR #4 still shows `rock:deployed`.
- [ ] **Screenshot both sites and the PR page.** This is the real insurance.
- [ ] Print 8 copies of the cheat sheet.
- [ ] Deck open, full screen, arrow keys working. Rail nodes jump between sections.
- [ ] Browser tabs pre-opened in demo order, logged in to GitHub.
- [ ] Zoom/browser at a size the back of the room can read — bump to 125%.
- [ ] Close Slack, mail, and anything that shows notifications.

**Then, in the five minutes before you start — warm both sites.** This is separate from the
90-minute check on purpose, and it is the single highest-value item on this list.

An IIS app pool idles out, and Rock's first request after that rebuilds caches and applies any
pending migrations before it renders anything. Cold, that measured **55 seconds** of blank
browser on 2026-08-11. Warm, it is instant. Fifty-five seconds of white screen while a room
watches is the demo failing even though nothing is broken.

Budget more than that if the VM has been restarted rather than merely gone idle. Measured
twice on 2026-08-11, on the first request after a reboot: **pr-4 53s / staging 129s**, and
after a second reboot **pr-4 95s / staging 107s**. So call it one to two minutes per host,
varying run to run — don't plan around the low number. Two minutes of white screen is well
past what a room will sit through politely, so if anything rebooted that morning, warm the
sites early and warm them twice. Both went back to well under half a second on the second
request in every measurement.

**A certificate renewal also causes a cold start**, and it is the sneakiest version of this
because nothing looks like it changed. Renewal rebinds the certificate in IIS, which restarts
the site. Measured immediately after the 2026-08-11 02:00 UTC renewal: **pr-4 took 85.3
seconds** on the next request, then 0.17s. That is longer than the idle-timeout cold start.
The weekly renewal cron is Monday 08:00 UTC — so if you ever present on a Monday morning, or
you run the renewal by hand that day, warm the sites *after* it finishes, not before.

```bash
# Run this immediately before presenting. Both should come back fast the second time.
for h in pr-4 staging; do
  curl -s -o /dev/null -k -w "$h  %{http_code}  %{time_total}s\n" \
    --max-time 240 "https://$h.rock-dev.connect.passion.team/"
done
```

Run it twice. The first pass may take a minute per host; the second should be well under a
second. If the second pass is still slow, something is actually wrong — go to the runbook.
Note `-k`: it skips certificate validation, so this warms the site without telling you anything
about the certificate. Check that separately with the `openssl` line in the certificate item.

### Warming before you start is not enough — warm it again at 0:35

This is the trap, and it is worth more than everything above it. **Warming a site at 0:00 does
not keep it warm until the demo at 0:42.** Nothing in this repo ever sets `idleTimeout`,
`startMode`, or `preloadEnabled` on the app pool, so IIS defaults apply: the worker process
shuts down after **20 minutes** with no requests. Warm pr-4 at 0:00, talk for forty minutes,
open it for the demo, and you are opening a *cold* site in front of the room — the exact
failure the pre-meeting warm-up was supposed to prevent.

Measured on 2026-08-11: pr-4 answered in 0.23s, sat untouched for about 32 minutes, and then
took **62.2 seconds** on the next request. Nothing had been deployed to it and nothing had
restarted; it simply idled out.

So add one item to the run of show: **at the start of the "Three doors" segment (0:35), load
pr-4 in a background tab.** Seven minutes ahead of the demo is comfortably inside the 20-minute
window and far enough ahead that the load finishes while you are still talking. If you would
rather not touch the keyboard mid-segment, ask someone in the room to hit it — that is a fine
thing for Ops to do and it costs them nothing.

The good news, measured the same night: **a site you just deployed to is already warm.** The
deploy's own health check makes a real request as its last step, so staging answered in 0.10s
just 33 seconds after deploy `31453111607` finished. A freshly deployed site never needs
warming — only an idle one does.

---

## Don't do these live

- **Don't run Deploy Production**, not even the dry run. The gate itself is real now — it will
  build, then hold and wait for your approval, which is the good part. But if you approve it,
  the run queues a command to the production VM, and *no agent is installed there yet*, so it
  sits and polls until it dies at the 60-minute timeout. A dry run does not skip that: the
  "changes nothing" logic lives on the VM, so it needs the agent too. On a projector that reads
  as "the production pipeline is broken," which is the opposite of true.

  If you want to show the gate, show it **without approving**: dispatch nothing, and instead
  open Settings → Environments → `production` and let them see the required reviewer and that
  admins can't bypass it. Same point, no hostage.
- **Don't merge PR #4** during the meeting. Merging destroys the environment you're
  demonstrating, and it would kick off a staging deploy you can't finish watching.
- **Don't start a build you can't finish.** Twenty-five minutes is longer than the segment,
  so any build begun on the projector ends as an unfinished progress spinner — the single worst
  image for a session arguing the pipeline is trustworthy. Everything you need is already built.
  Say the build time out loud as a fact about compiling .NET on Windows, not as an apology.
- **Don't promise dates** for the production agent install — that's a joint decision with
  DevOps, in the room.
- **Don't demo the operator hot-deploy path.** Describe it if asked. Doing it live teaches
  the wrong lesson about how urgent fixes should work.
- **Don't open a terminal.** The entire promise of this session is that they never need one.

---

## Questions you may not have an answer for

Say "I don't know, I'll find out" rather than improvising. These are the plausible ones:

- **"How much does this cost per month in GitHub Actions minutes?"** Windows runners bill at
  a higher multiplier than Linux. The build step itself measured 24m32s and 33m14s on the two
  most recent successful PR deploys, so call it ~30 minutes of Windows-runner time per deploy.
  The *cost* is still not measured — worth putting a number on before anyone asks twice.
- **"Can we have a test environment with a copy of real data?"** A real request with real
  privacy consequences. Don't answer in the room; it's a DevOps + Director decision.
- **"What happens if two people merge at once?"** Staging deploys supersede each other by
  design — the newer commit cancels the older in-flight one. Nobody's change is lost, because
  the newer build already contains it.
- **"Who can approve a production deploy?"** You can answer this one now — it changed on
  2026-08-11. The `production` environment exists, has **one required reviewer**
  (`justinpbarnett`), and admins **cannot** bypass it, all verified against the GitHub API that
  night. So today the honest answer is *"me, and only me — which is exactly one person too
  few."* The open item is no longer creating the gate; it is adding the DevOps engineer as a
  second reviewer and then turning on `prevent_self_review`, which is the point at which
  production genuinely takes two people. Say that plainly in front of the Director — asking for
  the second reviewer in the room is the cheapest way to get it.

  *(Earlier drafts of this script said the reviewer list "doesn't exist yet." That was true when
  written and is not true now; don't say it.)*

- **"I made a change, it deployed, and the page looks exactly the same. What did I do wrong?"**
  Probably nothing, and this is the single most useful thing the local team can take away from
  the hour, so volunteer it rather than waiting to be asked. Passion's Rock is not all in this
  repository: the sign-in page is drawn by `Themes/CONNECT/Layouts/Splash.aspx`, `/checkin` by
  `Themes/Checkin-Guest`, and the login box itself is a plugin block under
  `Plugins/org_passion/`. None of those are version controlled here, so no branch can change
  them and a test site always shows the *server's* copy. The consequence to state out loud:
  **on a test site, "it looks the same" is not evidence that your change did not deploy.** The
  check that does work is a nonsense path — `.../this-page-does-not-exist` — because Rock's 404
  page is the one page a signed-out visitor sees that this repository actually owns. That is
  precisely why the demo's banner is on a 404 rather than the home page, and it is the honest
  answer to "so which parts *can* I change?": core blocks, the upstream themes, the Obsidian
  components, the C# — everything except the pages people actually look at first.

- **"Why is the test site so slow? / It was fast earlier and now it isn't."** Very likely, and
  it may happen live during the demo. Nothing is broken. The server shuts a site down after
  **20 minutes** of no traffic and starts it again on the next request, and Rock's startup
  rebuilds caches and applies pending migrations before rendering anything. Measured 2026-08-11:
  0.2s warm, idle ~32 minutes, then 62 seconds. Every load after that is sub-second again. Two
  useful follow-ons: a site you *just deployed to* is already warm, because the deploy's health
  check makes a real request as its last step; and if they are about to show their change to
  somebody, open the page a few minutes early. This is on the printed handout too.

- **"Can these test environments break each other?"** *(Most likely from DevOps, and the
  honest answer is yes — say so plainly, because it's the top item on the fix list.)* Every
  test site — staging and all the `pr-*` ones — points at **one shared database**. The web
  servers are separate; the database is not. Rock applies its migrations to that database on
  first load, so two sites on different commits can disagree about the schema, and the one
  that loses serves an error page on every request.

  There is a live example to show if it comes up: **`pr-3` returns a 500 right now**, while
  `pr-4` and `staging` on the same box answer normally — and GitHub still shows PR #3 as
  successfully deployed, because the PR path doesn't check that the site actually came up.
  Don't hide it. It is a better argument for the fix than any slide, and "a catalog per
  environment" is the first thing on the list after this meeting.

  If you want the specifics, they're measured, not guessed — `AssemblySharedInfo.cs` declares
  **18.4.1** on the trunk and on PR #4, and **17.6.1** on PR #3 (its base branch is
  `develop-17.6.1`). So `pr-3` is Rock 17.6 trying to run against a database that Rock 18.4
  already migrated forward. Newer wins; older serves the error page.

  **Be ready for the follow-up — "then could your staging deploy break the demo you just
  showed us?"** The answer is no, and for a specific reason worth saying out loud: `staging`
  and `pr-4` are both **18.4.1**, so a staging deploy runs the exact migration set `pr-4` has
  already run. They're safe because their versions match, *not* because they're isolated —
  they aren't. That holds as long as every live `pr-*` sits on the trunk's minor line. Saying
  this precisely is much stronger than claiming isolation you don't have; if you overclaim
  here, DevOps will find the seam in about ten seconds.

  Resist the urge to redeploy `pr-3` to make it green before the meeting: that just moves the
  breakage to whichever environment matches the schema now.
