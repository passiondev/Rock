# 2026-08-18 — the v19 staging deploy migrated the shared sandbox catalog

**Status:** staging is down. The shared sandbox catalog is stranded between Rock 18.4.1
and 19.3.4 and needs a restore. No production system was touched.

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
- **Devops.** Restore from the 10:04 backup, then redeploy 18.4.1.
- **Devops.** Enable automated backups and PITR on `connect-restore-test` (open item 22).
- **Devops.** Provision a dedicated staging catalog and set the `STAGING_DB_NAME`
  repository variable. Until that exists, staging cannot go to v19 at all — which is now
  enforced rather than merely documented.
- **Done (this change).** `pr-test-deploy.yml` no longer reads `vars.STAGING_DB_NAME`; the
  fleet has its own `vars.PR_TEST_DB_NAME`. Both are unset and both fall back to
  `secrets.DB_NAME`, so nothing moves today — but setting staging's variable now moves
  staging alone. That the two were one variable is the reason there was nowhere to try v19
  before trying it here.
- **Done (this change).** `Deployment/Database/Find-LegacyTextColumns.ps1` (read-only) and
  `Convert-LegacyTextColumns.ps1` (`-Apply`-gated, explicit columns, generated rollback).
  The finder also prints the `__MigrationHistory` high-water mark, which is what names the
  last migration to commit on a stranded catalog.
- **Open — needs a database.** Run the finder against the restored catalog and fix what it
  reports. The repository has no route to a connection string (Secret Manager is not
  enabled on `passioncitychurch-com`), so this is the first step of the v19 attempt rather
  than something that can be closed from here. It will recur on the real cutover, on every
  catalog carrying the same drift — including production.
- **Open — one line, blocked on PR #10.** `test_powershell_edition_compatibility.py` scans
  `Deployment/PrTestEnvironments` for PowerShell 7-only syntax and now misses
  `Deployment/Database`. Point it at both directories once that PR lands; duplicating its
  table onto this branch would only create a merge conflict for the sake of it.
