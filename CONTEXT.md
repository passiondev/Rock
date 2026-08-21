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
| **trunk** | The branch the team currently develops on and staging deploys from. Today `passion-19.3.4`. | prose, `TRUNK_BRANCH` in the suite |
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

## Environments

| Term | Means |
|---|---|
| **environment** | One IIS site on the Windows VM, with its own app pool, host name and directory under `C:\RockTestEnvs`. |
| **PR environment** | An environment created for a pull request, named `rock-pr-<number>`. |
| **the fleet** / **the `pr-*` fleet** | Every PR environment at once. |
| **staging** | The long-lived environment at `staging.rock-dev.connect.passion.team`. Not a PR environment: it survives, and since 2026-08-18 it has its own catalog. |
| **production** | The live Rock. Reached only through `production-deploy.yml`, behind an approval gate. |

Do not call an environment an *instance*. In this project `instance` means a
Cloud SQL instance, and the runbooks use it only that way. The word is free and
it should stay that way.

## Data

| Term | Means |
|---|---|
| **catalog** | One SQL database. The word disambiguates from *instance*, which holds several. |
| **the shared catalog** | `RockConnectProd` on `connect-restore-test`. Every `pr-*` environment points at it. |
| **the staging catalog** | `RockStaging` on the same instance. Staging alone, since 2026-08-18. |
| **sandbox** | An adjective for the non-production data, never a noun for an environment. *Sandbox catalog*, *sandbox file storage*. |

**The word `sandbox` promises something it does not deliver.** The shared catalog
is a straight copy of a production backup: real names, addresses and giving
history. There is no sanitization step and there never has been. There is no
refresh either — it was seeded once on 2026-04-14. Six documents said otherwise
until 2026-08-21. `test_shared_catalog_claims.py` now guards every surface that
describes it.

## The control plane

| Term | Means |
|---|---|
| **command** | One JSON object naming work for the VM: `deploy`, `destroy`, `renew-certificate`, `find-legacy-text-columns`. |
| **the queue** | The GCS prefix the commands travel through: `pending/`, `in-progress/`, `results/`. |
| **producer** | A workflow that writes a command. |
| **the agent** | `Invoke-PrEnvironmentCommandQueue.ps1`, the scheduled task on the VM that consumes them. |
| **enqueue** / **poll** | Writing a command, and waiting for its result. The two halves of the protocol. |
| **the envelope** | The three fields every command carries whatever its verb: `commandId`, `command`, `requestedAtUtc`. Owned by `queue-vm-command`; a payload that sets one is an error. |
| **the payload** | The fields a particular verb adds on top of the envelope. A field whose value is blank is dropped rather than sent empty. |

Both halves of the protocol are composite actions — `.github/actions/queue-vm-command`
and `.github/actions/await-vm-command` — and a producer calls them rather than
carrying its own copy. The enqueue keeps its PowerShell in `Write-VmCommand.ps1`
beside `action.yml` instead of inline, because PowerShell embedded in YAML is a
string no test can execute: that is how two producers came to redact a field
named `connectionString` while the one holding the sandbox password called it
`sandboxConnectionString`. Redaction keys on the shape of a field name, not a
list of known ones.

Use **destroy** for removing an environment — it is the command name and the
chat trigger (`rock:destroy`). *Tear down*, *remove* and *prune* are prose
variants for the same act; prefer `destroy` where a reader might be looking for
the command.

## Deploy modes

| Term | Means |
|---|---|
| **DedicatedSite** | The mode that owns its whole directory. Every PR environment and staging. |
| **InPlace** | The mode that updates files inside an existing site it does not own. Production. |

The mode decides which of `Deploy-RockEnvironment.ps1`'s parameters apply, and
whether the shared-asset overlay runs at all. It is the single most consequential
input to that script.

Passing a parameter the mode has no use for is an error, not a no-op:
`Resolve-DeploymentTarget` refuses `TargetSitePath` and `TargetAppPoolName` under
`DedicatedSite` rather than dropping them. Both name a directory, and a deploy
that lands somewhere other than where its operator asked should not report
success.

---

**Adding a term here.** A name that appears in more than one layer — a workflow,
a script and a runbook — belongs in this file. A name used in one place does
not.
