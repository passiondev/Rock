import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RENEWAL_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCertificateRenewal.ps1"
QUEUE_SCRIPT = REPO_ROOT / "Deployment" / "PrTestEnvironments" / "Invoke-PrEnvironmentCommandQueue.ps1"
BOOTSTRAP_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-bootstrap-command-queue.yml"
RENEWAL_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-renew-certificates.yml"


class CertificateRenewalTests(unittest.TestCase):
    def test_renewal_script_uses_win_acme_http01_and_rebinds_iis(self):
        text = RENEWAL_SCRIPT.read_text()
        for expected in [
            "win-acme",
            "--validationmode', 'http-01'",
            "--validation', 'selfhosting'",
            "Stop-Service W3SVC",
            "Start-Service W3SVC",
            "Get-ChildItem Cert:\\LocalMachine\\My",
            "Let's Encrypt",
            "AddSslCertificate",
            "env.json",
            "RenewWithinDays"
        ]:
            self.assertIn(expected, text)

    def test_queue_supports_certificate_renewal_command(self):
        text = QUEUE_SCRIPT.read_text()
        self.assertIn('"renew-certificate"', text)
        self.assertIn("Invoke-PrEnvironmentCertificateRenewal.ps1", text)

    def test_bootstrap_copies_certificate_renewal_script_to_vm(self):
        text = BOOTSTRAP_WORKFLOW.read_text()
        self.assertIn("Invoke-PrEnvironmentCertificateRenewal.ps1", text)

    def test_scheduled_workflow_opens_http_temporarily_queues_command_and_cleans_up(self):
        text = RENEWAL_WORKFLOW.read_text()
        for expected in [
            "schedule:",
            "add-tags", "remove-tags", "pr-test-acme-http",
            "renew-certificate",
            "commands/pending", "commands/results",
            "Remove temporary ACME HTTP-01 network tag",
            "if: always()"
        ]:
            self.assertIn(expected, text)
        self.assertNotIn("sshpass", text)
        self.assertNotIn("Deploy over SSH", text)


if __name__ == "__main__":
    unittest.main()
