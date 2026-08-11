# Making a Change to Rock

**Who this is for:** anyone who needs a change made to Rock and wants to know how it gets
from an idea to the live site.

**What you need:** a GitHub account with access to `passiondev/Rock`, and a web browser.
You do not need to install anything. You do not need to use a command line.

**Time:** about ten minutes of your attention, and about forty minutes of waiting. Most of
the waiting is a computer working, not you.

---

## Start here: is this actually a file change?

A lot of what looks like "changing the website" in Rock is not a file, and none of this
document applies to it. If what you want to change is:

- text inside an HTML Content block
- a page's name or its web address
- Lava inside a block's settings
- a workflow, a report, or a data view

...then you change it by signing in to Rock as an administrator and editing it on the live
site. It is a database record, not a file, and this process never touches it.

This document is for changes to **files**: themes, stylesheets, images, and block code.

> **If you are not sure which kind of change you have, ask before you start.** Guessing wrong
> costs about an hour. Nobody minds the question.

---

## The one rule

Everything else in this document is detail. This is the part that matters:

> **Your change must go into the branch named `passion-18.4.1`.**

If it goes anywhere else, nothing happens. You get no error message, no warning, and no test
site. It looks exactly like the system is broken. It is working; it simply ignored you.

**That name will change.** It is named after the version of Rock we run, so when we upgrade
to Rock 19 it becomes something like `passion-19.3.4`. Do not memorise it. Instead:

- Open <https://github.com/passiondev/Rock>
- Whatever branch name the page shows you by default **is** the right one.

---

## Some words you will see

You do not need to understand these deeply. This is enough.

| Word | What it means |
| --- | --- |
| **Repository** (or "repo") | The folder holding every Rock file, plus a record of every change ever made to any of them. Ours is `passiondev/Rock`. |
| **Branch** | Your own private copy of everything. You can edit it freely. Nobody else sees it, and nothing you do in it can affect the live site. |
| **Commit** | One save point, with a short note about what you changed. |
| **Pull request** (or "PR") | A bad name for a simple thing. It means: *please pull my change into the shared branch.* It is a web page where your change is reviewed, tested, and approved. |
| **Staging** | A full copy of Rock the whole team can look at, running the same code as production but on a practice database. Nothing there is real. |
| **Production** | The live site. What real people use. |

---

## Part 1 — Make your change

All of this happens in a web browser.

1. Go to <https://github.com/passiondev/Rock>.

2. Check the branch name in the button near the top left of the file list. It should say
   **`passion-18.4.1`**. If it says anything else, click it and pick that one.

3. Click your way to the file you want to change.

4. Click the **pencil icon** at the top right of the file. That is "edit".

5. Make your change.

6. Click the green **Commit changes...** button.

7. A box appears. This is the important part:
   - In the message field, write what you changed, in plain English. "Fix typo on giving page"
     is a perfect message.
   - Below that, choose **"Create a new branch for this commit and start a pull request."**
     *(Do not choose the option that commits directly.)*
   - It suggests a branch name. Accept it, or type something short like `fix-giving-typo`.

8. Click **Propose changes**.

That is it. You have made a branch, saved your change into it, and started a pull request, all
in one step. You never touched a command line.

---

## Part 2 — Open the pull request

GitHub now shows you a new-pull-request page.

1. **Look at the top of the page.** It shows two branch names with an arrow, like
   `base: passion-18.4.1 ← compare: fix-giving-typo`.

   The **left** one is where your change is going. It must say **`passion-18.4.1`**. If it
   says `develop`, `develop-17.6.1`, `staging`, or anything else, click it and change it now.
   This is the single most common mistake and it is the one that fails silently.

2. Fill in the description. A template is already there. Answer what it asks; it is short.

3. Click **Create pull request**.

You now have a pull request page. This page is where everything else happens. Bookmark it.

---

## Part 3 — Get yourself a test site

You get a private, working copy of Rock with your change in it, at its own web address. You
ask for it by adding a label.

1. On your pull request page, find **Labels** in the right-hand sidebar. Click the gear icon.

2. Choose **`rock:start`**.

