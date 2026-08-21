"""Every local composite action is on disk before the step that uses it.

`uses: ./.github/actions/x` does not fetch anything. It reads the working tree, so
a job referencing a local action without having run `actions/checkout` first fails
with "Can't find 'action.yml'" -- at the step, after the deploy has already been
queued. Nothing in GitHub's own validation catches it, and it is invisible in
review because the checkout that makes it work is usually somewhere else in the
file.

Most of these jobs check out sparsely, which adds a second way to get it wrong:
the checkout succeeds, the action directory is simply not in the sparse list, and
the failure is identical. `env-deploy-command.yml` checked out twice for this
reason before the two were folded together.

Card 02 of the 2026-08-21 architecture review moved six copies of the
command-queue wait, and then six copies of the enqueue, into two actions. That
took the number of local action references from two to fourteen. This module is
what makes that safe to keep doing.
"""

import pathlib
import re
import unittest

import pipeline_harness as harness

ACTIONS_DIR = harness.REPO_ROOT / ".github" / "actions"

AWAIT_ACTION = "./.github/actions/await-vm-command"
AWAIT_ACTION_FILE = ACTIONS_DIR / "await-vm-command" / "action.yml"

QUEUE_ACTION = "./.github/actions/queue-vm-command"
QUEUE_ACTION_FILE = ACTIONS_DIR / "queue-vm-command" / "action.yml"
QUEUE_ACTION_SCRIPT = ACTIONS_DIR / "queue-vm-command" / "Write-VmCommand.ps1"

# Every workflow that queues a command onto the VM and waits for the answer. Both
# halves are one action for all of them: queue-vm-command and await-vm-command.
QUEUE_PRODUCERS = [
    "db-find-legacy-text-columns.yml",
    "env-deploy-command.yml",
    "pr-test-deploy.yml",
    "pr-test-destroy-all.yml",
    "pr-test-lifecycle.yml",
    "pr-test-renew-certificates.yml",
]


def _local_action_references(parsed):
    """(job, step index, action path) for every `uses: ./...` in a workflow."""
    for job_name, job in (parsed.get("jobs") or {}).items():
        for index, step in enumerate(job.get("steps") or []):
            uses = step.get("uses") or ""
            if uses.startswith("./"):
                yield job_name, index, uses


def _checkouts_before(parsed, job_name, index):
    """Every `actions/checkout` step in `job_name` occurring before `index`."""
    steps = parsed["jobs"][job_name].get("steps") or []
    return [
        step
        for step in steps[:index]
        if (step.get("uses") or "").startswith("actions/checkout@")
    ]


def _sparse_paths(checkout_step):
    """The sparse-checkout list, or None when the checkout is not sparse."""
    with_block = checkout_step.get("with") or {}
    sparse = with_block.get("sparse-checkout")
    if sparse is None:
        return None
    return [line.strip() for line in str(sparse).splitlines() if line.strip()]


