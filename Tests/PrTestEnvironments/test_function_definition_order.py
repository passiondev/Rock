"""A PowerShell script runs top to bottom, so a function called before its
definition is not defined yet.

`Deploy-RockEnvironment.ps1` defines `Resolve-DeploymentTarget` at file scope and
calls it at file scope eighty lines later. Move the definition below the call --
a reasonable-looking tidy-up, grouping the helpers at the bottom -- and the
script parses cleanly, passes every Pester test, and dies on the VM with "not
recognized as the name of a cmdlet". Pester cannot see it: it loads one function
out of the file and runs it in isolation, which is exactly the arrangement that
makes the ordering irrelevant. Neither can the parser, because the file is
syntactically fine.

The check is possible at all because these scripts have a shape: every function
is defined at column 0, and every file-scope statement is at column 0 too.
Anything indented is inside something and runs later. That is a convention rather
than a language rule, so the first test here holds the convention and the second
depends on it.
"""

import re
import unittest

import pipeline_harness as harness


SCRIPT_DIRS = [
    harness.REPO_ROOT / "Deployment" / "PrTestEnvironments",
    harness.REPO_ROOT / "Deployment" / "Repository",
    harness.REPO_ROOT / ".github" / "actions",
]

DEFINITION = re.compile(r"^function\s+([A-Za-z][\w-]*)", re.MULTILINE)
INDENTED_DEFINITION = re.compile(r"^[ \t]+function\s+[A-Za-z][\w-]*", re.MULTILINE)


def scripts():
    """Every PowerShell script under the directories that hold deployable code."""
    found = []
    for directory in SCRIPT_DIRS:
        if directory.exists():
            found.extend(sorted(directory.rglob("*.ps1")))
    return found


def executable_lines(text):
    """(line number, text) for lines that a runner will execute, at column 0 only.

    Block comments, line comments and here-string bodies are dropped. A here-string
    can hold anything at all -- SQL, another script -- and matching a function name
    inside one would report a call that is really just a word in a string."""
    lines = []
    in_block_comment = False
    here_string_terminator = None

    for number, line in enumerate(text.splitlines(), 1):
        if here_string_terminator is not None:
            if line.startswith(here_string_terminator):
                here_string_terminator = None
            continue

        if in_block_comment:
            if "#>" in line:
                in_block_comment = False
            continue

        if line.lstrip().startswith("<#"):
            in_block_comment = "#>" not in line
            continue

        opener = re.search(r"@(['\"])\s*$", line)
        if opener:
            here_string_terminator = opener.group(1) + "@"

        code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
        if code.strip() and not code[0].isspace():
            lines.append((number, code))

    return lines


class ColumnZeroConventionTests(harness.HarnessAssertions, unittest.TestCase):
    def test_no_function_is_defined_indented(self):
        """The ordering check below reads column 0 as file scope. A function defined
        inside another one breaks that reading, and would be reported as a call."""
        offenders = []
        for path in scripts():
            text = path.read_text(encoding="utf-8")
            for match in INDENTED_DEFINITION.finditer(text):
                line = harness.line_of(text, match.start())
                offenders.append(f"{path.name}:{line} {match.group(0).strip()}")

        self.assertEqual(
            [],
            offenders,
            "these define a function somewhere other than file scope, which is "
            "outside what test_function_definition_order.py can reason about:\n  "
            + "\n  ".join(offenders),
        )


class DefinitionPrecedesUseTests(harness.HarnessAssertions, unittest.TestCase):
    def test_every_file_scope_call_comes_after_its_definition(self):
        checked = []
        offenders = []

        for path in scripts():
            text = path.read_text(encoding="utf-8")
            defined = {}
            for match in DEFINITION.finditer(text):
                defined.setdefault(match.group(1), harness.line_of(text, match.start()))
            if not defined:
                continue

            callable_names = re.compile(
                r"(?<![\w-])(" + "|".join(re.escape(name) for name in defined) + r")(?![\w-])"
            )

            for number, code in executable_lines(text):
                if code.startswith("function "):
                    continue
                for name in set(callable_names.findall(code)):
                    checked.append(f"{path.name}:{name}")
                    if number < defined[name]:
                        offenders.append(
                            f"{path.name}:{number} calls {name}, defined at line {defined[name]}"
                        )

        self.assertNotVacuous(checked, "no file-scope call to a locally defined function was found")
        self.assertEqual(
            [],
            offenders,
            "these call a function before the line that defines it, so the script "
            "parses, passes Pester, and fails on the VM:\n  " + "\n  ".join(offenders),
        )


if __name__ == "__main__":
    unittest.main()
