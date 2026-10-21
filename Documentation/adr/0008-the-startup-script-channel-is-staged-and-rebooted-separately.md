# ADR-0008: The startup-script channel is two actions, and production's restart is not a caller

- **Status:** accepted
- **Date:** 2026-09-15
- **Governs:** `.github/actions/inject-startup-script/`, `.github/actions/restart-vm/`, `.github/workflows/production-bootstrap-command-queue.yml`
- **Enforced by:** `Tests/PrTestEnvironments/test_production_bootstrap.py`, `.github/actions/restart-vm/Restart-Vm.ps1`

## Context

There are two ways a command reaches these Windows VMs. One is the command queue,
which six workflows use through `queue-vm-command` and `await-vm-command`. The
other had no name and no module: write PowerShell into the instance's
`windows-startup-script-ps1` metadata, reboot the machine, and let it run at boot.
Three workflows used it -- the fleet bootstrap, production's bootstrap and the
diagnose run -- and each carried its own copy of both halves.

The copies had drifted in the way copies do. Only production checked whether
gcloud accepted the metadata write. Only production and the diagnose run checked
whether the stop succeeded. None of the three checked what was being staged,
which is the gap that matters: a startup script is an inert metadata string until
the machine boots, so a here-string that interpolated to nothing stages green,
boots green, and installs nothing at all.

## Decision

The channel is two composite actions, not one. `inject-startup-script` validates
and stages a script the caller has already written to disk; `restart-vm` stops
the instance, optionally sets service account scopes while it is down, and starts
it again with a bounded retry. Two things stay deliberately outside them: the
payload itself, and production's restart.

The payload stays with its caller because these scripts are built as here-strings
full of backticks and `$`, and handing several hundred such lines to a YAML input
would put them through another round of expansion. The action takes a path.

Production's restart is not routed through `restart-vm`. It reads the instance's
current scopes, refuses to continue when that read looks implausible, and unions
rather than replaces -- all of it before the stop, because once production is down
there is nothing left to recover to. The fleet's bootstrap replaces the list with
`cloud-platform` outright. Those are two policies, not one parameter apart, and
the sequence they need differs at the point where it is least recoverable.

## Consequences

Both fleet workflows gained checks they never had: the bootstrap now fails on a
refused stop instead of reporting a green bootstrap whose agent never installed,
and a failed scope change starts the instance again rather than leaving it off.
Each caller must now supply a sentence naming what is offline if the instance
never returns, because the same failed start means "staging and the whole pr-*
fleet" on one box and "production" on another.

The cost is that production's bootstrap keeps a restart step no other workflow
shares, so a fix to the shared reboot does not reach it. That is the trade: the
one path that touches production on upgrade day does not take edits made for the
test fleet's benefit.

## What would reopen this

If production's scope handling ever stops being production-specific -- if the
instance's scopes are set once out of band and the bootstrap no longer changes
them -- then its restart becomes the same stop-and-start as the fleet's and should
move behind `restart-vm`. Equally, if a caller appears that needs the action to
generate its payload rather than stage one, the path-versus-content decision above
is worth re-reading rather than worked around.

## Since this was written

2026-10-20. The command queue's callers no longer use `queue-vm-command` and
`await-vm-command` directly. They go through `run-vm-command`, which composes the
two, and eight workflows use it. That changes the context paragraph's count and
action names, not this decision: the queue is still the channel for a VM whose
agent is running, and this one is still the channel for reaching a VM at boot.

The queue gaining a claim and a per-queue list of accepted verbs on the same date
makes the two channels more different, not less. Both only take effect on a VM
whose bootstrap has been re-run since, and the bootstrap is a caller of this
channel. Production's own restart stays outside `restart-vm` for the reasons
above, so delivering the claim to production goes through that restart, under its
approval, and not through anything shared with the fleet.
