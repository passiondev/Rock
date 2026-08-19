# 2026-08-18 — the v19 staging deploy migrated the shared sandbox catalog

**Status:** **Resolved 2026-08-19.** Staging is serving 19.3.4 from its own catalog
(`RockStaging`) and the trunk has cut over. No production system was touched at any point.

*At the time:* staging was down, and the shared sandbox catalog was stranded between Rock
18.4.1 and 19.3.4 and needed a restore.

Everything below the header is the record as written during the incident and is left in the
present tense on purpose. What happened afterwards is in **Follow-up** and in
**What the cutover surfaced next**, both at the end.

A separate document because it is an incident with a timeline and a recovery, not an
open item. The follow-up work it generates lives in
`Training/DevOps-Open-Items-Rock-CICD.md`.

## What happened

A manually dispatched staging deploy of `passion-19.3.4` (run `32127109855`) ran its
Entity Framework migrations against `RockConnectProd` on `connect-restore-test` — the
prod-derived sandbox catalog that **every `pr-*` site also uses** — rather than against a
catalog of its own.

`vars.STAGING_DB_NAME` has never been set. The only repository variable is
`PR_TEST_GCS_BUCKET`. So `db_name` resolved to the empty string and took the documented
fallback, which the run log records plainly:

```
db_name:
DB_NAME_SOURCE: shared sandbox fallback (secrets.DB_NAME)
DB_NAME_REQUESTED:
```

Rock applies EF and plugin migrations at `Application_Start`, so the migration started on
the first request after the files landed. A **core** EF migration then failed:

```
Error occurred in RunApplicationStartup:
The data types text and nvarchar are incompatible in the equal to operator.
  at System.Data.Entity.Migrations.DbMigrator.ApplyMigration(...)
  at Rock.WebStartup.RockApplicationStartupHelper.MigrateDatabase(...)
```

Some column in this catalog is still the legacy `text` type where a v19 migration compares
it with `=`. That is schema drift carried in the prod-derived data, which is why no
clean-build check caught it.

EF wraps each migration in its own transaction, so the failing one rolled back — and every
migration applied before it stayed committed. The catalog is part-migrated.

The site has been crash-looping on a roughly 65-second cycle ever since: each restart
retries the same migration, fails the same way, and returns HTTP 500.

## Timeline (UTC)

| Time | Event |
| --- | --- |
| 09:37:38 | `passion-18.4.1` deploy to staging succeeds. Staging healthy. |
| 10:04:02 | On-demand backup of `connect-restore-test` completes. **Clean restore point.** |
| 10:25–10:28 | pr-3, pr-4 and pr-5 destroyed. Nothing left on the shared catalog. |
| 10:30:41 | v19 staging deploy dispatched. |
| 11:02:56 | Deploy command queued to the VM. Shared-catalog warning emitted, run continues. |
| 11:05:31 | v19 files written to `C:\RockTestEnvs\staging\site`. |
| 11:05:35 | First startup failure. Crash loop begins. |
| 11:22:11 | Agent writes a diagnostics dump. |
| 11:30:23 | Agent gives up: "did not become healthy within 900 seconds". Run fails. |

## Why nothing stopped it

`pr-test-deploy.yml` refuses a PR whose base branch is not the pinned one. That guard is
what keeps the `pr-*` fleet on a single Rock minor.

`staging-deploy.yml` had **no equivalent**. It carried the invariant as a header comment,
and `env-deploy-command.yml` emitted a `::warning::` when `db_name` resolved empty. The
warning fired exactly as designed. A warning does not stop a deploy, and by the time
anyone reads it the migration has already run.

## Blast radius

Contained, mostly by luck of timing. pr-3, pr-4 and pr-5 were destroyed at 10:25–10:28,
so no `pr-*` site was pointed at the catalog while it was being migrated, and none is
now. The next PR deploy would have started an 18.4.1 site against a part-v19 catalog —
the same failure that put pr-3 on a permanent HTTP 500 on 2026-08-11.

