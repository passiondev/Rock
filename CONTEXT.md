# CONTEXT

The domain vocabulary of **Passion's CI/CD pipeline** — the workflows under
`.github/`, the deploy scripts under `Deployment/`, the suite under
`Tests/PrTestEnvironments/`, and the runbooks under `Documentation/`.

Rock's own application domain is not covered here. For how to write Rock code,
see `CLAUDE.md`.

This file exists because an architecture review on 2026-08-21 found one concept
carrying several names across the layers, and two pairs of names that look like
synonyms but are not. The second problem is the dangerous one: a reader who
collapses a real distinction makes a worse mistake than one who learns two words
for the same thing.

---

## Branches

| Term | Means | Where it is spelled that way |
|---|---|---|
| **trunk** | The branch the team currently develops on and staging deploys from. Today `passion-19.4.4`. | prose, `TRUNK_BRANCH` in the suite |
| **base branch** | The branch a pull request targets. For an eligible PR this equals the trunk, which is why the two words get used interchangeably — but the gate exists precisely to catch the case where they differ. | `baseBranch` in `.github/pr-test-environments.json`, `EXPECTED_BASE_BRANCH` in the suite |
| **default branch** | GitHub's repository setting. **Not a synonym for the trunk.** | `context.payload.repository.default_branch` |
| **production branch** | The branch production actually runs, which lags the trunk until production is upgraded. | `productionBranch` in the config, `EXPECTED_PRODUCTION_BRANCH` in the suite |

**The distinction that is load-bearing.** `pr-test-deploy.yml` reads the config
from the **default branch**, so moving the default branch is what retires an old
fleet. `pr-test-lifecycle.yml` reads it from the PR's **base branch**, so
teardown keeps working for retired PRs. Those two look like the same read and
are not, and `CutoverGateFailClosedTests` pins both halves so neither gets tidied
into matching the other. At a cutover, trunk, base branch and default branch all
move — but they move in a required order, and the runbook's cutover section is
the authority on it.

Prefer **trunk** in prose. Keep `baseBranch`, `default branch` and
`productionBranch` where they name a concrete key or setting.

**The declared version** is the Rock version a checkout says it is: `19.4.4`,
always two or three numbers. Its **line** is the major alone, `19`. Its
**minor** is the first two parts, `19.4`. **The pinned version** is the version
declared by the branch that a pin names. Both deploy guards compare the minor of
the declared version with the minor of a pinned version, because Rock migrates
its database on the first request after a deploy, ships migrations in minor
releases, and a mismatch is not reversible:

| Guard | Pinned version from | Compares | Override |
|---|---|---|---|
| `production-deploy.yml` | the production branch | the minor | `acknowledge_version_change` |
| `staging-deploy.yml` | the branch the `pr-*` fleet is pinned to | the minor, and only while staging has no catalog of its own | none |

Staging compared the line until 2026-10-20, so a trunk on 19.5 could deploy to
staging while the fleet was pinned to 19.4. Since staging has its own catalog
(`STAGING_DB_NAME`), its guard refuses only a catalog collision and reads no
version at all.

Where the declared version is read from moves at a major upgrade -- an assembly
attribute in `Rock.Version/AssemblySharedInfo.cs` through 18.x, `<Version>` in
`Directory.Build.props` from Rock 19 -- so both guards read it through one
script, `.github/scripts/rock-version.sh`. They read it themselves until
2026-09-15, probing the two files in opposite orders, and agreed only because a
checkout carries one of the two. Which file answers first is the whole of what
that order decides, and the argument for it lives with the script. The script
also owns the split, `rock_minor_of_version`, so the two guards cannot disagree
about where a minor ends.

## Environments

| Term | Means |
|---|---|
| **environment** | One IIS site on the Windows VM, with its own app pool, host name and directory under `C:\RockTestEnvs`. |
| **PR environment** | An environment created for a pull request, named `rock-pr-<number>`. |
| **the fleet** / **the `pr-*` fleet** | Every PR environment at once. |
| **staging** | The long-lived environment at `staging.connect.passion.team`. Not a PR environment: it survives, and since 2026-08-18 it has its own catalog. |
| **production** | The live Rock. Reached only through `production-deploy.yml`, behind an approval gate. |

