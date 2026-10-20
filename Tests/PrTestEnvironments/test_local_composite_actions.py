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

A third action, run-vm-command, now calls those two, so every producer names one
action per command and the pair is written down in one file instead of ten.
"""

import pathlib
import re
import unittest

import pipeline_harness as harness

ACTIONS_DIR = harness.REPO_ROOT / ".github" / "actions"

AWAIT_ACTION = "./.github/actions/await-vm-command"
AWAIT_ACTION_FILE = ACTIONS_DIR / "await-vm-command" / "action.yml"
AWAIT_ACTION_SCRIPT = ACTIONS_DIR / "await-vm-command" / "Await-VmCommand.ps1"

QUEUE_ACTION = "./.github/actions/queue-vm-command"
QUEUE_ACTION_FILE = ACTIONS_DIR / "queue-vm-command" / "action.yml"
QUEUE_ACTION_SCRIPT = ACTIONS_DIR / "queue-vm-command" / "Write-VmCommand.ps1"

# The one action a workflow calls to do both: it queues through the first and
# waits through the second, with one id, one bucket and one queue for the pair.
RUN_ACTION = "./.github/actions/run-vm-command"
RUN_ACTION_FILE = ACTIONS_DIR / "run-vm-command" / "action.yml"

# Every workflow that queues a command onto the VM and waits for the answer. All
# of them do both through one action, run-vm-command.
#
# Hand-written, because the claim each sweep below makes is that a *named*
# workflow uses the shared action -- derived from the callers, that claim would
# read "everything that calls the action calls the action" and a workflow that
# reverted to its own enqueue would drop out of the list rather than fail.
# `test_no_workflow_queues_from_outside_this_list` is the other direction, and it
# exists because this list was two workflows short: db-anonymize-staging.yml and
# db-set-theme-customization.yml were added to the fleet after it was written and
# sat outside every sweep here, including the one that keeps a connection string
# out of an interpolated payload. Both of those workflows carry one.
QUEUE_PRODUCERS = [
    "db-anonymize-staging.yml",
    "db-find-legacy-text-columns.yml",
    "db-set-theme-customization.yml",
    "env-deploy-command.yml",
    "pr-test-deploy.yml",
    "pr-test-destroy-all.yml",
    "pr-test-lifecycle.yml",
    "pr-test-renew-certificates.yml",
]

QUEUE_AGENT = (
    harness.REPO_ROOT / "Deployment" / "PrTestEnvironments"
    / "Invoke-PrEnvironmentCommandQueue.ps1"
)


def _local_action_references(parsed):
    """(job, step index, action path) for every `uses: ./...` in a workflow."""
    for job_name, job in (parsed.get("jobs") or {}).items():
        for index, step in enumerate(job.get("steps") or []):
            uses = step.get("uses") or ""
            if uses.startswith("./"):
                yield job_name, index, uses


def _run_calls(name):
    """(job, step) for every call to run-vm-command in a workflow."""
    calls = []
    for job_name, job in (harness.workflow(name).get("jobs") or {}).items():
        for step in job.get("steps") or []:
            if (step.get("uses") or "") == RUN_ACTION:
                calls.append((job_name, step))
    return calls


def _run_action_step(uses):
    """The step of run-vm-command that calls `uses`, or None."""
    for step in harness.action_steps(harness.composite_action("run-vm-command")):
        if (step.get("uses") or "") == uses:
            return step
    return None


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

    def test_no_sparse_list_names_an_action_one_at_a_time(self):
        """`.github/actions`, not three entries that have to be kept in step.

        Six jobs listed the same three action directories. Adding a fourth action
        meant editing all six, and `queue-vm-command` is the proof -- it went in as
        six separate edits to six sparse lists, and the workflow that got missed
        failed several minutes into a deploy with `Can't find 'action.yml'`.

        The coverage check above catches that, so the cost was a red build rather
        than a broken deploy. This removes the occasion for the red build. One entry
        covers every action there is and every action there will be, and the four
        directories together are a few kilobytes of YAML and PowerShell.

        Directory entries only, so cone mode is unaffected: `.github/actions` is a
        directory in both modes, which is what the check below this one is about."""
        offenders = []
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            text = path.read_text(encoding="utf-8")
            for job_name, job in (harness.workflow(path.name).get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    for entry in _sparse_paths(step) or []:
                        if entry.startswith(".github/actions/"):
                            offenders.append(f"{path.name} [{job_name}] {entry}")

        self.assertEqual(
            [],
            offenders,
            "these name a single action inside the actions directory, so the next "
            "action added has to be added here too:\n  " + "\n  ".join(offenders),
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


class RunActionAdoptionTests(harness.HarnessAssertions, unittest.TestCase):
    """Every producer queues and waits through one action, and nothing else reaches
    either half.

    The two halves have to agree on an id, a bucket and a queue. With a call to
    each, ten jobs wrote all three down twice, and the only thing holding each pair
    together was a test comparing one step with the next. Inside one action the
    pair is written once, so a mismatch has nowhere to live.
    """

    def test_every_queue_producer_runs_its_commands_through_the_action(self):
        for name in QUEUE_PRODUCERS:
            self.assertTrue(
                _run_calls(name),
                f"{name} is listed as a queue producer but does not call "
                f"`{RUN_ACTION}`. That is how the six copies drifted the first time.",
            )

    def test_only_the_run_action_calls_either_half(self):
        """A workflow calling queue-vm-command directly is a pair whose id, bucket
        and queue are its own again, and a second action wrapping them is a second
        place the pairing is written. Either is the drift this action removed."""
        halves = (QUEUE_ACTION, AWAIT_ACTION)
        offenders = []

        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            for job_name, _, uses in _local_action_references(harness.workflow(path.name)):
                if uses in halves:
                    offenders.append(f"{path.name} job `{job_name}` -> {uses}")

        for action in harness.composite_actions():
            if action == "run-vm-command":
                continue
            for step in harness.action_steps(harness.composite_action(action)):
                if (step.get("uses") or "") in halves:
                    offenders.append(f"{action}/action.yml -> {step['uses']}")

        self.assertEqual(
            [],
            offenders,
            f"these call a half of the protocol directly; call `{RUN_ACTION}` "
            "instead:\n  " + "\n  ".join(offenders),
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

    def test_every_call_names_a_bucket_a_prefix_a_verb_and_a_label(self):
        # All four are `required: true`, which GitHub does not enforce for a
        # composite action: a missing input is the empty string. An empty bucket
        # makes every gsutil path `gs:///...`; an empty verb reaches the VM as a
        # command the agent has no branch for; an empty prefix queues an id that
        # starts with a hyphen and names no caller; an empty label makes the
        # failure annotation name nothing. None of them fails where it was caused.
        calls = []
        for name in QUEUE_PRODUCERS:
            for job_name, step in _run_calls(name):
                calls.append((name, job_name))
                supplied = step.get("with") or {}
                for required in ("bucket", "command-id-prefix", "command", "label"):
                    self.assertTrue(
                        str(supplied.get(required, "")).strip(),
                        f"{name} job `{job_name}` runs a command without "
                        f"`{required}`.",
                    )
        self.assertNotVacuous(calls, "no producer calls the run action")


class WaitCeilingTests(harness.HarnessAssertions, unittest.TestCase):
    """How long a producer waits for the VM to answer.

    Two rules. Every wait outlasts the agent's own timeout for the verb it
    queued, so a run that hangs comes back as the agent's verdict -- "timed out
    after N seconds and was terminated", with the log -- instead of as a
    workflow that gave up on a result still on its way. And two workflows that
    queue the same verb wait the same length.

    Both read a wait the way a run does. An attempt count or an interval taken
    from `env` or from an input resolves to the default the workflow declares
    for it. The first rule used to live only in prose, in three dispatch
    inputs' descriptions and the agent's contract table, and the second
    skipped every wait read from an input, which was six of the ten.
    """

    # The agent is a scheduled task Windows starts once a minute
    # (Install-PrEnvironmentCommandQueueTask.ps1, `/SC MINUTE /MO 1`), so a
    # command can sit in pending/ for up to sixty seconds before its timeout
    # starts counting. After the timeout the agent still has to report: the
    # result write retries twice, five and then ten seconds apart
    # (Complete-QueuedCommand), and around it are gsutil round trips -- the
    # script refresh before the queue is read, and the log upload before the
    # result. Ninety seconds is the minute, the fifteen, and fifteen for those.
    #
    # It does not cover a command queued behind another one. The agent runs
    # them one at a time, and how long the one ahead takes is not a property
    # of the verb being waited for.
    MARGIN_SECONDS = 90

    def action_defaults(self):
        """The `attempts` and `interval-seconds` defaults the action declares."""
        inputs = harness.composite_action("run-vm-command")["inputs"]
        return {name: inputs[name]["default"] for name in ("attempts", "interval-seconds")}

    def resolved(self, parsed, job, value):
        """`value` as a whole number of attempts or seconds.

        A literal is read as it is. `${{ env.X }}` is the job's, or else the
        workflow's, env entry X. `${{ inputs.X }}` and
        `${{ github.event.inputs.X }}` are the default the workflow declares for
        its input X under workflow_dispatch or workflow_call -- what every run
        waits unless an operator types another number into the form for that
        one run. Anything else fails rather than being skipped, because a
        skipped wait is one this class passes over without saying so.
        """
        text = str(value).strip()
        if text.isdigit():
            return int(text)

        env = {**(parsed.get("env") or {}), **(job.get("env") or {})}
        from_env = re.fullmatch(r"\$\{\{\s*env\.(\w+)\s*\}\}", text)
        if from_env and from_env.group(1) in env:
            # The job is dropped for the next hop: an env entry that reads
            # another env entry would be a loop, not a ceiling.
            return self.resolved(parsed, {}, env[from_env.group(1)])

        from_input = re.fullmatch(r"\$\{\{\s*(?:github\.event\.)?inputs\.(\w+)\s*\}\}", text)
        if from_input:
            on = harness.triggers(parsed) or {}
            defaults = {
                str(spec["default"])
                for trigger in ("workflow_dispatch", "workflow_call")
                for name, spec in (((on.get(trigger) or {}).get("inputs")) or {}).items()
                if name == from_input.group(1) and (spec or {}).get("default") is not None
            }
            if len(defaults) == 1:
                return self.resolved(parsed, {}, defaults.pop())

        self.fail(
            f"`{text}` is not a number, and not an env entry or an input with one "
            "default that resolves to a number, so how long this wait lasts cannot "
            "be read from the workflow."
        )

    def wait(self, parsed, job_name, step):
        """(attempts, interval in seconds) for one call, with the action's defaults."""
        block = step.get("with") or {}
        defaults = self.action_defaults()
        job = parsed["jobs"][job_name]
        return (
            self.resolved(parsed, job, block.get("attempts", defaults["attempts"])),
            self.resolved(
                parsed, job, block.get("interval-seconds", defaults["interval-seconds"])
            ),
        )

    def verbs(self, parsed, step):
        """The verbs one call can queue.

        A workflow's `command` dispatch input carries an `options:` list, which is
        the set of command names it can queue. That is how `pr-test-lifecycle.yml`
        is known to queue `destroy` even though the step passes an expression.
        The verb and its wait are one step now, so nothing has to guess which wait
        belongs to which enqueue.
        """
        named = str((step.get("with") or {}).get("command", ""))
        if not named.startswith("${{"):
            return [named]
        dispatch = (harness.triggers(parsed) or {}).get("workflow_dispatch") or {}
        options = (((dispatch.get("inputs") or {}).get("command") or {}).get("options")) or []
        self.assertTrue(
            options,
            f"the call queues `{named}` and the workflow's `command` input lists no "
            "options, so which verbs it waits for cannot be read.",
        )
        return [str(option) for option in options]

    def commands_and_ceilings(self):
        """{command name: {workflow: ceiling}} over every call that runs a command."""
        found = {}
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            parsed = harness.workflow(path.name)
            for job_name, step in _run_calls(path.name):
                attempts, interval = self.wait(parsed, job_name, step)
                for command in self.verbs(parsed, step):
                    found.setdefault(command, {})[path.name] = attempts * interval
        return found

    def test_every_wait_outlasts_the_timeout_of_the_verb_it_queued(self):
        """The agent's verdict arrives while somebody is still looking for it.

        The agent kills a command at its row's TimeoutSeconds and writes a failed
        result naming the timeout, and the log goes up with it. A wait that gives
        up first reports "No result" and points at the scheduled task -- the
        wrong place -- while the real answer lands in the bucket afterwards with
        nobody reading it.

        Measured to the last look, not to the end of the wait. The wait looks
        before it sleeps, so after the last look it sleeps one more interval and
        gives up without looking again; a result written in that interval is
        never seen.
        """
        agent = QUEUE_AGENT.read_text(encoding="utf-8")
        checked = []
        short = []

        for name in QUEUE_PRODUCERS:
            parsed = harness.workflow(name)
            for job_name, step in _run_calls(name):
                attempts, interval = self.wait(parsed, job_name, step)
                last_look = (attempts - 1) * interval
                for verb in self.verbs(parsed, step):
                    timeout = harness.command_contract(agent, verb)["TimeoutSeconds"]
                    checked.append((name, job_name, verb))
                    if last_look < timeout + self.MARGIN_SECONDS:
                        short.append(
                            f"{name} job `{job_name}` last looks for `{verb}` at "
                            f"{last_look}s ({attempts} attempts {interval}s apart); "
                            f"the agent may run it {timeout}s and report up to "
                            f"{self.MARGIN_SECONDS}s after that"
                        )

        self.assertNotVacuous(checked, "no call to the run action was found")
        self.assertEqual(
            [],
            short,
            "a wait gives up before the agent's own timeout can report. Raise its "
            "attempts: a longer wait costs time only on a run that has already "
            "gone wrong.\n  " + "\n  ".join(short),
        )

    def test_a_wait_it_cannot_read_fails_rather_than_being_skipped(self):
        """No workflow does this today, so only a made-up one shows the refusal.

        The class this replaced skipped what it could not read, and what it
        could not read was every wait an operator can change.
        """
        parsed = {"jobs": {"run": {"env": {"POLL_ATTEMPTS": "${{ needs.plan.outputs.attempts }}"}}}}
        with self.assertRaises(self.failureException):
            self.resolved(parsed, parsed["jobs"]["run"], "${{ env.POLL_ATTEMPTS }}")

    def test_one_command_has_one_ceiling(self):
        """Two workflows that can queue the same command must wait the same length.

        `pr-test-destroy-all.yml` queued `destroy` and waited 600 seconds while
        `pr-test-lifecycle.yml` queued the same `destroy` and waited 1800. A
        teardown still unanswered at ten minutes was a timeout in one run and a
        success in the other, for identical work on the same VM -- and because
        `fail-fast` is off in the sweep, the false timeout was triaged as a failed
        teardown of a PR whose disk had in fact been released.

        The rule above does not cover this. `destroy` is killed at 300 seconds and
        600 clears that, but a command can wait in pending/ behind another -- the
        agent runs them one at a time, and a PR deploy may hold it for 1500
        seconds -- so the time to an answer is not bounded by the verb's own
        timeout. Equal ceilings keep the verdict from depending on which workflow
        asked.
        """
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

    An output no step sets is exempt. Every defect above was a step output that a
    script failed to populate on some path; an output the runner assembles from
    `inputs` and `github` alone has no such path, because it is evaluated whether
    or not any step ran. run-vm-command's `command-id` is the one there is: it is
    exposed so a caller can name the command without rebuilding the id, and what
    could go wrong with it is its value, which RunActionTests pins to the id both
    halves are given.
    """

    def is_set_by_a_step(self, definition):
        """True when an output's value reads a step's output."""
        return "steps." in str(definition.get("value") or "")

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
            outputs = harness.composite_action(action).get("outputs") or {}
            for name, definition in outputs.items():
                if not self.is_set_by_a_step(definition):
                    continue
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

    These read Await-VmCommand.ps1 rather than action.yml. The wait used to be 97
    lines of PowerShell inlined into the YAML, where the only check available was
    a parse. It is a script now, so Pester can run it -- see
    Tests/PrTestEnvironments/Pester/AwaitCommand.Tests.ps1. What stays here is the
    handful of strings whose value is that they exist at all.

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
        text = AWAIT_ACTION_SCRIPT.read_text()

        self.assertIn("/pr-environments/$($env:AWAIT_QUEUE)/results/", text)
        self.assertNotIn("/pr-environments/commands/results/", text)

    # That the timeout message names the actual cause -- a missing result object
    # means the queue worker never ran, and "timed out" alone sent three months
    # of failures to the wrong place -- used to be a string match here. The
    # message is now Get-NoResultMessage, and Pester/AwaitCommand.Tests.ps1 runs
    # it: it names the scheduled task, the queue and the bucket, the command id,
    # and the claim a stranded command leaves in processing/.

    def test_a_failure_is_annotated_rather_than_only_logged(self):
        """Without the annotation the reason sits somewhere in a poll loop's
        output and the run summary says only that a step exited non-zero."""
        text = AWAIT_ACTION_SCRIPT.read_text()

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
        self.assertFalse(any(RUN_ACTION[2:].startswith(entry) for entry in paths))

    def test_a_non_sparse_checkout_covers_everything(self):
        self.assertIsNone(_sparse_paths({"uses": "actions/checkout@v4"}))


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
        """Every step in a workflow that queues a command, which is every call to
        run-vm-command: the payload and the verb are its inputs, passed through to
        the enqueue unchanged."""
        return _run_calls(name)

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

    def test_no_workflow_queues_from_outside_this_list(self):
        """The other direction, and the one the list cannot supply itself.

        Every sweep above walks QUEUE_PRODUCERS, so a workflow missing from it is
        not reported as a gap -- it is simply not looked at. Two were missing:
        db-anonymize-staging.yml and db-set-theme-customization.yml joined the
        fleet after the list was written, and for as long as they sat outside it
        this class reported a clean result over two workflows that hand-quoted
        free-text dispatch inputs into a JSON payload and one of which carries a
        connection string. A hand-written list loses entries loudly, because the
        sweep that walks it fails on the name it can no longer find. It gains
        them silently. This is the half that does not.
        """
        queuing = sorted(
            path.name
            for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml"))
            if _run_calls(path.name)
        )
        self.assertNotVacuous(queuing, "no workflow calls the run action at all")
        self.assertEqual(
            sorted(QUEUE_PRODUCERS),
            queuing,
            "QUEUE_PRODUCERS no longer names every workflow that queues a command "
            "onto the VM. A workflow outside the list is one every other check in "
            "this class passes over without saying so.",
        )

    def queue_verbs(self, name, step):
        """The verbs one queue step can send.

        Nearly always the step names one outright. `pr-test-lifecycle.yml` is the
        exception: it picks between `stop` and `destroy` in JavaScript and hands
        the answer over as `env.COMMAND`, so for an interpolated verb the
        workflow's own text is read for quoted contract verbs and every one it
        can reach is checked. A verb that resolves to nothing fails here rather
        than returning an empty list, because an empty list is the state in which
        the caller below checks a payload against no contract and passes.
        """
        contract_verbs = harness.command_contract_verbs(
            QUEUE_AGENT.read_text(encoding="utf-8")
        )
        named = str((step.get("with") or {}).get("command") or "").strip()
        if named in contract_verbs:
            return [named]

        text = (harness.WORKFLOWS_DIR / name).read_text(encoding="utf-8")
        reachable = sorted(
            verb for verb in contract_verbs if f"'{verb}'" in text or f'"{verb}"' in text
        )
        self.assertTrue(
            reachable,
            f"{name} queues `{named}`, which is neither a verb the contract has a "
            "row for nor a choice this can resolve from the workflow's own text.",
        )
        return reachable

    def test_every_payload_field_is_one_the_verb_binds(self):
        """The producer held to the same contract as the binder and the agent.

        A field no row binds is dropped without a word: the command queues, the
        job goes green, and the value the operator typed into the dispatch box
        never reaches the script. Nothing fails, because nothing on the VM was
        ever told to expect it.

        This is the third layer. Pester asserts the binder turns a document into
        arguments; `test_command_queue` asserts the rows name scripts that exist;
        this asserts the documents the workflows actually send are ones the rows
        can read. Writing it needed the contract to state its whole surface
        first: until `backupRoot` was bound and the rest declared unreachable, a
        payload field the table did not mention was as likely to be a gap in the
        table as a typo in the workflow, and a check that cannot tell those apart
        is one somebody turns off.
        """
        agent = QUEUE_AGENT.read_text(encoding="utf-8")
        kinds = harness.command_binding_kinds(agent)
        checked = []

        for name in QUEUE_PRODUCERS:
            for job_name, step in self.queue_steps(name):
                payload = str((step.get("with") or {}).get("payload") or "")
                fields = re.findall(r'"([A-Za-z]\w*)"\s*:', payload)
                for verb in self.queue_verbs(name, step):
                    contract = harness.command_contract(agent, verb)
                    bound = {
                        field
                        for kind in kinds
                        for field in (contract.get(kind) or {})
                    }
                    for field in fields:
                        checked.append((name, job_name, verb, field))
                        self.assertIn(
                            field,
                            bound,
                            f"{name} job `{job_name}` sends `{field}` to `{verb}`, "
                            "which binds no such field. The value is dropped and "
                            "the run still goes green.",
                        )

        self.assertNotVacuous(checked, "no queued payload carries a field")


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

    def test_the_queue_name_is_checked_where_the_path_is_built(self):
        """Three workflows carried a copy of this regex in a `run:` step and the
        other three carried none, so half the producers could address a queue no
        agent watches. The check belongs to whoever builds the path."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("Assert-ValidQueueName -QueueName $env:VMQ_QUEUE", text)

        validate = text.index("Assert-ValidQueueName -QueueName $env:VMQ_QUEUE")
        prefix = text.index('$queuePrefix = "gs://')
        self.assertLess(validate, prefix, "the name is used to build a path before it is checked")

    def test_no_workflow_keeps_its_own_copy_of_the_check(self):
        """A leftover copy is how the two sides drift apart, and a copy is exactly
        what hid the case-insensitivity defect: five places agreed, so the pattern
        looked settled and nobody read the operator."""
        copies = [
            path.name
            for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml"))
            if "[a-z][a-z0-9-]{1,30}" in path.read_text()
        ]

        self.assertEqual(
            [],
            copies,
            "these workflows still validate the queue name themselves; "
            "queue-vm-command does it now: " + ", ".join(copies),
        )

    def test_the_producer_is_no_laxer_than_the_agent_that_reads_the_queue(self):
        """Two checks, one on each side of the bucket, and they are different
        claims: this one says the command was addressed correctly, the agent's says
        this VM was asked for work meant for it. Neither replaces the other, and a
        producer looser than its consumer queues commands that are accepted here
        and ignored there -- which fails as a timeout, not an error.

        Both use `-cnotmatch`. The default operator is case-insensitive, so a
        lowercase-only pattern accepted 'Commands', and GCS does not fold case.
        """
        producer = QUEUE_ACTION_SCRIPT.read_text()
        agent = (
            harness.REPO_ROOT / "Deployment" / "PrTestEnvironments"
            / "Invoke-PrEnvironmentCommandQueue.ps1"
        ).read_text()

        pattern = "-cnotmatch '^[a-z][a-z0-9-]{1,30}$'"
        self.assertIn(pattern, producer, "the producer does not check the queue name case-sensitively")
        self.assertIn(pattern, agent, "the agent does not check the queue name case-sensitively")

    def test_the_stale_result_is_cleared_before_the_command_is_queued(self):
        """Order is the whole of it. Clearing after the upload races the agent: the
        VM can pick the command up, finish, and write its result in the gap, and the
        clear then deletes the answer this run is waiting for. The wait would run to
        its ceiling and report a timeout for work that had already succeeded."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        clear = text.index("Clear-StaleResult -ResultUri")
        upload = text.index("gsutil cp command.json")

        self.assertLess(
            clear,
            upload,
            "Write-VmCommand.ps1 clears the stale result after uploading the "
            "command, which can delete a result the VM has already written",
        )

    def test_both_queue_paths_follow_the_queue_the_caller_named(self):
        """Two callers pass a queue other than `commands`. A hardcoded prefix puts
        the command where no agent is looking, and the wait that follows reports a
        timeout -- so it reads as a dead VM rather than a misaddressed command.

        Two paths hang off the queue now, pending and results, and clearing the
        result of the wrong queue is worse than writing to it: it would delete a
        live answer another run is waiting on. Both are built from one prefix, so
        this asserts the prefix carries the caller's queue and that neither path
        is spelled out again.
        """
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn('$queuePrefix = "gs://$($env:VMQ_BUCKET)/pr-environments/$($env:VMQ_QUEUE)"', text)
        self.assertIn('"$queuePrefix/pending/$($env:VMQ_COMMAND_ID).json"', text)
        self.assertIn('"$queuePrefix/results/$($env:VMQ_COMMAND_ID).json"', text)
        self.assertNotIn("/pr-environments/commands/", text)

    def test_a_failed_upload_is_an_error_rather_than_a_silent_success(self):
        """gsutil failing leaves no command on the queue. Without this the step is
        green, and the wait spends its full timeout on a command that was never
        queued."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("$LASTEXITCODE -ne 0", text)

    def test_the_script_returns_before_uploading_when_it_is_only_being_loaded(self):
        """Pester dot-sources this file to reach the functions. Without the guard
        the load would try to queue a command.

        The guard reads VMQ_INVOKED, a literal action.yml sets, and not VMQ_BUCKET,
        which the caller supplies. DotSourceGuardTests holds the general rule and
        explains what guarding on an input costs. This pins the specific variable
        so the two cannot drift."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("IsNullOrWhiteSpace($env:VMQ_INVOKED)", text)
        self.assertFalse(
            "IsNullOrWhiteSpace($env:VMQ_BUCKET)" in text,
            "the guard is back on an input the caller supplies. See "
            "DotSourceGuardTests for why that exits 0 on a blank bucket.",
        )

    def test_redaction_keys_on_the_shape_of_a_name_not_a_list_of_known_ones(self):
        """The defect this replaces was a literal `$key -eq 'connectionString'`.
        A list of known names cannot cover the field nobody has added yet, which
        is the only case where redaction has to work unprompted."""
        text = QUEUE_ACTION_SCRIPT.read_text()

        self.assertIn("connectionstring|password|secret|token|credential", text)
        self.assertNotIn("-eq 'connectionString'", text)


class RunActionTests(harness.HarnessAssertions, unittest.TestCase):
    """What a caller of run-vm-command is promised.

    A re-run must not read the previous attempt's answer. `github.run_id` holds
    still across a re-run and `github.run_attempt` counts up, so an id built from
    the run alone repeats. Nothing deletes a result object, and await-vm-command
    acts on the first `results/<id>.json` it can copy. Together that means a
    re-run whose id omits the attempt finds the last attempt's result on the first
    poll, reports it, and never notices the VM did no work. A failed deploy re-run
    reports the same failure. A fixed one reports success it did not earn.

    Each producer used to spell the attempt into its own COMMAND_ID, and a scan of
    every producer's text was what held it there. The action appends it now, so a
    caller supplies only the part that names it and cannot leave the attempt out.
    """

    # The suffix every id ends in, and the whole of what the action adds to the
    # caller's prefix. Runbooks and operators search for ids of this shape, so the
    # shape is the contract rather than a detail of how it is built.
    RUN_SUFFIX = "-${{ github.run_id }}-${{ github.run_attempt }}"

    def test_both_halves_and_the_output_carry_one_id(self):
        """The enqueue and the wait are given the same id, and it is the id the
        action reports. Three copies of one expression, so they are compared."""
        expected = "${{ inputs.command-id-prefix }}" + self.RUN_SUFFIX
        queue = _run_action_step(QUEUE_ACTION)
        wait = _run_action_step(AWAIT_ACTION)
        output = harness.composite_action("run-vm-command")["outputs"]["command-id"]

        self.assertEqual(expected, str((queue.get("with") or {}).get("command-id")))
        self.assertEqual(expected, str((wait.get("with") or {}).get("command-id")))
        self.assertEqual(expected, str(output.get("value")))

    def test_no_caller_puts_the_run_in_its_prefix(self):
        """The action appends the run and the attempt. A prefix that carries them
        too queues `deploy-1-2-1-2`, which no runbook search finds."""
        prefixes = []
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            for job_name, step in _run_calls(path.name):
                prefix = str((step.get("with") or {}).get("command-id-prefix", ""))
                prefixes.append(prefix)
                for context in ("github.run_id", "github.run_attempt"):
                    self.assertNotIn(
                        context,
                        prefix,
                        f"{path.name} job `{job_name}` puts `{context}` in its "
                        "prefix; the action appends it already.",
                    )
        self.assertNotVacuous(prefixes, "no workflow calls the run action")

    def test_every_input_of_either_half_is_forwarded_under_its_own_name(self):
        """One input per input of the halves, same name, same default.

        A default written in two files is two defaults, and the caller gets the
        outer one without being told. The 140-attempt ceiling is the one that
        matters: a mismatch here moves the timeout of every caller that leaves it
        out. Derived from the halves, so an input added to either is covered
        without editing this test, and fails until the run action forwards it.
        """
        own = harness.composite_action("run-vm-command")["inputs"]
        compared = []

        for half, uses in (("queue-vm-command", QUEUE_ACTION), ("await-vm-command", AWAIT_ACTION)):
            supplied = _run_action_step(uses).get("with") or {}
            for name, definition in harness.composite_action(half)["inputs"].items():
                if name == "command-id":
                    continue
                compared.append(f"{half}.{name}")
                self.assertIn(name, own, f"run-vm-command does not take `{name}` for {half}")
                self.assertEqual(
                    "${{ inputs." + name + " }}",
                    str(supplied.get(name)),
                    f"run-vm-command does not pass its own `{name}` to {half}",
                )
                self.assertEqual(
                    definition.get("default"),
                    own[name].get("default"),
                    f"{half} defaults `{name}` to {definition.get('default')!r} and "
                    f"run-vm-command to {own[name].get('default')!r}.",
                )

        self.assertNotVacuous(compared, "neither half declares an input")

    def test_the_wait_does_not_run_after_a_failed_enqueue(self):
        """Fail closed. A composite action skips the steps after a failure unless
        they ask to run, so a wait with no `if:` is skipped when the upload fails.
        One that ran anyway would poll for a command that was never queued and
        report the VM as unresponsive after its full ceiling."""
        steps = harness.action_steps(harness.composite_action("run-vm-command"))
        uses = [step.get("uses") or "" for step in steps]

        self.assertLess(uses.index(QUEUE_ACTION), uses.index(AWAIT_ACTION))
        self.assertNotIn("if", _run_action_step(AWAIT_ACTION))
        self.assertEqual(
            [],
            [step.get("name") for step in steps if "continue-on-error" in step],
            "a step that continues on error turns a failed command into a green job",
        )

    def summary_step(self):
        """The step that writes the VM log into the job summary."""
        for step in harness.action_steps(harness.composite_action("run-vm-command")):
            if "GITHUB_STEP_SUMMARY" in (step.get("run") or ""):
                return step
        self.fail("run-vm-command has no step that writes the job summary")

    def test_the_log_goes_in_the_summary_when_asked_including_on_failure(self):
        """Off unless asked, because a deploy's summary is its own. When asked, a
        failed command needs the log there more than a successful one does: for a
        scan or a dry run it is the finding, and for a failure it is the reason."""
        own = harness.composite_action("run-vm-command")["inputs"]
        condition = str(self.summary_step().get("if") or "")

        self.assertEqual("false", own["log-to-summary"]["default"])
        self.assertIn("always()", condition)
        self.assertIn("inputs.log-to-summary == 'true'", condition)
        self.assertIn("steps.await.outputs.log-path != ''", condition)

    def test_the_summary_carries_the_whole_log(self):
        """Whole, not a tail. The callers that ask are the ones whose log is the
        result -- a column list, a plan an approver signs off -- and a tail cuts
        off the part somebody has to act on. The agent redacts before uploading.

        The path arrives through `env:`; RunnerExpressionPlacementTests in
        test_powershell_job.py holds why an expression does not go in the body."""
        step = self.summary_step()
        run = step.get("run") or ""
        variables = [
            variable
            for variable, value in (step.get("env") or {}).items()
            if str(value) == "${{ steps.await.outputs.log-path }}"
        ]

        self.assertEqual(1, len(variables), "the log path does not arrive through env:")
        self.assertIn(f"Get-Content -LiteralPath $env:{variables[0]} -Raw", run)
        self.assertNotIn("-Tail", run)

    def test_a_job_behind_an_approval_follows_one_that_shows_its_plan(self):
        """An approver decides against the plan job's summary. Without the log in
        it, approving means opening the plan job's log and finding the command's
        output in the middle of the poll loop -- or approving without reading.

        Derived from the jobs: any job behind an `environment:` gate that needs a
        job running a command makes that command's log the thing approved."""
        checked = []
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            jobs = harness.workflow(path.name).get("jobs") or {}
            for gated_name, gated in jobs.items():
                if "environment" not in gated:
                    continue
                needs = gated.get("needs") or []
                for needed in [needs] if isinstance(needs, str) else needs:
                    for step in (jobs.get(needed) or {}).get("steps") or []:
                        if (step.get("uses") or "") != RUN_ACTION:
                            continue
                        checked.append(f"{path.name}:{needed}")
                        self.assertEqual(
                            "true",
                            str((step.get("with") or {}).get("log-to-summary")),
                            f"{path.name} job `{gated_name}` is approved against "
                            f"`{needed}`, whose command log stays out of the summary.",
                        )

        self.assertNotVacuous(checked, "no gated job follows a job that runs a command")


