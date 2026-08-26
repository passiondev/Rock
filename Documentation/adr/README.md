# Architecture decisions

Each file here records a decision this team made, considered again, and kept.

They exist because of a specific failure. Three times now, an architecture review
has proposed a change this pipeline had already rejected, for a reason that is
still true. Twice somebody caught it in time, in a test docstring, because they
happened to open that file.

That is not a durable place for a reason. Only the person editing a test reads its
docstring, and a reviewer who wants to change the design has no cause to open the
test that explains it. So the reasons live here, and the tests link to them.

## The rule these records serve

A decision a reviewer could reasonably re-propose belongs in an ADR.

That is a narrower bar than "every decision". Most choices are legible from the
code, and writing those down produces a directory nobody reads. The test is whether
someone competent, reading the code carefully and meaning well, would suggest
undoing it.

`Tests/PrTestEnvironments/test_architecture_decisions.py` checks that every ADR the
tree cites exists, and that the code each ADR governs cites it back. An ADR nothing
points at is one nobody will find.

## The records

| ADR | Decision |
|---|---|
| [0001](0001-no-shared-powershell-module.md) | The deploy scripts copy their shared helpers rather than importing a module |
| [0002](0002-script-code-lives-in-script-files.md) | Script code lives in a `.ps1` or `.sh`, never inlined into YAML |
| [0003](0003-tests-spell-repository-paths-out.md) | Test files write repository paths out in full rather than through an accessor |

## Format

Short, and written for the person about to propose the opposite.

Give the context, the decision, the consequences the team accepted, and what would
have to change for the decision to be worth reopening. A record that does not say
what would change its mind is a rule rather than a decision, and rules rot.
