import pathlib
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