class DotSourceGuardTests(harness.HarnessAssertions, unittest.TestCase):
    """A script the tests dot-source is inert on load, and never inert on a real call.

    Both extracted scripts return early so that Pester can load their functions
    without running the body. The variable that guard reads decides what happens
    when a caller passes an input blank.

    Guarding on `$env:AWAIT_BUCKET` reads a caller-supplied value as "this is a
    test". A workflow that resolves `bucket` to an empty string then gets a step
    that exits 0 without polling, which the job reads as the VM command having
    succeeded. That is the silent-green failure this pipeline keeps paying for,
    reached through the input the action declares `required: true`.

    So the guard reads a marker the action sets to a literal, and a blank input
    falls through to a real error. This test holds the two apart by checking that
    the guard variable's value in action.yml contains no `inputs.` expression."""

    SCRIPTS = (
        ("await-vm-command", AWAIT_ACTION_SCRIPT),
        ("queue-vm-command", QUEUE_ACTION_SCRIPT),
    )

    GUARD = re.compile(
        r"if \(\[string\]::IsNullOrWhiteSpace\(\$env:(\w+)\)\)\s*\{\s*return\s*\}",
        re.S,
    )

    def _step_env(self, action):
        """The `env:` mapping of the step that runs the extracted script."""
        for step in harness.action_steps(harness.composite_action(action)):
            if ".ps1" in (step.get("run") or ""):
                return step.get("env") or {}
        self.fail(f"{action} has no step that runs a .ps1")

    def test_every_extracted_script_has_a_guard(self):
        for _, script in self.SCRIPTS:
            with self.subTest(script=script.name):
                found = self.GUARD.findall(script.read_text())
                self.assertEqual(
                    1,
                    len(found),
                    f"{script.name} needs exactly one early-return guard so Pester "
                    "can dot-source it without running the body.",
                )

    def test_the_guard_does_not_read_an_input_the_caller_supplies(self):
        for action, script in self.SCRIPTS:
            with self.subTest(script=script.name):
                variable = self.GUARD.findall(script.read_text())[0]
                declared = self._step_env(action)

                self.assertIn(
                    variable,
                    declared,
                    f"{script.name} guards on $env:{variable}, which "
                    f"{action}/action.yml never sets. The script is inert on every "
                    "real invocation.",
                )

                self.assertNotIn(
                    "inputs.",
                    str(declared[variable]),
                    f"{script.name} guards on $env:{variable}, and "
                    f"{action}/action.yml fills it from an input: "
                    f"{declared[variable]!r}. A caller who resolves that input to an "
                    "empty string gets a step that exits 0 having done nothing, "
                    "which the job reads as success. Guard on a literal marker and "
                    "let the blank input fail on its own.",
                )


