import json
import shutil
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"
STATUS_SCRIPT = REPO_ROOT / ".github" / "scripts" / "pr-test-status.js"

# How a step spells the module it requires, and how a checkout names it: relative
# to the workspace, which is where both resolve it.
STATUS_MODULE = STATUS_SCRIPT.relative_to(REPO_ROOT).as_posix()


class LabelTriggeredDeployWorkflowTests(unittest.TestCase):
    def test_workflow_is_label_triggered_and_refuses_forks_before_building(self):
        text = WORKFLOW_PATH.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("pull_request_target", workflow["on"])
        self.assertIn("labeled", workflow["on"]["pull_request_target"]["types"])
        self.assertIn("rock:start", text)
        self.assertIn("head.repo.full_name !== context.payload.repository.full_name", text)
        self.assertIn("Skipping forked PR", text)

    def test_workflow_builds_artifact_then_queues_deploy_command(self):
        text = WORKFLOW_PATH.read_text()

        self.assertIn("./.github/workflows/pr-test-artifact.yml", text)
        self.assertIn("secrets: inherit", text)
        # Queueing the command is `.github/actions/queue-vm-command` now, reached
        # through run-vm-command. Where it writes, and that the echo redacts, are
        # asserted once in
        # test_local_composite_actions.py instead of once per producer -- which is
        # how two of the six came to redact a field name the third does not use.
        # The wait itself is .github/actions/await-vm-command now, called by the
        # same action, and its behaviour is asserted once in
        # test_local_composite_actions.py rather
        # than once per producer. What stays here is what this workflow chooses.
        self.assertIn("attempts: '120'", text)
        self.assertIn("artifactGcsPath", text)
        self.assertIn("staging.connect.passion.team", text)
        self.assertNotIn("sshpass", text)

