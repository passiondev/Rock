# Fork-local changes to Rock's own source

**Audience:** whoever is merging a new Rock version into this fork.
**Measured against upstream** `19.3.4` · **Upstream remote** `https://github.com/SparkDevNetwork/Rock.git`
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
the only spot where the fork changes Rock's behaviour. It is one of six files across two
entirely unrelated changes.

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
- `Rock.JavaScript.Obsidian.Blocks/src/WorkFlow/WorkflowEntry/Actions/entryFormPersonEntry.partial.obs`

**What it does.** Adds a `HeaderImage` picker to the FormBuilder general-settings panel
and renders the chosen image at the top of the user-facing form. The value is stored in a
`HeaderImage` entity attribute on `WorkflowType` rather than in a column, so it can be
read from Lava on the entry page.

**Why it is fragile.** It spans five files across three layers — C# block, view model,
and three Obsidian components. A merge that resolves any one of them towards upstream
leaves the other four referencing a member that no longer exists, and the break shows up
as a build error a long way from the file that caused it. Worse, a resolution that takes
upstream's `entryFormPersonEntry.partial.obs` cleanly would compile fine and simply stop
rendering the image.

**If a merge drops it,** forms lose their header image with no error anywhere.

**Nothing tests it.** There is no coverage of this feature in the repository, so the only
thing standing between it and a bad merge is this page. That is worth fixing separately.

---

## Re-deriving this list

Needs the upstream remote, which a fresh clone does not have:

```bash
git remote add upstream https://github.com/SparkDevNetwork/Rock.git   # once
git fetch upstream --tags

python3 Deployment/Repository/upgrade_diff.py fork-local 19.3.4
```

Replace `19.3.4` with whatever `<Version>` in `Directory.Build.props` says. The two must
agree, and `test_upgrade_diff.py` fails when they do not.

Paths under `.github/`, `Deployment/`, `Documentation/`, `Tests/PrTestEnvironments/` and
`.gitignore` are excluded. The fork owns those outright; they are modified relative to
upstream permanently and by design, and including them would bury these six.

## What to do at a merge

1. Re-derive the list against the **outgoing** version first, so you know what you are
   carrying before anything is resolved.
2. Merge.
3. Re-derive against the **incoming** version. Anything that has dropped off the list was
   resolved towards upstream — check each one was meant to be.
4. Update this page and the `Measured against upstream` line together.

Step 3 is the one that matters. Steps 1 and 2 tell you what should survive; only step 3
tells you what did. Item 23 covers the rest of the repo-side cutover work.
