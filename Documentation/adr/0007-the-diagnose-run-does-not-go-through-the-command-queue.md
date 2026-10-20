# ADR-0007: The diagnose run reaches the VM through the startup script, not the command queue

- **Status:** accepted
- **Date:** 2026-09-15
- **Governs:** `.github/workflows/pr-test-diagnose-command-queue.yml`
- **Enforced by:** `Tests/PrTestEnvironments/test_diagnostics_workflow.py`, `.github/workflows/pr-test-diagnose-command-queue.yml`

## Context

Six workflows put a command on the queue and wait for it, and since
`queue-vm-command` and `await-vm-command` were written they all do it the same
way. One workflow that touches the same VM does not: the diagnose run writes a
PowerShell payload into the instance's `windows-startup-script-ps1` metadata,
reboots the box, and polls a `pr-environments/diagnostics/` object for the
transcript.

From the workflow directory that reads as the last un-migrated caller, and an
architecture review proposed migrating it: replace the inline steps with the two
queue actions. It is the obvious move, it will be proposed again, and it does not
work.

## Decision

The diagnose run keeps the startup script and its own poll. It is not migrated
onto `queue-vm-command` and `await-vm-command`, and a future review that counts
callers and finds one missing should read this before proposing the migration
again. What it does share with its siblings is shared, one behaviour at a time.

## Why

It exists to diagnose a queue agent that is not running. That is the whole of its
job: it lists what is stranded in `pending/`, `processing/` and `results/`, dumps
`Get-ScheduledTask` and `Get-ScheduledTaskInfo` for the agent's task, then runs
`Invoke-PrEnvironmentCommandQueue.ps1` once by hand and prints the exit code.
Delivering that through the queue means the diagnosis arrives only when the thing
being diagnosed already works, and stays stuck in `pending/` in precisely the case
it was built for.

There is also no verb to send. The agent dispatches on eight -- `deploy`,
`deploy-environment`, `stop`, `destroy`, `renew-certificate`,
`find-legacy-text-columns`, `anonymize-staging` and `set-theme-customization` --
and a ninth reaches a VM only through `pr-test-bootstrap-command-queue.yml`, which
stops and starts the instance. So acquiring the ability to diagnose without a
reboot would begin with a reboot.

The startup script is the only channel this workflow has, and a startup script
runs on boot. The metadata write and the stop/start are not incidental steps
around the diagnosis; they are how it is delivered.

## Consequences

This workflow is not the cheap read-back tool its name suggests, and nothing about
keeping it off the queue makes it one. It reboots the test VM, so staging and the
whole `pr-*` fleet are down for the minutes Rock needs to warm. It overwrites
`windows-startup-script-ps1` and never restores the previous value, so the box
boots into the diagnostics payload until a bootstrap rewrites it. Run
`pr-test-bootstrap-command-queue.yml` afterwards.

What this workflow genuinely shares with its siblings has been moved out. Turning
an external IP into a name and zone is now `.github/actions/resolve-vm`, which is
where the diagnose run's `accessConfigs[0].natIP` filter and its missing
resolved-VM guard went. The poll stays its own: it waits on a diagnostics
transcript, not on a command result, so `await-vm-command` would be reading the
wrong prefix for the wrong kind of answer.

## What would reopen this

A `diagnose` verb on the agent, published to every VM, together with a channel
onto the box that does not require a boot -- working sshd, or the once-a-minute
script refresh actually delivering a file, which it never has. With both, routine
diagnosis becomes a command like any other and this workflow shrinks to the dead
agent case alone.

Failing that, if the queue ever grows claim semantics and a liveness heartbeat,
most of what this run is used for could be read out of the bucket without touching
the VM, and the workflow would not need to exist.

## Since this was written

2026-10-20. The queue's callers no longer use `queue-vm-command` and
`await-vm-command` directly. They go through `run-vm-command`, which composes the
two, and eight workflows use it. Nothing above changes with that: the composed
action still writes the command into `pending/` and waits for a result, and a dead
agent still leaves it there.

The queue also has a claim now, which is half of the reopening condition above. A
VM whose bootstrap has been re-run since then copies each command into
`processing/` before running it and takes it out of `pending/`, so the bucket
alone says whether an agent took a command: still in `pending/` means none did,
and in `processing/` with no result means one did and has not finished. The other
half, a heartbeat, does not exist. A command in `processing/` looks the same
whether its agent is still running it or died part way through, and an empty
queue looks the same whether the agent is alive or not. So this workflow is still
the only answer for an agent that is not running, which is the case it was built
for.
