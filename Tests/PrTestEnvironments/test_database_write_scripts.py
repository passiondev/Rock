"""The house rule for a script that writes to a Rock catalog, checked in one place.

`Deployment/Database` holds five scripts. Four of them write, three of those have
a test file each, and all three pin the same three properties in three different
spellings: the run is a dry run unless you ask for a write, nothing executes
before the gate that decides, and a rollback is on disk before the first
statement runs.

`Set-RockGlobalAttributeValue.ps1` is the fourth. It follows all three today --
it was written by copying the one beside it -- and nothing holds it there. It
appears in no test, no workflow and no runbook, and the next script in this
directory will be written the same way it was: by copying whichever file is
already there.

So the rule stops being three copies of an assertion about three named files and
becomes one statement about the directory. A `.ps1` added to
`Deployment/Database` is sorted by what it does, not by whether somebody
remembered to write a test for it, and it either satisfies the rule or says in
its own header why the rule does not fit.

The per-script test files stay. They assert what their script means -- which
columns the anonymizer rewrites, that `image` becomes `varbinary` and not text --
and none of that belongs here. This file holds only what is true of all of them.
"""

import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
SCRIPT_DIR = REPO_ROOT / "Deployment" / "Database"

# Scripts that issue no write. The split is derived below from what the SQL in
# each file actually says, and this is the answer that derivation has to produce
# -- so a read-only script that grows an UPDATE fails here rather than quietly
# joining the set of files nothing checks.
READ_ONLY = {"Find-LegacyTextColumns.ps1"}

# Writes without a generated rollback, and why. The reason has to also be in the
# script, which the test below requires: an operator deciding whether to run this
# reads the script, not this file.
NO_GENERATED_ROLLBACK = {
    "Invoke-StagingAnonymization.ps1": (
        "a pre-image table mapping every Id to its real email address is the same "
        "PII the run exists to remove, so reversal is re-importing the .bak"
    ),
}

# The positional gate rule: one `$Apply` branch, every execution after it. Three
# of the four write scripts have that shape, and it is checkable without knowing
# what any single statement does.
#
# The anonymizer does not have it, on purpose. It executes through a SQL adapter
# it is handed, and it runs reads before the gate -- the catalog identity check
# and the computed-column guard -- because refusing the wrong catalog or an
# UPDATE SQL Server will reject has to happen before anything else does. Its
# gate is proven by running it instead: the Pester suite named here drives the
# script's own function against a recording adapter and asserts that a dry run
# issues no write and that every write follows every check. The entry exists so
# that exempting a script means naming what covers it, and the test below fails
# if that is not there.
GATE_PROVEN_ELSEWHERE = {
    "Invoke-StagingAnonymization.ps1": (
        "StagingAnonymization.Tests.ps1",
        "Describe 'Invoke-StagingAnonymization'",
    ),
}

EXECUTES = re.compile(r"Execute(NonQuery|Scalar)")


def scripts():
    """Every PowerShell script in the directory, by name."""
    return sorted(SCRIPT_DIR.glob("*.ps1"))


def body_of(path):
    """The script with its comments blanked and its line numbering intact."""
    return harness.strip_powershell_comments(path.read_text(encoding="utf-8"))


def writes(path):
    """Whether the SQL in `path` changes anything.

    Read off the statements rather than taken from a list, because a list is what
    goes stale -- the whole failure this file is about is a script nobody added to
    one."""
    body = body_of(path)
    return any(re.search(verb, body, re.IGNORECASE) for verb in harness.SQL_WRITE_VERBS)


def write_scripts():
    return [path for path in scripts() if writes(path)]