class SecretsContextTests(harness.HarnessAssertions, unittest.TestCase):
    """No composite action may name the `secrets` context, anywhere in its file.

    A composite action cannot read `secrets`. GitHub exposes `inputs`, `env`,
    `github`, `runner`, `job`, `steps`, `strategy` and `matrix` to one, and
    nothing else. Referencing `secrets` is not an empty value at runtime -- it
    fails template validation while the action is being loaded, so every step
    the action would have run is skipped and the job dies at the `uses:` line.

    The trap is that the parser does not care which field the expression sits
    in. `gcp-session` took its key through an input, correctly, and then said so
    in the input's own `description`:

        description: The service account key. Pass `${{ secrets.GCP_SA_KEY }}`; ...

    That is documentation. It reads as a worked example of the right call, and
    it is the reason the action could not load. GitHub evaluated the expression
    in the description text and rejected the file at line 22, column 18, before
    reaching a single step. Nine workflows use this action. All nine were dead
    at their authentication step, each reporting a Google Cloud failure that had
    nothing to do with Google Cloud.

    A YAML parse cannot see this. `yaml.safe_load` reads that description as an
    ordinary string and returns a valid document, which is why the tests around
    it stayed green. The check has to run over the raw text.
    """

    # Any expression naming the secrets context, in any field. The `[^}]*` is
    # deliberate: `${{ inputs.x || secrets.Y }}` is the same failure as a bare
    # reference, and an anchored match on the opening brace would miss it.
    SECRETS_EXPRESSION = re.compile(r"\$\{\{[^}]*\bsecrets\.", re.IGNORECASE)

    def test_no_composite_action_references_the_secrets_context(self):
        names = harness.composite_actions()
        self.assertNotVacuous(names, "no composite actions found to check")

        offenders = []
        for name in names:
            text = (ACTIONS_DIR / name / "action.yml").read_text(encoding="utf-8")
            for match in self.SECRETS_EXPRESSION.finditer(text):
                line = harness.line_of(text, match.start())
                offenders.append(f"{name}/action.yml:{line}")

        self.assertEqual(
            [],
            offenders,
            "A composite action cannot read `secrets`; the reference fails template "
            "validation and the action never loads. Take the value as an input and "
            "let the calling workflow pass the secret. To show the call in a "
            "description, write it without the expression braces.",
        )

    def test_an_action_taking_a_secret_declares_it_as_a_required_input(self):
        """The other half of the same rule. Moving a secret to an input is only
        safe if the input is mandatory -- an optional one authenticates as the
        runner's own identity and fails later, against the wrong principal."""
        credentials = harness.composite_action("gcp-session")["inputs"]["credentials-json"]

        self.assertIs(True, credentials["required"])


if __name__ == "__main__":
    unittest.main()
