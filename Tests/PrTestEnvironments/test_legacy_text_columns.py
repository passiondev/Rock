"""Static checks on the legacy-column tooling in Deployment/Database.

There is no SQL Server and no PowerShell in CI, so nothing here executes either
script -- these assert the properties that make them safe to hand to an operator
pointed at a real catalog, which is exactly the situation where a mistake is not
recoverable. Same approach the rest of this suite takes to the .ps1 files.

The scripts exist because the 2026-08-18 v19 deploy died on
"The data types text and nvarchar are incompatible in the equal to operator".
`text`, `ntext` and `image` were deprecated in SQL Server 2005 and removed in
2016; Rock's own schema uses `nvarchar`, so a column of that type in a Passion
catalog is local drift, and a v19 migration that compares one with `=` fails.
Finding them needs a read; fixing them needs a write against production-derived
data, which is why they are two scripts and not one.
"""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_DIR = REPO_ROOT / "Deployment" / "Database"
FINDER = SCRIPT_DIR / "Find-LegacyTextColumns.ps1"
CONVERTER = SCRIPT_DIR / "Convert-LegacyTextColumns.ps1"
OP_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"

WRITE_VERBS = [
    r"\bALTER\s+TABLE\b",
    r"\bUPDATE\s+\[",
    r"\bDELETE\s+FROM\b",
    r"\bINSERT\s+INTO\b",
    r"\bDROP\s+\w",
    r"\bTRUNCATE\s+TABLE\b",
    r"\bCREATE\s+(TABLE|INDEX|PROCEDURE)\b",
    r"\bEXEC(UTE)?\s+sp_",
]


def _strip_comments(text):
    """Drop block and line comments. The finder's whole reason for existing is a
    write it deliberately does not perform, and explaining that in a comment must
    not trip the scan that checks it performs no writes."""
    text = re.sub(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.DOTALL)
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


class ScriptsExistTests(unittest.TestCase):
    def test_the_operator_runbook_points_at_scripts_that_exist(self):
        """The runbook tells an operator to run these by path during a version
        cutover. A path that resolves to nothing is discovered at the worst possible
        moment -- mid-cutover, by someone following the document because they do not
        already know the answer."""
        runbook = OP_RUNBOOK.read_text()

        for script in [FINDER, CONVERTER]:
            self.assertTrue(script.exists(), f"{script} does not exist")
            self.assertIn(
                script.name,
                runbook,
                f"{script.name} is not mentioned in the operator runbook",
            )

        for match in re.findall(r"`(Deployment/Database/[\w./-]+)`", runbook):
            self.assertTrue(
                (REPO_ROOT / match).exists(),
                f"the runbook names {match}, which does not exist",
            )


class FinderIsReadOnlyTests(unittest.TestCase):
    def test_the_finder_issues_no_writes(self):
        """The whole point of splitting these in two is that one of them can be run
        against any catalog, including one nobody has agreed to change yet, without
        anyone having to read it first to be sure."""
        body = _strip_comments(FINDER.read_text())

        offenders = [
            f"{lineno}: {line.strip()}"
            for lineno, line in enumerate(body.splitlines(), start=1)
            for verb in WRITE_VERBS
            if re.search(verb, line, re.IGNORECASE)
        ]
        self.assertEqual(offenders, [], "the read-only finder contains writes:\n  " + "\n  ".join(offenders))

    def test_the_scan_would_catch_a_write_added_to_the_finder(self):
        """A verb list that stopped matching makes the test above vacuous. This is
        the statement the converter runs, checked against the finder's scan."""
        sample = '    $sql = "ALTER TABLE [dbo].[Foo] ALTER COLUMN [Bar] nvarchar(max) NULL"'
        self.assertTrue(
            any(re.search(verb, sample, re.IGNORECASE) for verb in WRITE_VERBS),
            "the write-verb list no longer matches an ALTER TABLE",
        )

    def test_the_finder_reports_the_migration_high_water_mark(self):
        """A catalog stranded part-way through a migration set looks identical to a
        healthy one until you read __MigrationHistory. That is the single most useful
        fact when a deploy has failed and nobody knows how far it got, and it is a
        read -- so it belongs in the script anyone is allowed to run."""
        body = _strip_comments(FINDER.read_text())
        self.assertIn("__MigrationHistory", body)


