import pathlib
import re
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"

# GitHub constrains `boolean` to true/false and `choice` to the options declared
# beside it. `string` is the free-text case, and an omitted type defaults to string.
#
# `number` is in this list too, and that is a correction rather than caution. The type
# renders a plain text box and is not enforced on the way in -- the REST dispatch
# endpoint takes inputs as strings and hands them straight through, so `number` buys a
# hint to the operator and nothing else. Treating it as constrained is what let
# `$attempts = ${{ inputs.poll_attempts }}` into db-find-legacy-text-columns.yml and
# past this very scan on 2026-08-18.
#
# The cost of including it is nil: the only number-typed dispatch input in the
# repository reads its value from env: already. The cost of leaving it out was a
# workflow holding a live database password reparsing operator text as code.
FREE_TEXT_TYPES = frozenset({"string", "number"})


def _triggers(workflow):
    """PyYAML resolves a bare `on:` key to the boolean True (YAML 1.1), so a workflow
    that quotes it and one that does not parse to different keys for the same file."""
    return workflow.get("on", workflow.get(True)) or {}


def _free_text_inputs(workflow):
    triggers = _triggers(workflow)
    if not isinstance(triggers, dict):
        return []
    dispatch = triggers.get("workflow_dispatch") or {}
    inputs = (dispatch or {}).get("inputs") or {}
    return [
        name
        for name, spec in inputs.items()
        if (spec or {}).get("type", "string") in FREE_TEXT_TYPES
    ]


def _script_bodies(workflow):
    """Every place a step's text is handed to an interpreter: `run:` goes to a shell,
    and github-script's `script:` goes to node."""
    for job_name, job in (workflow.get("jobs") or {}).items():
        for step in (job or {}).get("steps") or []:
            for body in [step.get("run"), ((step.get("with") or {}).get("script"))]:
                if body:
                    yield job_name, step.get("name", "(unnamed step)"), body


class WorkflowInputInjectionTests(unittest.TestCase):
    """`${{ }}` is not a variable reference. Actions pastes the value into the file as
    text and *then* hands the result to bash or to node, so operator-typed input
    becomes part of the program rather than data read by it.

    A ref is allowed to contain a backtick, a `$(`, a quote. Someone deploying a
    branch called `fix-$(whoami)` gets a confusing failure; someone who wants to can
    do considerably better than that in a workflow holding production credentials.
    The fix costs one `env:` line -- bash expanding `$REF` at runtime never reparses
    what it finds.

    The workflow_dispatch permission check is not the answer here. It bounds who can
    try, not what the attempt does, and these workflows deliberately run with more
    reach than the person pressing the button is meant to have."""

    def test_no_free_text_input_is_pasted_into_a_script_body(self):
        offenders = []

        for path in sorted(WORKFLOW_DIR.glob("*.yml")):
            workflow = yaml.safe_load(path.read_text())
            if not isinstance(workflow, dict):
                continue

            for name in _free_text_inputs(workflow):
                # Both spellings reach the same value.
                pattern = re.compile(
                    r"\$\{\{\s*(?:inputs|github\.event\.inputs)\." + re.escape(name) + r"\s*\}\}"
                )
                for job_name, step_name, body in _script_bodies(workflow):
                    if pattern.search(body):
                        offenders.append(f"{path.name} :: {job_name} :: {step_name} :: inputs.{name}")

        self.assertEqual(
            offenders,
            [],
            "operator-typed input is pasted directly into a script body; pass it through "
            "the step's `env:` and read it as an environment variable instead:\n  "
            + "\n  ".join(offenders),
        )

    def test_the_scan_covers_comments_too(self):
        """Not a stylistic point. Expansion happens before the body is parsed, so a
        `${{ }}` inside a `#` or `//` comment is expanded exactly like one outside it
        -- and a value containing a newline simply ends the comment and continues on
        the next line as code. A comment is the *worst* place for one of these,
        because it reads as inert.

        This is not hypothetical: the destroy-all workflow's confirmation check was
        written to read `context.payload.inputs.confirm` specifically to avoid
        interpolation, and the comment explaining why quoted the interpolation it was
        avoiding -- reintroducing it two lines above the code that dodged it."""
        body = "// deliberately not ${{ inputs.thing }} here\nconst x = 1;\n"
        workflow = {
            "on": {"workflow_dispatch": {"inputs": {"thing": {"type": "string"}}}},
            "jobs": {"j": {"steps": [{"name": "s", "with": {"script": body}}]}},
        }

        names = _free_text_inputs(workflow)
        self.assertEqual(names, ["thing"])

        found = [
            step_name
            for _, step_name, text in _script_bodies(workflow)
            if re.search(r"\$\{\{\s*inputs\.thing\s*\}\}", text)
        ]
        self.assertEqual(
            found,
            ["s"],
            "the scan skips commented-out interpolations, which are expanded just the "
            "same and are the easiest kind to leave behind",
        )

    def test_constrained_inputs_are_not_flagged(self):
        """Guard against the test being 'fixed' by widening it until it matches
        nothing. A boolean cannot carry a payload, and flagging one would push the
        next person to work around the rule rather than follow it."""
        workflow = {
            "on": {
                "workflow_dispatch": {
                    "inputs": {
                        "apply": {"type": "boolean"},
                        "mode": {"type": "choice", "options": ["a", "b"]},
                        "ref": {"type": "string"},
                        "attempts": {"type": "number"},
                        "untyped": {"description": "no type key at all"},
                    }
                }
            },
            "jobs": {},
        }

        self.assertEqual(
            sorted(_free_text_inputs(workflow)),
            ["attempts", "ref", "untyped"],
            "boolean and choice are enforced by GitHub and must not be flagged -- a "
            "scan that cries wolf gets widened until it matches nothing. number must "
            "be flagged: it is a text box with a label, not a constraint.",
        )


if __name__ == "__main__":
    unittest.main()
