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
command-queue wait into one action, which took the number of local action
references from two to eight. This module is what makes that safe to keep doing.
"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pipeline_harness as harness

ACTIONS_DIR = harness.REPO_ROOT / ".github" / "actions"

AWAIT_ACTION = "./.github/actions/await-vm-command"
AWAIT_ACTION_FILE = ACTIONS_DIR / "await-vm-command" / "action.yml"

# Every workflow that queues a command onto the VM and waits for the answer. The
# wait is one action for all of them; see the action's own header for why the
# enqueue is not.
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


class LocalActionCheckoutTests(unittest.TestCase, harness.HarnessAssertions):
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
                covered = any(
                    _sparse_paths(checkout) is None
                    or any(uses[2:].startswith(entry) for entry in _sparse_paths(checkout))
                    for checkout in checkouts
                )
                self.assertTrue(
                    covered,
                    f"{path.name} job `{job_name}` uses `{uses}`, and every checkout "
                    "before it is sparse without including that path. The checkout "
                    "succeeds and the action is still missing.",
                )

        self.assertNotVacuous(
            references, "no workflow references a local action, so this checked nothing"
        )

    def test_every_referenced_local_action_exists(self):
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            for job_name, index, uses in _local_action_references(harness.workflow(path.name)):
                action = harness.REPO_ROOT / uses[2:] / "action.yml"
                self.assertTrue(
                    action.exists(),
                    f"{path.name} job `{job_name}` uses `{uses}`, which has no action.yml",
                )


class AwaitActionAdoptionTests(unittest.TestCase, harness.HarnessAssertions):
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
                    inline_poll = "Start-Sleep" in run and "result.json" in run
                    self.assertFalse(
                        inline_poll,
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
