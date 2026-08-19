import pathlib
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ACTION = REPO_ROOT / ".github" / "actions" / "verify-public-url" / "action.yml"
ACTION_REF = "./.github/actions/verify-public-url"

# Every path that deploys something a human is expected to open in a browser.
DEPLOY_WORKFLOWS = [
    REPO_ROOT / ".github" / "workflows" / "env-deploy-command.yml",
    REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml",
]


def _load(path):
    return yaml.safe_load(path.read_text())


def _steps(workflow):
    for job in workflow.get("jobs", {}).values():
        for step in job.get("steps", []) or []:
            yield job, step


class PublicUrlVerificationTests(unittest.TestCase):
    """The VM probes its own loopback to decide a deploy is healthy, and a loopback probe
    cannot tell you whether anyone else can reach the site. DNS, the host binding, the
    load balancer and the certificate all sit outside it. The staging path asked the
    external question; the pr-* path never did, so a PR environment could be reported
    deployed and healthy while being unreachable to the reviewer it exists for."""

    def test_the_action_exists_and_is_a_composite_action(self):
        self.assertTrue(ACTION.exists(), f"{ACTION} is missing")
        self.assertEqual(_load(ACTION)["runs"]["using"], "composite")

    def test_every_deploy_path_verifies_the_public_url(self):
        for path in DEPLOY_WORKFLOWS:
            with self.subTest(workflow=path.name):
                uses = [
                    step.get("uses", "")
                    for _job, step in _steps(_load(path))
                ]
                self.assertIn(
                    ACTION_REF,
                    uses,
                    f"{path.name} deploys a site but never checks it is reachable from "
                    "outside the VM",
                )

    def test_the_job_that_uses_the_action_also_checks_it_out(self):
        """A local `uses: ./path` resolves against the working tree, not the repository.
        Without a checkout in the same job it fails at runtime with a message about a
        missing action file, and it fails *after* a successful deploy -- so the whole
        thing reads as a broken deploy rather than a missing step. Neither of these jobs
        needed a working tree before this, so neither had a checkout to inherit."""
        for path in DEPLOY_WORKFLOWS:
            workflow = _load(path)
            for job_name, job in workflow.get("jobs", {}).items():
                steps = job.get("steps", []) or []
                if not any(step.get("uses", "") == ACTION_REF for step in steps):
                    continue

                checkouts = [
                    step for step in steps
                    if str(step.get("uses", "")).startswith("actions/checkout@")
                ]
                with self.subTest(workflow=path.name, job=job_name):
                    self.assertTrue(
                        checkouts,
                        f"{path.name}:{job_name} uses the local action without checking "
                        "out the repository first",
                    )

                    action_index = next(
                        i for i, step in enumerate(steps)
                        if step.get("uses", "") == ACTION_REF
                    )
                    self.assertLess(
                        min(steps.index(c) for c in checkouts),
                        action_index,
                        f"{path.name}:{job_name} checks out the repository after using "
                        "the action",
                    )

    def test_the_sparse_checkout_includes_the_action(self):
        """A sparse checkout that omits the action's own path produces a working tree
        without it, which fails exactly like having no checkout at all -- while looking
        like the checkout succeeded.

        The one that has to contain it is the *last* checkout before the action runs,
        because each checkout replaces the sparse patterns and the working tree that
        the previous one left. A job may legitimately check out something else earlier
        for an unrelated step -- env-deploy-command.yml checks out
        Deployment/PrTestEnvironments for the drift comparison -- and requiring every
        checkout in the job to carry this action's path would only force cargo into
        steps that have nothing to do with it.
        """
        for path in DEPLOY_WORKFLOWS:
            for job_name, job in _load(path).get("jobs", {}).items():
                steps = job.get("steps", []) or []
                action_indexes = [
                    index for index, step in enumerate(steps)
                    if step.get("uses", "") == ACTION_REF
                ]
                if not action_indexes:
                    continue

                preceding = [
                    step for step in steps[: action_indexes[0]]
                    if str(step.get("uses", "")).startswith("actions/checkout@")
                    and (step.get("with") or {}).get("sparse-checkout") is not None
                ]
                if not preceding:
                    continue

                with self.subTest(workflow=path.name, job=job_name):
                    self.assertIn(
                        ".github/actions/verify-public-url",
                        preceding[-1]["with"]["sparse-checkout"],
                        f"{path.name}:{job_name} sparse-checks-out a tree that does "
                        "not contain the action it then uses",
                    )

    def test_unreachable_is_fatal_but_a_certificate_finding_is_not(self):
        """These are different failures with different owners. A site nobody can load is
        an outage; a certificate a browser complains about is a chore. Folding them
        together means a renewal that is merely due reads as a broken deploy, and people
        stop believing the check."""
        body = _load(ACTION)["runs"]["steps"][0]["run"]

        certificate_section = body.index('cert="$(echo | openssl s_client')
        reachability = body[:certificate_section]
        certificate = body[certificate_section:]

        self.assertIn(
            "exit 1",
            reachability,
            "an unreachable site does not fail the job",
        )
        self.assertNotIn(
            "exit 1",
            certificate,
            "a certificate finding fails the deploy; it should warn, not fail",
        )
        self.assertIn("::warning::", certificate)

    def test_the_verification_is_not_also_duplicated_inline(self):
        """The point of extracting it was to stop the production path and the pr-* path
        drifting. A leftover inline copy re-creates exactly that."""
        for path in DEPLOY_WORKFLOWS:
            with self.subTest(workflow=path.name):
                self.assertNotIn(
                    "is not reachable from the internet",
                    path.read_text(),
                    f"{path.name} still carries its own copy of the probe as well as "
                    "calling the shared action",
                )


if __name__ == "__main__":
    unittest.main()