def _status_script_step(job):
    """The step in `job` that loads pr-test-status.js, and its index among the steps."""
    steps = harness.steps(harness.workflow(WORKFLOW_PATH.name), job=job)
    for index, step in enumerate(steps):
        if STATUS_MODULE in ((step.get("with") or {}).get("script") or ""):
            return index, step
    raise AssertionError(f"no step in the {job} job loads {STATUS_MODULE}")


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class StateTransitionTests(unittest.TestCase):
    """Each job that moves a pull request to its next state does it through
    `reconcilePrTestLabels`, so every transition leaves exactly one state label.

    These run each job's own `script:` body under node against a pull request that
    holds a stale `rock:stopped` -- which is what a stop finishing partway through a
    deploy leaves. The two middle jobs used to carry their own shorter label lists,
    and neither list named `rock:stopped`, so the pull request came out showing two
    states at once. Running the body is what catches that; the test this replaced
    checked that five label names appeared somewhere in the file."""

    def run_job(self, job, held, **kwargs):
        _, step = _status_script_step(job)
        return harness.run_github_script(step["with"]["script"], labels={42: held}, **kwargs)

    def test_mark_building_leaves_building_as_the_only_state(self):
        result = self.run_job(
            "mark-building",
            ["rock:queued", "rock:stopped", "rock:auto"],
            expressions={"needs.prepare.outputs.pr_number": "42"},
        )

        self.assertEqual(["rock:auto", "rock:building"], result["labels"][42])

    def test_mark_deploying_leaves_deploying_as_the_only_state(self):
        result = self.run_job(
            "mark-deploying",
            ["rock:building", "rock:stopped", "rock:auto"],
            expressions={"needs.prepare.outputs.pr_number": "42"},
        )

        self.assertEqual(["rock:auto", "rock:deploying"], result["labels"][42])

    def test_a_start_command_clears_itself_and_queues_the_pull_request(self):
        """`rock:start` is a command, not a state, so the module does not own it; the
        prepare job clears it so the next `rock:start` is a fresh `labeled` event.

        The base branch here is a stand-in. The gate compares the pull request's
        base with the config's, so any matching pair takes the path under test."""
        pull = {
            "number": 42,
            "labels": [{"name": "rock:start"}, {"name": "rock:deployed"}, {"name": "rock:auto"}],
            "base": {"ref": "trunk"},
            "head": {"sha": "0123abc", "repo": {"full_name": "passiondev/Rock"}},
        }
        result = self.run_job(
            "prepare",
            ["rock:start", "rock:deployed", "rock:auto"],
            context={
                "eventName": "pull_request_target",
                "payload": {
                    "action": "labeled",
                    "label": {"name": "rock:start"},
                    "pull_request": pull,
                    "repository": {"full_name": "passiondev/Rock", "default_branch": "trunk"},
                },
            },
            files={
                ".github/pr-test-environments.json": json.dumps(
                    {"baseBranch": "trunk", "environmentDomain": "staging.connect.passion.team"}
                )
            },
        )

        self.assertIsNone(result["failed"])
        self.assertEqual("true", result["outputs"].get("should_deploy"))
        self.assertEqual(["rock:auto", "rock:queued"], result["labels"][42])


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class OneCopyOfTheStateLabelsTests(unittest.TestCase):
    def test_no_job_restates_a_state_label_the_module_owns(self):
        """The module owns the list. A copy in a job is how the middle transitions
        came to miss `rock:stopped`: a list that is right the day it is written,
        and stays right only until a state is added to the module.

        The labels come from the module itself, so adding a state there widens
        this check without anybody editing it. `pr-test-destroy-all.yml` is held
        to the same rule in test_destroy_all.py."""
        body = f"core.setOutput('labels', JSON.stringify(require('./{STATUS_MODULE}').STATE_LABELS));"
        state_labels = json.loads(harness.run_github_script(body, labels={})["outputs"]["labels"])
        self.assertTrue(state_labels, "pr-test-status.js exported no state labels, so this checks nothing")

        workflow = harness.workflow(WORKFLOW_PATH.name)
        bodies = [
            (job, step.get("name", "(unnamed step)"), (step.get("with") or {}).get("script") or "")
            for job in workflow["jobs"]
            for step in harness.steps(workflow, job=job)
        ]
        restated = [
            f"{job} :: {name} :: {label}"
            for job, name, body in bodies
            for label in state_labels
            if f"'{label}'" in body
        ]

        self.assertEqual(
            [],
            restated,
            "these steps name a state label themselves instead of passing a status "
            "to reconcilePrTestLabels, which puts a second copy of the list back",
        )


class StatusModuleCheckoutTests(unittest.TestCase):
    """`require` reads the module from the workspace, so each job that loads it
    checks it out first -- and checks out the right commit.

    This workflow runs on `pull_request_target` with a token that can write to the
    pull request. A checkout with no `ref` takes the base branch's commit, the same
    trusted commit the workflow file itself came from, and under
    `workflow_dispatch` the dispatched ref, which again is where the workflow came
    from. A `ref` or `repository` here would be the one way to hand that token to
    JavaScript the pull request wrote. The build reads the PR head deliberately,
    but in pr-test-artifact.yml, which runs no `require` of this module."""

    JOBS = ("prepare", "mark-building", "mark-deploying", "finalize")

    def test_each_job_checks_out_the_module_from_trusted_code_before_loading_it(self):
        for job in self.JOBS:
            with self.subTest(job=job):
                steps = harness.steps(harness.workflow(WORKFLOW_PATH.name), job=job)
                script_at, _ = _status_script_step(job)
                checkouts = [
                    (index, step.get("with") or {})
                    for index, step in enumerate(steps)
                    if (step.get("uses") or "").startswith("actions/checkout@")
                ]
                self.assertEqual(1, len(checkouts), f"{job} should check out exactly once")
                checkout_at, checkout = checkouts[0]

                self.assertLess(checkout_at, script_at, f"{job} loads the module before checking it out")
                self.assertIn(STATUS_MODULE, (checkout.get("sparse-checkout") or "").split())
                self.assertNotIn("ref", checkout, f"{job} checks out a ref other than the trusted one")
                self.assertNotIn("repository", checkout, f"{job} checks out another repository")


if __name__ == "__main__":
    unittest.main()
