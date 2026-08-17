import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PROTECTION_SCRIPT = REPO_ROOT / "Deployment" / "Repository" / "set-trunk-protection.sh"

# The dry run prints the ruleset already in place and then the one it would send.
# Tests that care about the second have to be able to find where it starts.
WOULD_WRITE_MARKER = "Would write:"


def _executable_lines(text):
    """Only what bash runs. This script's header documents how to undo it, which
    means the word DELETE appears in prose long before any write -- and a test that
    reads the comments concludes the dry run mutates the repository."""
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


class TrunkProtectionScriptTests(unittest.TestCase):
    """`passiondev/Rock` has no rulesets and no branch protection: as of 2026-08-17 a
    GET on repos/passiondev/Rock/rulesets returns nothing and the trunk's protection
    endpoint 404s with 'Branch not protected'. Anyone with write can force-push over
    the trunk or delete it outright.

    That matters most at the cutover. The trunk is about to be re-pointed at a new
    branch, several people are working from it, and a force-push that lands during
    that window is the kind of thing nobody notices until the history it overwrote is
    already gone."""

    def setUp(self):
        self.assertTrue(
            PROTECTION_SCRIPT.exists(),
            "there is no set-trunk-protection.sh; protecting the trunk is a click-path "
            "in repository settings that nobody can review or repeat",
        )
        self.text = PROTECTION_SCRIPT.read_text()
        self.code = _executable_lines(self.text)

    def assertMentions(self, needle, why):
        """assertIn prints the whole script into the failure. These get read while
        somebody is mid-cutover, so they stay one line."""
        self.assertTrue(needle in self.text, f"{PROTECTION_SCRIPT.name}: {why} (looked for {needle!r})")

    def test_it_blocks_force_pushes_and_deletion(self):
        """The two things that destroy history. Everything else about the trunk stays
        exactly as it is today."""
        self.assertMentions(
            'type: "non_fast_forward"',
            "the ruleset does not block force-pushes, which is half the point of it",
        )
        self.assertMentions(
            'type: "deletion"',
            "the ruleset does not block deleting the trunk",
        )

    def test_it_does_not_require_pull_request_approvals(self):
        """Deliberate, and the reason is timing. The cutover itself lands commits
        directly on the trunk; a review requirement switched on the day before would
        block the very work it was meant to protect. Approvals are a separate
        decision to take once the dust settles, not a freebie to smuggle in here."""
        for rule in ["required_approving_review_count", '"pull_request"']:
            self.assertFalse(
                rule in self.text,
                f"{PROTECTION_SCRIPT.name}: the ruleset requires pull request review "
                f"({rule!r}); that was explicitly deferred so it cannot block the cutover",
            )

    def test_it_does_nothing_until_apply_is_passed(self):
        """Same shape as every other write in this repository: dry run by default,
        and the run that changes something has to say so."""
        self.assertMentions("--apply", "the script has no --apply flag")
        self.assertMentions(
            'if [ "$APPLY" -eq 0 ]',
            "nothing branches on --apply, so a dry run would write the ruleset anyway",
        )

        # End the block at the first `fi` in column one -- the branch has a nested
        # if/else inside it, and that one is indented.
        after_guard = self.code.split('if [ "$APPLY" -eq 0 ]', 1)[1]
        dry_run_branch = re.split(r"^fi$", after_guard, maxsplit=1, flags=re.MULTILINE)[0]
        self.assertTrue(
            "exit 0" in dry_run_branch,
            f"{PROTECTION_SCRIPT.name}: the dry-run branch does not exit, so it falls "
            f"through into the write it was meant to preview",
        )

    def test_the_dry_run_reaches_for_no_write_verb(self):
        """The whole value of the preview is that running it costs nothing. Anything
        that mutates has to sit after the early exit."""
        preview, _, applying = self.code.partition('if [ "$APPLY" -eq 0 ]')

        for verb in ["--method POST", "--method PUT", "--method DELETE"]:
            self.assertFalse(
                verb in preview,
                f"{PROTECTION_SCRIPT.name}: {verb!r} runs before the dry-run check, so "
                f"a preview would change something",
            )
        self.assertTrue(applying, "the dry-run guard is missing entirely")

    def test_it_reads_the_trunk_from_the_repository_rather_than_hardcoding_it(self):
        """Branch names here do not tell you the Rock version and the trunk is about
        to move. A hardcoded branch name would protect the retired branch and leave
        the new trunk open -- while reporting success."""
        self.assertMentions(
            ".default_branch",
            "the script does not resolve the trunk from the repository, so it would "
            "protect whichever branch was hardcoded when it was written",
        )
        self.assertMentions(
            "~DEFAULT_BRANCH",
            "the ruleset pins a literal branch name, so it would guard the retired "
            "branch once the default moves",
        )

    def test_it_reads_the_ruleset_back_and_checks_what_came_back(self):
        """A write that returns 200 is not proof the rules are in force -- the wrong
        target, or an enforcement left at 'evaluate', both look like success."""
        self.assertMentions(
            'rulesets/$written_id"',
            "the script never re-reads the ruleset it just wrote, so a write that did "
            "not take effect would still look like it worked",
        )
        self.assertTrue(
            re.search(r'if \[ "\$enforcement" != "active" \][\s\S]{0,200}exit 1', self.text),
            f"{PROTECTION_SCRIPT.name}: the read-back is printed but not checked, so a "
            f"ruleset left on 'evaluate' would be reported as protection",
        )

    def test_it_is_rerunnable(self):
        """It will be run at least twice -- once now on the retired trunk, once after
        the default branch moves. The second run must update the ruleset it already
        created rather than stacking a duplicate beside it."""
        self.assertMentions(
            "--method PUT",
            "the script only ever creates, so re-running it after the cutover would "
            "leave two rulesets fighting over the same repository",
        )

    def test_the_existing_ruleset_lookup_cannot_fail_quietly(self):
        """This lookup is the only thing choosing between create and update, and it
        was originally written as `gh api --jq --arg ...` with `|| true` on the end.
        gh's own --jq takes one argument and rejects --arg, so the call failed every
        time, `|| true` turned the failure into an empty string, and the script read
        that as 'no ruleset exists yet' -- taking the create path forever. The PUT
        branch was unreachable while a test that only looked for the string
        '--method PUT' went on passing."""
        lookup = next(
            (line for line in self.code.splitlines() if "existing_id=" in line and "gh api" in line),
            None,
        )
        self.assertIsNotNone(lookup, f"{PROTECTION_SCRIPT.name}: no lookup for an existing ruleset")

        self.assertNotIn(
            "|| true",
            lookup,
            f"{PROTECTION_SCRIPT.name}: the existing-ruleset lookup suppresses its own "
            f"errors, so a broken lookup reads as 'nothing there' and always creates",
        )
        self.assertNotIn(
            "--jq --arg",
            self.code,
            f"{PROTECTION_SCRIPT.name}: `gh api --jq` is being passed --arg, which it "
            f"rejects; pipe into jq instead",
        )

    def test_it_is_executable(self):
        """It is documented as `./set-trunk-protection.sh`. Without the bit set that
        is a confusing permission error at the exact moment somebody is trying to
        close a hole."""
        self.assertTrue(
            PROTECTION_SCRIPT.stat().st_mode & stat.S_IXUSR,
            f"{PROTECTION_SCRIPT.name} is not executable",
        )


