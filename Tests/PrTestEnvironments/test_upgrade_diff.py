"""A Rock upgrade can move a file from committed to generated, and nothing notices.

Every other check in this suite re-derives its facts from the *current* checkout. That
is the right shape for almost all of them, and it is exactly the wrong shape for a
trunk cutover, because a path that quietly stops existing looks like a perfectly
ordinary tree. It is only wrong relative to the version we came from, and until this
module nothing in CI held that comparison.

Three v19 incidents came out of that one blind spot, each found in production by
symptom rather than by a check:

  RockWeb/Styles/styles-v2/      178 tracked files -> 1, plus a .gitignore of `*`.
                                 Found when the dashboard rendered unstyled.
  Rock.Version/AssemblySharedInfo.cs   deleted; the version moved to Directory.Build.props.
                                 Found when the production version guard read a file
                                 that was not there.
  The legacy-column workflow     deleted upstream (item 26). Found weeks later during
                                 an unrelated audit.

All three are mechanically detectable before the cutover, from nothing but two refs.

The tests here are on the pure functions, fed hand-written file lists, because the
interesting cases are the ones no ref pair in this repository currently exhibits --
a directory that empties to zero, a deleted path named only in a PowerShell string
with backslashes, a migration whose UPDATE spans two lines. Pinning those to real refs
would mean the tests only cover whatever the last upgrade happened to do. One test at
the bottom does run against the real 18.4.1 -> 19.3.4 pair, as a check that the pure
functions are wired to git correctly and still find the incident they were written for.
"""

import ast
import contextlib
import importlib.util
import io
import os
import pathlib
import re
import subprocess
import unittest
from unittest import mock

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
UPGRADE_DIFF = REPO_ROOT / "Deployment" / "Repository" / "upgrade_diff.py"
CI_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "deployment-pipeline-tests.yml"
DISPATCH_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "upgrade-diff.yml"
BUILD_PROPS = REPO_ROOT / "Directory.Build.props"


def _load_upgrade_diff():
    """Imported by path rather than by name. `Deployment/Repository/` is not a package
    and should not become one -- it holds two repository-maintenance tools, and adding
    an `__init__.py` to make an import statement work would be the tail wagging the dog."""
    spec = importlib.util.spec_from_file_location("upgrade_diff", UPGRADE_DIFF)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


upgrade_diff = _load_upgrade_diff()


def _require_ref(ref, reason):
    """Skip when `ref` is missing locally; fail when it is missing in CI.

    A ref-dependent test that skips is indistinguishable from one that passes, and this
    suite exists because a check nobody executes is a comment. Locally a missing ref is a
    fresh or shallow clone and skipping is right. In CI it means the fetch step that is
    supposed to provide it did not, and the honest report of that is red -- otherwise the
    fetch can break and every assertion behind it silently stops running.
    """
    present = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "rev-parse", "--verify", "--quiet", ref],
        capture_output=True, text=True,
    )
    if present.returncode == 0:
        return

    message = f"{ref} is not in this checkout -- {reason}"
    if os.environ.get("GITHUB_ACTIONS"):
        raise AssertionError(message)
    raise unittest.SkipTest(message)


class DeletedPathsTests(unittest.TestCase):
    def test_it_reports_paths_present_before_and_absent_after(self):
        deleted = upgrade_diff.deleted_paths(
            ["a.cs", "b.cs", "c.cs"],
            ["a.cs", "c.cs"],
        )

        self.assertEqual(["b.cs"], deleted)

    def test_added_paths_are_not_deletions(self):
        """The report is about what went away. A cutover adds thousands of files and
        listing them would bury the handful that matter."""
        deleted = upgrade_diff.deleted_paths(["a.cs"], ["a.cs", "new.cs"])

        self.assertEqual([], deleted)

    def test_the_result_is_sorted(self):
        """The report is read by a human and diffed between runs by whoever is doing the
        cutover twice. Set iteration order would make those diffs meaningless."""
        deleted = upgrade_diff.deleted_paths(["z.cs", "a.cs", "m.cs"], [])

        self.assertEqual(["a.cs", "m.cs", "z.cs"], deleted)


class EmptiedDirectoriesTests(unittest.TestCase):
    def test_it_finds_a_directory_that_kept_one_file_of_many(self):
        """The styles-v2 shape, which a pure deletion filter misses entirely: the
        directory still exists and is still tracked, so nothing about it reads as
        removed. 178 files became 1."""
        old = [f"RockWeb/Styles/styles-v2/f{n}.css" for n in range(178)]
        new = ["RockWeb/Styles/styles-v2/.gitignore"]

        emptied = upgrade_diff.emptied_directories(old, new)

        self.assertEqual(1, len(emptied))
        self.assertEqual("RockWeb/Styles/styles-v2", emptied[0].path)
        self.assertEqual(178, emptied[0].before)
        self.assertEqual(1, emptied[0].after)

    def test_a_directory_that_merely_shrank_is_not_reported(self):
        """RockWeb/Blocks lost 95 of 448 .ascx files at the 19.3.4 cutover, because
        blocks were converted to Obsidian. That is a normal upgrade and reporting it
        would train the reader to skim."""
        old = [f"d/f{n}.cs" for n in range(100)]
        new = [f"d/f{n}.cs" for n in range(60)]

        self.assertEqual([], upgrade_diff.emptied_directories(old, new))

    def test_a_tiny_directory_is_not_reported_however_completely_it_empties(self):
        """A two-file directory going to zero is a deletion, and deleted_paths already
        names both files. Reporting it here too is the same finding twice."""
        old = ["d/one.cs", "d/two.cs"]

        self.assertEqual([], upgrade_diff.emptied_directories(old, []))

    def test_one_loss_is_reported_once_at_its_most_specific_directory(self):
        """Every ancestor and every subdirectory of an emptied directory is also emptied,
        so the raw answer to "what emptied" is forty findings describing one event. The
        rule that collapses them: drop a directory when a descendant states the same
        before/after counts, because the descendant is the more precise statement of the
        same fact, then drop anything a surviving ancestor already covers.

        Here `a` and `a/b` both went 20 -> 0 and `a/b` is the directory that actually held
        the files, so `a/b` is the finding. The twenty `a/b/cN` below it hold one file each
        and never qualify."""
        old = [f"a/b/c{n}/f.cs" for n in range(20)]

        emptied = upgrade_diff.emptied_directories(old, [])
        paths = [entry.path for entry in emptied]

        self.assertEqual(["a/b"], paths)

    def test_a_parent_with_a_bigger_loss_than_its_child_is_the_finding(self):
        """The collapse only prefers the descendant when the counts are identical. When
        the parent lost more than the child did, the parent is the bigger story and
        reporting the child as well would split one event into two."""
        old = [f"a/b/f{n}.cs" for n in range(50)] + [f"a/f{n}.cs" for n in range(50)]
        new = [f"a/f{n}.cs" for n in range(5)]

        paths = [entry.path for entry in upgrade_diff.emptied_directories(old, new)]

        self.assertEqual(["a"], paths)

    def test_a_parent_that_does_not_qualify_does_not_hide_a_child_that_does(self):
        """The real styles-v2 case. RockWeb/Styles as a whole kept enough files to stay
        under the threshold while styles-v2 inside it lost everything -- so 'report the
        shallowest' has to mean the shallowest *qualifying* directory, not the shallowest
        ancestor."""
        old = (
            [f"RockWeb/Styles/styles-v2/f{n}.css" for n in range(178)]
            + [f"RockWeb/Styles/keeper{n}.css" for n in range(60)]
        )
        new = [f"RockWeb/Styles/keeper{n}.css" for n in range(60)]

        paths = [entry.path for entry in upgrade_diff.emptied_directories(old, new)]

        self.assertEqual(["RockWeb/Styles/styles-v2"], paths)

    def test_a_new_gitignore_in_the_directory_is_flagged(self):
        """This is the difference between 'upstream deleted this' and 'upstream now
        generates this at build time', and the two want completely different responses.
        Nothing else in the report distinguishes them."""
        old = [f"d/f{n}.cs" for n in range(20)]

        emptied = upgrade_diff.emptied_directories(
            old, [], newly_ignored={"d/f0.cs", "d/f1.cs"}
        )

        self.assertTrue(emptied[0].is_newly_ignored)

    def test_an_unrelated_gitignore_change_is_not_attributed_to_this_directory(self):
        old = [f"d/f{n}.cs" for n in range(20)]

        emptied = upgrade_diff.emptied_directories(
            old, [], newly_ignored={"elsewhere/f0.cs"}
        )

        self.assertFalse(emptied[0].is_newly_ignored)


