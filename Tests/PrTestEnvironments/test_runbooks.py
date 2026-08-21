import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
DEV_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Developer-Runbook.md"
OP_RUNBOOK = REPO_ROOT / "Documentation" / "PR-Test-Environments-Operator-Runbook.md"


class RunbookTests(unittest.TestCase):
    def assertCovers(self, path, needles, why):
        """assertIn against a runbook prints the entire runbook into the failure,
        which buries the one term that is missing. Report the missing terms and
        nothing else."""
        text = path.read_text()
        missing = [needle for needle in needles if needle not in text]
        self.assertFalse(missing, f"{path.name}: {why}: missing {missing}")

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
            '*.rock-dev.connect.passion.team',
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


if __name__ == "__main__":
    unittest.main()
