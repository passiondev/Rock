import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
DEV_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md"
OP_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"
PROD_RUNBOOK = REPO_ROOT / "Documentation" / "Production-Upgrade-Runbook.md"

PRODUCTION_BOOTSTRAP_WORKFLOW = harness.WORKFLOWS_DIR / "production-bootstrap-command-queue.yml"
PRODUCTION_DEPLOY_WORKFLOW = harness.WORKFLOWS_DIR / "production-deploy.yml"


class RunbookAssertions:
    """Shared by every runbook class here. A mixin rather than a base class with
    tests on it: subclassing RunbookTests to reach `assertCovers` would inherit its
    four test methods too and run the developer and operator runbooks a second time
    under the subclass's name, which reads as coverage and is a copy."""

    def assertCovers(self, path, needles, why):
        """assertIn against a runbook prints the entire runbook into the failure,
        which buries the one term that is missing. Report the missing terms and
        nothing else."""
        text = path.read_text()
        missing = [needle for needle in needles if needle not in text]
        self.assertFalse(missing, f"{path.name}: {why}: missing {missing}")


class RunbookTests(RunbookAssertions, unittest.TestCase):
    def test_developer_runbook_covers_commands_access_and_shared_data(self):
        self.assertCovers(DEV_RUNBOOK, [
            'rock:start',
            'rock:stop',
            'rock:destroy',
            'rock:auto',
            'VPN',
            '159.63.145.194',
            'shared sandbox database',
            'shared sandbox file storage',
            're-add `rock:start`',
        ], "developer runbook no longer covers the commands, access or shared data")

        # The runbook called the catalog "sanitized" until 2026-08-19. It is not,
        # and never was -- see open item 24. Pinning the old phrase in the list
        # above is what kept the misstatement alive through several reviews, so
        # assert the correction and refuse the reassuring wording.
        text = DEV_RUNBOOK.read_text()
        self.assertNotIn('sanitized sandbox', text)
        self.assertIn('not sanitized', text)

    def test_operator_runbook_covers_infrastructure_and_recovery(self):
        self.assertCovers(OP_RUNBOOK, [
            '*.staging.connect.passion.team',
            "Let's Encrypt",
            'pr-test-renew-certificates.yml',
            '159.63.145.194/32',
            'command queue',
            'GCP_VM_EXTERNAL_IP',
            'C:\\RockTestEnvs',
            'env.json',
            'rock-pr-<number>',
            'Invoke-PrEnvironmentCleanup.ps1',
            'Invoke-SandboxRefreshWithPrEnvironments.ps1',
            'Troubleshooting',
        ], "operator runbook no longer covers the infrastructure and recovery basics")

    def test_operator_runbook_documents_the_trunk_cutover_ordering(self):
        """Flipping the trunk branch points staging at a new Rock minor, and the
        first request after that deploy migrates the catalog every `pr-*` site
        now shares. Any pr-* still serving the old minor is then pr-3 again --
        once per live environment. The ordering that avoids it is not inferable
        from any single workflow, so it has to be written down.

        `pull.base.ref` and the retired-branch step are asserted because the
        section was first written with the opposite belief -- that flipping the
        pins makes the gate reject stale PRs. It did not: both gates read the
        config from the PR's own base branch, so the retired fleet stayed live
        and had to be shut off deliberately. A cutover section that omits that is
        worse than none, because it reads as complete.

        The deploy gate now reads its config from the default branch instead, so
        moving the default branch is what closes the door -- which makes it a
        required step rather than repository housekeeping, and makes the runbook
        wrong again if it still says the flip is enough. The lifecycle gate keeps
        reading `pull.base.ref` on purpose, so `rock:destroy` goes on working for
        retired PRs; that asymmetry is the whole teardown path and is easy to
        mistake for an oversight and 'fix'."""
        self.assertCovers(OP_RUNBOOK, [
            'Trunk cutover',
            'BASE_BRANCH_PIN_SITES',
            'rock:destroy',
            'pr-3',
            'pull.base.ref',
            'retired branch',
            'default branch',
            'pr-test-destroy-all.yml',
            'set-trunk-protection.sh',
        ], "operator runbook does not cover the cutover")

    def test_the_cutover_never_tells_the_operator_to_drop_the_ruleset(self):
        """This section said, at step 3, that deleting the retired branch was blocked
        by the ruleset from step 0 and that you should drop the ruleset first. Both
        halves were wrong in the same way: the ruleset targets `~DEFAULT_BRANCH`, and
        by step 3 the default has already moved to the new trunk. The retired branch
        was never the one protected, so nothing was blocking its deletion -- and
        following the advice would have removed the only protection from the branch
        the whole team had just moved onto, at the exact moment the section is
        telling them to start landing commits on it.

        The plausible-sounding version is the dangerous one, so pin the wording."""
        text = OP_RUNBOOK.read_text()
        cutover = text.split('## Trunk cutover', 1)[1].split('\n## ', 1)[0]

        for phrase in ['drop the ruleset', 'delete the ruleset', 'remove the ruleset']:
            self.assertNotIn(
                phrase,
                cutover.lower(),
                f"the cutover section tells the operator to {phrase}; the ruleset "
                f"follows ~DEFAULT_BRANCH onto the new trunk, so by then it is the only "
                f"thing protecting the branch everyone just moved to",
            )

        self.assertIn(
            'Leave the ruleset alone',
            cutover,
            "the cutover section does not say to leave the ruleset in place, which is "
            "what stops the next person reasoning their way back to dropping it",
        )