class PathsNewlyIgnoredTests(unittest.TestCase):
    """The Class A signal at its most direct: a path that stopped being tracked *and*
    became ignored in the same span is generated now, not gone. The first version of this
    check only noticed a .gitignore sitting in the same directory, which meant a rule
    added at the repository root -- the most natural place to put one -- found nothing."""

    def _rule(self, rule, file=".gitignore"):
        return (upgrade_diff.IgnoreRule(file=file, rule=rule),)

    def test_a_root_rule_covers_a_path_several_directories_down(self):
        covered = upgrade_diff.paths_newly_ignored(
            ["RockWeb/Styles/styles-v2/core.css"], self._rule("RockWeb/Styles/styles-v2/")
        )

        self.assertEqual(["RockWeb/Styles/styles-v2/core.css"], list(covered))

    def test_a_rule_is_relative_to_the_gitignore_that_holds_it(self):
        """`*` in RockWeb/Themes/RockNextGen/.gitignore covers that theme and nothing
        else. Reading it as a repository-root rule would mark the whole tree generated."""
        covered = upgrade_diff.paths_newly_ignored(
            ["RockWeb/Themes/RockNextGen/.system", "RockWeb/Themes/Rock/Assets/logo.png"],
            self._rule("*", file="RockWeb/Themes/RockNextGen/.gitignore"),
        )

        self.assertEqual(["RockWeb/Themes/RockNextGen/.system"], list(covered))

    def test_an_unanchored_rule_matches_at_any_depth(self):
        covered = upgrade_diff.paths_newly_ignored(
            ["a/b/c/thing.dll", "thing.dll"], self._rule("*.dll")
        )

        self.assertEqual(["a/b/c/thing.dll", "thing.dll"], sorted(covered))

    def test_a_leading_slash_anchors_a_rule_and_a_trailing_one_does_not(self):
        """Both halves verified against `git check-ignore`, because the two look alike and
        behave differently: a separator at the start or middle anchors the rule, while a
        trailing slash only means directory-only. Reading `build/` as anchored would miss
        every nested match; reading `/build/` as unanchored would claim unrelated trees."""
        paths = ["build/out.js", "vendor/build/out.js"]

        self.assertEqual(
            paths, sorted(upgrade_diff.paths_newly_ignored(paths, self._rule("build/")))
        )
        self.assertEqual(
            ["build/out.js"],
            sorted(upgrade_diff.paths_newly_ignored(paths, self._rule("/build/"))),
        )

    def test_a_file_rule_does_not_claim_a_longer_name(self):
        covered = upgrade_diff.paths_newly_ignored(
            ["core.css.map"], self._rule("core.css")
        )

        self.assertEqual([], list(covered))

    def test_a_star_does_not_cross_a_separator_but_a_double_star_does(self):
        covered = upgrade_diff.paths_newly_ignored(
            ["dist/a.js", "dist/nested/a.js"], self._rule("/dist/*.js")
        )
        self.assertEqual(["dist/a.js"], list(covered))

        deep = upgrade_diff.paths_newly_ignored(
            ["dist/a.js", "dist/nested/a.js"], self._rule("/dist/**/*.js")
        )
        self.assertEqual(["dist/a.js", "dist/nested/a.js"], sorted(deep))

    def test_a_path_no_rule_covers_is_a_real_deletion(self):
        covered = upgrade_diff.paths_newly_ignored(
            ["Rock.Version/AssemblySharedInfo.cs"], self._rule("*.dll")
        )

        self.assertEqual({}, covered)

    def test_a_rule_reports_the_file_it_came_from(self):
        """The report names the .gitignore so the reader can go read the rule in context
        rather than take the tool's word for what it covers."""
        covered = upgrade_diff.paths_newly_ignored(
            ["d/x.css"], self._rule("*", file="d/.gitignore")
        )

        self.assertEqual("d/.gitignore", covered["d/x.css"].file)
        self.assertEqual("*", covered["d/x.css"].rule)


