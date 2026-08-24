"""`CONTEXT.md` names one thing one way. This checks it stays that way.

Written after an architecture review counted the spellings of the trunk branch
across the layers. Most of that multiplicity is legitimate -- `baseBranch` is a
JSON key and `default branch` is a GitHub setting, and collapsing those two would
break the cutover gate rather than tidy it. What is worth guarding is the
opposite case: one word quietly acquiring a second meaning.

`instance` is the live example. It means a Cloud SQL instance throughout the
runbooks, and an operator reading "restart the instance" during an incident has
to know whether that is a website or a database holding real congregant data.
Nothing violates this today. The test is cheap and the failure it prevents is
not.
"""

import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT

CONTEXT = REPO_ROOT / "CONTEXT.md"
OPERATOR_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"
DEVELOPER_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md"
ENGINEERING_GUIDE = REPO_ROOT / "Documentation" / "Local-Engineering-Training-Edit-Test-and-Deploy.md"

OPERATIONAL_PROSE = [OPERATOR_RUNBOOK, DEVELOPER_RUNBOOK, ENGINEERING_GUIDE]


class ContextFileCoversTheLoadBearingTermsTests(harness.HarnessAssertions, unittest.TestCase):
    def test_the_context_file_exists(self):
        self.assertTrue(CONTEXT.exists(), "CONTEXT.md is gone; the vocabulary has nowhere to live")

    def test_it_defines_the_terms_that_span_more_than_one_layer(self):
        """A term used by a workflow, a script and a runbook at once is exactly the
        term a reader meets in three spellings. Those are the ones that have to be
        written down."""
        text = CONTEXT.read_text(encoding="utf-8")

        for term in (
            "trunk", "base branch", "default branch", "production branch",
            "environment", "the fleet", "staging", "catalog", "sandbox",
            "command", "the queue", "producer", "enqueue", "DedicatedSite", "InPlace",
        ):
            self.assertIn(term, text, f"CONTEXT.md no longer defines `{term}`")

    def test_it_keeps_the_cutover_distinction_that_is_load_bearing(self):
        """`default branch` and `base branch` are read by two different gates on
        purpose. A future editor tidying CONTEXT.md into fewer terms would be
        deleting the reason the teardown path still works for retired PRs."""
        text = CONTEXT.read_text(encoding="utf-8")

        self.assertIn("Not a synonym for the trunk", text)
        self.assertIn("pr-test-lifecycle.yml", text)
        self.assertIn("pr-test-deploy.yml", text)


class OneWordOneMeaningTests(harness.HarnessAssertions, unittest.TestCase):
    # `instance` belongs to Cloud SQL here. These are the shapes it takes when it
    # has drifted onto an environment instead.
    # `the instance` on its own is fine and frequent -- the runbook says it about
    # `connect-restore-test` twice. What gives the drift away is a quantifier
    # implying many of them, or a possessive naming something only a website has.
    INSTANCE_AS_ENVIRONMENT = re.compile(
        r"\b(?:PR|pr-\*|each|every|per)\s+instances?\b"
        r"|\binstance(?:'s|s)?\s+(?:site|app ?pool|host ?name|URL|deploy)",
        re.IGNORECASE,
    )

    def test_instance_still_means_a_cloud_sql_instance(self):
        for path in OPERATIONAL_PROSE:
            text = path.read_text(encoding="utf-8")
            self.assertNoMatch(
                self.INSTANCE_AS_ENVIRONMENT,
                text,
                f"{path.name} uses `instance` where it means a PR environment. In this "
                f"project `instance` is a Cloud SQL instance holding real congregant "
                f"data, and an operator acting on the wrong one during an incident is "
                f"the failure this guards (see CONTEXT.md)",
            )

    def test_the_guard_can_actually_fire(self):
        """A regex that stopped matching anything would leave the test above green
        forever. Prove it still catches the phrasing it is written for."""
        self.assertRegex("restart each instance before the deploy", self.INSTANCE_AS_ENVIRONMENT)
        self.assertRegex("the instance's app pool is stopped", self.INSTANCE_AS_ENVIRONMENT)
        self.assertNotRegex("gcloud sql operations list --instance=connect-restore-test", self.INSTANCE_AS_ENVIRONMENT)


if __name__ == "__main__":
    unittest.main()
