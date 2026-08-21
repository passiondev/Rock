"""One Google Cloud session, opened one way, by every workflow that needs one.

Card 06 of the 2026-08-21 architecture review counted nine byte-identical
`auth@v2` + `setup-gcloud@v2` pairs and proposed a local composite action. This
module first argued against it, on the grounds that `uses: ./...` loads from the
checkout and five of the nine callers never checked out. That was wrong, and it
is worth saying why, because the mistake is easy to repeat: the check was run
against the tree as it stood *before* the same review's card 02 landed. Card 02
moved the enqueue and the wait into composite actions, which forced a checkout
into three of those five workflows. By the time the rebuttal was written, seven of
the nine already checked out, an eighth checked out later in the same job, and the
ninth needed one sparse checkout of a single directory.

So the action exists, at `.github/actions/gcp-session`, and what this module holds
changed with it. Byte-identity across nine copies is no longer a thing to test --
there is one copy. What replaces it is the cost the action brought in: a local
action is loaded from disk, so every caller now needs a checkout that runs first
*and* reaches the action's directory. Neither requirement appears in the `with:`
block, and neither fails at parse time. A sparse checkout that omits one directory
gets an "action not found" several minutes into a deploy, and only on the branch
where somebody added the caller.

The bucket expression is a separate claim from the same card, and it holds for
most of what it covers. All twelve remaining uses sit in a job-level `env:` block,
which GitHub evaluates before any step runs -- so a step output there resolves to
the empty string and every `gsutil` path silently becomes `gs:///...`, a deploy
that writes nowhere and reports success. No accessor can reach those. They stay,
and the identity test below is what holds them together.

The count was wrong here for a while, and the correction is worth keeping: it read
"eleven of fourteen" when the real split was ten of fourteen. The other four were
not load-bearing at all. Three sat in `run:` bodies in the bootstrap workflow and
one in a `github-script` body in the deploy workflow, and every one of them could
read a name the job had already declared. They now do, which is where twelve comes
from. The test below pins the shape rather than the number, so the next copy in a
`run:` body fails on the spot instead of being counted as one of the unavoidable
ones.
"""

import re
import unittest

import yaml

import pipeline_harness as harness

DEPENDABOT_CONFIG = harness.REPO_ROOT / ".github" / "dependabot.yml"

SESSION_ACTION = "gcp-session"
SESSION_USES = f"./.github/actions/{SESSION_ACTION}"

# Matched against raw text rather than parsed YAML on purpose: this is looking for
# a hand-rolled pair anywhere in a file, including one commented back in during a
# debugging session and never removed.
HAND_ROLLED_AUTH = re.compile(r"uses:\s*google-github-actions/(?:auth|setup-gcloud)@")

# Anchored on the closing paren of `format(...)` rather than on the first `}`,
# because the format string itself contains `{0}` and `{1}`.
BUCKET_FALLBACK = re.compile(
    r"\$\{\{\s*vars\.PR_TEST_GCS_BUCKET\s*\|\|.*?\)\s*\}\}",
    re.DOTALL,
)

# The nine workflows that open a Google Cloud session. Listed rather than counted
# so that a tenth workflow authenticating some other way is a failure here, not a
# silently lower number.
AUTHENTICATING_WORKFLOWS = [
    "db-find-legacy-text-columns.yml",
    "env-deploy-command.yml",
    "pr-test-artifact.yml",
    "pr-test-bootstrap-command-queue.yml",
    "pr-test-deploy.yml",
    "pr-test-destroy-all.yml",
    "pr-test-diagnose-command-queue.yml",
    "pr-test-lifecycle.yml",
    "pr-test-renew-certificates.yml",
]


def _workflow_files():
    """Every workflow file, sorted."""
    return sorted(harness.WORKFLOWS_DIR.glob("*.yml"))


def _matches(pattern):
    """Every match of `pattern` across the workflow directory, with its file."""
    found = []
    for path in _workflow_files():
        for match in pattern.finditer(path.read_text(encoding="utf-8")):
            found.append((path.name, match.group(0)))
    return found


def _enclosing_keys(lines, index):
    """The mapping keys enclosing `lines[index]`, outermost first.

    Walks up by indentation, so it does not care how deep a workflow nests. List
    items are skipped rather than named: a step inside `steps:` reports `steps`,
    which is all the callers here need."""
    keys = []
    indent = len(lines[index]) - len(lines[index].lstrip())
    for line in reversed(lines[:index]):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        here = len(line) - len(line.lstrip())
        if here >= indent:
            continue
        indent = here
        stripped = line.lstrip("- ").strip()
        if stripped.endswith(":"):
            keys.append(stripped[:-1])
        elif ":" in stripped:
            keys.append(stripped.split(":", 1)[0])
        if indent == 0:
            break
    return list(reversed(keys))