class ReferencesToTests(unittest.TestCase):
    def test_it_finds_a_deleted_path_that_ci_still_names(self):
        """The AssemblySharedInfo.cs shape. The file went away; the path filter and the
        version guard both still named it, and both stayed green."""
        found = upgrade_diff.references_to(
            ["Rock.Version/AssemblySharedInfo.cs"],
            {"deployment-pipeline-tests.yml": "      - 'Rock.Version/AssemblySharedInfo.cs'\n"},
        )

        self.assertEqual(
            {"Rock.Version/AssemblySharedInfo.cs": ["deployment-pipeline-tests.yml"]},
            found,
        )

    def test_a_deleted_path_nobody_references_is_not_reported(self):
        """A major upgrade deletes thousands of files. The ones worth a human's attention
        are the ones our own tooling still points at."""
        found = upgrade_diff.references_to(
            ["Rock/Some/Ordinary/Class.cs"],
            {"a-workflow.yml": "nothing relevant here"},
        )

        self.assertEqual({}, found)

    def test_a_windows_style_path_still_matches(self):
        """Half the deploy tooling is PowerShell, which writes these with backslashes.
        A forward-slash-only match would miss exactly the scripts that break hardest."""
        found = upgrade_diff.references_to(
            ["Deployment/Database/Find-LegacyTextColumns.ps1"],
            {"Deploy-RockEnvironment.ps1": r'$script = "Deployment\Database\Find-LegacyTextColumns.ps1"'},
        )

        self.assertIn("Deployment/Database/Find-LegacyTextColumns.ps1", found)

    def test_each_source_is_listed_once_and_sources_are_sorted(self):
        found = upgrade_diff.references_to(
            ["x/y.cs"],
            {"b.md": "x/y.cs and again x/y.cs", "a.md": "x/y.cs"},
        )

        self.assertEqual({"x/y.cs": ["a.md", "b.md"]}, found)


class ConfigWritingMigrationsTests(unittest.TestCase):
    def test_it_finds_a_site_theme_repoint_written_across_two_lines(self):
        """Verbatim from 202602092251477_UpdateCheckinManagerToNextGen. The statement the
        detector has to catch puts the table on one line and SET on the next, so anything
        anchored on `UPDATE [Site] SET` reads the file and finds nothing."""
        text = 'Sql( @"\nUPDATE [Site]\nSET [Theme] = \'RockManagerNextGen\'\nWHERE [Guid] = \'A5FA\'\n" );'

        writes = upgrade_diff.config_writing_migrations({"202602092251477_X.cs": text})

        self.assertEqual(1, len(writes))
        self.assertEqual("Site", writes[0].table)
        self.assertEqual("202602092251477_X.cs", writes[0].migration)
        # The report's most useful column, and the one a naive implementation gets wrong:
        # reporting only the matched source line reads back the bare word `UPDATE` for
        # exactly the layout this test was written for.
        self.assertEqual(
            "UPDATE [Site] SET [Theme] = 'RockManagerNextGen' WHERE [Guid] = 'A5FA'",
            writes[0].statement,
        )

    def test_the_line_number_points_at_the_statement(self):
        """The report exists to be opened and read. A finding without a line number in a
        two-thousand-line rollup migration is a finding nobody checks."""
        text = "// filler\n// filler\nUPDATE [Site]\n"

        writes = upgrade_diff.config_writing_migrations({"m.cs": text})

        self.assertEqual(3, writes[0].line)

    def test_writes_to_ordinary_tables_are_not_reported(self):
        """Measured against the real 18.4.1 -> 19.3.4 migration set: LavaShortcode alone
        is written 59 times, DefinedValue 16, Page 10. Including them turns a report of
        two findings into a list of a hundred and thirty, which is a list nobody reads."""
        text = "UPDATE [LavaShortcode] SET [Name] = 'x'\nUPDATE [DefinedValue] SET [Value] = 'y'\n"

        self.assertEqual([], upgrade_diff.config_writing_migrations({"m.cs": text}))

    def test_the_table_name_may_be_unbracketed(self):
        writes = upgrade_diff.config_writing_migrations({"m.cs": "UPDATE Site SET [Theme] = 'x'"})

        self.assertEqual("Site", writes[0].table)

    def test_a_table_whose_name_merely_starts_with_a_watched_name_is_not_matched(self):
        """`SiteDomain` and `SiteUrlMap` are real Rock tables and neither is a theme
        repoint. Matching them would be the kind of near-miss that gets a whole report
        dismissed as noisy."""
        self.assertEqual(
            [],
            upgrade_diff.config_writing_migrations({"m.cs": "UPDATE [SiteDomain] SET [Domain] = 'x'"}),
        )

    def test_a_schema_qualified_table_is_matched(self):
        """Rock writes both `UPDATE [Site]` and the schema-qualified forms, and a pattern
        that only reads the bare name reports nothing for the qualified ones -- a miss
        that looks exactly like a clean upgrade."""
        for text in ("UPDATE [dbo].[Site] SET x = 1", "UPDATE dbo.Site SET x = 1"):
            with self.subTest(text=text):
                writes = upgrade_diff.config_writing_migrations({"m.cs": text})

                self.assertEqual(1, len(writes), f"{text!r} was not matched")
                self.assertEqual("Site", writes[0].table)

    def test_a_qualified_lookalike_table_is_still_rejected(self):
        """The schema qualifier must not loosen the boundary that keeps [SiteDomain] out."""
        writes = upgrade_diff.config_writing_migrations({"m.cs": "UPDATE [dbo].[SiteDomain] SET x = 1"})

        self.assertEqual([], writes)

    def test_the_reported_line_and_statement_describe_the_same_line(self):
        """`str.count("\n")` and `str.splitlines()` do not agree: splitlines() also breaks
        on \x0c, \u2028 and a lone \r. Mixing them prints one line's number beside a
        different line's text, which sends the reader to the wrong place in a rollup."""
        text = "header\x0cstill line one\nUPDATE [Site] SET [Theme] = 'x'\n"

        writes = upgrade_diff.config_writing_migrations({"m.cs": text})

        self.assertEqual(2, writes[0].line)
        self.assertEqual("UPDATE [Site] SET [Theme] = 'x'", writes[0].statement)

    def test_a_long_statement_is_truncated_rather_than_flooding_the_report(self):
        text = 'Sql( @"UPDATE [Site] SET [Theme] = \'x\' WHERE [Id] IN (' + ", ".join("1" for _ in range(200)) + ')");'

        writes = upgrade_diff.config_writing_migrations({"m.cs": text})

        self.assertTrue(writes[0].statement.endswith("..."))
        self.assertLessEqual(len(writes[0].statement), upgrade_diff.STATEMENT_WIDTH + 3)

    def test_the_match_is_case_insensitive_on_the_keyword(self):
        writes = upgrade_diff.config_writing_migrations({"m.cs": "update [site] set [Theme] = 'x'"})

        self.assertEqual(1, len(writes))


