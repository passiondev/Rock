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
            "commands/pending",
            "Remove temporary ACME HTTP-01 network tag",
            "if: always()"
        ]:
            self.assertIn(expected, text)
        self.assertNotIn("sshpass", text)
        self.assertNotIn("Deploy over SSH", text)

        # Waiting for the result is .github/actions/await-vm-command, shared with
        # the other five producers; test_local_composite_actions.py asserts both
        # that this workflow uses it and how it behaves.


class CertificateBindResilienceTests(unittest.TestCase):
    def test_one_dead_environment_does_not_block_renewal_for_the_others(self):
        """The bind pass used to throw on the first host with no certificate, so a
        PR environment whose DNS or site had gone away took every healthy
        environment's certificate renewal down with it. It should now bind each
        host independently and fail only when nothing could be bound."""
        text = RENEWAL_SCRIPT.read_text()

        self.assertNotIn(
            'throw "No Let\'s Encrypt certificate is available for $hostName after renewal."',
            text,
            "bind pass must not abort the whole run on the first host without a certificate",
        )
        self.assertIn("$bindFailures", text)
        self.assertIn("if ($boundCount -eq 0)", text)


if __name__ == "__main__":
    unittest.main()
