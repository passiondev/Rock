# Making a Change to Rock

**Who this is for:** anyone who needs a change made to Rock and wants to know how it gets
from an idea to the live site.

**What you need:** VS Code, and a GitHub account with access to `passiondev/Rock`. You will
not type a single command, and you do not need a Windows machine.

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

> **Your work starts from the repository's default branch, and it goes back to the same
> branch. Never into anything else, and never directly into it.**

Get either half wrong and nothing happens. You get no error message, no warning, and no test
site. It looks exactly like the system is broken. It is working; it simply ignored you.

**Do not memorise the name.** The branch is named after the version of Rock we run, in the
form `passion-<version>`, so it is replaced by a new one at every upgrade. Read it instead of
remembering it:

- Open <https://github.com/passiondev/Rock>
- Whatever branch name the page shows you by default **is** the right one.

That is the only lookup you need, and it is right the day after an upgrade too. Everywhere
below, "the default branch" means the name you just read.

---

## Some words you will see

You do not need to understand these deeply. This is enough.

| Word | What it means |
| --- | --- |
| **Repository** (or "repo") | The folder holding every Rock file, plus a record of every change ever made to any of them. Ours is `passiondev/Rock`. |
| **Clone** | Downloading your own complete copy of the repository onto your Mac. You do this once, ever. |
| **Branch** | Your own private copy of everything. You can edit it freely. Nobody else sees it, and nothing you do in it can affect the live site. |
| **Commit** | One save point, with a short note about what you changed. Saving a file in VS Code is not a commit. |
| **Pull** | Fetching everyone else's recent work down onto your Mac, so your copy is current. |
| **Publish** (or "push") | Sending your branch up to GitHub, where everyone else and all the automation can see it. Until you publish, your work exists only on your laptop. |
| **Pull request** (or "PR") | A bad name for a simple thing. It means: *please pull my change into the shared branch.* It is a web page where your change is reviewed, tested, and approved. |
| **Staging** | A full copy of Rock the whole team can look at, running the same code as production but on a practice database. Nothing there is real. |
| **Production** | The live site. What real people use. |

---

## First time only: get set up

You do this once and never think about it again.

1. Install **VS Code** from <https://code.visualstudio.com>.

2. Open VS Code. On the welcome screen, click **Clone Git Repository...**

3. Paste `https://github.com/passiondev/Rock` and press Enter.

4. It asks where to put it. Pick somewhere you will find again, like your Documents folder.

5. VS Code will ask you to sign in to GitHub. Say yes. It opens a browser, you click
   **Authorize**, and it hands you back. That is all the authentication you will ever do.

6. Wait. **This is a 2.5 GB download** because it brings the entire history of Rock with it.
   Ten to twenty minutes on good wifi. Start it before a meeting, not during one.

7. When it finishes, click **Open**.

You are now on the default branch, because that is what a fresh clone gives you. You can
see its name in the **bottom left corner** of the VS Code window. Get used to looking
there. It is the single most useful thing on the screen.

---

## Part 1 — Make your change in VS Code

Steps 1 to 3 are the ones people skip, and they are the reason changes go wrong.

1. **Look at the bottom left corner.** Click the branch name. A list drops down. Choose the
   **default branch** — the name you read off GitHub above.

2. **Pull.** Next to the branch name there is a small circular-arrows icon. Click it. This
   pulls down everything the team has done since you last looked. If you skip this, you are
   building on a stale copy of Rock, and your pull request will collide with someone else's
   work later.

3. **Make your own branch.** Click the branch name in the bottom left again, and choose
   **Create new branch...** at the top of the list. Type a short name with dashes instead of
   spaces, like `fix-giving-typo`, and press Enter.

   The bottom left corner now shows *your* branch name. This is what should be there for the
   rest of your work.

4. **Open the file.** Press **Cmd+P**, start typing the file name, and press Enter when you
   see it. (The folder tree on the left works too, but Cmd+P is much faster.)

5. **Make your change**, and save it with **Cmd+S**. Saving is not yet a commit. Nothing has
   left your laptop.

6. **Commit it.** Click the **Source Control** icon in the far-left strip, the one that looks
   like a branching line. Or press **Cmd+Shift+G**.

   - Your changed files are listed under **Changes**. Hover over each one you meant to change
     and click the **`+`**. That is "include this in the commit."
   - In the message box at the top, write what you changed in plain English. "Fix typo on
     giving page" is a perfect message.
   - Click the blue **Commit** button.

7. **Publish it.** The blue button now reads **Publish Branch**. Click it.

   Your branch is now on GitHub. Nothing else in this document can happen until you do this.