class StepsTheRunbookTellsYouToWatchTests(harness.HarnessAssertions, unittest.TestCase):
    """A runbook that names a step by its exact title is only useful while the step
    still carries that title.

    The architecture review read these two lines as an error -- the runbook sends the
    operator to a step in `staging-deploy.yml` that really lives in
    `env-deploy-command.yml`. It is not one. The runbook names no workflow file; it
    says to check the run, and `staging-deploy.yml` calls `env-deploy-command.yml` as
    a reusable workflow, so the step shows up inside the run the operator is already
    looking at. The claim is recorded here rather than argued in a commit message,
    because the next review will read the same two lines the same way.

    What is worth holding is the weaker fact the review was reaching for: the title
    in the prose and the title in the YAML are two copies of one string.
    """

    WATCHED_STEP = re.compile(r"(?:check|watch) the run's `([^`]+)` step", re.IGNORECASE)

    def step_names(self):
        """Every step title in every workflow and composite action.

        The actions count. A composite action's steps run inside the caller's job
        and appear in the caller's run under their own titles, so a step that moves
        into one is still a step the operator sees. Globbing only the workflows made
        this scan report a clean result over a shrinking half of the tree -- and it
        would have turned every runbook line green the moment a named step moved,
        which is the one edit most likely to invalidate the line.
        """
        names = set()
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            parsed = harness.workflow(path.name)
            for job in (parsed.get("jobs") or {}).values():
                names.update(s.get("name") for s in (job.get("steps") or []) if s.get("name"))
        for action in harness.composite_actions():
            steps = harness.action_steps(harness.composite_action(action))
            names.update(s.get("name") for s in steps if s.get("name"))
        return names

    def test_every_step_a_runbook_names_still_exists_under_that_name(self):
        available = self.step_names()
        self.assertNotVacuous(available, "no workflow step names were found")

        watched = []
        offenders = []
        for runbook in (DEV_RUNBOOK, OP_RUNBOOK, PROD_RUNBOOK):
            text = runbook.read_text(encoding="utf-8")
            for match in self.WATCHED_STEP.finditer(text):
                name = match.group(1)
                watched.append(name)
                if name not in available:
                    line = harness.line_of(text, match.start())
                    offenders.append(f"{runbook.name}:{line} names the step {name!r}")

        self.assertNotVacuous(watched, "no runbook line points at a named step any more")
        self.assertEqual(
            [],
            offenders,
            "these send an operator looking for a step title no workflow carries:\n  "
            + "\n  ".join(offenders),
        )