class ConnectionStringHandlingTests(unittest.TestCase):
    """Standing rule for this repository: a DB script never prints its connection
    string. These run against a prod-derived catalog and their output gets pasted
    into tickets and chat."""

    def test_neither_script_writes_the_connection_string_to_output(self):
        offenders = []
        for script in [FINDER, CONVERTER]:
            for lineno, line in enumerate(_strip_comments(script.read_text()).splitlines(), start=1):
                if re.search(r"Write-(Host|Output|Warning|Error|Verbose|Information)", line) and re.search(
                    r"\$(resolved)?[Cc]onnectionString", line
                ):
                    offenders.append(f"{script.name}:{lineno}: {line.strip()}")

        self.assertEqual(
            offenders,
            [],
            "a script echoes its connection string:\n  " + "\n  ".join(offenders),
        )

    def test_the_connection_string_can_be_supplied_out_of_band(self):
        """Passed as an argument it lands in shell history, in the scrollback, and in
        the process list. An environment variable is not secret either, but it is the
        one form that survives being pasted into a ticket."""
        for script in [FINDER, CONVERTER]:
            body = _strip_comments(script.read_text())
            self.assertIn("ROCK_DB_CONNECTION_STRING", body, f"{script.name} has no out-of-band input")

    def test_a_missing_connection_string_names_the_variable_not_a_value(self):
        for script in [FINDER, CONVERTER]:
            body = _strip_comments(script.read_text())
            self.assertRegex(
                body,
                r"throw\s+\"[^\"]*ROCK_DB_CONNECTION_STRING",
                f"{script.name} does not tell the operator how to supply a connection string",
            )


class ConverterIsGatedTests(unittest.TestCase):
    def test_the_converter_defaults_to_a_dry_run(self):
        """-Apply, not -WhatIf. The default has to be the safe one, and it has to be
        the default you get by forgetting a flag rather than by remembering one."""
        body = _strip_comments(CONVERTER.read_text())
        self.assertRegex(body, r"\[switch\]\s*\n?\s*\$Apply", "there is no -Apply switch")

    def test_no_statement_executes_before_the_apply_gate(self):
        """A dry run that prints the statement and runs it anyway is worse than no dry
        run: it reads as a rehearsal.

        Written against the position of the gate rather than its shape. Pinned to a
        literal `if ($Apply)` this passed only for one of the two ways to write the
        same thing, and failed the moment the redundant second gate that shape had
        encouraged was removed -- the test was holding the code in a worse form than
        it wanted to be in."""
        lines = _strip_comments(CONVERTER.read_text()).splitlines()

        executing = [(i, line) for i, line in enumerate(lines) if "ExecuteNonQuery" in line]
        self.assertTrue(executing, "the converter never executes anything")

        # Either shape: `if ($Apply) { write }` or `if (-not $Apply) { return }`.
        # The second only gates what follows it if it actually leaves, so require the
        # return -- without it the guard prints a message and falls through to the
        # writes it was supposed to prevent.
        gate = None
        for i, line in enumerate(lines):
            if re.search(r"if\s*\(\s*\$Apply\s*\)", line):
                gate = i
                break
            if re.search(r"if\s*\(\s*-not\s+\$Apply\s*\)", line):
                block = "\n".join(lines[i:i + 6])
                self.assertRegex(
                    block,
                    r"(?m)^\s*return\s*$",
                    "the -not $Apply branch does not return, so a dry run falls through to the writes",
                )
                gate = i
                break

        self.assertIsNotNone(gate, "nothing gates the writes on -Apply")
        for i, line in executing:
            self.assertGreater(
                i,
                gate,
                f"line {i + 1} executes a statement before the -Apply gate: {line.strip()}",
            )

    def test_the_converter_only_touches_columns_named_on_the_command_line(self):
        """The rule this inherits from the row-level scripts: a write script is
        addressed, never discovered. The finder enumerates; a human reads the list
        and decides; the converter is told. A converter that could find its own work
        can convert a column nobody looked at."""
        body = _strip_comments(CONVERTER.read_text())

        self.assertRegex(body, r"Mandatory\s*=\s*\$true", "the column list is optional")
        self.assertRegex(body, r"\[string\[\]\]\s*\n?\s*\$Column", "there is no -Column parameter")
        self.assertNotRegex(
            body,
            r"IN\s*\(\s*'text'",
            "the converter enumerates legacy columns itself instead of being told which to change",
        )

    def test_the_converter_refuses_a_column_that_is_not_a_legacy_type(self):
        """Addressed-not-discovered only helps if the address is checked. A typo that
        resolves to a real `nvarchar` column would otherwise rewrite it -- a
        size-of-data ALTER on a table nobody meant to touch."""
        body = _strip_comments(CONVERTER.read_text())

        self.assertRegex(
            body,
            r"throw\s+\"[^\"]*(not a legacy|is a )",
            "nothing refuses a column whose current type is not text, ntext or image",
        )
        self.assertIn("sys.columns", body, "the converter never reads the column's actual type")