class MigrationsAfterTests(unittest.TestCase):
    """Migrations added between two refs are not the same set as migrations that will
    run. Rock 18.4.1 already carried the rollup that repoints the internal site to
    RockNextGen -- it was added long before the cutover and had simply never run here.
    Filtering by the target database's high-water mark is what closes that gap, and it
    is a value the operator reads out of __MigrationHistory and passes in, so this tool
    never needs database access of its own."""

    def test_migrations_at_or_below_the_high_water_mark_are_dropped(self):
        kept = upgrade_diff.migrations_after(
            ["Version 18.0/202508051740308_Rollup.cs", "Version 19.0/202602092251477_Next.cs"],
            "202601010000000",
        )

        self.assertEqual(["Version 19.0/202602092251477_Next.cs"], kept)

    def test_a_shorter_timestamp_is_compared_by_date_and_not_by_magnitude(self):
        """The pattern accepts 12 digits and up, and int-comparing across widths compares
        magnitude: a 12-digit 2027 stamp is numerically smaller than a 15-digit 2026 one,
        so a future migration gets dropped as already run. That is precisely the "quietly
        decided old" outcome that let the theme repoint through in the first place."""
        kept = upgrade_diff.migrations_after(
            ["V/202701010000_Future.cs"], "202602092251477"
        )

        self.assertEqual(["V/202701010000_Future.cs"], kept)

    def test_a_shorter_timestamp_genuinely_in_the_past_is_still_dropped(self):
        dropped = upgrade_diff.migrations_after(
            ["V/202501010000_Old.cs"], "202602092251477"
        )

        self.assertEqual([], dropped)

    def test_no_high_water_mark_keeps_everything(self):
        paths = ["Version 18.0/202508051740308_Rollup.cs"]

        self.assertEqual(paths, upgrade_diff.migrations_after(paths, None))

    def test_a_path_with_no_timestamp_is_kept_rather_than_silently_dropped(self):
        """Erring towards a false positive. A migration this tool cannot parse is one it
        must not quietly decide is old -- that is precisely how the rollup got missed."""
        paths = ["Version 19.0/HandWrittenHelper.cs"]

        self.assertEqual(paths, upgrade_diff.migrations_after(paths, "202601010000000"))


class ReportTests(unittest.TestCase):
    def test_a_clean_report_says_so_and_exits_zero(self):
        report, exit_code = upgrade_diff.render_report(
            old_ref="a", new_ref="b", referenced={}, emptied=[], config_writes=[]
        )

        self.assertEqual(0, exit_code)
        self.assertIn("Nothing to review", report)

    def test_findings_make_it_exit_nonzero(self):
        """Dispatched by hand before a cutover, so the exit code is what a human sees as
        a red run. `should_run=false` exiting successfully is the failure shape this
        pipeline keeps rediscovering -- a report with findings must not be green."""
        _, exit_code = upgrade_diff.render_report(
            old_ref="a", new_ref="b",
            referenced={"x/y.cs": ["z.yml"]}, emptied=[], config_writes=[],
        )

        self.assertEqual(1, exit_code)

    def test_the_report_names_the_refs_it_compared(self):
        """It gets pasted into an item in the open-items register. Without the refs it is
        an undated assertion about an unnamed pair of branches."""
        report, _ = upgrade_diff.render_report(
            old_ref="passion-18.4.1", new_ref="passion-19.3.4",
            referenced={}, emptied=[], config_writes=[],
        )

        self.assertIn("passion-18.4.1", report)
        self.assertIn("passion-19.3.4", report)

    def test_a_reference_into_a_now_generated_directory_says_so(self):
        """Run against the real cutover, two of the deleted-path findings are the artifact
        gate checking for `styles-v2/core.css` and `styles-v2/icons/tabler-icon.css`. Both
        are correct and deliberate -- the gate exists to confirm the build emits them. Read
        under a heading about paths that stopped existing they look like broken references,
        and a report whose loudest findings are false alarms is one that gets ignored.

        The cross-reference is what separates the two readings, and it is free: the report
        already knows which directories became generated."""
        report, _ = upgrade_diff.render_report(
            old_ref="a", new_ref="b",
            referenced={"RockWeb/Styles/styles-v2/core.css": ["pr-test-artifact.yml"]},
            emptied=[upgrade_diff.EmptiedDirectory("RockWeb/Styles/styles-v2", 178, 1, True)],
            config_writes=[],
        )

        self.assertIn("<- build output", report)

    def test_a_reference_to_a_genuinely_deleted_path_carries_no_such_note(self):
        """AssemblySharedInfo.cs was deleted outright, not moved behind a build step. If
        every finding carried the reassurance, the reassurance would mean nothing."""
        report, _ = upgrade_diff.render_report(
            old_ref="a", new_ref="b",
            referenced={"Rock.Version/AssemblySharedInfo.cs": ["production-deploy.yml"]},
            emptied=[upgrade_diff.EmptiedDirectory("RockWeb/Styles/styles-v2", 178, 1, True)],
            config_writes=[],
        )

        self.assertNotIn("<- build output", report)

    def test_a_directory_that_emptied_without_becoming_generated_carries_no_note(self):
        """`Rock/Services/NuGet` went to zero at the real cutover with no gitignore -- an
        outright upstream removal. A reference into that is a real broken reference."""
        report, _ = upgrade_diff.render_report(
            old_ref="a", new_ref="b",
            referenced={"Rock/Services/NuGet/thing.cs": ["some-runbook.md"]},
            emptied=[upgrade_diff.EmptiedDirectory("Rock/Services/NuGet", 6, 0, False)],
            config_writes=[],
        )

        self.assertNotIn("<- build output", report)

    def test_newly_ignored_paths_are_grouped_by_rule_rather_than_listed(self):
        """styles-v2 alone contributes 177 of these at the real cutover. Listed one per
        line they would be four fifths of the report and say one thing 177 times, so the
        reader scrolls past the section that most directly names the failure."""
        rule = upgrade_diff.IgnoreRule(file="d/.gitignore", rule="*")
        report, _ = upgrade_diff.render_report(
            old_ref="a", new_ref="b", referenced={}, emptied=[], config_writes=[],
            newly_ignored={f"d/f{n}.css": rule for n in range(177)},
        )

        self.assertIn("177 path(s)", report)
        self.assertIn("d/.gitignore", report)
        self.assertEqual(
            1, report.count("path(s), e.g."),
            "one rule should produce one line, not one per path it covers",
        )

    def test_a_newly_ignored_path_counts_as_a_finding(self):
        """An annotation that never fails is advice. This section is the Class A signal,
        so it has to be able to make the run red on its own."""
        rule = upgrade_diff.IgnoreRule(file=".gitignore", rule="*.css")
        _, exit_code = upgrade_diff.render_report(
            old_ref="a", new_ref="b", referenced={}, emptied=[], config_writes=[],
            newly_ignored={"d/x.css": rule},
        )

        self.assertEqual(1, exit_code)

    def test_every_finding_reaches_the_rendered_text(self):
        report, _ = upgrade_diff.render_report(
            old_ref="a", new_ref="b",
            referenced={"Rock.Version/AssemblySharedInfo.cs": ["deployment-pipeline-tests.yml"]},
            emptied=[upgrade_diff.EmptiedDirectory("RockWeb/Styles/styles-v2", 178, 1, True)],
            config_writes=[upgrade_diff.ConfigWrite("m.cs", "Site", 211, "UPDATE [Site]")],
        )

        self.assertIn("Rock.Version/AssemblySharedInfo.cs", report)
        self.assertIn("deployment-pipeline-tests.yml", report)
        self.assertIn("RockWeb/Styles/styles-v2", report)
        self.assertIn("178", report)
        self.assertIn("m.cs", report)
        self.assertIn("211", report)


