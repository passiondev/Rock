# Fork-local changes to Rock's own source

**Audience:** whoever is merging a new Rock version into this fork.
**Measured against upstream** `19.4.4` · **Upstream remote** `https://github.com/SparkDevNetwork/Rock.git`
**Derived, not hand-collected** — see the command at the bottom.

Everything Passion has *added* to this repository — the CI pipeline, the deploy scripts,
the runbooks, `Tests/PrTestEnvironments/` — is safe at a merge. New files do not conflict
with anything and nothing upstream will quietly take them away.

What is not safe is an edit to a file Rock also owns. Those are the changes a merge
resolves *for* you, and "take theirs" on one of them silently reverts a fix or deletes a
feature while every test stays green. That is item 26's shape, and it has already
happened here once.

This page is the list of them. It is short on purpose and it is derived, so it cannot
quietly fall behind: `test_upgrade_diff.py` re-computes the set from the upstream tag and
fails if this file misses one or lists one that upstream has since absorbed. That check
runs in CI as well as on a laptop — the pipeline fetches the tag named above from the
remote named above, and a test that cannot find it fails there rather than skipping,
because in CI a missing tag means the fetch broke and not that the clone is fresh.

There are no commit SHAs below, deliberately. This working copy is a shallow clone, where
`git log <ref> -- <path>` answers with the graft commit for every path and attribution is
not recoverable. The file list is derived from tree comparison, which is exact; a column
of confidently wrong SHAs beside it would be worse than no column.

The list was longer than anyone expected when it was first derived on 2026-08-20. The
working belief — written down in more than one place — was that the icon migration was
the only spot where the fork changes Rock's behaviour. It is one of eight files across
four entirely unrelated changes.

Re-derived against 19.4.4 on 2026-09-14, at the 19.3.4 -> 19.4.4 bump, and the set came
back byte-for-byte the same eight files. Nothing was resolved towards upstream and nothing
upstream has absorbed yet -- in particular the icon migration below is still fork-local, so
item 1 has not been retired. That is step 3 of the procedure at the bottom of this page,
and this paragraph is its answer for this bump.

---

## 1. The Tabler icon migration skips LOB columns

- `Rock.Migrations/Migrations/Version 19.0/Version 19.0/202603271810501_ReplaceFontAwesomeWithTablerIcons.cs`

**What it does.** Adds two predicates to the cursor that collects `IconCssClass` columns,
so it takes only `nvarchar`/`varchar`/`nchar`/`char` columns from non-system tables.

**Why it exists.** The `UPDATE` the migration generates joins `IconCssClass` against
`__IconTransition.FontAwesomeFull`, which is `NVARCHAR(75)`. SQL Server will not put a
`text` or `ntext` column on either side of `=`. Every table's `UPDATE` is concatenated
into one batch and run by a single `sp_executesql`, so **one** LOB column anywhere fails
the conversion for **every** table. This is what blocked the v19 upgrade outright.

**If a merge drops it,** the v19 upgrade stops being possible again, and the failure
surfaces as a conversion error naming a table that has nothing to do with the real cause.

**Retire it when** upstream fixes the cursor. Check the file at the next merge before
re-applying: this is a bug report worth sending to SparkDevNetwork, and once it is fixed
upstream this entry should be deleted rather than carried.

## 2. FormBuilder forms can carry a header image

- `Rock.Blocks/WorkFlow/FormBuilder/FormBuilderDetail.cs`
- `Rock.ViewModels/Blocks/WorkFlow/FormBuilder/FormGeneralViewModel.cs`
- `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/FormBuilder/FormBuilderDetail/generalSettings.partial.obs`
- `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/FormBuilder/Shared/types.partial.ts`

**What it does.** Adds a `HeaderImage` picker to the FormBuilder general-settings panel
and renders the chosen image at the top of the user-facing form. The value is stored in a
`HeaderImage` entity attribute on `WorkflowType` rather than in a column, so it can be
read from Lava on the entry page.

**Why it is fragile.** It spans four files across three layers — C# block, view model,
and two Obsidian components. A merge that resolves any one of them towards upstream
leaves the other three referencing a member that no longer exists, and the break shows
up as a build error a long way from the file that caused it.

**If a merge drops it,** forms lose their header image with no error anywhere.

**Nothing tests it.** There is no coverage of this feature in the repository, so the only
thing standing between it and a bad merge is this page. That is worth fixing separately.

## 3. Workflow person entry is full width

- `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/WorkflowEntry/Actions/entryFormPersonEntry.partial.obs`

**What it does.** Two edits to the person-entry block on workflow forms. The primary
person editor becomes full width (`col-md-12` in place of `col-md-6`), and the spouse
editor moves out of that column into a row of its own. Net effect is a two-line file
growth, because the change relocates markup rather than adding any.

**Why it is listed separately.** Until 2026-08-26 this file sat under item 2, described
as part of the header image. It is not: the file contains no `HeaderImage` reference at
all, and the two changes touch different screens. Grouping them meant the entry told
whoever was merging to look for image code in a file that has none.

**If a merge drops it,** person-entry forms silently return to half width with the spouse
editor beside the primary. Nothing fails to compile and no error is logged, so the only
signal is someone noticing the form looks different.

**Not this entry:** the Campus dropdown's `rules="required"` in this same file is
upstream's, added between `hotfix-18.4` and `hotfix-19.3`. It was briefly recorded here
as fork-local on 2026-08-26 and is not. Take upstream's version of that attribute at
every merge. The layout above is the only thing in this file worth protecting.