@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class TrunkProtectionDryRunTests(unittest.TestCase):
    """Run the script for real against a stubbed `gh`.

    Every earlier test here reads the source as text, and text-matching has already
    let one live bug through: `test_it_is_rerunnable` passed on the string
    '--method PUT' while the branch containing it was unreachable, because the
    lookup that chose between create and update failed on every invocation. Running
    it is the only way to find that class of thing."""

    def _run(self, rulesets, ruleset_detail=None, args=()):
        """Put a fake `gh` at the front of PATH and run the script against it.
        `rulesets` is what the list endpoint returns -- as a list of pages, so
        pagination is exercised rather than assumed."""
        stub_dir = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))

        pages = "".join(json.dumps(page) for page in rulesets)
        detail = json.dumps(ruleset_detail or {})

        stub = stub_dir / "gh"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'args="$*"\n'
            "case \"$args\" in\n"
            "  *--paginate*rulesets)  cat <<'EOF'\n" + pages + "\nEOF\n    ;;\n"
            "  *rulesets/*)           cat <<'EOF'\n" + detail + "\nEOF\n    ;;\n"
            "  *default_branch*)      echo 'passion-18.4.1' ;;\n"
            "  *nameWithOwner*)       echo 'passiondev/Rock' ;;\n"
            "  *)                     echo \"stub gh: unhandled: $args\" >&2; exit 1 ;;\n"
            "esac\n"
        )
        stub.chmod(0o755)

        env = dict(os.environ, PATH=f"{stub_dir}:{os.environ['PATH']}")
        self.stub_dir = stub_dir
        return subprocess.run(
            [str(PROTECTION_SCRIPT), "--repository", "passiondev/Rock", *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=stub_dir,
        )

    def test_the_dry_run_finds_a_ruleset_that_is_not_on_the_first_page(self):
        """The lookup is the only thing choosing between create and update. Unpaginated
        it reads 30 rulesets, and a repository past that number would take the create
        path and post a second ruleset beside the one already there -- two rulesets
        with the same name, and no error anywhere."""
        result = self._run(
            rulesets=[
                [{"id": 1, "name": "Something else"}],
                [{"id": 77, "name": "Trunk history protection"}],
            ],
            ruleset_detail={
                "id": 77,
                "name": "Trunk history protection",
                "enforcement": "active",
                "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}],
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "77",
            result.stdout,
            "the script did not find the existing ruleset on the second page, so a "
            f"re-run would create a duplicate:\n{result.stdout}\n{result.stderr}",
        )

    def test_the_dry_run_shows_the_ruleset_it_would_overwrite(self):
        """A preview that only prints what it is about to send answers half the
        question. The operator is deciding whether to overwrite something, so the
        thing being overwritten has to be on screen next to its replacement."""
        result = self._run(
            rulesets=[[{"id": 77, "name": "Trunk history protection"}]],
            ruleset_detail={
                "id": 77,
                "name": "Trunk history protection",
                "enforcement": "evaluate",
                "rules": [{"type": "deletion"}, {"type": "required_signatures"}],
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "required_signatures",
            result.stdout,
            "the dry run never shows the rules already in place, so an operator cannot "
            f"see what the write would change:\n{result.stdout}",
        )

    def test_a_rule_added_later_survives_a_re_run(self):
        """The script writes a whole ruleset, not a patch. Composing the payload from
        a fixed literal means anything added to that ruleset afterwards -- the
        pull-request review requirement that was deliberately deferred until after
        the cutover, most obviously -- is deleted by the next run, silently, by a
        script whose output says it is protecting the branch."""
        result = self._run(
            rulesets=[[{"id": 77, "name": "Trunk history protection"}]],
            ruleset_detail={
                "id": 77,
                "name": "Trunk history protection",
                "enforcement": "active",
                "rules": [{"type": "deletion"}, {"type": "pull_request"}],
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)

        # Only the payload half of the output. The rule also appears in the
        # "currently in place" dump above it, so scanning the whole of stdout would
        # pass whether or not the payload preserved anything.
        self.assertIn(WOULD_WRITE_MARKER, result.stdout, "the dry run does not label the payload")
        payload = result.stdout.split(WOULD_WRITE_MARKER, 1)[1]

        payload_rules = re.findall(r'"type":\s*"(\w+)"', payload)
        self.assertIn(
            "pull_request",
            payload_rules,
            "a rule already on the ruleset is absent from the payload the script would "
            f"write, so re-running it removes that rule:\n{payload}",
        )
        for required in ["deletion", "non_fast_forward"]:
            self.assertIn(required, payload_rules, f"the payload dropped {required!r}")

    def test_the_dry_run_names_the_rollback_it_would_leave_behind(self):
        """Every other write in this work is dry-run gated and leaves a way back. A
        ruleset write is no different for being a repository setting rather than a
        row: the operator needs the prior state saved before it is replaced, not a
        memory of what the page looked like."""
        result = self._run(
            rulesets=[[{"id": 77, "name": "Trunk history protection"}]],
            ruleset_detail={
                "id": 77,
                "name": "Trunk history protection",
                "enforcement": "active",
                "rules": [{"type": "deletion"}],
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "rollback",
            result.stdout.lower(),
            f"the dry run never mentions a rollback artifact:\n{result.stdout}",
        )

    def test_the_dry_run_writes_nothing_to_disk(self):
        """It runs in a scratch directory here, so anything the script drops shows up
        beside the stub. A preview that leaves a rollback file behind has decided
        something happened when nothing did."""
        result = self._run(rulesets=[[]])
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertIn(
            "create",
            result.stdout.lower(),
            f"with no ruleset present the dry run should describe a create:\n{result.stdout}",
        )

        left_behind = sorted(p.name for p in self.stub_dir.iterdir() if p.name != "gh")
        self.assertEqual(
            left_behind,
            [],
            f"the dry run wrote {left_behind} into the working directory",
        )


if __name__ == "__main__":
    unittest.main()