def _session_jobs():
    """(workflow, job name, steps) for every job that opens a session."""
    found = []
    for path in _workflow_files():
        parsed = harness.workflow(path.name)
        for job_name, job in (parsed.get("jobs") or {}).items():
            steps = job.get("steps") or []
            if any((step.get("uses") or "") == SESSION_USES for step in steps):
                found.append((path.name, job_name, steps))
    return found


class OneWayInTests(harness.HarnessAssertions, unittest.TestCase):
    """Every session goes through the action, and no workflow rolls its own."""

    def test_no_workflow_authenticates_by_hand(self):
        offenders = []
        for path in _workflow_files():
            text = path.read_text(encoding="utf-8")
            for match in HAND_ROLLED_AUTH.finditer(text):
                offenders.append(f"{path.name}:{harness.line_of(text, match.start())}")

        self.assertEqual(
            [],
            offenders,
            "these reach for the Google Cloud actions directly instead of "
            f"`uses: {SESSION_USES}`. The pair is one thing: authenticate without "
            "setting up the SDK and `gsutil` is not a command several steps later, "
            "in whichever script calls it first.\n  " + "\n  ".join(offenders),
        )

    def test_the_action_is_the_only_place_the_pair_appears(self):
        text = harness.composite_action(SESSION_ACTION)
        names = [step.get("name") for step in harness.action_steps(text)]
        self.assertEqual(["Authenticate to Google Cloud", "Set up Cloud SDK"], names)

    def test_the_expected_workflows_are_the_ones_that_authenticate(self):
        found = sorted({name for name, _, _ in _session_jobs()})
        self.assertEqual(
            AUTHENTICATING_WORKFLOWS,
            found,
            "a workflow started or stopped opening a Google Cloud session. That is "
            "fine, but update AUTHENTICATING_WORKFLOWS here so the count stays a "
            "statement about this repository rather than whatever it happens to be.",
        )

    def test_the_key_comes_from_the_secret_and_is_not_inlined(self):
        offenders = []
        for name, job_name, steps in _session_jobs():
            for step in steps:
                if (step.get("uses") or "") != SESSION_USES:
                    continue
                given = (step.get("with") or {}).get("credentials-json")
                if given != "${{ secrets.GCP_SA_KEY }}":
                    offenders.append(f"{name} job `{job_name}` passes {given!r}")

        self.assertEqual(
            [],
            offenders,
            "a service account key belongs in a secret and nowhere else:\n  "
            + "\n  ".join(offenders),
        )


class TheCheckoutTheActionRequiresTests(harness.HarnessAssertions, unittest.TestCase):
    """The requirement `uses: ./...` adds and the `with:` block cannot state.

    A local action is read off the runner's disk. That makes a prior checkout part
    of the interface, and a sparse one has to name the directory. Both failures look
    identical from the YAML -- valid, reviewed, merged -- and surface as "Can't find
    'action.yml'" in whichever run first exercises the path.
    """

    def test_every_session_job_checks_out_first(self):
        jobs = _session_jobs()
        self.assertNotVacuous(jobs, "no job opens a Google Cloud session any more")

        offenders = []
        for name, job_name, steps in jobs:
            uses = [step.get("uses") or "" for step in steps]
            at = uses.index(SESSION_USES)
            if not any(u.startswith("actions/checkout") for u in uses[:at]):
                offenders.append(f"{name} job `{job_name}`")

        self.assertEqual(
            [],
            offenders,
            "these open a session before checking out, so the action is not on disk "
            "when the runner looks for it:\n  " + "\n  ".join(offenders),
        )

    def test_every_sparse_checkout_reaches_the_action(self):
        offenders = []
        for name, job_name, steps in _session_jobs():
            uses = [step.get("uses") or "" for step in steps]
            at = uses.index(SESSION_USES)
            checkouts = [i for i, u in enumerate(uses[:at]) if u.startswith("actions/checkout")]
            if not checkouts:
                continue
            # The last checkout before the step is the one whose working tree the
            # step sees; an earlier one has been overwritten by it.
            with_block = steps[checkouts[-1]].get("with") or {}
            sparse = with_block.get("sparse-checkout")
            if sparse is None:
                continue
            # A parent entry covers the action. The lists name `.github/actions`
            # rather than each action in turn, so a substring test for the action's
            # own name reports a tree that plainly contains it.
            entries = [entry.strip() for entry in str(sparse).split("\n") if entry.strip()]
            target = SESSION_USES.removeprefix("./")
            if not any(target == entry or target.startswith(entry + "/") for entry in entries):
                offenders.append(f"{name} job `{job_name}`")

        self.assertEqual(
            [],
            offenders,
            f"these check out sparsely without `.github/actions/{SESSION_ACTION}` in "
            "the list, so the checkout succeeds and the action is still missing:\n  "
            + "\n  ".join(offenders),
        )


