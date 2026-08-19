"""`Invoke-PrEnvironmentCleanup.ps1` exists, is tested, and never runs.

This is a tripwire, not a guard. It does not assert that the cleanup *should* stay
unscheduled -- open item 6 wants it scheduled. It asserts that the documents which
currently tell operators "nothing reaps on a timer" are still telling the truth.

The claim has been wrong before in the other direction. Three documents stated the
6-hour idle stop and 7-day destroy as active policy while nothing invoked the script:
the training handout, the operator runbook, and the issue that specified the work,
which had every acceptance criterion ticked under the title "Add scheduled idle
cleanup" without one of them being "it is scheduled". Whoever finally wires it up will
be changing behaviour on shared infrastructure, and the cost of them not knowing which
pages contradict them is a fleet that starts deleting environments while the runbook
says it cannot.

So: add a trigger and this fails, with the list of files to update in the message.
"""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
DEPLOY_DIR = REPO_ROOT / "Deployment" / "PrTestEnvironments"

CLEANUP_SCRIPT = "Invoke-PrEnvironmentCleanup.ps1"

# Every document that currently tells a reader the reaping does not happen. If the
# cleanup is ever scheduled, each of these is wrong the moment it starts running.
DOCUMENTS_THAT_PROMISE_IT_DOES_NOT_RUN = [
    REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md",
    REPO_ROOT / "Documentation" / "Training" / "DevOps-Open-Items-Rock-CICD.md",
    REPO_ROOT / "Documentation" / "Training" / "rock-cicd-cheat-sheet.html",
    REPO_ROOT / "Documentation" / "Discussion Docs" / "PR-Test-Environments-Issues"
    / "08-scheduled-idle-cleanup.md",
]

TASK_INSTALLER = re.compile(r"Register-ScheduledTask|schtasks(?:\.exe)?\b")


def _workflows_scheduling_cleanup():
    """Workflow files that both run on a schedule and mention the cleanup script."""
    scheduled = []
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        text = workflow.read_text()
        if re.search(r"^\s*schedule:", text, re.M) and CLEANUP_SCRIPT in text:
            scheduled.append(workflow.name)
    return scheduled


def _scripts_installing_cleanup_as_a_task():
    """Deploy scripts that register a Windows scheduled task naming the cleanup."""
    installers = []
    for script in sorted(DEPLOY_DIR.glob("*.ps1")):
        text = script.read_text()
        if TASK_INSTALLER.search(text) and CLEANUP_SCRIPT in text:
            installers.append(script.name)
    return installers


class NothingInvokesTheCleanupOnATimerTests(unittest.TestCase):
    def test_the_pieces_this_test_watches_still_exist(self):
        """If the script is renamed or moved, every check below passes by looking at
        nothing at all."""
        self.assertTrue((DEPLOY_DIR / CLEANUP_SCRIPT).is_file(), f"{CLEANUP_SCRIPT} has moved")
        self.assertTrue(list(WORKFLOW_DIR.glob("*.yml")), "no workflows found")
        for document in DOCUMENTS_THAT_PROMISE_IT_DOES_NOT_RUN:
            self.assertTrue(document.is_file(), f"{document} has moved; update this test's list")

    def test_no_scheduled_workflow_runs_the_cleanup(self):
        scheduled = _workflows_scheduling_cleanup()

        self.assertEqual(
            [],
            scheduled,
            f"{scheduled} now runs {CLEANUP_SCRIPT} on a schedule. That is open item 6 being "
            "closed, which is good -- but these documents say it does not happen and are now "
            "wrong:\n"
            + "\n".join(f"  {d.relative_to(REPO_ROOT)}" for d in DOCUMENTS_THAT_PROMISE_IT_DOES_NOT_RUN),
        )

    def test_no_deploy_script_installs_the_cleanup_as_a_windows_task(self):
        installers = _scripts_installing_cleanup_as_a_task()

        self.assertEqual(
            [],
            installers,
            f"{installers} now installs {CLEANUP_SCRIPT} as a scheduled task. Update the "
            "documents listed in this module's docstring before merging.",
        )

    def test_the_only_task_the_vm_installs_is_the_command_queue(self):
        """The reason the cleanup looks wired up is that the bootstrap copies it to the
        VM alongside nine other scripts. Pinning what is actually installed keeps that
        distinction visible."""
        installers = [s.name for s in sorted(DEPLOY_DIR.glob("*.ps1")) if TASK_INSTALLER.search(s.read_text())]

        self.assertEqual(
            ["Install-PrEnvironmentCommandQueueTask.ps1"],
            installers,
            "a deploy script other than the command-queue installer now registers a Windows "
            "scheduled task; check whether the runbook still describes the VM correctly",
        )


if __name__ == "__main__":
    unittest.main()