Do not call an environment an *instance*. In this project `instance` means a
Cloud SQL instance, and the runbooks use it only that way. The word is free and
it should stay that way.

## Data

| Term | Means |
|---|---|
| **catalog** | One SQL database. The word disambiguates from *instance*, which holds several. |
| **the shared catalog** | Whatever `vars.PR_TEST_DB_NAME` names, currently `RockStaging`, on `connect-restore-test`. Every `pr-*` environment runs on it. They share it with each other and with nothing else. Set on 2026-08-26. Until then the fleet fell back to `secrets.DB_NAME`, which names a catalog that had already left the instance, so the fallback was dead: a deploy taking it failed with `Cannot open database`, which reads as a credential problem and is not one. |
| **the staging catalog** | Whatever `vars.STAGING_DB_NAME` names, currently `RockStaging20260824`, on the same instance. Staging alone, since 2026-08-18. `RockStaging` is the earlier copy and is still on the instance, so the two names are both real and only one is live. |
| **sandbox** | An adjective for the non-production data, never a noun for an environment. *Sandbox catalog*, *sandbox file storage*. |

**The word `sandbox` promises something it does not deliver.** The shared catalog
is a straight copy of a production backup: real names, addresses and giving
history. There is no sanitization step and there never has been. There is no
refresh either — it was seeded once on 2026-04-14. Six documents said otherwise
until 2026-08-21. `test_shared_catalog_claims.py` guards every surface that
describes it, and since 2026-08-26 that includes this file. It did not before:
the guard swept `Documentation/` and `.github/`, and the document defining the
term sits at the repository root, so the one place a reader looks up what the
shared catalog is was the one place nothing checked.

The **staging anonymizer** is a different matter, and it does not change any of
that. `Deployment/Database/Invoke-StagingAnonymization.ps1`, run through
`db-anonymize-staging.yml`, rewrites email addresses and phone numbers in the
staging catalog only. It never reads or writes the shared catalog. Its terms:

| Term | Means |
|---|---|
| **SQL adapter** | The five operations the anonymizer reaches the database through: Open, Close, Scalar, NonQuery and Rows. `New-SqlClientAdapter` is the real one. If Open fails, it leaves nothing open. |
| **recording adapter** | The one in `StagingAnonymization.Tests.ps1`. It answers like the staging catalog and records every call. |
| **safety sequence** | The order the anonymizer must keep: refuse the production address, check the keep domains, open, compare `DB_NAME()` with `-ExpectedCatalog`, check the computed columns still bind, stop unless `-Apply`, then update in batches. The Pester suite proves the order; the Python suite proves only the SQL text. |

## The control plane

| Term | Means |
|---|---|
| **command** | One JSON object naming work for the VM: `deploy`, `destroy`, `renew-certificate`, `find-legacy-text-columns`. |
| **the queue** | The GCS prefix the commands travel through: `pending/` then `results/`. A `processing/` prefix is declared and unused -- the agent runs a command in place under `pending/`, so there is no claim marker and no middle state. |
| **producer** | A workflow that writes a command. |
| **the agent** | `Invoke-PrEnvironmentCommandQueue.ps1`, the scheduled task on the VM that consumes them. |
| **enqueue** / **poll** | Writing a command, and waiting for its result. The two halves of the protocol. |
| **the envelope** | The three fields every command carries whatever its verb: `commandId`, `command`, `requestedAtUtc`. Owned by `queue-vm-command`; a payload that sets one is an error. |
| **the payload** | The fields a particular verb adds on top of the envelope. A field whose value is blank is dropped rather than sent empty. |
| **command id prefix** | The part of a `commandId` the producer chooses, such as `deploy-pr-123`. `run-vm-command` appends `-<run_id>-<run_attempt>`, so a re-run never collides with the result of the run before it. |
| **wait ceiling** | The longest a producer waits for a result: (attempts − 1) × interval, because the last look happens before the final sleep. It must be longer than the verb's own timeout on the VM plus a margin, or the producer reports a timeout while the command is still running. |
| **queue transport** | What the agent reads and writes the queue through: List, Read, Write and Remove. `New-GcsQueueTransport` is the real one; the Pester suite passes an in-memory one. |
| **command runner** | `Invoke-CommandJob`: runs one command's script in a background job with a timeout, and returns its output, whether it timed out, and its failure. |
| **poll pass** | `Invoke-CommandQueuePass`: one run of the agent. It refreshes its scripts, then drains `pending/` -- run, write the log, write the result, remove. A failed refresh never stops the drain. |