class AgainstTheRealCutoverTests(unittest.TestCase):
    """The pure functions above are fed hand-written lists, which proves the logic and
    proves nothing about whether it is wired to git correctly. This runs the real thing
    over the real cutover and asserts it finds the incident it was written for."""

    @classmethod
    def setUpClass(cls):
        cls.refs = ("origin/passion-18.4.1", "origin/passion-19.4.4")
        for ref in cls.refs:
            _require_ref(
                ref,
                "a shallow clone or a fetch that did not include it. The pure-function "
                "tests above still ran.",
            )

    def test_it_reports_styles_v2_as_emptied_and_newly_ignored(self):
        old, new = self.refs
        emptied = upgrade_diff.emptied_directories(
            upgrade_diff.tracked_files(old, REPO_ROOT),
            upgrade_diff.tracked_files(new, REPO_ROOT),
            newly_ignored=frozenset(
                upgrade_diff.paths_newly_ignored(
                    upgrade_diff.deleted_paths(
                        upgrade_diff.tracked_files(old, REPO_ROOT),
                        upgrade_diff.tracked_files(new, REPO_ROOT),
                    ),
                    upgrade_diff.added_ignore_rules(old, new, REPO_ROOT),
                )
            ),
        )

        styles = [entry for entry in emptied if entry.path == "RockWeb/Styles/styles-v2"]

        self.assertEqual(
            1, len(styles),
            "the real 18.4.1 -> 19.4.4 diff no longer reports styles-v2 as emptied. It "
            f"reported: {[entry.path for entry in emptied]}",
        )
        self.assertEqual(178, styles[0].before)
        self.assertTrue(
            styles[0].is_newly_ignored,
            "styles-v2 emptied without a new ignore rule being attributed to it, which "
            "is the annotation that tells the reader it became generated rather than deleted",
        )

    def test_it_finds_the_checkin_manager_theme_repoint(self):
        old, new = self.refs
        added = upgrade_diff.added_migrations(old, new, REPO_ROOT)
        writes = upgrade_diff.config_writing_migrations(added)

        tables = {write.table for write in writes}

        self.assertIn(
            "Site", tables,
            "the real cutover's UpdateCheckinManagerToNextGen migration repoints a site's "
            "theme and the detector no longer sees it",
        )

    def test_the_real_diff_does_not_drown_the_reader(self):
        """A report of two hundred findings is a report nobody reads, and this is the
        number that decides whether the thresholds are set usefully. If a future upgrade
        genuinely trips more than this, that is worth a deliberate look at the thresholds
        rather than a silently enormous report."""
        old, new = self.refs
        emptied = upgrade_diff.emptied_directories(
            upgrade_diff.tracked_files(old, REPO_ROOT),
            upgrade_diff.tracked_files(new, REPO_ROOT),
        )
        writes = upgrade_diff.config_writing_migrations(upgrade_diff.added_migrations(old, new, REPO_ROOT))

        self.assertLess(
            len(emptied) + len(writes), 25,
            f"the real cutover produces {len(emptied)} emptied directories and "
            f"{len(writes)} config writes",
        )


class CommandLineTests(unittest.TestCase):
    """The tuning flags exist for someone reading a report at a cutover who wants a wider
    or narrower view. Exercised end to end here so they are supported surface rather than
    options that merely parse -- an argument nothing ever passes is one that quietly stops
    working."""

    @classmethod
    def setUpClass(cls):
        for ref in ("origin/passion-18.4.1", "origin/passion-19.4.4"):
            _require_ref(ref, "the upgrade-diff fetch step should have provided it")

    def _run(self, argv):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            exit_code = upgrade_diff.main(argv)
        return stdout.getvalue(), exit_code

    def test_a_stricter_loss_threshold_narrows_the_emptied_section(self):
        base = ["cutover", "origin/passion-18.4.1", "origin/passion-19.4.4"]

        default, _ = self._run(base)
        strict, _ = self._run(base + ["--loss-threshold", "1.0"])

        self.assertIn("Rock/Services/NuGet", default)
        self.assertIn("RockWeb/Styles/styles-v2", default)
        # styles-v2 kept one file, so a threshold of exactly 1.0 excludes it while the
        # directories that went to zero stay. If both survive, the flag is not reaching
        # emptied_directories at all.
        self.assertNotIn("RockWeb/Styles/styles-v2:", strict)
        self.assertIn("Rock/Services/NuGet", strict)

    def test_a_larger_minimum_removes_the_emptied_section_entirely(self):
        report, _ = self._run([
            "cutover", "origin/passion-18.4.1", "origin/passion-19.4.4",
            "--min-tracked", "100000",
        ])

        self.assertNotIn("## Directories that emptied", report)

    def test_the_since_migration_filter_drops_migrations_already_run(self):
        """A mark past every added migration must empty that section. Without the flag the
        same run reports the Check-in Manager repoint."""
        base = ["cutover", "origin/passion-18.4.1", "origin/passion-19.4.4"]

        default, _ = self._run(base)
        filtered, _ = self._run(base + ["--since-migration", "202700000000000"])

        self.assertIn("## Migrations that repoint site configuration", default)
        self.assertNotIn("## Migrations that repoint site configuration", filtered)

    def test_a_missing_subcommand_is_an_error_rather_than_a_default(self):
        """Several commands share this entry point and they answer different questions.
        Guessing which was meant is how someone reads a fork-local list as an upgrade report."""
        with self.assertRaises(SystemExit) as raised:
            with contextlib.redirect_stderr(io.StringIO()):
                upgrade_diff.main([])

        self.assertNotEqual(0, raised.exception.code)

    def test_fork_local_accepts_an_explicit_fork_ref(self):
        """Comparing the same ref against itself is the one case with a knowable answer:
        nothing differs, so nothing is fork-local."""
        report, exit_code = self._run(["fork-local", "HEAD", "--fork-ref", "HEAD"])

        self.assertEqual(0, exit_code)
        self.assertIn("none", report)
        self.assertIn("0 file(s)", report)


