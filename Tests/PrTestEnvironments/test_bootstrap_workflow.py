import pathlib
import re
import unittest

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"

class BootstrapCommandQueueWorkflowTests(unittest.TestCase):
    def test_bootstrap_workflow_uses_gcp_metadata_startup_script_not_manual_ssh(self):
        text = WORKFLOW.read_text()
        workflow = yaml.safe_load(text)

        self.assertIn("workflow_dispatch", workflow["on"])
        self.assertIn("google-github-actions/auth@v2", text)
        self.assertIn("gsutil -m cp Deployment/PrTestEnvironments/*.ps1", text)
        self.assertIn("gcloud compute instances list", text)
        self.assertIn("GCP_VM_EXTERNAL_IP", text)
        self.assertIn("gcloud compute instances add-metadata", text)
        self.assertIn("windows-startup-script-ps1", text)
        self.assertIn("gcloud compute instances stop", text)
        self.assertIn("gcloud compute instances set-service-account", text)
        self.assertIn("https://www.googleapis.com/auth/cloud-platform", text)
        self.assertIn("gcloud compute instances start", text)
        self.assertIn("Install-PrEnvironmentCommandQueueTask.ps1", text)
        self.assertIn("Invoke-PrEnvironmentCommandQueue.ps1", text)
        self.assertIn("PR_TEST_GCS_BUCKET", text)
        self.assertIn("rock-pr-env-{0}-{1}", text)
        self.assertNotIn("sshpass", text)
        self.assertNotIn("scp ", text)


class BootstrapPublishesEveryScriptDirectoryTests(unittest.TestCase):
    """Whatever reaches gs://.../bootstrap/latest/ is what reaches the VM. A script that
    is not published there does not exist as far as the box is concerned, however
    correct it is in the repository.

    Deployment/Database spent its whole life in exactly that state. The operator runbook
    said to run Find-LegacyTextColumns.ps1 on the VM before a v19 cutover and nothing had
    ever put it there, because both publishers named PrTestEnvironments and only
    PrTestEnvironments."""

    PUBLISHERS = [
        REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml",
        REPO_ROOT / ".github" / "workflows" / "pr-test-renew-certificates.yml",
    ]

    SCRIPT_DIRS = ["Deployment/PrTestEnvironments", "Deployment/Database"]

    def test_every_publisher_uploads_every_script_directory(self):
        for workflow in self.PUBLISHERS:
            text = workflow.read_text()
            upload = [ln for ln in text.splitlines()
                      if "gsutil" in ln and "bootstrap/latest" in ln]
            self.assertTrue(upload, f"{workflow.name} no longer publishes to bootstrap/latest")

            for line in upload:
                for directory in self.SCRIPT_DIRS:
                    self.assertIn(
                        f"{directory}/*.ps1",
                        line,
                        f"{workflow.name} publishes to bootstrap/latest without {directory}; "
                        "the set of scripts on the VM would depend on which workflow ran last",
                    )

    def test_every_publisher_checks_out_what_it_uploads(self):
        """A sparse checkout that omits a directory makes the upload a silent no-op --
        gsutil is handed a glob that matches nothing, and on a -m copy that is not an
        error. The workflow goes green having shipped less than it says."""
        for workflow in self.PUBLISHERS:
            text = workflow.read_text()
            for directory in self.SCRIPT_DIRS:
                self.assertRegex(
                    text,
                    r"sparse-checkout:[^\n]*\n(?:\s+\S+\n)*?\s+" + directory.replace("/", r"/") + r"\s*\n",
                    f"{workflow.name} uploads {directory} but never checks it out",
                )

    def test_the_parse_check_covers_both_directories(self):
        """The parse gate is what stops a syntax error reaching an unattended box. It
        has to cover the same set the upload does, or the extra directory ships
        unchecked."""
        text = self.PUBLISHERS[0].read_text()
        parse_line = [ln for ln in text.splitlines() if "Get-ChildItem" in ln and ".ps1" in ln]
        self.assertTrue(parse_line, "the bootstrap workflow no longer parse-checks anything")
        for directory in self.SCRIPT_DIRS:
            self.assertTrue(
                any(f"{directory}/*.ps1" in ln for ln in parse_line),
                f"the parse check skips {directory}, which is uploaded anyway",
            )