class GcsBucketFallbackTests(harness.HarnessAssertions, unittest.TestCase):
    """The twelve copies of the bucket-name expression that nothing can collapse."""

    def test_every_copy_is_byte_identical(self):
        self.assertOneShape(
            _matches(BUCKET_FALLBACK),
            "the bucket-name expression",
            "Two spellings of a bucket name means half the pipeline reads from one "
            "bucket and half writes to another.",
        )

    def test_the_expression_only_appears_in_a_job_level_env_block(self):
        """A copy inside a `run:` body is a copy that did not have to exist.

        The job-level copies are load-bearing: GitHub evaluates a job's `env:`
        before any step runs, so the value cannot come from a step output and the
        expression has to be written where it is. A copy inside a step's `run:` has
        no such excuse -- the job it sits in can declare the name once and every
        step in that job can read it. Four of them did, and each was a place the
        expression could drift without the other ten noticing.

        Matched by position rather than by value. The first version of this
        compared each match against the set of job-level `env:` values in the same
        file, which meant one legitimate declaration in one job hid every inline
        copy in every other job of that file -- it passed `pr-test-deploy.yml`
        while line 305 was exactly the thing being looked for."""
        offenders = []
        for path in _workflow_files():
            text = path.read_text(encoding="utf-8")
            lines = text.split("\n")
            for match in BUCKET_FALLBACK.finditer(text):
                index = text.count("\n", 0, match.start())
                keys = _enclosing_keys(lines, index)
                # jobs -> <the job> -> env
                at_job_level = len(keys) >= 3 and keys[-1] == "env" and keys[-3] == "jobs"
                if not at_job_level:
                    offenders.append(f"{path.name}:{index + 1}")

        self.assertEqual(
            [],
            offenders,
            "these spell the bucket expression out somewhere a job-level `env:` entry "
            "would have done, so they drift independently of the ones that have to be "
            "written where they are:\n  " + "\n  ".join(offenders),
        )

    def test_the_fallback_still_has_a_project_in_it(self):
        # The default name is derived, not typed, so that a fork gets its own
        # bucket rather than reaching into this one. Losing either half of the
        # derivation would point every fork at the same place.
        for name, text in _matches(BUCKET_FALLBACK):
            self.assertIn("github.repository_id", text, f"{name} dropped the repository id")
            self.assertIn("secrets.GCP_PROJECT_ID", text, f"{name} dropped the project id")


class DependabotTests(harness.HarnessAssertions, unittest.TestCase):
    """The config that moves the pinned versions.

    Grouping mattered more when nine copies had to move together or fail. With one
    copy the group is no longer load-bearing, but it is still what keeps a bump to
    `auth@v2` and a bump to `setup-gcloud@v2` in one pull request -- and those two
    are a matched pair, so reviewing them apart is reviewing half a change.
    """

    def _actions_ecosystem(self):
        """The `github-actions` entry of the Dependabot config, or None."""
        config = yaml.safe_load(DEPENDABOT_CONFIG.read_text(encoding="utf-8"))
        return next(
            (
                update
                for update in config["updates"]
                if update.get("package-ecosystem") == "github-actions"
            ),
            None,
        )

    def test_dependabot_watches_the_actions(self):
        self.assertTrue(
            DEPENDABOT_CONFIG.exists(),
            "`.github/dependabot.yml` is gone. It is the only thing that notices "
            "when the pinned versions go stale.",
        )
        self.assertIsNotNone(self._actions_ecosystem())

    def test_the_actions_move_as_one_pull_request(self):
        actions = self._actions_ecosystem()
        self.assertIn(
            "groups",
            actions,
            "without a group, Dependabot opens one pull request per action, which "
            "splits the authenticate/setup pair across two reviews.",
        )


class GuardTests(unittest.TestCase):
    """Prove the patterns can fail, rather than trusting that they would."""

    def test_a_hand_rolled_pair_is_caught(self):
        rolled = (
            "      - name: Authenticate to Google Cloud\n"
            "        uses: google-github-actions/auth@v2\n"
        )
        self.assertEqual(1, len(HAND_ROLLED_AUTH.findall(rolled)))

    def test_a_drifted_bucket_name_is_caught(self):
        drifted = (
            "${{ vars.PR_TEST_GCS_BUCKET || "
            "format('rock-pr-{0}-{1}', github.repository_id, secrets.GCP_PROJECT_ID) }}"
        )
        original = _matches(BUCKET_FALLBACK)[0][1]
        self.assertEqual(1, len(BUCKET_FALLBACK.findall(drifted)))
        self.assertNotEqual(original, drifted)


if __name__ == "__main__":
    unittest.main()