class TheseTestsActuallyRunInCiTests(unittest.TestCase):
    """`AgainstTheRealCutoverTests` skips itself when the two trunks are not in the
    checkout, which is the right behaviour on a shallow clone and a silent disaster in
    CI: `actions/checkout@v4` fetches only the ref that triggered the run, so without a
    step that fetches the trunks the suite reports OK having checked nothing.

    That is the exact shape this whole workflow exists to prevent -- a guard nobody
    executes is a comment -- so the step that keeps it honest gets a guard of its own."""

    def _fetch_steps(self):
        workflow = yaml.safe_load(CI_WORKFLOW.read_text())
        return [
            step for step in workflow["jobs"]["test"]["steps"]
            if "git fetch" in (step.get("run") or "")
        ]

    def test_the_pipeline_workflow_fetches_both_trunks(self):
        fetching = self._fetch_steps()

        self.assertTrue(
            fetching,
            "no step in deployment-pipeline-tests.yml fetches the trunk branches, so "
            "AgainstTheRealCutoverTests skips on every CI run and this module is only "
            "ever exercised on whichever laptop last ran it by hand",
        )

    def test_the_fetch_reads_the_branch_names_from_the_config(self):
        """Hard-coding them here would make this the tenth place a cutover has to flip,
        and the one nobody would think of -- its only symptom is tests quietly skipping."""
        workflow = yaml.safe_load(CI_WORKFLOW.read_text())
        body = "\n".join(
            step.get("run") or "" for step in workflow["jobs"]["test"]["steps"]
        )

        self.assertIn("pr-test-environments.json", body)
        self.assertIn("baseBranch", body)
        self.assertIn("productionBranch", body)

    def _upstream_fetch_steps(self):
        workflow = yaml.safe_load(CI_WORKFLOW.read_text())
        return [
            step for step in workflow["jobs"]["test"]["steps"]
            if "fetch-upstream" in (step.get("run") or "")
        ]

    def test_the_pipeline_workflow_fetches_the_upstream_releases(self):
        """Each trunk is measured against the upstream tag its own version names, and
        origin carries no tags. Without this step `ForkEditsAcrossTheRealCutoverTests`
        cannot run in CI at all."""
        self.assertTrue(
            self._upstream_fetch_steps(),
            "no step in deployment-pipeline-tests.yml runs `upgrade_diff.py fetch-upstream`, "
            "so the fork-edit tests have no upstream tags to measure the trunks against",
        )

    def test_the_upstream_fetch_names_neither_a_release_nor_the_remote(self):
        """The tool reads each release from the trunk and owns the remote. Writing either
        here makes this a second place a cutover has to remember, and its only symptom
        when forgotten is a fetch of the wrong tag."""
        for step in self._upstream_fetch_steps():
            self.assertIsNone(
                re.search(r"\b\d+\.\d+\.\d+\b", step["run"]),
                f"the {step.get('name')!r} step names a release; the tool reads it from the trunk",
            )
            self.assertNotIn("SparkDevNetwork", step["run"])

    def test_the_upstream_fetch_cannot_fail_the_suite(self):
        """It reaches a network the suite does not control. `_require_ref` turns a fetch
        that stopped working into red tests, so the step itself may fail quietly."""
        for step in self._upstream_fetch_steps():
            self.assertTrue(
                step.get("continue-on-error"),
                f"the {step.get('name')!r} step can fail the whole suite over a network fetch",
            )

    def test_the_fetch_cannot_fail_the_suite(self):
        """An old trunk is deleted eventually, a fork may have neither branch, and the
        upstream fetch reaches the network. Losing those assertions is tolerable; failing
        the other 200-odd tests over it is not. What stops that tolerance from hiding a
        broken fetch is `_require_ref`, which turns the resulting absence into a failure
        in CI -- so the step may fail quietly and the tests behind it may not."""
        for step in self._fetch_steps():
            self.assertTrue(
                step.get("continue-on-error") or "|| true" in step["run"],
                f"the {step.get('name')!r} step can fail the whole suite when a trunk "
                "branch is missing, which is a situation that should cost skipped tests "
                "and nothing else",
            )


