"""The queue the VMs poll, and the table the agent answers it from."""

import unittest

import yaml

import pipeline_harness as harness

REPO_ROOT = harness.REPO_ROOT
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
BOOTSTRAP_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Install-PrEnvironmentCommandQueueTask.ps1"
DEPLOY_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"
LIFECYCLE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-lifecycle.yml"


def _queued_verbs():
    """Every verb any workflow puts on a VM queue, and the file it came from.

    Derived rather than listed. A hand-kept list of producers is the shape this
    whole area kept failing in: the v19 cutover carried a script and its runbook
    forward and left the bootstrap, the command and the workflow behind, and every
    test stayed green because nothing was deriving the set.

    Producers are found by the action they call, so renaming a step changes
    nothing. A command given as an expression is resolved through the workflow's
    own `choice` input -- which is where pr-test-lifecycle.yml's two verbs are
    declared -- and an expression that resolves to nothing is reported rather than
    dropped, because dropping it is how a producer stops being watched.
    """
    found = {}
    unresolved = []

    for path in sorted(WORKFLOW_DIR.glob("*.yml")):
        parsed = yaml.safe_load(path.read_text())
        if not isinstance(parsed, dict):
            continue

        choices = {}
        for trigger in (parsed.get(True) or parsed.get("on") or {}).values():
            if not isinstance(trigger, dict):
                continue
            declared = (trigger.get("inputs") or {}).get("command") or {}
            if declared.get("type") == "choice":
                for option in declared.get("options") or []:
                    choices[str(option)] = True

        for job in (parsed.get("jobs") or {}).values():
            for step in job.get("steps") or []:
                if not str(step.get("uses", "")).endswith("run-vm-command"):
                    continue

                command = str((step.get("with") or {}).get("command", ""))
                if "${{" not in command:
                    found.setdefault(command, path.name)
                    continue

                if not choices:
                    unresolved.append(f"{path.name}: {command}")
                for option in choices:
                    found.setdefault(option, path.name)

    return found, unresolved


class ContractTableTests(harness.HarnessAssertions, unittest.TestCase):
    """What the producers ask for and what the agent answers to, compared.

    Both halves used to be lists somebody kept: a switch arm per verb in the agent,
    a `command:` per producer in the workflows, and nothing between them. A verb
    queued without an arm came back "Unknown command" after the poll, which reads
    like a queue fault rather than a missing feature; an arm with no producer was
    dead code nobody could tell from live code.
    """

    def test_every_verb_a_workflow_queues_is_a_verb_the_agent_has_a_row_for(self):
        self.assertNotVacuous(
            sorted(WORKFLOW_DIR.glob("*.yml")), "no workflows were found to read"
        )

        queued, unresolved = _queued_verbs()
        self.assertEqual(
            [], unresolved, "these queue a command this cannot resolve: " + ", ".join(unresolved)
        )
        self.assertNotVacuous(queued, "no workflow queues a command, so this compares nothing")

        rows = harness.command_contract_verbs(QUEUE_SCRIPT.read_text())

        self.assertEqual(
            sorted(queued),
            sorted(rows),
            "the producers and the contract table disagree; queued without a row "
            f"{sorted(set(queued) - set(rows))}, a row nothing queues "
            f"{sorted(set(rows) - set(queued))}",
        )

    def test_every_row_names_a_script_the_bootstrap_publishes(self):
        """A row naming a script that never reaches the VM fails minutes later with
        'file not found', after the queue round trip and the operator's wait.

        Both directories, because the bootstrap copies them into one directory on the
        box: the row names a bare file name and the agent joins it onto $DeployRoot."""
        published = [
            REPO_ROOT / "Deployment" / "PrTestEnvironments",
            REPO_ROOT / "Deployment" / "Database",
        ]
        text = QUEUE_SCRIPT.read_text()

        missing = []
        for verb in harness.command_contract_verbs(text):
            script = harness.command_contract(text, verb).get("Script")
            if not script:
                missing.append(f"{verb} names no script")
            elif not any((directory / script).exists() for directory in published):
                missing.append(f"{verb} names {script}, which is in neither directory")

        self.assertEqual([], missing, "; ".join(missing))


class CommandQueueTests(unittest.TestCase):
    def test_the_agent_never_reaches_the_vm_over_ssh_or_restarts_it(self):
        """The two absences are all this keeps. It used to match a dozen strings that
        said the agent pulls from GCS and runs local scripts, and every one of them is
        now held by something that runs it: the queue prefixes by
        test_environment_deploy.py, the scripts each verb runs by the contract tests
        above, and the result's shape by Pester/CommandQueuePass.Tests.ps1, which reads
        what the poll pass writes back through the reader the workflow uses. An absence
        is the one claim nothing executes."""
        text = QUEUE_SCRIPT.read_text()
        self.assertNotIn("ssh", text.lower())
        self.assertNotIn("Restart-Computer", text)

    def test_bootstrap_installs_windows_scheduled_task_for_queue_processor(self):
        text = BOOTSTRAP_SCRIPT.read_text()
        for expected in ["schtasks.exe", "/SC MINUTE", "/RU SYSTEM", "Invoke-PrEnvironmentCommandQueue.ps1", "C:\\RockDeploy"]:
            self.assertIn(expected, text)

    def test_workflows_upload_commands_and_poll_results_without_ssh(self):
        for path in [DEPLOY_WORKFLOW, LIFECYCLE_WORKFLOW]:
            text = path.read_text()
            self.assertIn("./.github/actions/run-vm-command", text)
            self.assertNotIn("sshpass", text)
            self.assertNotIn("Deploy over SSH", text)

            # Both halves of the queue protocol moved into shared actions,
            # queue-vm-command and await-vm-command, and run-vm-command calls the
            # pair. test_local_composite_actions.py asserts every producer goes
            # through it and that none kept a private copy, which is a stronger
            # claim than the strings this used to match. What is left here is the
            # property the class is named for: no SSH.

if __name__ == "__main__":
    unittest.main()