Production was not involved at any point. `connect-prod` is a different instance, it has
automated backups and point-in-time recovery enabled, and nothing in this run addressed it.

## Recovery

There is a clean restore point: the **on-demand backup at 10:04:02Z**, taken after the
healthy 18.4.1 deploy and before v19 started.

`RockConnectProd` is the only user database on `connect-restore-test`, so a whole-instance
restore has no collateral damage. That matters, because Cloud SQL restores the instance,
not a single database.

This needs a person to run, because it replaces the instance:

```
gcloud sql backups restore 1787047442610 \
  --restore-instance connect-restore-test \
  --project passioncitychurch-com
```

Confirm the backup id first — `gcloud sql backups list --instance connect-restore-test`.
After the restore, redeploy `passion-18.4.1` to staging to put matching code on the
catalog.

Note that `connect-restore-test` has **automated backups and PITR both disabled**. The
10:04 backup exists because someone took it by hand before the deploy. Without it the
recovery position here would have been considerably worse. See open item 22.

## Follow-up

- **Done (this change).** `staging-deploy.yml` now refuses a Rock minor change while
  `STAGING_DB_NAME` is unset, in the `resolve` job, before anything is built or deployed.
  The way past the guard is to give staging its own catalog, which is the documented
  migration path rather than a bypass.
- **Done 2026-08-18.** Restored, then redeployed. Staging recovered.
- **Done 2026-08-18.** Automated backups, PITR with 7-day log retention, and unlimited
  `storageAutoResize` are all enabled on `connect-restore-test` (open item 22, now closed).
  The autoresize was not in the original list and turned out to be a prerequisite: the copy
  in the next item would otherwise have risked filling a disk that was already half full.
- **Done 2026-08-18.** `RockStaging` provisioned on `connect-restore-test` by
  `gcloud sql export bak` / `import bak` from `RockConnectProd` (~29 min out, ~24 min back),
  probed read-only with the legacy-column finder before the switch, then `STAGING_DB_NAME`
  set. Staging has its own catalog; the `pr-*` fleet still shares `RockConnectProd`.
- **Done (this change).** `pr-test-deploy.yml` no longer reads `vars.STAGING_DB_NAME`; the
  fleet has its own `vars.PR_TEST_DB_NAME`. Both are unset and both fall back to
  `secrets.DB_NAME`, so nothing moves today — but setting staging's variable now moves
  staging alone. That the two were one variable is the reason there was nowhere to try v19
  before trying it here.
- **Done (this change).** `Deployment/Database/Find-LegacyTextColumns.ps1` (read-only) and
  `Convert-LegacyTextColumns.ps1` (`-Apply`-gated, explicit columns, generated rollback).
  The finder also prints the `__MigrationHistory` high-water mark, which is what names the
  last migration to commit on a stranded catalog.
- **Done 2026-08-18 — and the answer was not what this item assumed.** The finder reported
  67 legacy `text` columns and **not one of them in a Rock table**. All of them sit in
  leftover scratch: `RESTORE_Step`, `RESTORE_Step_Attribute`, `RESTORE_Step_Attribute_Values`,
  `RESTORE_StepType`, and one column in `scheduler_log`. The migration that dies opens a
  cursor over *every* user table with a column named `IconCssClass`, with no `is_ms_shipped`
  filter and no allow-list, and exactly two of those scratch columns are typed `text`. So the
  blocker was 2 columns and 24 rows in tables Rock does not own — not core schema drift.
  **This changes the production forecast:** production is only exposed if it carries the same
  scratch tables, which is a question about one prefix rather than a catalog-wide audit.
