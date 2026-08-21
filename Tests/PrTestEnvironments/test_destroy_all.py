import pathlib
import re
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DESTROY_ALL_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-destroy-all.yml"
LIFECYCLE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-lifecycle.yml"
STATUS_SCRIPT = REPO_ROOT / ".github" / "scripts" / "pr-test-status.js"

CONFIRMATION_PHRASE = "destroy all pr environments"


def _workflow():
    return yaml.safe_load(DESTROY_ALL_WORKFLOW.read_text())


def _triggers(workflow):
    """PyYAML resolves a bare `on:` key to the boolean True (YAML 1.1), so a
    workflow that quotes it and one that does not parse to different keys for
    the same file. Accept either rather than depending on the quoting style."""
    return workflow.get("on", workflow.get(True))


def _all_run_scripts(workflow):
    scripts = []
    for job in workflow.get("jobs", {}).values():
        for step in job.get("steps", []):
            scripts.append(step.get("run", ""))
            scripts.append(step.get("with", {}).get("script", ""))
    return "\n".join(scripts)


def _state_labels_from_status_script():
    """Read the labels out of the module that writes them instead of restating
    them here. If the two lists were maintained separately, adding a state to
    pr-test-status.js would silently make destroy-all blind to environments in
    that state -- and the failure would look like 'the button missed some'."""
    source = STATUS_SCRIPT.read_text()
    block = re.search(r"const STATE_LABELS = \[(.*?)\]", source, re.DOTALL)
    assert block, "pr-test-status.js no longer declares STATE_LABELS"
    return re.findall(r"'([^']+)'", block.group(1))


class DestroyAllTriggerTests(unittest.TestCase):
    """The button exists for one job: after the trunk cutover, the PR environments
    built against the retired branch are stranded. The deploy gate now refuses
    them, so they will never be redeployed or refreshed, but their IIS sites and
    files stay on the VM until something removes them."""

    def setUp(self):
        self.assertTrue(
            DESTROY_ALL_WORKFLOW.exists(),
            "there is no pr-test-destroy-all.yml; the old fleet has to be torn down "
            "by hand, one label at a time",
        )
        self.workflow = _workflow()

    def test_it_can_only_be_started_by_a_person(self):
        """Nothing about this should ever fire on its own. A schedule or a branch
        push trigger on a workflow that destroys every environment is a way to lose
        the whole fleet to a merge."""
        triggers = _triggers(self.workflow)

        self.assertEqual(
            list(triggers),
            ["workflow_dispatch"],
            f"destroy-all has a trigger other than manual dispatch: {list(triggers)}",
        )

    def test_it_requires_the_operator_to_type_a_confirmation(self):
        """A dropdown or a checkbox is one misclick. Typing the phrase means the
        operator read what the button does."""
        inputs = _triggers(self.workflow)["workflow_dispatch"]["inputs"]

        self.assertIn("confirm", inputs, "destroy-all has no typed confirmation input")
        self.assertTrue(
            inputs["confirm"].get("required"),
            "the confirmation input is optional, so it can be left blank",
        )
        self.assertIn(
            CONFIRMATION_PHRASE,
            _all_run_scripts(self.workflow),
            f"nothing checks the confirmation against {CONFIRMATION_PHRASE!r}, so any "
            f"text passes",
        )

    def test_it_is_a_dry_run_unless_apply_is_ticked(self):
        """The first run should always answer 'what would this remove'. The
        enumeration is the part most likely to be wrong -- it reads labels, and
        labels drift -- so the operator gets to read the list before it acts."""
        inputs = _triggers(self.workflow)["workflow_dispatch"]["inputs"]

        self.assertIn("apply", inputs, "destroy-all has no apply toggle; it always acts")
        self.assertIs(
            inputs["apply"].get("default"),
            False,
            "the apply toggle does not default to off, so the safe path is not the "
            "default path",
        )

        destroy_job = self.workflow["jobs"]["destroy"]
        self.assertIn(
            "apply",
            str(destroy_job.get("if", "")),
            "the destroy job does not test the apply toggle, so a dry run would still "
            "queue commands",
        )

    def test_it_accepts_an_explicit_list_of_pull_requests(self):
        """Label-based enumeration is a best effort. When it misses one -- or catches
        one it should not -- the operator needs a way to name the PRs directly rather
        than fight the labels."""
        inputs = _triggers(self.workflow)["workflow_dispatch"]["inputs"]

        self.assertIn("pr_numbers", inputs, "destroy-all cannot be pointed at specific PRs")
        self.assertFalse(
            inputs["pr_numbers"].get("required"),
            "the explicit PR list is required, which defeats the enumeration path",
        )


class DestroyAllEnumerationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(DESTROY_ALL_WORKFLOW.exists())
        self.workflow = _workflow()
        self.scripts = _all_run_scripts(self.workflow)

    def test_it_reads_the_state_labels_from_the_module_that_writes_them(self):
        """`destroyed` maps to no label at all in pr-test-status.js, which is what
        makes the remaining labels usable as 'this PR may still have a site on the
        box'. Missing one state would leave those environments behind -- and a second
        hand-maintained copy of the list is exactly how one goes missing, because
        adding a state is a change to the writer and nobody thinks about the reader."""
        exports = STATUS_SCRIPT.read_text().split("module.exports")[1]
        self.assertIn(
            "STATE_LABELS",
            exports,
            "pr-test-status.js does not export STATE_LABELS, so the list cannot be "
            "shared and has to be duplicated",
        )
        self.assertIn(
            "pr-test-status.js",
            self.scripts,
            "the teardown does not load the module that owns the state labels",
        )
        self.assertIn("STATE_LABELS", self.scripts, "the teardown does not use the shared label list")

        for label in _state_labels_from_status_script():
            self.assertNotIn(
                f"'{label}'",
                self.scripts,
                f"the teardown restates {label!r} instead of using the shared list, "
                f"which puts the two copies back out of step",
            )

    def test_it_says_out_loud_that_the_vm_is_the_real_source_of_truth(self):
        """This is the honest limit of the whole approach. The list comes from GitHub
        labels; the environments live in C:\\RockTestEnvs. A site whose PR was deleted,
        or whose label was cleared by a half-failed run, is invisible here and has to
        be removed on the box. An operator who does not know that will read a clean
        run as an empty VM.

        Unescaped first: the path sits inside a JS string literal, so the source
        carries a doubled backslash while the operator reads a single one. Asserting
        on the source spelling would be a test about escaping, not about the warning
        actually reaching anybody."""
        rendered = self.scripts.replace("\\\\", "\\")

        self.assertTrue(
            "C:\\RockTestEnvs" in rendered,
            "the teardown never mentions the directory that actually holds the "
            "environments, so its blind spot is undocumented at the point of use",
        )


class DestroyAllQueueTests(unittest.TestCase):
    """The VM agent runs whatever copy of itself was installed at bootstrap; there is
    no self-update path. So this workflow cannot introduce a new command type -- a
    `destroy-all` verb would sit in the queue unrecognised until somebody re-runs the
    bootstrap, which is exactly the dependency this work is avoiding. It queues the
    `destroy` the agent already understands, once per PR."""

    def setUp(self):
        self.assertTrue(DESTROY_ALL_WORKFLOW.exists())
        self.workflow = _workflow()
        self.scripts = _all_run_scripts(self.workflow)

    def test_it_queues_the_command_type_the_agent_already_understands(self):
        # Where the command lands is `.github/actions/queue-vm-command`, asserted
        # once in test_local_composite_actions.py. The verb is still this
        # workflow's own decision, so it stays here -- it is read out of the
        # action call rather than out of a line of PowerShell.
        verbs = {
            str((step.get("with") or {}).get("command") or "").strip()
            for job in (self.workflow.get("jobs") or {}).values()
            for step in (job.get("steps") or [])
            if (step.get("uses") or "") == "./.github/actions/queue-vm-command"
        }

        # Assert the verb positively rather than banning a substring: the workflow's
        # own file name and command ids reasonably contain the words "destroy all",
        # and a test that forbids the string would be satisfied by renaming rather
        # than by queueing the right thing.
        self.assertEqual(
            verbs,
            {"destroy"},
            f"the teardown queues {sorted(verbs)}; the agent on the VM runs the copy of "
            f"itself installed at bootstrap and only knows the verbs it shipped with, "
            f"so anything else sits in the queue unrecognised",
        )

    def test_one_environment_failing_does_not_strand_the_others(self):
        """Half a teardown is the worst outcome -- the operator believes the fleet is
        gone and the remainder keeps holding disk. Every PR gets its attempt."""
        strategy = self.workflow["jobs"]["destroy"].get("strategy", {})

        self.assertIs(
            strategy.get("fail-fast"),
            False,
            "the destroy matrix stops at the first failure, leaving the rest of the "
            "fleet in place",
        )


if __name__ == "__main__":
    unittest.main()