3. Walk away for about half an hour.

A comment will appear on your pull request from the automation, containing the web address of
your test site. Open it.

### The labels

You only ever apply the four in the first group. The rest are the system telling you where it
is up to; leave them alone.

| Label | What it does |
| --- | --- |
| `rock:start` | **You apply this.** Build my change and give me a test site. |
| `rock:stop` | **You apply this.** Shut the test site down, keep it for later. |
| `rock:destroy` | **You apply this.** Delete the test site completely. |
| `rock:auto` | **You apply this.** Rebuild automatically every time I push a change. |
| `rock:queued` `rock:building` `rock:deploying` `rock:deployed` `rock:stopped` `rock:failed` | The system sets these. They are a status light. `rock:deployed` means your site is up. |

### Things to know about your test site

- **It is on a practice database that everyone shares, and it gets reset.** Do not build a
  demonstration on data you need to keep.
- **It sends no email, no texts, and takes no payments.** Scheduled jobs do not run.
- **The first time you load it, it will take one to two minutes.** Rock is setting itself up.
  Reload once. It is quick after that. If you are about to show someone, open it a few minutes
  early so it is already awake.
- **You can open it from anywhere,** including your phone. There is no VPN.
- **If your change is not visible, that does not mean it failed.** Some of Passion's Rock, the
  front page and the login box in particular, lives outside this repository. Check a page this
  repository actually owns.

---

## Part 4 — Review, then merge to staging

1. On your pull request, open the **Files changed** tab and read your own change. Confirm it is
   what you meant. This takes ten seconds and catches most mistakes.

2. Check the **Checks** tab shows a green tick. Green means it compiled. Red means it did not,
   and the change will not work anywhere until it is fixed.

3. Ask someone to review it. Add them under **Reviewers** in the sidebar.

4. When they approve, click **Merge pull request**.

**Merging automatically puts your change on staging.** About forty minutes later it is live at
staging for the whole team to see. You do not do anything to make that happen and there is no
button to press.

**Merging also deletes your test site.** That is deliberate. If you want to keep it, close the
pull request without merging instead, which only pauses it.

> **Merging does not touch the live site.** There is no branch you can push and no label you can
> add that reaches production. That is a separate, deliberate act, described next.

---

## Part 5 — Deploy to production

This is a different kind of operation from everything above. It is manual, it needs two
people, and it is the only path to the live site.

**Who does this:** whoever is authorised to release. Not part of a normal change.

1. Go to the **Actions** tab of the repository.

2. In the left sidebar, choose **Deploy Production**.

3. Click **Run workflow**. Three fields appear:

   | Field | What to put |
   | --- | --- |
   | Branch, tag or SHA to deploy | Leave it. It defaults to `passion-18.4.1`, which is what you want unless you are rolling back. |
   | Actually deploy | **Leave this unchecked the first time.** |
   | Only for a real Rock upgrade | Leave unchecked. This is only for a Rock version upgrade. |

4. Click the green **Run workflow** button.

   With "Actually deploy" unchecked, this is a **dry run**. It works out exactly what it would
   do, writes it down for you, and changes nothing at all. Read what it says.

5. Happy with the plan? Run it again, this time **with "Actually deploy" checked**.

6. It builds the site, which takes about half an hour, and then **stops and waits**. A second,
   named person has to approve it before anything reaches the live site. Not even a repository
   administrator can skip this.

7. Once approved, the deploy runs. On the server it backs up the current site, stops Rock,
   copies the new files over, starts Rock again, and then waits until the site answers before
   declaring success.

### What a production deploy will never do

- It never deletes uploaded content, logs, or Rock's cache. Those belong to the server.
- It never writes the production database password. That stays on the server and CI never sees
  it, which also means a deploy cannot accidentally point the live site at the wrong database.

### Rolling back

Run **Deploy Production** again and give it the previous good commit instead of the branch
name. Rolling back and going forward are the same operation, on purpose, so there is no
separate emergency procedure to get wrong under pressure.

