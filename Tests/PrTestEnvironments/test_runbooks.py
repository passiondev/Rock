import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
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
            'shared sanitized sandbox database',
            'shared sandbox file storage',
            're-add `rock:start`',
        ], "developer runbook no longer covers the commands, access or shared data")

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
        pins makes the gate reject stale PRs. It does not: both gates read the
        config from the PR's own base branch, so the retired fleet stays live and
        has to be shut off deliberately. A cutover section that omits that is
        worse than none, because it reads as complete."""
        text = OP_RUNBOOK.read_text()
        for expected in [
            'Trunk cutover',
            'BASE_BRANCH_PIN_SITES',
            'rock:destroy',
            'pr-3',
            'pull.base.ref',
            'retired branch',
        ]:
            self.assertIn(expected, text, f"operator runbook does not cover the cutover: missing {expected!r}")


if __name__ == "__main__":
    unittest.main()