A producer calls one composite action, `.github/actions/run-vm-command`, which
enqueues, waits, and can copy the command's log into the job summary.
`.github/actions/queue-vm-command` and `.github/actions/await-vm-command` are its
two halves. They stay separate actions because the Pester suite runs their
scripts, but no workflow calls them directly. The enqueue keeps its PowerShell in
`Write-VmCommand.ps1` beside `action.yml` instead of inline, because PowerShell
embedded in YAML is a string no test can execute: that is how two producers came
to redact a field named `connectionString` while the one holding the sandbox
password called it `sandboxConnectionString`. Redaction keys on the shape of a
field name, not a list of known ones.

A result counts as success only when its status is `succeeded`.
`Read-CommandResult` in `Await-VmCommand.ps1` owns that rule. Any other status
is a failure, and so is a result with no status at all.

Use **destroy** for removing an environment — it is the command name and the
chat trigger (`rock:destroy`). *Tear down*, *remove* and *prune* are prose
variants for the same act; prefer `destroy` where a reader might be looking for
the command.

## Labels

A PR's `rock:*` labels are of three kinds, and a label of one kind never does the
work of another.

| Term | Means | Labels |
|---|---|---|
| **state label** | What the PR environment is doing now. Only the pipeline sets one. Each reconcile leaves at most one, but the deploy and lifecycle workflows run in separate concurrency groups, so two reconciles that overlap can briefly leave two. `STATE_LABELS` in `.github/scripts/pr-test-status.js` is the list. | `rock:queued`, `rock:building`, `rock:deploying`, `rock:deployed`, `rock:failed`, `rock:stopped` |
| **command label** | A request from a person. The workflow that handles it removes it, so the next request fires a fresh `labeled` event. | `rock:start` (`pr-test-deploy.yml`), `rock:stop` and `rock:destroy` (`pr-test-lifecycle.yml`) |
| **setting label** | A choice that stays on the PR until a person removes it. | `rock:auto` (redeploy on every push), `rock:full-build` (never repackage) |
| **reconcile** | `reconcilePrTestLabels`: remove every state label, then add the one for the new status. `destroyed` adds none. | |

## Manifests

| Term | Means |
|---|---|
| **manifest** | `env.json`: the record of one environment, beside its site. Three functions write it -- `Write-EnvironmentManifest` (`Deploy-PrEnvironment.ps1`), `Write-DeploymentManifest` (`Deploy-RockEnvironment.ps1`) and `Write-StoppedManifest` (`Stop-PrEnvironment.ps1`). `Invoke-PrEnvironmentCleanup.ps1`, `Invoke-SandboxRefreshWithPrEnvironments.ps1` and `Invoke-PrEnvironmentCertificateRenewal.ps1` read it. `ManifestContract.Tests.ps1` pins the fields the readers depend on. |
| **`prNumber`** | The field that makes a manifest a PR environment's. Cleanup stops and destroys by it, so staging and production never carry one. |
| **manifest root** | A directory that a reader searches for manifests. `C:\RockTestEnvs` is the one every reader searches. |
| **backup root** | `C:\RockBackups`. An InPlace deploy writes production's manifest and its site backups here, under `<name>\`. It is not a manifest root, and certificate renewal must never search it: `-AdditionalManifestRoots` defaults to none. |

## Artifacts

