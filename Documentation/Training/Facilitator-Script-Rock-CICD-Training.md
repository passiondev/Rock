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
| 0:30 | 5 | Why GitHub builds it | 13–14 | 25 minutes of compiling on a Windows machine none of us owns. |
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

---

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

Slide 14, reason 3 is for the Technology Director: credentials live in GitHub secrets and are
only ever read by a build. They never land on anyone's laptop.

Set the expectation explicitly: **~30 minutes, label to live site.** Better they hear it from
you than discover it while staring at a PR.

### 0:35 — Three doors (slides 15–16, 7 min)

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

### 0:42 — Demo (slide 17, 10 min)

See the runbook below. Narrate the baking-show framing as you go: the 25-minute build is
already done, so you're taking the finished one out of the oven.

### 0:52 — Q&A + asks (slides 18–20, 8 min)

Slides 18–19 are prepared answers — use them as a safety net if the room goes quiet, don't
read them aloud in order.

The one to volunteer even if nobody asks is **"was this working before today?"** Getting
ahead of it is what makes the rest credible:

> "Parts of this were reporting green while being broken. The test server had been powered
> off for three months. The build was looking for Visual Studio in a folder that no longer
> existed. Failures were being forced green. The compiled block JavaScript was never built at
> all — so every test site had zero working Obsidian blocks. And the deploy was overwriting
> the exact theme files people were trying to test. Five separate bugs, all fixed, all with
> tests that fail if they come back. There's a written list of what's still open, and DevOps
> has it."

Close on slide 20: two asks for the team, two for DevOps. End on the last line — *the
pipeline's job is to make a change boring.*

---

## Demo runbook

**Pre-warmed:** PR #4 — <https://github.com/passiondev/Rock/pull/4>
Branch `demo/ptp-cicd-training-walkthrough` · deployed SHA `c78d87c277`
Live: <https://pr-4.rock-dev.connect.passion.team>
Staging: <https://staging.rock-dev.connect.passion.team>

`c78d87c277` is a merge of the trunk into the demo branch, not one of the two demo commits
below. That is deliberate and worth a sentence if anyone asks: the branch was brought up to
date with `passion-18.4.1` and redeployed, which is the same thing they will do to any branch
that has fallen behind. **Files changed** still shows only the three demo files, because GitHub
diffs against the merge base rather than the branch tip.

The two demo commits are chosen so the change is visible without logging in and also proves
the overlay bug is fixed:

1. `a16b5b2c3b` — labels the login page (a core Obsidian block, `login.obs`)
2. `f605feb801` — a banner on every themed page (`Themes/Rock/Layouts/Site.Master`)

Commit 2 is the one that matters technically: `Themes/` is the directory the old deploy used
to overwrite. If the banner is on the page, the `/MIR` bug is genuinely dead.

**Sequence:**

1. **The PR page.** Files changed → three files. One is a one-line Vue change; the other two
   are the theme `Site.Master` layouts. Point out the base branch reads `passion-18.4.1`.
2. **The sidebar.** The label *you* added, and the state labels the robot set in response.
3. **The bot comment.** Status table: `deployed`, the URL, the SHA, the artifact path. Note
   it also lists the commands — the PR documents itself.

   > **One stale line, on purpose.** The comment currently posted ends with "VPN/office network
   > access is required." That is wrong and the text is already fixed in the repo, but a sticky
   > comment only rewrites itself on the next deploy of that PR, and PR #4 is not being
   > redeployed before this meeting. If anyone reads it aloud: the URL is public HTTPS, no VPN,
   > and the next deploy will say so. Don't let it become a five-minute detour.
4. **The Checks tab.** Open the build job, scroll the step list. Don't read it; just let them
   see that every step is named and logged. This is where "it's a black box" dies.
5. **The live site.** Open the pr-4 URL. Show the banner, then the login page label.

   > **Check this the morning of, and don't assume a padlock.** As of 2026-08-11 00:40Z *both*
   > `pr-4` and `staging` serve the same **self-signed** wildcard for
   > `*.rock-dev.connect.passion.team`, so both throw a browser warning. An earlier version of
   > this script claimed pr-4 held a valid Let's Encrypt certificate; that was never measured
   > and it was wrong. Verify with
   > `echo | openssl s_client -connect pr-4.rock-dev.connect.passion.team:443 -servername pr-4.rock-dev.connect.passion.team 2>/dev/null | openssl x509 -noout -issuer`
   > — if the issuer names Let's Encrypt you have a real certificate; if issuer and subject
   > match, it is self-signed and you will get the warning.
   >
   > If the warning is there, own it in one sentence and move: *"These test hosts are on an
   > internal certificate — the real site isn't, and getting a public certificate onto them is
   > on the open list."* Click through once, deliberately, and say you're doing it. Do **not**
   > teach the room that clicking through warnings is routine.
   >
   > Better: pre-accept the certificate in the demo browser profile before the meeting so the
   > warning never appears on the projector.
6. **Staging.** Open the staging URL. Same trunk, no banner — that's the point: staging shows
   what's merged, the PR site shows what's proposed.
7. **Optional, if time and if it's warm:** push a trivial third commit and watch `deployed`
   flip to `building` within seconds. Only do this if you're at 0:46 or earlier — you're
   showing the *transition*, not waiting for the build.

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

- [ ] <https://pr-4.rock-dev.connect.passion.team> loads and the banner is visible.
      No VPN needed — 443 is open to the world on the test VM.
- [ ] <https://staging.rock-dev.connect.passion.team> loads.
- [ ] PR #4 still shows `rock-test:deployed`.
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
- **Don't promise dates** for the production agent install — that's a joint decision with
  DevOps, in the room.
- **Don't demo the operator hot-deploy path.** Describe it if asked. Doing it live teaches
  the wrong lesson about how urgent fixes should work.
- **Don't open a terminal.** The entire promise of this session is that they never need one.

---

## Questions you may not have an answer for

Say "I don't know, I'll find out" rather than improvising. These are the plausible ones:

- **"How much does this cost per month in GitHub Actions minutes?"** Windows runners bill at
  a higher multiplier than Linux, and a full build is ~25 minutes. Not measured yet — worth
  putting a number on before anyone asks twice.
- **"Can we have a test environment with a copy of real data?"** A real request with real
  privacy consequences. Don't answer in the room; it's a DevOps + Director decision.
- **"What happens if two people merge at once?"** Staging deploys supersede each other by
  design — the newer commit cancels the older in-flight one. Nobody's change is lost, because
  the newer build already contains it.
- **"Who can approve a production deploy?"** Whoever is on the `production` environment's
  reviewer list — which doesn't exist yet. That's item 5 on the open list, and configuring it
  *is* the answer to this question.