## 4. The internal-site themes carry Passion's branding

- `RockWeb/Themes/Rock/Styles/_variable-overrides.less`
- `RockWeb/Themes/RockManager/Styles/_variable-overrides.less`

**What it does.** Sets Passion's colours on the two themes the internal site uses, and
registers the Font Awesome Pro weights. The `Rock` theme takes eight lines: `@fa-edition:
'pro'`, two `.fa-font-face` calls for the Regular and Light weights, and five colours led
by `@brand-color: #00b8e4`. `RockManager` takes one, `@brand-color: #00b8e4`. Both files
now match what production serves, byte for byte.

**Why it exists.** It did not, until 2026-08-26 — that is the point of the entry. These
were hand edits on the production box, dated 2026-01-22 and 2026-07-30 and present in no
repository. Production has never had an automated deploy, so nothing had overwritten them
yet, but the InPlace copy is plain `robocopy /E` and both paths are inside the artifact.
The v19 cutover would have been the first run to reach them, and it would have reverted
the internal site to stock Rock orange with no warning and no log line. Staging showed the
outcome in advance: it deployed from the artifact, came up orange, and got its blue put
back by hand through the admin UI — a staging-only database value that fixed the symptom
in one environment and left the cause in place.

`_variables.less` is *not* here and does not need to be. Both boxes run it unmodified, so
the whole difference between a branded Rock and a stock one is the override file, which is
the file upstream provides for exactly this.

**If a merge drops it,** the staff-facing site reverts to Rock's default orange on the next
deploy, and every Font Awesome Pro icon falls back to an empty box because
`@fa-edition: 'pro'` stops being set. Nothing fails to compile and nothing is logged.
`test_theme_branding.py` is the guard: it pins the colours and the Pro registration so a
take-theirs resolution fails CI instead of shipping.

**Not this entry:** the Pro *webfont binaries* are deliberately absent from git. This
repository is a public fork and the fonts are licensed, so they stay on the servers and
reach a deploy through `$ServerOwnedDirectories` in `Deploy-RockEnvironment.ps1`. The
override file above only names the weights; it does not carry them.

## 5. The LMS program tabs carry icons and follow a course's own page

- `RockWeb/Themes/Rock/Assets/Lava/LMSPageListAsTabs.lava`

**What it does.** Rewrites the template that draws the tabs across a Learn program's pages
(Courses, Classes, Completions, Semesters). Each tab carries its page's icon, falling back
to the parent's. Courses and Semesters stay highlighted on a single course or semester as
well as on their own page: a course is its own page nested under Courses, and
`childPage.Current` marks only an exact match, so the template checks for the
`LearningCourseId` and `LearningSemesterId` page parameters instead. Semesters is hidden
for On-Demand programs, decided by a `{% sql %}` lookup of the program's
`ConfigurationMode`. The block's Include Page List now renders ahead of the tabs. It is the
only place in this file an extra link can come from, so PR #21's "back to programs" tab
is presumably an entry there, which is block configuration in the database, not part of
this file. Check the block's settings before relying on that.

**Why it exists.** PR #21 restored it on 2026-10-20. Its description says the change had
been made before and was overwritten at the upgrade, so it is item 4's shape again: an edit
that lived outside git until a deploy replaced it with Rock's copy.

**Read the lookup carefully before changing it.** Its naming is inverted, and the
inversions cancel. `ConfigurationMode = 0` is `AcademicCalendar`
(`Rock.Enums/Lms/ConfigurationMode.cs`), not On-Demand as the SQL comment says, so
`programIsOnDemand` is true for calendar programs. The tab is skipped when
`programIsOnDemand == false`, which inverts it back, so Semesters shows exactly where the
template's header says. Correct both or neither: fixing only the number hides Semesters
from every calendar program. The block also needs the `Sql` Lava command enabled, as the
header says, or the lookup renders a Lava error in place of a result.

**If a merge drops it,** the tabs go back to Rock's plain text list: no icons, none of
the Include Page List links, Courses unhighlighted on a course's page, and Semesters shown
on On-Demand programs. Nothing fails and nothing is logged.

---

---

## Re-deriving this list

Needs the upstream remote, which a fresh clone does not have:

```bash
git remote add upstream https://github.com/SparkDevNetwork/Rock.git   # once
git fetch upstream --tags

python3 Deployment/Repository/upgrade_diff.py fork-local 19.4.4
```

Replace `19.4.4` with whatever `<Version>` in `Directory.Build.props` says. The two must
agree, and `test_upgrade_diff.py` fails when they do not.

Paths under `.github/`, `Deployment/`, `Documentation/`, `Tests/PrTestEnvironments/` and
`.gitignore` are excluded. The fork owns those outright; they are modified relative to
upstream permanently and by design, and including them would bury the entries above.

## What to do at a merge

1. Re-derive the list against the **outgoing** version first, so you know what you are
   carrying before anything is resolved.
2. Merge.
3. Re-derive against the **incoming** version. Anything that has dropped off the list was
   resolved towards upstream — check each one was meant to be.
4. Update this page and the `Measured against upstream` line together.

Step 3 is the one that matters. Steps 1 and 2 tell you what should survive; only step 3
tells you what did. Item 23 covers the rest of the repo-side cutover work.