| Term | Means |
|---|---|
| **the artifact** | The deployable RockWeb zip and the `pr-test-artifact.json` beside it, in `pr-environments/<slug>/<sha>/` in the deployment bucket. Every deploy starts from one. |
| **full build** | The Windows `package` job of `pr-test-artifact.yml`: compile, bundle, zip. About half an hour. |
| **repackage** | The `repackage` job: a copy of a **base artifact** with the files that changed since swapped in. Minutes, and nothing is compiled. |
| **base artifact** | An artifact already in the bucket whose commit differs from the target only in files the build copies verbatim. The **plan** looks for one. |
| **the plan** | The `plan` job, and `.github/scripts/Get-ArtifactPlan.ps1` under it: repackage if it found a base artifact, build otherwise. |
| **build** / **patch** / **ignore** | How `.github/scripts/artifact-paths.json` classes a changed path: the build writes it, the build copies it verbatim, or it never reaches the artifact. One build-class path anywhere in the difference rules a base out. |
| **server-owned** | A path the deploy keeps the server's copy of: the lists at the top of `Deploy-RockEnvironment.ps1`. A change to one still reaches the artifact, built or patched, but the plan warns that it may not reach the site. |
| **artifact address** | Where one artifact lives: its zip's name, its folder, and the object paths of the zip and the record. `Get-ArtifactAddress` composes it from the slug and the commit, and `ConvertFrom-ArtifactObjectPath` reads one back by composing again and comparing. Both are in `.github/scripts/ArtifactRecord.psm1`, which runs only on runners, so ADR-0001 does not govern it. |
| **artifact record** | `pr-test-artifact.json`, beside each zip: seven fields in a fixed order, and nine for a repackage, which adds `builtFromSha` and `baseArtifactGcsPath`. Written and read by `New-`, `Write-` and `Read-ArtifactRecord`. The deploy never reads it. A later repackage does, for `builtFromSha` and `sha256`. |
| **artifact store** | What the plan and the repackage list and download artifacts through: a List and a Download. `New-GsutilArtifactStore` is the real one; the Pester suite passes an in-memory one. Uploads do not go through it. |

A repackage is not a lighter kind of deploy. What it produces is the zip a full
build would have made, under the same name, in the same folder, with the same
metadata plus `builtFromSha` naming the commit whose compiled output it carries.
Everything after the artifact -- the deploy command, the VM, both deploy modes --
cannot tell the two apart and does not need to.

Use **full build** for forcing one: it is what `force_build` and the
`rock:full-build` label ask for. *Skip the build* is fine in prose for the
repackage path, but the job and the step summary say **repackage**.

## Deploy modes

| Term | Means |
|---|---|
| **DedicatedSite** | The mode that owns its whole directory. Every PR environment and staging. |
| **InPlace** | The mode that updates files inside an existing site it does not own. Production. |
| **overlay plan** | What an InPlace deploy will do, as one record: where (`SitePath`, `ExtractPath`, `BackupDirectory`), what it keeps (the preserved and server-owned lists, the theme overrides it found), and the robocopy exclusions built from those. `Get-InPlaceOverlayPlan` makes it once, before the dry-run fork. A dry run prints it; `Invoke-InPlaceOverlay` carries it out. |

The mode decides which of `Deploy-RockEnvironment.ps1`'s parameters apply, and
whether the shared-asset overlay runs at all. It is the single most consequential
input to that script.

Passing a parameter the mode has no use for is an error, not a no-op:
`Resolve-DeploymentTarget` refuses `TargetSitePath` and `TargetAppPoolName` under
`DedicatedSite` rather than dropping them. Both name a directory, and a deploy
that lands somewhere other than where its operator asked should not report
success.

## Commit prefixes

`CLAUDE.md` splits commits two ways: `+` for a notable change that appears in the
Rock release notes, `-` for one that does not.

Every commit to the pipeline this file describes uses `-`, including the ones
that alter what a deploy does. The release notes go to churches running Rock. This pipeline is ours: it
builds and deploys our fork, it ships to nobody, and no Rock installation
anywhere is affected by a change to it. A `+ (Other)` line here would put a
GitHub Actions workflow in front of an audience with no way to act on it.

The rule that does apply is the one underneath the prefix -- the message has to
be the whole release note. A pipeline commit gets the same treatment, written for
whoever is reading `git log` at two in the morning trying to work out why the
deploy behaves differently than it did last week.

---

**Adding a term here.** A name that appears in more than one layer — a workflow,
a script and a runbook — belongs in this file. A name used in one place does
not.