class SkipsCannotCreepBackTests(unittest.TestCase):
    """Every ref-dependent test in this module routes its absence check through
    `_require_ref`, which skips locally and fails in CI. Skipping directly from a test
    added later would restore the failure mode this was written to close: CI reporting OK
    having quietly run none of the assertions behind the missing ref."""

    def test_only_the_shared_helper_may_skip(self):
        # Parsed rather than grepped: this module has to talk about skipping in its own
        # prose, and a text scan counts those mentions as violations of the rule they
        # describe. The syntax tree only sees statements that actually raise.
        tree = ast.parse(pathlib.Path(__file__).read_text())

        offenders = set()
        for node in ast.walk(tree):
            if not isinstance(node, ast.FunctionDef) or node.name == "_require_ref":
                continue
            for statement in ast.walk(node):
                if isinstance(statement, ast.Raise) and "SkipTest" in ast.dump(statement):
                    offenders.add(node.name)

        self.assertEqual(
            set(),
            offenders,
            "these tests skip directly instead of calling _require_ref, so in CI they "
            f"will report success without running: {sorted(offenders)}",
        )

    def test_the_helper_fails_rather_than_skips_in_ci(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            with self.assertRaises(AssertionError):
                _require_ref("refs/heads/definitely-not-a-real-ref", "test")

    def test_the_helper_skips_outside_ci(self):
        environment = {key: value for key, value in os.environ.items() if key != "GITHUB_ACTIONS"}
        with mock.patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(unittest.SkipTest):
                _require_ref("refs/heads/definitely-not-a-real-ref", "test")

    def test_a_ref_that_exists_neither_skips_nor_fails(self):
        _require_ref("HEAD", "test")


class DispatchWorkflowTests(unittest.TestCase):
    """The entry point operators actually use. Its logic lives in the module above -- this
    only checks the wiring that a YAML edit can quietly break."""

    def setUp(self):
        self.workflow = yaml.safe_load(DISPATCH_WORKFLOW.read_text())

    def test_it_runs_the_tool_this_module_tests(self):
        """A copy of the logic inlined into the workflow would be a second implementation
        that no test covers, which is how the version guard's sed expression became its
        own separate bug."""
        body = "\n".join(
            step.get("run") or ""
            for job in self.workflow["jobs"].values()
            for step in job["steps"]
        )

        self.assertIn("Deployment/Repository/upgrade_diff.py", body)

    def test_it_is_dispatch_only(self):
        """Its subject is a comparison between two long-lived branches. On a pull request
        it would compare a branch to itself and report nothing, every time, which is a
        reliable way to teach people the report is always empty."""
        triggers = self.workflow.get("on") or self.workflow.get(True)

        self.assertEqual(["workflow_dispatch"], list(triggers))

    def test_it_fetches_the_upstream_releases_before_reporting(self):
        """Without the tags the fork-edit section reports itself unchecked, which counts as
        a finding. Every dispatch would then go red for a reason unrelated to the upgrade."""
        runs = [
            step.get("run") or ""
            for job in self.workflow["jobs"].values()
            for step in job["steps"]
        ]
        fetching = [index for index, run in enumerate(runs) if "fetch-upstream" in run]
        reporting = [index for index, run in enumerate(runs) if "upgrade_diff.py cutover" in run]

        self.assertTrue(fetching, "the dispatch workflow never fetches the upstream tags")
        self.assertTrue(reporting, "the dispatch workflow no longer runs the cutover report")
        self.assertLess(fetching[0], reporting[0])

    def test_the_report_keeps_its_exit_code_through_the_pipe(self):
        """`run:` defaults to `bash -e` without pipefail, so piping the tool into tee
        would report tee's success and turn a report full of findings into a green run --
        the same shape as `should_run=false` exiting successfully."""
        piping = [
            step
            for job in self.workflow["jobs"].values()
            for step in job["steps"]
            if "|" in (step.get("run") or "") and "tee" in (step.get("run") or "")
        ]

        self.assertTrue(piping, "no step pipes the report anywhere -- has it been rewritten?")
        for step in piping:
            self.assertEqual(
                "bash", step.get("shell"),
                f"the {step.get('name')!r} step pipes the tool's output without "
                "`shell: bash`, so it loses pipefail and the exit code with it",
            )


class ForkLocalChangesTests(unittest.TestCase):
    """Which of Rock's own files this fork has edited -- the set that a trunk merge can
    silently drop, and the one nobody had a complete list of.

    The working belief before this was derived was that the narrowed cursor in the Tabler
    icon migration was the only place the fork changes Rock's behaviour. It is not: five
    files carry a fork-local FormBuilder header-image feature, and nothing recorded them.
    A merge that lost those would take a working feature with it and every test would
    stay green, which is item 26's shape exactly."""

    def test_a_file_both_sides_changed_is_fork_local(self):
        modified = upgrade_diff.fork_local_changes(
            {"Rock/A.cs": "aaa", "Rock/B.cs": "bbb"},
            {"Rock/A.cs": "aaa", "Rock/B.cs": "CHANGED"},
        )

        self.assertEqual(["Rock/B.cs"], modified)

    def test_a_file_only_the_fork_has_is_not_a_modification(self):
        """Added files are the fork's own additions -- the whole CI pipeline is one. They
        cannot be lost to a merge conflict the way an edit to an upstream file can, so
        listing them would bury the handful that can."""
        modified = upgrade_diff.fork_local_changes({}, {"Deployment/New.ps1": "x"})

        self.assertEqual([], modified)

    def test_a_file_only_upstream_has_is_not_a_modification(self):
        """Upstream deleting something is the report's other half, and `deleted_paths`
        already covers it."""
        modified = upgrade_diff.fork_local_changes({"Rock/Gone.cs": "x"}, {})

        self.assertEqual([], modified)

    def test_fork_infrastructure_is_excluded(self):
        """The fork owns its CI, deploy scripts, runbooks and test suite outright. They
        are modified relative to upstream by design and permanently, so including them
        would put six real findings behind a wall of expected ones."""
        modified = upgrade_diff.fork_local_changes(
            {
                ".github/PULL_REQUEST_TEMPLATE.md": "a",
                ".gitignore": "a",
                "Rock/Real.cs": "a",
            },
            {
                ".github/PULL_REQUEST_TEMPLATE.md": "CHANGED",
                ".gitignore": "CHANGED",
                "Rock/Real.cs": "CHANGED",
            },
        )

        self.assertEqual(["Rock/Real.cs"], modified)


class DroppedForkEditsTests(unittest.TestCase):
    """What replaced the hand-kept register of fork-local files.

    The register listed every Rock file the fork had edited, and CI failed any pull request
    that touched one until its author added a line -- a list git could already derive,
    enforced on people who had never heard of it. What the register was actually for was
    the merge: knowing which edits an upgrade must not lose. Both trunks' lists are derived
    now, so the only thing left to judge is what disappeared between them."""

    def test_an_edit_the_new_trunk_no_longer_carries_is_reported(self):
        dropped = upgrade_diff.dropped_fork_edits(
            ["Rock/Kept.cs", "Rock/Lost.cs"],
            ["Rock/Kept.cs"],
        )

        self.assertEqual(["Rock/Lost.cs"], dropped)

    def test_a_new_edit_is_not_a_dropped_one(self):
        """Every pull request that edits a Rock file adds one of these. Flagging them is
        what the register's CI check did, and it is the rule this replaced."""
        dropped = upgrade_diff.dropped_fork_edits(
            ["Rock/Kept.cs"],
            ["Rock/Kept.cs", "Rock/New.cs"],
        )

        self.assertEqual([], dropped)

    def test_the_result_is_sorted(self):
        dropped = upgrade_diff.dropped_fork_edits(["z.cs", "a.cs", "m.cs"], [])

        self.assertEqual(["a.cs", "m.cs", "z.cs"], dropped)


class RockVersionTests(unittest.TestCase):
    """Which upstream tag a trunk is measured against. It is read from the trunk itself,
    so a cutover has nothing to update by hand -- the register's header line, which named
    the tag, had to be bumped at every upgrade and had a test of its own to say so."""

    def test_rock_19_reads_directory_build_props(self):
        version = upgrade_diff.rock_version({
            "Directory.Build.props": "<Project>\n  <PropertyGroup>\n    <Version>19.4.4</Version>\n",
        })

        self.assertEqual("19.4.4", version)

    def test_rock_18_reads_assembly_shared_info(self):
        """Production's cutover starts from 18.4.1, which predates Directory.Build.props.
        Reading only the newer file would leave the cutover that matters most unchecked."""
        version = upgrade_diff.rock_version({
            "Rock.Version/AssemblySharedInfo.cs": '[assembly: AssemblyVersion( "18.4.1" )]\n',
        })

        self.assertEqual("18.4.1", version)

    def test_a_tree_that_names_no_version_reads_as_none(self):
        self.assertIsNone(upgrade_diff.rock_version({}))

    def test_head_is_measured_against_the_release_it_builds(self):
        """Wired to git through `_read_at_ref`, on the one ref every checkout has."""
        declared = re.search(r"<Version>([^<]+)</Version>", BUILD_PROPS.read_text()).group(1)

        self.assertEqual(declared, upgrade_diff.release_at("HEAD", REPO_ROOT))


class ForkEditsInTheReportTests(unittest.TestCase):
    def test_a_dropped_edit_is_a_finding(self):
        """Nothing else notices a lost edit. It compiles, every test passes, and the
        feature is simply gone, so this section has to be able to turn the run red."""
        report, exit_code = upgrade_diff.render_report(
            old_ref="a", new_ref="b", referenced={}, emptied=[], config_writes=[],
            dropped_edits=["Rock.Blocks/WorkFlow/FormBuilder/FormBuilderDetail.cs"],
        )

        self.assertEqual(1, exit_code)
        self.assertIn("Rock.Blocks/WorkFlow/FormBuilder/FormBuilderDetail.cs", report)

    def test_it_says_how_to_tell_a_lost_edit_from_an_absorbed_one(self):
        """The report cannot tell the merge taking upstream's side from upstream shipping
        the same change. A diff between the trunks can, so the report gives that command
        with the real refs filled in."""
        report, _ = upgrade_diff.render_report(
            old_ref="origin/passion-19.3.4", new_ref="origin/passion-19.4.4",
            referenced={}, emptied=[], config_writes=[],
            dropped_edits=["Rock/Lost.cs"],
        )

        self.assertIn("git diff origin/passion-19.3.4 origin/passion-19.4.4 --", report)

    def test_a_comparison_that_could_not_run_is_a_finding(self):
        """A check that quietly did not run reads exactly like one that found nothing, and
        "Nothing to review" would then be a claim about fork edits nobody looked at."""
        report, exit_code = upgrade_diff.render_report(
            old_ref="a", new_ref="b", referenced={}, emptied=[], config_writes=[],
            fork_edits_unchecked="upstream tag 19.4.4, which b is built from, is not in this checkout",
        )

        self.assertEqual(1, exit_code)
        self.assertIn("is not in this checkout", report)
        self.assertNotIn("Nothing to review", report)

    def test_a_missing_tag_is_reported_rather_than_raised(self):
        """The rest of the report is still worth reading when the upstream fetch failed,
        so the gap comes back as a reason and the other sections still print."""
        with mock.patch.object(upgrade_diff, "release_at", return_value="0.0.0-not-a-tag"):
            dropped, unchecked = upgrade_diff.fork_edits_across("HEAD", "HEAD", REPO_ROOT)

        self.assertEqual([], dropped)
        self.assertIn("0.0.0-not-a-tag", unchecked)
        self.assertIn("fetch-upstream", unchecked)

    def test_a_ref_that_names_no_version_is_reported_rather_than_raised(self):
        with mock.patch.object(upgrade_diff, "release_at", return_value=None):
            dropped, unchecked = upgrade_diff.fork_edits_across("HEAD", "HEAD", REPO_ROOT)

        self.assertEqual([], dropped)
        self.assertIn("declares no Rock version", unchecked)


class ForkEditsAcrossTheRealCutoverTests(unittest.TestCase):
    """The functions above, wired to git: each trunk's version read at the ref, its tag
    resolved, both sides derived.

    This asserts on the wiring and on what a frozen trunk carried, and deliberately not on
    which edits HEAD carries. Pinning that here would make this test the hand-kept list
    again, failing whoever reverts an edit on purpose."""

    OLD = "origin/passion-18.4.1"
    NEW = "origin/passion-19.4.4"

    @classmethod
    def setUpClass(cls):
        for ref in (cls.OLD, cls.NEW, "refs/tags/18.4.1", "refs/tags/19.4.4"):
            _require_ref(
                ref,
                "the pipeline-tests fetch steps should have provided it; locally, run "
                f"`upgrade_diff.py fetch-upstream {cls.OLD} {cls.NEW}`",
            )

    def test_the_18_trunk_is_measured_against_18_4_1(self):
        self.assertEqual("18.4.1", upgrade_diff.release_at(self.OLD, REPO_ROOT))

    def test_the_comparison_runs(self):
        _, unchecked = upgrade_diff.fork_edits_across(self.OLD, self.NEW, REPO_ROOT)

        self.assertIsNone(unchecked)

    def test_the_old_trunk_is_seen_to_carry_its_fork_edits(self):
        """passion-18.4.1 is frozen, so what it had edited is a fixed fact. If this came
        back empty the comparison would be reading the wrong trees, and every cutover would
        report that nothing was dropped."""
        before = upgrade_diff.fork_local_changes(
            upgrade_diff.tracked_blobs("refs/tags/18.4.1", REPO_ROOT),
            upgrade_diff.tracked_blobs(self.OLD, REPO_ROOT),
        )

        self.assertIn("Rock.Blocks/WorkFlow/FormBuilder/FormBuilderDetail.cs", before)
