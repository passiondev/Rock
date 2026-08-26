"""The public-URL probe, run rather than read.

This was sixty-four lines of bash inside `verify-public-url/action.yml`. Nothing
could execute it, so the only thing any test could do was match its text, and the
one branch that most needed a test is the one where matching text is exactly the
wrong tool. The action's own comment says so:

    Self-signed is decided by issuer == subject, not by pattern-matching a CN,
    because the printed form of a DN is not stable [...] All three were observed
    while building this.

A check that can only fail closed reports "certificate fine" for every
certificate. These tests run the script against a stub `curl` and `openssl`, so
the three DN forms are real inputs rather than a note in a comment.

The stubs go on PATH ahead of the real tools. `sleep` is stubbed to nothing so a
retry test costs no wall clock, and `date` is stubbed so the expiry arithmetic
does not depend on GNU date being the one installed.
"""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

import pipeline_harness as harness

SCRIPT = harness.REPO_ROOT / ".github" / "actions" / "verify-public-url" / "verify-public-url.sh"

# Every printed form of a distinguished name the action's comment records seeing.
DN_FORMS = [
    "/CN=*.example.org",
    "CN=*.example.org",
    "CN = *.example.org",
]

NOW_EPOCH = 1_700_000_000


class _Probe:
    """One run of the script with the outside world stubbed out."""

    def __init__(self, http_codes, issuer=None, subject=None, expiry_epoch=None):
        self.http_codes = list(http_codes)
        self.issuer = issuer
        self.subject = subject
        self.expiry_epoch = expiry_epoch

    def run(self, **env_overrides):
        with tempfile.TemporaryDirectory() as work:
            binaries = os.path.join(work, "bin")
            os.makedirs(binaries)
            self._write_stubs(binaries, work)

            summary = os.path.join(work, "summary.md")
            env = {
                **os.environ,
                "PATH": binaries + os.pathsep + os.environ["PATH"],
                "HOST_NAME": "site.example.org",
                "ATTEMPTS": "3",
                "RETRY_DELAY_SECONDS": "0",
                "REQUEST_TIMEOUT_SECONDS": "5",
                "CERTIFICATE_WARNING_DAYS": "21",
                "GITHUB_STEP_SUMMARY": summary,
                **env_overrides,
            }

            completed = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=work,
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            # Absent on the fatal path: the script exits before it writes the
            # table, which is the behaviour a reachability failure should have.
            completed.summary = ""
            if os.path.exists(summary):
                with open(summary, encoding="utf-8") as handle:
                    completed.summary = handle.read()
            return completed

    def _write_stubs(self, binaries, work):
        def stub(name, body):
            path = os.path.join(binaries, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("#!/usr/bin/env bash\n" + textwrap.dedent(body))
            os.chmod(path, 0o755)

        # One code per attempt, so a test can make the site come up on the third try.
        codes = os.path.join(work, "codes")
        with open(codes, "w", encoding="utf-8") as handle:
            handle.write("\n".join(self.http_codes) + "\n")
        stub("curl", f"""
            code="$(head -n 1 {codes})"
            tail -n +2 {codes} > {codes}.rest && mv {codes}.rest {codes}
            [ -n "$code" ] || code="$(printf '%s' "{self.http_codes[-1]}")"
            printf '%s' "$code"
        """)

        stub("sleep", "exit 0")

        if self.issuer is None:
            # `openssl s_client` failing is the real shape of an unreachable or
            # non-TLS host: the script must survive reading nothing.
            stub("openssl", "exit 1")
        else:
            expiry = "" if self.expiry_epoch is None else "Jan  1 00:00:00 2030 GMT"
            stub("openssl", f"""
                case "$*" in
                  *-issuer*)  printf 'issuer={self.issuer}\\n' ;;
                  *-subject*) printf 'subject={self.subject}\\n' ;;
                  *-enddate*) [ -n "{expiry}" ] && printf 'notAfter={expiry}\\n' ;;
                  *)          printf 'CONNECTED\\n' ;;
                esac
                exit 0
            """)

        end = self.expiry_epoch if self.expiry_epoch is not None else NOW_EPOCH
        stub("date", f"""
            for argument in "$@"; do
              if [ "$argument" = "-d" ]; then printf '%s' "{end}"; exit 0; fi
            done
            printf '%s' "{NOW_EPOCH}"
        """)


class ReachabilityTests(unittest.TestCase):
    def test_a_serving_site_passes_and_reports_its_code(self):
        result = _Probe(["200"]).run()

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("returned HTTP 200", result.stdout)

    def test_a_site_that_comes_up_late_still_passes(self):
        """The retry exists because a cold IIS site serves nothing for the better
        part of a minute after a deploy. A probe that gave up on the first 000
        would fail every deploy it was added to protect."""
        result = _Probe(["000", "000", "200"]).run()

        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("returned HTTP 200", result.stdout)

    def test_an_unreachable_site_is_fatal_and_says_where_to_look(self):
        result = _Probe(["000", "000", "000"]).run()

        self.assertEqual(1, result.returncode)
        self.assertIn("::error::", result.stdout)
        self.assertIn("something between the internet and IIS did not", result.stdout)

    def test_a_server_error_is_fatal_rather_than_a_pass(self):
        """`-lt 400` is the whole test. A 500 is a reachable socket and a broken
        site, and reading it as reachable is how a failed deploy goes green."""
        result = _Probe(["500", "500", "500"]).run()

        self.assertEqual(1, result.returncode)
        self.assertIn("::error::", result.stdout)


class SelfSignedCertificateTests(unittest.TestCase):
    """The branch the extraction was for."""

    def test_every_printed_form_of_a_dn_is_detected_as_self_signed(self):
        for form in DN_FORMS:
            with self.subTest(dn=form):
                result = _Probe(["200"], issuer=form, subject=form).run()

                self.assertEqual(0, result.returncode, "a self-signed certificate is not an outage")
                self.assertIn("::warning::", result.stdout)
                self.assertIn("self-signed certificate", result.stdout)

    def test_a_real_certificate_raises_no_self_signed_warning(self):
        result = _Probe(
            ["200"],
            issuer="CN = R11, O = Let's Encrypt, C = US",
            subject="CN = site.example.org",
        ).run()

        self.assertEqual(0, result.returncode)
        self.assertNotIn("self-signed", result.stdout)

    def test_a_certificate_that_cannot_be_read_is_not_called_self_signed(self):
        """Both strings come back empty when openssl fails, and empty equals empty.
        Without the `-n "$issuer"` guard every unreadable certificate is reported as
        self-signed, which is the false alarm that gets the check ignored."""
        result = _Probe(["200"], issuer=None).run()

        self.assertEqual(0, result.returncode)
        self.assertNotIn("self-signed", result.stdout)
        self.assertIn("(could not be read)", result.stdout)


class CertificateExpiryTests(unittest.TestCase):
    def test_a_certificate_near_expiry_warns(self):
        result = _Probe(
            ["200"],
            issuer="CN = R11",
            subject="CN = site.example.org",
            expiry_epoch=NOW_EPOCH + 5 * 86400,
        ).run()

        self.assertIn("::warning::", result.stdout)
        self.assertIn("expires in 5 days", result.stdout)
        self.assertIn("Run the certificate renewal workflow", result.stdout)

    def test_a_certificate_with_time_left_does_not_warn(self):
        result = _Probe(
            ["200"],
            issuer="CN = R11",
            subject="CN = site.example.org",
            expiry_epoch=NOW_EPOCH + 60 * 86400,
        ).run()

        self.assertIn("60 days remaining", result.stdout)
        self.assertNotIn("::warning::", result.stdout)


class JobSummaryTests(unittest.TestCase):
    def test_the_summary_records_the_probe(self):
        """Whoever opens the run reads this table rather than the log."""
        result = _Probe(
            ["200"],
            issuer="CN = R11",
            subject="CN = site.example.org",
            expiry_epoch=NOW_EPOCH + 60 * 86400,
        ).run()

        self.assertIn("| Public URL | HTTP 200 from the GitHub runner |", result.summary)
        self.assertIn("| Certificate | CN = R11 |", result.summary)
        self.assertIn("(60 days)", result.summary)


class ScriptShapeTests(unittest.TestCase):
    def test_the_script_is_executable(self):
        """A composite action calls it by path. Without the bit the step fails with
        permission denied, and the deploy that queued it is already finished."""
        self.assertTrue(os.access(SCRIPT, os.X_OK), f"{SCRIPT} is not executable")

    @unittest.skipIf(shutil.which("shellcheck") is None, "shellcheck is not installed")
    def test_the_script_passes_shellcheck(self):
        """Available only because the bash left the YAML."""
        result = subprocess.run(
            ["shellcheck", "--severity=warning", str(SCRIPT)],
            capture_output=True, text=True,
        )
        self.assertEqual(0, result.returncode, result.stdout)


if __name__ == "__main__":
    unittest.main()