- **Superseded 2026-08-19 — the blocker is fixed in code, so production no longer depends on
  the state of its catalog here.** `aead938018` narrows the migration's cursor to
  `TYPE_NAME( c.system_type_id ) IN ( 'nvarchar', 'varchar', 'nchar', 'char' )` and
  `t.is_ms_shipped = 0`, so a `text` column named `IconCssClass` is skipped rather than joined
  to `__IconTransition.FontAwesomeFull` and throwing. That matters more than a data cleanup
  would: every table's UPDATE is concatenated into one batch and run by a single
  `sp_executesql`, so one bad column failed the whole statement for every table.

  Staging then migrated 18.4.1 → 19.3.4 against `RockStaging` — a faithful copy of the
  prod-derived catalog, carrying all 67 legacy columns and all four `RESTORE_*` tables — and
  came up clean. That is the same catalog shape production will present, so the guard has been
  exercised against the real case rather than a reduced one.

  Two things this does **not** retire. It is a local edit to an upstream Rock migration, the
  only one in the fork, so it has to survive the next upgrade's merge — see the fork-diff
  count in the facilitator script, which exists to make that visible. And the `RESTORE_*`
  tables are still scratch that nobody owns and should still be dropped; that is now hygiene
  with a rollback rather than a prerequisite blocking the cutover. Running the finder against
  production stays worthwhile for the same reason — to know what is there — but it is no
  longer something the cutover waits on.
- **Open — one line, blocked on PR #10.** `test_powershell_edition_compatibility.py` scans
  `Deployment/PrTestEnvironments` for PowerShell 7-only syntax and now misses
  `Deployment/Database`. Point it at both directories once that PR lands; duplicating its
  table onto this branch would only create a merge conflict for the sake of it.


## What the cutover surfaced next (2026-08-19)

Recorded here rather than as its own incident, because it is the same cutover and the same
class of defect: something that is generated rather than committed, and that nothing in CI
was producing.

Once staging came up on 19.3.4 against its own catalog, the login page rendered correctly and
every page behind it did not. That reads like a theme or a permissions problem, and it was
neither.

`RockWeb/Styles/styles-v2/` is committed on the 18.4.1 line — 178 files — and on 19.3.4 its
`.gitignore` is `*`, because the content is generated by the `Rock.Frontend.Styles` project
instead. No workflow in this repo referenced that project, so the v19 artifact shipped without
it. `RockWeb/Styles/_rock-core.less:243` does `@import (less) "styles-v2/icons/tabler-icon.css"`,
that file 404'd, Rock's LESS compile failed at startup, and the site went on serving whatever
`theme.css` was already on disk — the 18.4.1 build, with no Tabler rules in it. Meanwhile
`202603271810501_ReplaceFontAwesomeWithTablerIcons` had already rewritten every `IconCssClass`
in the database to Tabler classes, and the webfont deployed fine. So the classes resolved to
nothing.

Measured, staging against production:

| | staging (19.3.4, broken) | production (18.4.1) |
|---|---|---|
| `/Styles/styles-v2/icons/tabler-icon.css` | **404** | 200, 314,234 bytes |
| `Themes/Rock/Styles/theme.css` | 430,153 bytes | 721,458 bytes |
| — occurrences of `ti-` in it | **0** | 5,780 |
| `Themes/RockManager/Styles/theme.css` | 393,455 bytes | 684,913 bytes |

Both themes short by about the same amount is the tell: one shared import failing, not a
theme-specific fault.

**Fixed in PR #19** — `pr-test-artifact.yml` now builds `Rock.Frontend.Styles`, guarded on its
lockfile so the step no-ops on the 18.4.1 line the `pr-*` fleet still builds. All three deploy
paths reach the build through that one reusable workflow, so production's eventual v19 cutover
is covered by the same change.

**The generalisable lesson, which is the reason this is written down:** a Rock upgrade can move
a directory from *committed* to *generated*, and nothing in a diff makes that obvious — the
files simply stop being listed. The `Rock.JavaScript.Obsidian.Blocks` step in the same workflow
exists for exactly this reason and was added the same way, after the same kind of outage. Before
the next upgrade, diff `git ls-files` between the two tags and look for directories that lose
their contents.
