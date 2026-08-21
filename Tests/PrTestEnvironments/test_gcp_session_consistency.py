"""Hold the duplicated Google Cloud preamble identical across the workflows.

Card 06 of the 2026-08-21 architecture review counted nine byte-identical
`auth@v2` + `setup-gcloud@v2` pairs and fourteen copies of one bucket-name
expression, and proposed a local composite action to collapse them. Neither
collapse is available, for two separate reasons, and both are worth writing down
because the next reader will propose the same thing.

The auth pair cannot move into a local composite action because `uses: ./...`
loads the action from the checkout. Requiring a checkout is part of the interface
even though nothing in the `with:` block says so, and five of the nine callers do
not meet it: `env-deploy-command.yml` and `pr-test-deploy.yml` authenticate before
they check out, and `db-find-legacy-text-columns.yml`,
`pr-test-diagnose-command-queue.yml` and `pr-test-lifecycle.yml` never check out
at all. A five-line wrapper is not worth a clone of this repository, least of all
in the scheduled teardown.

The bucket expression cannot move into a step output because eleven of its
fourteen uses sit in a job-level `env:` block, which GitHub evaluates before any
step runs. A step output there resolves to the empty string, and every `gsutil`
path silently becomes `gs:///...` -- a deploy that writes nowhere and reports
success.

So the copies stay, and this module holds them together instead. `.github/dependabot.yml`
moves the pinned versions as one grouped pull request. These tests fail if a copy
is edited alone, which is the failure a composite action would have made
impossible and which nothing else in the suite would notice.
"""

import re
import unittest

import pipeline_harness as harness

DEPENDABOT_CONFIG = harness.REPO_ROOT / ".github" / "dependabot.yml"

# Both patterns match raw text rather than parsed YAML on purpose. Parsing would
# normalise away the indentation and key order that make these copies identical,
# and it is drift in exactly those that this module exists to catch.
# The version is matched loosely rather than pinned to `@v2`. Pinning it would
# turn every Dependabot bump red, and worse, a copy bumped by hand would stop
# matching and quietly leave the comparison set instead of showing up as drift.
# Loose, the grouped bump moves all nine at once and stays one shape, while one
# hand-edited copy becomes a second shape and fails.
AUTH_PREAMBLE = re.compile(
    r"[ \t]*- name: [^\n]*\n"
    r"[ \t]*uses: google-github-actions/auth@[^\s]+\n"
    r"(?:[ \t]*[^\n]*\n)*?"
    r"[ \t]*- name: [^\n]*\n"
    r"[ \t]*uses: google-github-actions/setup-gcloud@[^\s]+\n"
)

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


def _matches(pattern):
    """Every match of `pattern` across the workflow directory, with its file."""
    found = []
    for path in sorted(harness.WORKFLOWS_DIR.glob("*.yml")):
        for match in pattern.finditer(path.read_text()):
            found.append((path.name, match.group(0)))
    return found


class GcpAuthPreambleTests(harness.HarnessAssertions, unittest.TestCase):
    """The nine copies of the authentication preamble."""

    def test_every_copy_is_byte_identical(self):
        self.assertOneShape(
            _matches(AUTH_PREAMBLE),
            "the Google Cloud preamble",
            "They have to stay identical, because nothing collapses them.",
        )

    def test_the_expected_workflows_are_the_ones_that_authenticate(self):
        found = sorted({name for name, _ in _matches(AUTH_PREAMBLE)})
        self.assertEqual(
            AUTHENTICATING_WORKFLOWS,
            found,
            "a workflow started or stopped opening a Google Cloud session. That is "
            "fine, but update AUTHENTICATING_WORKFLOWS here so the count stays a "
            "statement about this repository rather than whatever it happens to be.",
        )

    def test_the_key_comes_from_the_secret_and_is_not_inlined(self):
        for name, text in _matches(AUTH_PREAMBLE):
            self.assertIn(
                "credentials_json: ${{ secrets.GCP_SA_KEY }}",
                text,
                f"{name} authenticates with something other than the GCP_SA_KEY "
                "secret. A service account key belongs in a secret and nowhere else.",
            )


class GcsBucketFallbackTests(harness.HarnessAssertions, unittest.TestCase):
    """The fourteen copies of the bucket-name expression."""

    def test_every_copy_is_byte_identical(self):
        self.assertOneShape(
            _matches(BUCKET_FALLBACK),
            "the bucket-name expression",
            "Two spellings of a bucket name means half the pipeline reads from one "
            "bucket and half writes to another.",
        )

    def test_the_fallback_still_has_a_project_in_it(self):
        # The default name is derived, not typed, so that a fork gets its own
        # bucket rather than reaching into this one. Losing either half of the
        # derivation would point every fork at the same place.
        for name, text in _matches(BUCKET_FALLBACK):
            self.assertIn("github.repository_id", text, f"{name} dropped the repository id")
            self.assertIn("secrets.GCP_PROJECT_ID", text, f"{name} dropped the project id")


class DependabotTests(harness.HarnessAssertions, unittest.TestCase):
    """The config that moves the pinned versions, since no action collapses them."""

    def test_dependabot_watches_the_actions(self):
        self.assertTrue(
            DEPENDABOT_CONFIG.exists(),
            "`.github/dependabot.yml` is gone. It is the only thing that notices "
            "when the nine pinned copies of `auth@v2` go stale.",
        )
        import yaml

        config = yaml.safe_load(DEPENDABOT_CONFIG.read_text())
        ecosystems = [update.get("package-ecosystem") for update in config["updates"]]
        self.assertIn("github-actions", ecosystems)

    def test_the_actions_move_as_one_pull_request(self):
        import yaml

        config = yaml.safe_load(DEPENDABOT_CONFIG.read_text())
        actions = next(
            update
            for update in config["updates"]
            if update.get("package-ecosystem") == "github-actions"
        )
        self.assertIn(
            "groups",
            actions,
            "without a group, Dependabot opens one pull request per action and the "
            "nine copies of the preamble move one at a time. Every intermediate "
            "state fails the identical-copies test above, which is a merge queue "
            "that cannot drain.",
        )


class GuardTests(unittest.TestCase):
    """Prove the two patterns can fail, rather than trusting that they would."""

    def test_a_drifted_preamble_is_caught(self):
        drifted = (
            "      - name: Authenticate to Google Cloud\n"
            "        uses: google-github-actions/auth@v3\n"
            "        with:\n"
            "          credentials_json: ${{ secrets.GCP_SA_KEY }}\n"
            "\n"
            "      - name: Set up Cloud SDK\n"
            "        uses: google-github-actions/setup-gcloud@v2\n"
        )
        original = _matches(AUTH_PREAMBLE)[0][1]
        self.assertNotEqual(original, drifted)
        self.assertEqual(1, len(AUTH_PREAMBLE.findall(drifted)))

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