> **Before every commit, look at the bottom left corner.** If it still shows the default
> branch, stop. Committing and publishing there skips review entirely and deploys
> straight to staging. Nothing protects you from this yet, so the check is yours to make.
>
> If you have already done it, tell Global Engineering. It is fixable, and it is much easier
> to fix in the first ten minutes.

*For a one-word typo, editing the file straight on the GitHub website with the pencil icon
still works and skips all of the above. Everything from Part 2 onward is the same either way.*

---

## Part 2 — Open the pull request

This part happens on the GitHub website.

1. Go to <https://github.com/passiondev/Rock>. There is a yellow banner at the top offering
   your branch, with a **Compare & pull request** button. Click it.

   No banner? Click the branch dropdown, pick your branch, then **Contribute → Open pull
   request**.

2. **Look at the top of the page.** It shows two branch names with an arrow, like
   `base: passion-<version> ← compare: fix-giving-typo`.

   The **left** one is where your change is going. It must be the **default branch**. If it
   says `develop`, `develop-17.6.1`, or anything else, click it and change it now.
   This is the single most common mistake and it is the one that fails silently.

3. Fill in the description. A template is already there. Answer what it asks; it is short.

4. Click **Create pull request**.

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

4. When they approve, click **Merge pull request**, then **Delete branch** when GitHub offers.

5. **Back in VS Code**, click the branch name in the bottom left, choose the default branch,
   and click the circular-arrows icon to pull. Your change is now in there along with everyone
   else's, and your machine is back in step with the team. Do this before you start your next
   change, not when you remember.

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
   | Branch, tag or SHA to deploy | Leave it. It defaults to the branch production is pinned to, which is what you want unless you are rolling back. Note this is **not** always the repository default: during a Rock upgrade production deliberately lags. |
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
| Cloning the repository, once ever | 10–20 minutes, 2.5 GB |
| Branching, editing, committing, publishing | 5 minutes |
| Build after you apply `rock:start` | 25 minutes |
| Installing it onto your test site | 5–10 minutes |
| First page load of a fresh site | 1–2 minutes, once. Reload. |
| Merge to live on staging | about 40 minutes |
| A production deploy, start to finish | about 45 minutes, plus however long approval takes |

---

## When something looks broken

**I added the label and nothing happened at all.**
Almost certainly the branch. Open your pull request and look at the two names at the top: the
left-hand one must be the repository's default branch. If it is wrong, you can change it on an
existing pull request: click it, pick the right one, then re-apply `rock:start`.

**GitHub does not offer me a pull request, and my branch is not in the list.**
You committed but did not publish. Go back to VS Code, open Source Control, and look for a
**Publish Branch** or **Sync Changes** button. Until you click it, your work is only on your
laptop.

**VS Code says my commit failed, or asks me who I am.**
It needs a name and email on this machine once. Tell Global Engineering rather than following
a Stack Overflow answer; it is a thirty-second fix and getting it wrong puts a stranger's
name on your work.

**My pull request says it has conflicts.**
Two people changed the same lines. This is normal and it is not yours to untangle alone. Ask
Global Engineering. It is usually five minutes with the two of you looking at it.

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
> This one is easier to do by accident in VS Code than on the website, because a stray file
> sitting in your Rock folder will show up in the **Changes** list waiting to be included.
> Only ever click the `+` on files you actually meant to change.
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

Editing Rock on your Mac is fine. That is what Part 1 is. What a Mac cannot do is **compile**
Rock, because Rock is built on older Microsoft technology that only Windows can build. This is
not the "harder on a Mac" kind of problem. It genuinely cannot be done, and everyone on this
team has a MacBook.

So instead of anyone building Rock on their own machine, GitHub rents us a clean Windows
computer for the length of each build, compiles Rock there, and installs the result onto our
server in Google Cloud. That is the half hour. It is why you can do all of your own work in
VS Code and still never need Windows.

It also means the passwords for our servers live in one place that only the build can read,
rather than on several laptops, and that "it worked on my machine" stops being a thing anyone
can say.

---

## Who to ask

| Situation | Ask |
| --- | --- |
| Is this a file change or a database change? | Ask before you start. Cheapest question here. |
| Something committed that should not have been | DevOps, immediately |
| A commit that went onto the default branch directly | Global Engineering, immediately |
| A pull request with conflicts | Global Engineering |
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

*This page deliberately names no branch, so it survives a Rock upgrade unedited — read the
repository's default branch instead. Facts here that can still go stale: the warning that
nothing yet stops a commit going onto the default branch directly, and the production-agent
status note in Part 5. Last checked 19 August 2026.*