If you need it faster than a build takes, the previous version of the site is still sitting on
the server under `C:\RockBackups\production\`. That is a conversation with DevOps.

> **Status, as of 11 August 2026**
>
> The production path is built and gated, but the final piece (the agent on the production
> server that picks up and runs the deploy) **is not installed yet**. Until DevOps installs
> it, a production run will build and wait for approval correctly, and then have nothing to
> hand the work to.
>
> **Confirm with DevOps before the first real production deploy.** It needs a brief window
> where Rock stops and starts, so it gets scheduled rather than squeezed in.

---

## How long everything takes

Nothing here is queuing or stuck. It is genuinely this slow, for a reason described at the
bottom of this page.

| Step | Roughly |
| --- | --- |
| Making the change in the browser | 2 minutes |
| Build after you apply `rock:start` | 25 minutes |
| Installing it onto your test site | 5–10 minutes |
| First page load of a fresh site | 1–2 minutes, once. Reload. |
| Merge to live on staging | about 40 minutes |
| A production deploy, start to finish | about 45 minutes, plus however long approval takes |

---

## When something looks broken

**I added the label and nothing happened at all.**
Almost certainly the branch. Open your pull request and look at the two names at the top: the
left-hand one must be `passion-18.4.1`. If it is wrong, you can change it on an existing pull
request: click it, pick the right one, then re-apply `rock:start`.

**My change is not showing up, but the build was green.**
Three usual causes. Check your change is actually in the **Files changed** tab. If it is a
stylesheet, Rock has to rebuild the theme (in Rock: Admin → CMS → Themes). If it is HTML
Content block text or a page setting, it was never a file. See the top of this page.

**Every page is failing.**
Open staging. If staging is broken too, it is not your change.

**The site is very slow, or timed out.**
If it is the first load after a build, that is expected. Reload once.

---

## Two ways to cause real damage

Everything else in this process is safe to get wrong. These two are not.

> **1. This repository is public.**
>
> Rock is open-source software and our copy of it is public too. Anything committed is visible
> to anyone on the internet, permanently, **including after you delete it in a later change**,
> because the history keeps it.
>
> Never commit a password, a connection string, an API key, or any export containing member
> names, emails, phone numbers, or giving data.
>
> If it happens, tell DevOps immediately so the credential can be replaced. Deleting it is not
> enough.

> **2. A database change in your pull request hits the shared database.**
>
> Test sites share one practice database. A change to the database structure affects everyone
> using it, and you cannot take it back.
>
> If your change includes one, tell DevOps **before** you apply `rock:start`.

---

## Why it works this way

Rock is built on older Microsoft technology that can only be compiled on Windows. Everyone on
this team has a MacBook. This is not the "harder on a Mac" kind of problem. It genuinely
cannot be done.

So instead of anyone building Rock on their own machine, GitHub rents us a clean Windows
computer for the length of each build, compiles Rock there, and installs the result onto our
server in Google Cloud. That is the half hour. It is why all of your work happens in a browser
and why nobody needs Windows.

It also means the passwords for our servers live in one place that only the build can read,
rather than on several laptops, and that "it worked on my machine" stops being a thing anyone
can say.

---

## Who to ask

| Situation | Ask |
| --- | --- |
| Is this a file change or a database change? | Ask before you start. Cheapest question here. |
| Something committed that should not have been | DevOps, immediately |
| A database change in a pull request | DevOps, before you apply the label |
| A production deploy | DevOps and Global Engineering, together |
| Anything in this process that feels risky | Global Engineering. If it feels like a risk, that is a bug worth reporting. |

---

## If you want the long version

This page is deliberately the short one. In the repository:

- `Documentation/Local-Engineering-Training-Edit-Test-and-Deploy.md` — the full version,
  including nine specific traps and what to do about each, a glossary, and known issues.
- `Documentation/PR-Test-Environments-Developer-Runbook.md` — the labels in more detail.
- `Documentation/PR-Test-Environments-Operator-Runbook.md` — for whoever is running the servers.

---

*Facts on this page that will go stale: the branch name `passion-18.4.1` changes at every Rock
upgrade (read the repository's default branch instead), and the production-agent status note in
Part 5. Last checked 11 August 2026.*