if __name__ == "__main__":
    unittest.main()


STARTUP_STEP_NAME = "Install command queue scheduled task through VM startup script"
BOOTSTRAP_PREFIX = "pr-environments/bootstrap/latest/"


def _startup_script():
    """The PowerShell the VM runs at boot, pulled out of the step that installs it as
    windows-startup-script-ps1."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    for job in workflow["jobs"].values():
        for step in job.get("steps", []):
            if step.get("name") == STARTUP_STEP_NAME:
                return step["run"]
    raise AssertionError(
        f"no step named {STARTUP_STEP_NAME!r} in {WORKFLOW.name}; "
        "the bootstrap no longer installs a startup script"
    )


class BootstrapDownloadsEveryScriptItUploadsTests(unittest.TestCase):
    """The class above proves the bootstrap *uploads* both script directories. This is
    the other half, and it is a separate half: the upload is a glob over the
    directories, while the startup script that pulls them down was a list of ten file
    names typed by hand. Nothing tied the two together, so the moment the glob matched
    something the list did not name, the VM simply did not get it.

    Measured on 2026-08-18. The bootstrap ran green, uploaded Find-LegacyTextColumns.ps1
    at 19:07:22Z, and the agent came up knowing the find-legacy-text-columns command --
    then failed it with "The term 'C:\\RockDeploy\\Find-LegacyTextColumns.ps1' is not
    recognized", because the hand-written list did not mention it. Every assertion in
    the class above passed while that was true.

    The agent's own Sync-DeploymentScripts does glob the prefix, so in principle it
    closes the gap a minute later. It is not a substitute: it writes its progress to the
    scheduled task's local stdout and nothing uploads that, so when it does not do what
    it is expected to do there is no evidence off the box. The bootstrap is the step that
    is watched, so the bootstrap should land what it published."""

    SCRIPT_DIRS = ["Deployment/PrTestEnvironments", "Deployment/Database"]

    def _uploaded_script_names(self):
        names = []
        for directory in self.SCRIPT_DIRS:
            names.extend(sorted(p.name for p in (REPO_ROOT / directory).glob("*.ps1")))
        self.assertTrue(names, "no .ps1 files found to upload; the test is not testing anything")
        return names

    def test_every_uploaded_script_reaches_the_vm_at_bootstrap(self):
        """Satisfied either way -- enumerate the prefix, or name every file. Enumerating
        is preferred because it cannot drift, but a complete list is equally correct and
        this should not fail a design it merely disagrees with."""
        startup = _startup_script()

        enumerates = BOOTSTRAP_PREFIX in startup and "?prefix=" in startup
        if enumerates:
            return

        missing = [name for name in self._uploaded_script_names() if name not in startup]
        self.assertFalse(
            missing,
            "the bootstrap uploads these but its startup script never downloads them, so "
            f"they are absent from C:\\RockDeploy on a freshly bootstrapped VM: {missing}. "
            "Either name them in the startup script or list the bootstrap prefix and take "
            "whatever is published there.",
        )

    def test_a_hand_written_list_does_not_name_scripts_that_no_longer_exist(self):
        """The mirror failure, and the quieter one. A renamed or deleted script leaves its
        old name in the list, and the startup script's download of it 404s at boot -- on a
        box where nobody reads the console."""
        # Only the download array. The step's own `run:` also names the runner-temp file
        # it writes the startup script to, and that one is not downloaded from anywhere.
        array = re.search(r"\$scripts\s*=\s*@\((.*?)\)", _startup_script(), re.DOTALL)
        if not array:
            return
        quoted = set(re.findall(r"'([A-Za-z0-9.-]+\.ps1)'", array.group(1)))
        if not quoted:
            return

        real = set(self._uploaded_script_names())
        stale = sorted(quoted - real)
        self.assertFalse(
            stale,
            f"the startup script downloads {stale}, which no longer exist in "
            f"{self.SCRIPT_DIRS}; the bootstrap would 404 on them at boot",
        )