class TheDirectoryIsSortedTests(harness.HarnessAssertions, unittest.TestCase):
    def test_every_script_is_either_a_writer_or_declared_read_only(self):
        """The list and the tree agree, or the run is red.

        Both directions. A new writer is covered by everything below without
        anybody adding it anywhere, and a script that was read-only growing its
        first UPDATE stops being treated as safe to point at any catalog."""
        found = {path.name for path in scripts()}
        self.assertNotVacuous(found, f"{SCRIPT_DIR} holds no scripts, so nothing below checks anything")

        derived_read_only = {path.name for path in scripts() if not writes(path)}

        self.assertEqual(
            sorted(READ_ONLY),
            sorted(derived_read_only),
            "the scripts that issue no writes are not the ones declared read-only. "
            "A script that gained a write is now read as safe to run against any "
            "catalog; a script that lost one is checked for a rollback it no "
            "longer needs.",
        )
        self.assertNotVacuous(
            write_scripts(), "no script in the directory writes, so every rule below is vacuous"
        )

    def test_the_classifier_sees_a_write_it_is_shown(self):
        """`writes()` returning False for everything would sort the whole directory
        read-only and pass the test above by moving the failure into a constant
        nobody edits. This is the statement the converter runs."""
        samples = [
            '    $sql = "ALTER TABLE [dbo].[Foo] ALTER COLUMN [Bar] nvarchar(max) NULL"',
            # The anonymizer's batched write. Pinned to `UPDATE [`, the list read
            # this as no write at all and sorted the anonymizer read-only.
            "UPDATE TOP ($BatchSize) $($target.Table)",
            "UPDATE [dbo].[AttributeValue] SET [Value] = @value WHERE [Id] = @id;",
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertTrue(
                    any(re.search(verb, sample, re.IGNORECASE) for verb in harness.SQL_WRITE_VERBS),
                    "the write-verb list no longer matches a statement that changes rows",
                )


class DryRunIsTheDefaultTests(harness.HarnessAssertions, unittest.TestCase):
    def test_every_write_script_takes_an_apply_switch(self):
        """`-Apply`, not `-WhatIf`. The safe outcome has to be the one you get by
        forgetting a flag rather than by remembering one."""
        for path in write_scripts():
            with self.subTest(script=path.name):
                self.assertRegex(
                    body_of(path),
                    r"\[switch\]\s*\n?\s*\$Apply",
                    f"{path.name} writes to a catalog and has no -Apply switch, so "
                    "running it is the same as running it for real",
                )

    def test_no_write_script_defaults_apply_on(self):
        """A `[switch] $Apply = $true` reads as a gate and is not one."""
        for path in write_scripts():
            with self.subTest(script=path.name):
                self.assertNoMatch(
                    r"\$Apply\s*=\s*\$true",
                    body_of(path),
                    f"{path.name} defaults -Apply on, which makes the dry run the "
                    "thing you have to ask for",
                )

    def test_nothing_executes_before_the_apply_gate(self):
        """A dry run that prints the statement and runs it anyway is worse than no
        dry run: it reads as a rehearsal.

        Written against the position of the gate rather than its shape, and taking
        either spelling. `if (-not $Apply)` only gates what follows it if it
        actually leaves, so the return is required -- without it the branch prints
        a message and falls through to the writes it was meant to prevent."""
        for path in write_scripts():
            if path.name in GATE_PROVEN_ELSEWHERE:
                continue
            with self.subTest(script=path.name):
                lines = body_of(path).splitlines()
                executing = [(i, line) for i, line in enumerate(lines) if EXECUTES.search(line)]
                self.assertNotVacuous(
                    executing, f"{path.name} is classed as a writer and executes nothing"
                )

                gate = None
                for i, line in enumerate(lines):
                    if re.search(r"if\s*\(\s*\$Apply\s*\)", line):
                        gate = i
                        break
                    if re.search(r"if\s*\(\s*-not\s+\$Apply\s*\)", line):
                        self.assertRegex(
                            "\n".join(lines[i:i + 8]),
                            r"(?m)^\s*return\s*$",
                            f"{path.name}: the -not $Apply branch does not return, so a "
                            "dry run falls through to the writes",
                        )
                        gate = i
                        break

                self.assertIsNotNone(gate, f"{path.name}: nothing gates the writes on -Apply")
                for i, line in executing:
                    self.assertGreater(
                        i,
                        gate,
                        f"{path.name}:{i + 1} executes before the -Apply gate: {line.strip()}",
                    )

    def test_a_script_exempted_from_the_gate_rule_names_what_proves_it_instead(self):
        """The exemption is the dangerous part of this file. An entry with nothing
        behind it turns an ungated write script green, so the entry has to name a
        Pester suite that exists, a Describe block inside it that does, and the
        suite has to load the script it is standing in for -- a suite that tests
        some other file proves nothing about this one."""
        for name, (suite, describe) in GATE_PROVEN_ELSEWHERE.items():
            with self.subTest(script=name):
                self.assertIn(
                    name,
                    [path.name for path in write_scripts()],
                    f"{name} is exempted from the gate rule and is not a write script",
                )
                # Spelled out one quoted segment at a time, per ADR-0003.
                proof = REPO_ROOT / "Tests" / "PrTestEnvironments" / "Pester" / suite
                self.assertTrue(proof.exists(), f"{name} points at {suite}, which does not exist")
                text = proof.read_text(encoding="utf-8")
                self.assertIn(
                    describe,
                    text,
                    f"{name} says {suite} proves its gate in {describe}, and that "
                    "block is not there",
                )
                self.assertIn(
                    f"Deployment/Database/{name}",
                    text,
                    f"{suite} does not load {name}, so it cannot be what proves its gate",
                )


class RollbackTests(harness.HarnessAssertions, unittest.TestCase):
    def test_a_rollback_is_on_disk_before_the_first_write(self):
        """Generated after the statement, it is not a rollback. A run that dies part
        way through describes the rows it got to and not the ones it changed."""
        for path in write_scripts():
            if path.name in NO_GENERATED_ROLLBACK:
                continue
            with self.subTest(script=path.name):
                lines = body_of(path).splitlines()
                rollback = next(
                    (
                        i for i, line in enumerate(lines)
                        if re.search(r"(Out-File|Set-Content)", line)
                        and re.search(r"[Rr]ollback", line)
                    ),
                    None,
                )
                first_write = next((i for i, line in enumerate(lines) if EXECUTES.search(line)), None)

                self.assertIsNotNone(rollback, f"{path.name} never writes a rollback file")
                self.assertIsNotNone(first_write, f"{path.name} executes nothing")
                self.assertLess(
                    rollback,
                    first_write,
                    f"{path.name} writes its rollback after the statement it undoes",
                )

    def test_a_script_with_no_rollback_says_so_where_the_operator_reads(self):
        """The exemption is real and the reasoning is the script's, not this file's.
        Whoever decides to run it opens the script, so the reason has to be there --
        and naming the house rule is what tells a reader this is a departure from it
        rather than an oversight."""
        for name, reason in NO_GENERATED_ROLLBACK.items():
            with self.subTest(script=name):
                path = SCRIPT_DIR / name
                self.assertTrue(path.exists(), f"{name} is exempted from the rollback rule and does not exist")
                # Read whole, comments included: the explanation is the help text.
                text = path.read_text(encoding="utf-8")
                self.assertRegex(
                    text,
                    r"(?i)house rule",
                    f"{name} has no generated rollback and does not say it is departing "
                    f"from the house rule ({reason})",
                )
                self.assertRegex(
                    text,
                    r"(?i)rollback",
                    f"{name} never tells the operator what reversal looks like",
                )


class ConnectionStringTests(harness.HarnessAssertions, unittest.TestCase):
    """Standing rule for this repository: a database script never prints its
    connection string. These run against a production-derived catalog and their
    output gets pasted into tickets and chat. It applies to the read-only script
    too -- the string is the same string."""

    def test_no_script_echoes_its_connection_string(self):
        offenders = []
        for path in scripts():
            for number, line in enumerate(body_of(path).splitlines(), start=1):
                writes_out = re.search(r"Write-(Host|Output|Warning|Error|Verbose|Information)", line)
                if writes_out and re.search(r"\$(resolved)?[Cc]onnectionString", line):
                    offenders.append(f"{path.name}:{number}: {line.strip()}")

        self.assertEqual(offenders, [], "a script echoes its connection string:\n  " + "\n  ".join(offenders))

    def test_every_script_accepts_the_connection_string_out_of_band(self):
        """Passed as an argument it lands in shell history, in the scrollback and in
        the process list. An environment variable is not secret either, but it is the
        one form that survives being pasted into a ticket."""
        for path in scripts():
            with self.subTest(script=path.name):
                self.assertIn(
                    "ROCK_DB_CONNECTION_STRING",
                    body_of(path),
                    f"{path.name} has no out-of-band way to take a connection string",
                )

    def test_a_missing_connection_string_names_the_variable_and_not_a_value(self):
        for path in scripts():
            with self.subTest(script=path.name):
                self.assertRegex(
                    body_of(path),
                    r"throw\s+\"[^\"]*ROCK_DB_CONNECTION_STRING",
                    f"{path.name} does not tell the operator how to supply a connection string",
                )


class AddressedNotDiscoveredTests(harness.HarnessAssertions, unittest.TestCase):
    def test_every_write_script_is_told_what_to_change(self):
        """The rule the row-level scripts inherit: a write script is addressed, never
        discovered. A reader enumerates, a human decides, the script is told. One
        that can find its own work can change a row nobody looked at.

        The anonymizer is the exception by definition -- finding every row holding
        a real address is the operation -- and it is covered instead by a mandatory
        `-ExpectedCatalog` and a refusal of the production address, both pinned in
        its own file. So the rule here is the weaker one that is true of all four:
        something about the run is mandatory, and it is not defaulted."""
        for path in write_scripts():
            with self.subTest(script=path.name):
                self.assertRegex(
                    body_of(path),
                    r"Mandatory\s*=\s*\$true",
                    f"{path.name} writes to a catalog with every parameter optional, so "
                    "running it with no arguments does something",
                )


if __name__ == "__main__":
    unittest.main()