class ProductionUpgradeRunbookTests(RunbookAssertions, unittest.TestCase):
    """Production's upgrade is the one procedure in this repository where the
    pipeline deliberately stops short and hands off to prose.

    Every other control here is a guard that refuses. This one cannot be: the
    ordering is forced by three guards that each read a different ref, the reboot
    is forced by a Compute Engine scope rule, and the backup is forced by nothing
    at all -- `production-deploy.yml` stops demanding `acknowledge_version_change`
    the moment `productionBranch` is repointed, and says in its own comments that
    the runbook is where the backup requirement lives from then on. So these tests
    guard a document rather than code, and they are the only thing standing under
    that handoff.
    """

    # Steps this runbook sends an operator to read. Named here rather than left to
    # the prose scan in StepsTheRunbookTellsYouToWatchTests, which only matches the
    # "watch the run's X step" phrasing -- most of these are cited in sentences that
    # read better without it, and a step title that moved would take the citation
    # with it and fail nothing.
    CITED_STEPS = [
        "Refuse a ref that is not the production branch",
        "Say what happened",
        "Restart the production VM to apply it",
        "Wait for the agent to report in",
        "Resolve SHA and summarize the request",
        "Refuse a ref that is not on the production branch",
        "Refuse a ref from a different Rock version",
        "Record approval",
    ]

    def workflow_step_names(self):
        names = set()
        for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
            parsed = harness.workflow(path.name)
            for job in (parsed.get("jobs") or {}).values():
                names.update(s.get("name") for s in (job.get("steps") or []) if s.get("name"))
        return names

    def test_it_covers_the_ordering_the_guards_force(self):
        """The order is not a preference and not inferable from any one workflow.
        `production-deploy.yml` refuses a ref off `productionBranch`; the bootstrap
        refuses a ref that is not exactly `productionBranch`; and `workflow_dispatch`
        only lists a workflow that exists on the default branch. While those two
        branches differ the bootstrap file has to exist on both, which is the
        constraint that actually decides the order -- repoint first, and one branch
        satisfies every guard."""
        self.assertCovers(PROD_RUNBOOK, [
            'productionBranch',
            'production-bootstrap-command-queue.yml',
            'restart_vm',
            'commands-prod',
            'pr-environments/bootstrap/prod/',
            'connect-srv-prod',
            'connect-prod',
            'RockConnectProd',
            'default branch',
            'EXPECTED_PRODUCTION_BRANCH',
            'PRODUCTION_PIN_SITES',
        ], "the production upgrade runbook no longer covers the forced ordering")

    def test_it_says_the_reboot_is_unavoidable_and_gives_both_reasons(self):
        """"Restart production" is the line most likely to be argued away by
        somebody who has not hit the wall, and there are two independent walls, so
        removing either reason still leaves a reader thinking the other has a way
        round it. Scopes cap IAM and can only be edited while the instance is
        stopped; a startup script runs at boot and never otherwise."""
        text = PROD_RUNBOOK.read_text()

        self.assertIn('devstorage.read_only', text)
        self.assertIn('devstorage.read_write', text)
        self.assertIn('stopped', text)
        self.assertIn('windows-startup-script-ps1', text)

        # The scope edit overwrites the whole list, and production's list carries the
        # two the Ops Agent needs. A runbook that does not say so invites somebody
        # reading the gcloud docs to "simplify" the workflow's union back into a
        # single --scopes= value and silently take production's logging with it.
        self.assertIn('logging.write', text)
        self.assertIn('monitoring.write', text)

    def test_it_carries_the_backup_requirement_the_deploy_guard_hands_off(self):
        """`production-deploy.yml` stops demanding the acknowledgement checkbox once
        `productionBranch` moves -- deliberately, because a guard that fires on
        routine work gets ticked without being read. Its comment names the runbook as
        where the backup requirement goes instead. Assert both halves: if the comment
        ever stops delegating, this test should be reconsidered rather than kept
        green by a document nobody is being sent to."""
        # One line of that comment, not a phrase spanning its wrap -- and asserted
        # with a message rather than assertIn, which would print the whole workflow
        # into the failure and bury the sentence that moved.
        guard = PRODUCTION_DEPLOY_WORKFLOW.read_text()
        self.assertTrue(
            "cutover checklist is where the backup requirement is attached" in guard,
            "production-deploy.yml no longer hands the backup requirement to a runbook; "
            "check whether the guard took it back before relaxing this file",
        )

        self.assertCovers(PROD_RUNBOOK, [
            'gcloud sql backups create',
            'connect-prod',
            'point-in-time recovery',
            'acknowledge_version_change',
        ], "the runbook the deploy guard delegates its backup requirement to does not "
           "actually require a backup")

    def test_it_refuses_the_belief_that_reinstalling_the_old_binaries_is_a_rollback(self):
        """The plausible-sounding version is the dangerous one. A deploy that backs
        the site up first reads as reversible, and it is -- right up until the first
        request runs migrations. EF commits each migration separately, so a failure
        part-way leaves the schema between two minors, and 18.4.1 could not start
        against that catalog either when this was measured on staging.

        Pin the correction rather than the reassurance."""
        text = PROD_RUNBOOK.read_text()

        self.assertIn('Binaries roll back. The database does not.', text)
        self.assertIn('DbMigrator', text)
        self.assertIn("Invalid column name 'ScheduleReminderSystemEmailId'", text)

        # The one property that makes an instance-level restore safe here, and the
        # reason it is not safe on the sandbox instance. Losing this line turns a
        # correct instruction into a habit that destroys three other catalogs.
        rollback = text.split('## Rollback', 1)[1].split('\n## ', 1)[0]
        self.assertIn('exactly one user database', rollback)

    def test_every_step_it_cites_still_exists_under_that_name(self):
        available = self.workflow_step_names()
        self.assertTrue(available, "no workflow step names were found")

        text = PROD_RUNBOOK.read_text()
        missing_from_workflows = [s for s in self.CITED_STEPS if s not in available]
        missing_from_runbook = [s for s in self.CITED_STEPS if f'`{s}`' not in text]

        self.assertEqual(
            [], missing_from_workflows,
            "the runbook sends an operator looking for step titles no workflow carries: "
            + ", ".join(missing_from_workflows),
        )
        self.assertEqual(
            [], missing_from_runbook,
            "these are listed here as cited but the runbook no longer cites them, so this "
            "list has stopped guarding anything: " + ", ".join(missing_from_runbook),
        )

    def test_it_carries_the_repoint_step_no_test_can_check(self):
        """The `production` environment is restricted to one branch by name, and
        that name lives in GitHub rather than in this repository. `PRODUCTION_PIN_SITES`
        reads files, so it cannot see this one and reports green while it is stale.
        Left stale through a cutover, every job declaring `environment: production` is
        refused at the gate and the error names the environment, not the branch."""
        text = PROD_RUNBOOK.read_text()

        self.assertIn(
            "deployment-branch-policies",
            text,
            "the runbook never tells anyone to move the environment's branch policy, "
            "which is the one pin the repository's own guard cannot check",
        )

        # Order matters and the runbook has to say so: removing the old branch before
        # adding the new one leaves the environment with no allowed branch at all.
        self.assertIn(
            "--method POST",
            text,
            "the runbook names the branch policy without saying how to add one",
        )

    def test_the_literals_it_tells_you_to_verify_match_the_workflow(self):
        """Step 4 tells the operator to read the installed task's command line and
        check two values against this document. Both are copied out of the workflow,
        so the check is only worth running while the copies agree -- otherwise it
        sends someone to confirm production is configured a way it deliberately is
        not, and the honest answer looks like a fault."""
        workflow = PRODUCTION_BOOTSTRAP_WORKFLOW.read_text()
        text = PROD_RUNBOOK.read_text()

        # `ROCK-BOOTSTRAP: refusing to install` is here for a different reason than
        # the rest. The runbook tells the operator that seeing it after a stray boot
        # is the correct outcome and not a fault to chase. If the startup script
        # stopped printing that exact text, the advice would send someone hunting a
        # message that no longer exists, on the one day nobody has time for it.
        literals = [
            'commands-prod',
            'pr-environments/bootstrap/prod/',
            'connect-srv-prod',
            'ROCK-BOOTSTRAP: refusing to install',
        ]
        for literal in literals:
            self.assertIn(
                literal, workflow,
                f"the bootstrap workflow no longer uses {literal!r}, which the runbook "
                f"tells an operator to verify on the VM",
            )
            self.assertIn(literal, text)

        # The staging prefix must not appear as an instruction. Both hosts re-download
        # their scripts from whatever prefix their task names, once a minute, so a
        # production agent on the staging prefix runs staging's next upload as SYSTEM
        # within the minute. It is named in the runbook only as the thing to refuse.
        for line in text.splitlines():
            if 'bootstrap/latest/' in line:
                self.assertIn(
                    'would execute', line,
                    "the production runbook names the staging bootstrap prefix outside the "
                    "sentence explaining why production must not be pointed at it",
                )


if __name__ == "__main__":
    unittest.main()