class LocalActionCheckoutTests(harness.HarnessAssertions, unittest.TestCase):
    """The invariant: checked out, before, and included in the sparse list."""

    def test_every_local_action_reference_is_checked_out_first(self):
        references = []
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            parsed = harness.workflow(path.name)
            for job_name, index, uses in _local_action_references(parsed):
                references.append((path.name, job_name, index, uses))
                checkouts = _checkouts_before(parsed, job_name, index)
                self.assertTrue(
                    checkouts,
                    f"{path.name} job `{job_name}` step {index} uses `{uses}`, but "
                    "nothing checks out the repository earlier in that job. A local "
                    "action is read from the working tree, so this fails at runtime "
                    "with `Can't find 'action.yml'`.",
                )

                # A sparse checkout that omits the action is the same failure with a
                # green checkout step in front of it. Only one of the checkouts has
                # to cover it; a non-sparse checkout covers everything.
                is_covered = any(
                    _sparse_paths(checkout) is None
                    or any(uses[2:].startswith(entry) for entry in _sparse_paths(checkout))
                    for checkout in checkouts
                )
                self.assertTrue(
                    is_covered,
                    f"{path.name} job `{job_name}` uses `{uses}`, and every checkout "
                    "before it is sparse without including that path. The checkout "
                    "succeeds and the action is still missing.",
                )

        self.assertNotVacuous(
            references, "no workflow references a local action, so this checked nothing"
        )

    def test_a_sparse_checkout_that_names_a_file_turns_cone_mode_off(self):
        """Cone mode matches directories, so a file pattern in a cone-mode list
        matches nothing and the checkout still reports success.

        Every sparse checkout in the pipeline is correct on this today: the four
        that name a file already set the flag, and the two that leave it unset list
        directories only. What this holds is the next edit. Adding
        `.github/scripts/something.js` to one of those two lists is a one-line change
        that reviews cleanly and fails at runtime as a missing file, which reads as
        a bad path rather than as a checkout that quietly skipped it.

        Not switching the other two to non-cone instead: cone mode also brings down
        the files at each parent level, so turning it off removes files from the
        working tree rather than adding any.
        """
        offenders = []
        checked = []

        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            parsed = harness.workflow(path.name)
            for job_name, job in (parsed.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    entries = _sparse_paths(step)
                    if entries is None:
                        continue

                    checked.append(f"{path.name}:{job_name}")
                    named_files = [e for e in entries if pathlib.PurePosixPath(e).suffix]
                    cone_off = (step.get("with") or {}).get("sparse-checkout-cone-mode") is False
                    if named_files and not cone_off:
                        offenders.append(
                            f"{path.name} job `{job_name}` -> " + ", ".join(named_files)
                        )

        self.assertNotVacuous(checked, "no workflow checks out sparsely any more")
        self.assertEqual(
            [],
            offenders,
            "these name a file in a cone-mode sparse checkout, so the pattern matches "
            "nothing and the file never lands. Set `sparse-checkout-cone-mode: false`:"
            "\n  " + "\n  ".join(offenders),
        )

    def test_every_referenced_local_action_exists(self):
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            for job_name, index, uses in _local_action_references(harness.workflow(path.name)):
                action = harness.REPO_ROOT / uses[2:] / "action.yml"
                self.assertTrue(
                    action.exists(),
                    f"{path.name} job `{job_name}` uses `{uses}`, which has no action.yml",
                )


class AwaitActionAdoptionTests(harness.HarnessAssertions, unittest.TestCase):
    """The six producers all wait the same way now."""

    def test_every_queue_producer_waits_through_the_action(self):
        for name in QUEUE_PRODUCERS:
            parsed = harness.workflow(name)
            uses = [u for _, _, u in _local_action_references(parsed)]
            self.assertIn(
                AWAIT_ACTION,
                uses,
                f"{name} queues a command onto the VM but does not wait through "
                "the shared action. That is how the six copies drifted the first time.",
            )

    def test_no_producer_kept_its_own_poll_loop(self):
        for name in QUEUE_PRODUCERS:
            parsed = harness.workflow(name)
            for job_name, job in (parsed.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    run = step.get("run") or ""
                    polls_inline = "Start-Sleep" in run and "result.json" in run
                    self.assertFalse(
                        polls_inline,
                        f"{name} job `{job_name}` step `{step.get('name')}` polls for "
                        "a result object inline. The wait belongs to "
                        "`await-vm-command`, so that a fix to it reaches every caller.",
                    )

    def test_the_action_gets_a_bucket_and_a_command_id_from_every_caller(self):
        # Both are `required: true`, which GitHub does not enforce for composite
        # actions -- a missing input is the empty string, and an empty bucket makes
        # every gsutil path `gs:///...`, which fails in a way that names nothing.
        for name in QUEUE_PRODUCERS:
            parsed = harness.workflow(name)
            for job_name, job in (parsed.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    if (step.get("uses") or "") != AWAIT_ACTION:
                        continue
                    supplied = step.get("with") or {}
                    for required in ("bucket", "command-id", "label"):
                        value = str(supplied.get(required, "")).strip()
                        self.assertTrue(
                            value,
                            f"{name} job `{job_name}` calls the await action without "
                            f"`{required}`.",
                        )


class WaitCeilingTests(harness.HarnessAssertions, unittest.TestCase):
    """Two workflows that can queue the same command must wait the same length.

    `pr-test-destroy-all.yml` queued `destroy` and waited 600 seconds while
    `pr-test-lifecycle.yml` queued the same `destroy` and waited 1800. A teardown
    that ran past ten minutes was a timeout in one run and a success in the other,
    for identical work on the same VM -- and because `fail-fast` is off in the
    sweep, the false timeout was triaged as a failed teardown of a PR whose disk
    had in fact been released.

    Six copies of this wait were converted to the shared action and five of them
    were brought to a common ceiling. This is the sixth, found by review rather
    than by anything in the suite, which is the gap this test closes.

    A ceiling is only compared where both ends resolve to a literal. Where a caller
    computes its attempt count from an input, there is nothing here to compare and
    the pair is skipped rather than guessed at.
    """

    def ceiling_seconds(self, with_block, defaults):
        """The wait ceiling in seconds, or None if either half is an expression."""
        attempts = str(with_block.get("attempts", defaults["attempts"]))
        interval = str(with_block.get("interval-seconds", defaults["interval-seconds"]))
        if not (attempts.isdigit() and interval.isdigit()):
            return None
        return int(attempts) * int(interval)

    def action_defaults(self):
        """The `attempts` and `interval-seconds` defaults the action declares."""
        inputs = harness.composite_action("await-vm-command")["inputs"]
        return {name: inputs[name]["default"] for name in ("attempts", "interval-seconds")}

    def commands_and_ceilings(self):
        """{command name: {workflow: ceiling}} over every job that queues and waits.

        A workflow's `command` dispatch input carries an `options:` list, which is
        the set of command names it can queue. That is how `pr-test-lifecycle.yml`
        is known to queue `destroy` even though the step passes an expression.
        """
        defaults = self.action_defaults()
        found = {}
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            parsed = harness.workflow(path.name)
            dispatch = (harness.triggers(parsed) or {}).get("workflow_dispatch") or {}
            options = (((dispatch.get("inputs") or {}).get("command") or {}).get("options")) or []

            for job in (parsed.get("jobs") or {}).values():
                steps = job.get("steps") or []
                queued, ceilings = [], []
                for step in steps:
                    uses = step.get("uses") or ""
                    block = step.get("with") or {}
                    if uses == QUEUE_ACTION:
                        named = str(block.get("command", ""))
                        queued.extend(options if named.startswith("${{") else [named])
                    elif uses == AWAIT_ACTION:
                        ceilings.append(self.ceiling_seconds(block, defaults))
                if not (queued and ceilings):
                    continue
                # One wait per job in every caller today; take the first so a second
                # one added later does not silently pick up the wrong pairing.
                seconds = ceilings[0]
                if seconds is None:
                    continue
                for command in queued:
                    found.setdefault(command, {})[path.name] = seconds
        return found

    def test_one_command_has_one_ceiling(self):
        found = self.commands_and_ceilings()
        self.assertNotVacuous(found, "no workflow both queues a command and waits for it")

        shared = {c: w for c, w in found.items() if len(w) > 1}
        self.assertNotVacuous(
            shared,
            "no command is queued by two workflows any more, so this test compares "
            "nothing. If that is real, delete it; if a queue step stopped being "
            "recognised, fix that instead.",
        )

        offenders = [
            f"`{command}`: " + ", ".join(f"{w} waits {s}s" for w, s in sorted(by_workflow.items()))
            for command, by_workflow in sorted(shared.items())
            if len(set(by_workflow.values())) > 1
        ]
        self.assertEqual(
            [],
            offenders,
            "the same command gets two different ceilings depending on which "
            "workflow queued it, so the same run is a timeout from one and a "
            "success from the other:\n  " + "\n  ".join(offenders),
        )


class DeclaredOutputTests(harness.HarnessAssertions, unittest.TestCase):
    """An output nobody reads is a promise nobody checks.

    `await-vm-command` used to declare two of them. `status` was set to
    `succeeded` on the success path and `failed` on the failure path -- but the
    failure path exits non-zero immediately after, so the calling step never runs
    and the only value a caller could ever observe was `succeeded`. `error` was
    documented as "the error text the VM reported, empty on success" and was
    assigned exactly once, on the success path, to the empty string. Neither the
    failure path nor the timeout path ever populated it.

    Both were wrong in ways that reading them would have surfaced immediately, and
    both survived because nothing read them. Deleting is the fix; this stops the
    next one being added.
    """

    def reads_of(self, name, declaring_action):
        """Every place outside the declaring action that reads `.outputs.<name>`.

        A composite action forwards its own inner step's output, so its own file
        always mentions the name. That line is the declaration, not a caller."""
        own_file = harness.ACTIONS_DIR / declaring_action / "action.yml"
        pattern = re.compile(r"\.outputs\." + re.escape(name) + r"\b")
        found = []
        candidates = sorted(harness.WORKFLOWS_DIR.glob("*.yml")) + sorted(
            harness.ACTIONS_DIR.glob("*/action.yml")
        )
        for path in candidates:
            if path == own_file:
                continue
            text = path.read_text(encoding="utf-8")
            for match in pattern.finditer(text):
                found.append(f"{path.name}:{harness.line_of(text, match.start())}")
        return found

    def test_every_declared_output_is_read_by_a_caller(self):
        declared, unread = [], []
        for action in harness.composite_actions():
            for name in harness.composite_action(action).get("outputs") or {}:
                declared.append(f"{action}.{name}")
                if not self.reads_of(name, action):
                    unread.append(f"{action}.{name}")

        self.assertNotVacuous(declared, "no composite action declares an output")
        self.assertEqual(
            [],
            unread,
            "these outputs are declared and never read, so nothing would notice if "
            "they stopped being populated -- delete them or read them: "
            + ", ".join(unread),
        )


class AwaitActionBehaviourTests(unittest.TestCase):
    """The wait's own behaviour, asserted once.

    These assertions used to live in the producers' test files, one copy per
    workflow, and only ever matched the copy that happened to have the feature.
    The timeout message below is the clearest case: it was written after a real
    misdiagnosis, added to one of the six copies, and never reached the other
    five.
    """

    def test_the_result_path_follows_the_queue_the_caller_named(self):
        """Two callers pass a queue other than `commands`. A hardcoded path polls
        the wrong prefix forever and reports a timeout, so the command looks hung
        rather than misaddressed -- the failure is silent in the direction that
        costs the most to diagnose."""
        text = AWAIT_ACTION_FILE.read_text()

        self.assertIn("/pr-environments/$($env:AWAIT_QUEUE)/results/", text)
        self.assertNotIn("/pr-environments/commands/results/", text)

    def test_the_timeout_message_names_the_actual_cause(self):
        """A missing result object means the queue worker never ran. 'Timed out'
        alone sent three months of failures to the wrong place."""
        text = AWAIT_ACTION_FILE.read_text()

        self.assertIn("scheduled task is running on the target VM", text)

    def test_a_failure_is_annotated_rather_than_only_logged(self):
        """Without the annotation the reason sits somewhere in a poll loop's
        output and the run summary says only that a step exited non-zero."""
        text = AWAIT_ACTION_FILE.read_text()

        self.assertIn("::error::", text)


class GuardTests(unittest.TestCase):
    """Prove the sparse-list check can fail rather than trusting that it would."""

    def test_a_sparse_list_that_omits_the_action_is_not_covered(self):
        checkout = {
            "uses": "actions/checkout@v4",
            "with": {"sparse-checkout": "Deployment/PrTestEnvironments\n"},
        }
        paths = _sparse_paths(checkout)
        self.assertEqual(["Deployment/PrTestEnvironments"], paths)
        self.assertFalse(any(AWAIT_ACTION[2:].startswith(entry) for entry in paths))

    def test_a_non_sparse_checkout_covers_everything(self):
        self.assertIsNone(_sparse_paths({"uses": "actions/checkout@v4"}))


if __name__ == "__main__":
    unittest.main()


class QueueActionAdoptionTests(harness.HarnessAssertions, unittest.TestCase):
    """The enqueue is the other half of the wait, and it moved for a sharper reason.

    Two of the six producers echoed the queued command into the Actions log
    through a redaction loop keyed on the literal field name `connectionString`.
    The producer that carries the sandbox password calls that field
    `sandboxConnectionString`, so it was one copied step away from putting a
    plaintext password into a public log. The queue agent on the VM has redacted
    both names since it was written; only the workflow half knew one name.
    """

    def queue_steps(self, name):
        """Every step in a workflow that calls the enqueue action."""
        steps = []
        for job_name, job in (harness.workflow(name).get("jobs") or {}).items():
            for step in job.get("steps") or []:
                if (step.get("uses") or "") == QUEUE_ACTION:
                    steps.append((job_name, step))
        return steps

    def test_every_producer_queues_through_the_action(self):
        for name in QUEUE_PRODUCERS:
            self.assertTrue(
                self.queue_steps(name),
                f"{name} is listed as a queue producer but does not call "
                f"`{QUEUE_ACTION}`.",
            )

    def test_no_producer_kept_its_own_enqueue(self):
        """A leftover hand-rolled enqueue is not a duplicate, it is a second
        command on the queue -- and the one that skips the shared redaction."""
        for name in QUEUE_PRODUCERS:
            for job_name, job in (harness.workflow(name).get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    run = step.get("run") or ""
                    self.assertNotIn(
                        "/pending/",
                        run,
                        f"{name} job `{job_name}` step `{step.get('name')}` still "
                        "writes to the queue directly.",
                    )

    def test_every_call_names_a_bucket_a_command_id_and_a_verb(self):
        # `required: true` is not enforced for a composite action: a missing input
        # arrives as the empty string, and an empty verb reaches the VM as a
        # command the agent has no branch for, which it reports as a failure
        # naming neither the workflow nor the field.
        calls = []
        for name in QUEUE_PRODUCERS:
            for job_name, step in self.queue_steps(name):
                calls.append((name, job_name))
                supplied = step.get("with") or {}
                for required in ("bucket", "command-id", "command"):
                    self.assertTrue(
                        str(supplied.get(required, "")).strip(),
                        f"{name} job `{job_name}` queues a command without "
                        f"`{required}`.",
                    )
        self.assertNotVacuous(calls, "no producer calls the queue action")

    def test_no_caller_passes_a_connection_string_inside_the_payload(self):
        """`secret-value` exists so a connection string never passes through an
        interpolated JSON literal. A password containing a quote would break the
        JSON and land in the expanded workflow text on the way."""
        for name in QUEUE_PRODUCERS:
            for job_name, step in self.queue_steps(name):
                payload = str((step.get("with") or {}).get("payload") or "")
                self.assertNotIn(
                    "onnectionString",
                    payload,
                    f"{name} job `{job_name}` puts a connection string in the "
                    "payload; pass it as `secret-value` instead.",
                )

    def test_a_payload_that_interpolates_a_value_uses_toJSON(self):
        r"""`target_site_path` is a Windows path, and a bare backslash is not a
        valid JSON escape -- `C:\inetpub` inside a quoted JSON string is a parse
        error, not a path. toJSON emits the quotes and the escaping together, so
        the rule is that an interpolated string value is never hand-quoted."""
        for name in QUEUE_PRODUCERS:
            for job_name, step in self.queue_steps(name):
                payload = str((step.get("with") or {}).get("payload") or "")
                self.assertNotRegex(
                    payload,
                    r'"\s*\$\{\{',
                    f"{name} job `{job_name}` hand-quotes an interpolated payload "
                    "value. Use toJSON(...) without the surrounding quotes.",
                )


class QueueActionBehaviourTests(harness.HarnessAssertions, unittest.TestCase):
    """The enqueue's own behaviour, asserted once.

    What the command *does* -- the envelope, the drop-if-empty rule, and the
    redaction -- is executed by Tests/PrTestEnvironments/Pester/QueueCommand.Tests.ps1
    rather than pattern-matched here. These are the wiring claims that Pester
    cannot see, because Pester loads the script and never reads action.yml.
    """

    def test_the_action_runs_the_script_rather_than_inlining_the_powershell(self):
        """PowerShell inlined in YAML is a string until a runner expands it, so
        nothing can execute it -- which is exactly how the two redaction loops
        drifted apart while both looked correct in review."""
        text = QUEUE_ACTION_FILE.read_text()

        self.assertTrue(QUEUE_ACTION_SCRIPT.is_file(), f"{QUEUE_ACTION_SCRIPT} is missing")
        self.assertIn("Write-VmCommand.ps1", text)
        # The action's own directory, read from the env var the runner exports
        # rather than from a `${{ }}` expression -- the expression form cannot be
        # quoted safely and breaks the syntax job. RunnerExpressionPlacementTests
        # in test_powershell_job.py holds that rule for every block.
        self.assertIn('& "$env:GITHUB_ACTION_PATH/Write-VmCommand.ps1"', text)

    def test_a_default_is_not_written_down_twice(self):
        """action.yml defaults an input; the script defaults the parameter it feeds.
        Whoever changes one has to remember the other, and this action exists
        because a field name in one file drifted from the same field name in
        another: two echo loops keyed on `connectionString` while the producer
        holding the sandbox password called it `sandboxConnectionString`.

        Derived from both files rather than tabulated here, so an input added
        tomorrow is covered without anyone editing this test.
        """
        inputs = harness.composite_action("queue-vm-command")["inputs"]

        # The parameters of the one function the action calls. Names map from the
        # input's kebab-case to PowerShell's PascalCase.
        parameters = dict(
            re.findall(
                r"\[Parameter\([^)]*\)\]\[string\]\$(\w+)\s*=\s*'([^']*)'",
                QUEUE_ACTION_SCRIPT.read_text(),
            )
        )
        self.assertNotVacuous(
            parameters,
            "Found no defaulted parameters in the script. Either the param block "
            "moved or its shape changed, and this test would pass on any pair of "
            "files that disagree.",
        )

        compared = []
        for name, definition in inputs.items():
            if "default" not in definition:
                continue
            pascal = "".join(part.capitalize() for part in name.split("-"))
            if pascal not in parameters:
                continue

            compared.append(name)
            self.assertEqual(
                str(definition["default"]),
                parameters[pascal],
                f"action.yml defaults `{name}` to {definition['default']!r} and "
                f"Write-VmCommand.ps1 defaults ${pascal} to "
                f"{parameters[pascal]!r}. Whichever is wrong, only one of them is "
                "the one a caller gets.",
            )

        self.assertNotVacuous(
            compared,
            "No input lined up with a parameter, so this compared nothing. The "
            "kebab-case to PascalCase mapping is the likely break.",
        )

    def test_the_pending_path_follows_the_queue_the_caller_named(self):
        """Two callers pass a queue other than `commands`. A hardcoded prefix puts
        the command where no agent is looking, and the wait that follows reports a
        timeout -- so it reads as a dead VM rather than a misaddressed command."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("/pr-environments/$($env:VMQ_QUEUE)/pending/", text)
        self.assertNotIn("/pr-environments/commands/pending/", text)

    def test_a_failed_upload_is_an_error_rather_than_a_silent_success(self):
        """gsutil failing leaves no command on the queue. Without this the step is
        green, and the wait spends its full timeout on a command that was never
        queued."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("$LASTEXITCODE -ne 0", text)

    def test_the_script_returns_before_uploading_when_it_is_only_being_loaded(self):
        """Pester dot-sources this file to reach the functions. Without the guard
        the load would try to queue a command."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("IsNullOrWhiteSpace($env:VMQ_BUCKET)", text)

    def test_redaction_keys_on_the_shape_of_a_name_not_a_list_of_known_ones(self):
        """The defect this replaces was a literal `$key -eq 'connectionString'`.
        A list of known names cannot cover the field nobody has added yet, which
        is the only case where redaction has to work unprompted."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("connectionstring|password|secret|token|credential", text)
        self.assertNotIn("-eq 'connectionString'", text)