class RollbackTests(unittest.TestCase):
    def test_a_rollback_script_is_written_before_the_first_write(self):
        """Generated after the ALTER, it is not a rollback -- if the run dies half way
        through a column list, the file describes the columns it got to and not the
        ones it changed."""
        body = _strip_comments(CONVERTER.read_text())
        lines = body.splitlines()

        rollback_write = next(
            (i for i, line in enumerate(lines) if re.search(r"(Out-File|Set-Content).*Rollback", line, re.IGNORECASE)),
            None,
        )
        first_execute = next(
            (i for i, line in enumerate(lines) if "ExecuteNonQuery" in line),
            None,
        )

        self.assertIsNotNone(rollback_write, "no rollback file is ever written")
        self.assertIsNotNone(first_execute, "the converter never executes anything")
        self.assertLess(
            rollback_write,
            first_execute,
            "the rollback is written after the ALTERs it is supposed to undo",
        )

    def test_the_rollback_restores_the_type_that_was_actually_there(self):
        """Hardcoding `text` in the rollback is wrong for two of the three types it
        handles, and wrong about nullability for most columns. The original has to be
        read off the catalog and carried into the generated statement."""
        body = _strip_comments(CONVERTER.read_text())

        self.assertRegex(
            body,
            r"is_nullable",
            "nullability is never read, so the rollback guesses it",
        )
        self.assertRegex(
            body,
            r"ALTER COLUMN[^\"']*\$\(?\$?\w*[Oo]riginal",
            "the rollback statement does not use the original type read from the catalog",
        )

    def test_the_rollback_says_where_it_is_not_lossless(self):
        """nvarchar(max) -> text is a Unicode to code-page conversion. Anything
        written after the forward conversion that the original collation cannot
        represent is lost by the rollback, silently. A rollback file that does not say
        so invites someone to treat it as a free undo."""
        body = CONVERTER.read_text()
        self.assertRegex(
            body,
            r"(?i)loss|code page",
            "the generated rollback makes no mention of where it loses data",
        )


class TypeMappingTests(unittest.TestCase):
    def test_the_converter_handles_every_type_the_finder_reports(self):
        """The finder hands an operator a list and the runbook tells them to fix it
        with the converter. A type on one list and not the other is a dead end found
        mid-cutover."""
        finder_types = set(re.findall(r"'(text|ntext|image)'", _strip_comments(FINDER.read_text())))
        converter_types = set(re.findall(r"'(text|ntext|image)'", _strip_comments(CONVERTER.read_text())))

        self.assertEqual(
            finder_types,
            {"text", "ntext", "image"},
            "the finder no longer looks for all three removed types",
        )
        self.assertEqual(
            finder_types - converter_types,
            set(),
            "the finder reports types the converter cannot fix: "
            + ", ".join(sorted(finder_types - converter_types)),
        )

    def test_image_becomes_varbinary_and_not_nvarchar(self):
        """`image` is bytes. Converted to nvarchar(max) it is corrupted, and the ALTER
        succeeds -- SQL Server will not stop you converting a binary column to text."""
        body = _strip_comments(CONVERTER.read_text())

        mapping = re.search(r"'image'\s*=\s*'([^']+)'", body)
        self.assertIsNotNone(mapping, "there is no explicit mapping for image")
        self.assertEqual(mapping.group(1), "varbinary(max)")

        for legacy in ["'text'", "'ntext'"]:
            entry = re.search(re.escape(legacy) + r"\s*=\s*'([^']+)'", body)
            self.assertIsNotNone(entry, f"there is no explicit mapping for {legacy}")
            self.assertEqual(entry.group(1), "nvarchar(max)")


if __name__ == "__main__":
    unittest.main()
