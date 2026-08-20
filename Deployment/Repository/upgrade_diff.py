#!/usr/bin/env python3
"""Report what a Rock upgrade quietly took away, before the trunk moves.

Run this against the outgoing and incoming trunk while both still exist:

    python3 Deployment/Repository/upgrade_diff.py cutover origin/passion-18.4.1 origin/passion-19.3.4

Every other check in the deployment suite re-derives its facts from the current
checkout, which is the right shape for a branch and the wrong shape for a cutover. A
file that moved from committed to generated leaves a perfectly ordinary tree behind;
it is only wrong relative to the version we came from. Three v19 incidents came out of
that -- `RockWeb/Styles/styles-v2/` going 178 tracked files to 1 behind a `*` gitignore,
`Rock.Version/AssemblySharedInfo.cs` being deleted while CI still named it, and item 26's
legacy-column workflow disappearing upstream -- and every one was found in production, by
symptom, weeks apart.

Three findings, chosen because each maps to one of those and none of them needs a
database or a build:

  1. Deleted paths our own tooling still names. Highest signal in the report: a path
     that stopped existing and a workflow, deploy script, runbook or test that still
     points at it. This is the AssemblySharedInfo shape.
  2. Directories that emptied, plus the deleted paths a newly added ignore rule now
     covers. That pairing is the whole diagnosis -- it separates "upstream deleted this"
     from "upstream generates this now", which want opposite responses.
  3. Migrations that repoint site configuration. `UPDATE [Site] SET [Theme]` is how the
     internal site became RockNextGen without anyone choosing it.

This is deliberately not a pull-request gate. It is dispatched by hand at a cutover,
because its whole subject is a comparison between two long-lived branches, and a check
that runs on every PR would spend most of its life comparing a branch to itself.

The exit code is 1 when there is anything to review. Findings are things to decide
about, not necessarily things that are wrong -- a green run means the upgrade moved
nothing this tool knows how to worry about.
"""

import argparse
import pathlib
import re
import subprocess
import sys
from typing import NamedTuple


# Directories whose text is scanned for references to deleted paths. This is the set
# where a stale path name fails silently rather than loudly: a workflow path filter that
# matches nothing still passes, a runbook that names a missing script is only wrong when
# somebody follows it, and a test asserting on a file that is gone tends to be a test
# that was quietly skipped. Application source is deliberately excluded -- the compiler
# already refuses to build against a file that is not there.
REFERENCE_DIRECTORIES = (
    ".github",
    "Deployment",
    "Documentation",
    "Tests",
)

# Read as text for the reference scan. Anything else in those trees is either binary or
# large enough that scanning it costs more than the finding is worth.
TEXT_SUFFIXES = (
    ".yml", ".yaml", ".ps1", ".psm1", ".sh", ".js", ".py", ".md", ".json", ".txt", ".sql",
)

MIGRATIONS_DIRECTORY = "Rock.Migrations/Migrations"

# Trees this fork owns outright. Every one of them is modified relative to upstream by
# design and permanently -- the CI pipeline, the deploy scripts, the runbooks and this
# suite are all Passion's -- so counting them as fork-local edits would put the six that
# matter behind a wall of expected ones. What is left after this filter is the set that
# a trunk merge can silently drop: edits to Rock's own source.
FORK_INFRASTRUCTURE = (
    ".github/",
    "Deployment/",
    "Documentation/",
    "Tests/PrTestEnvironments/",
)
FORK_INFRASTRUCTURE_FILES = (".gitignore",)

# Tables where a migration's write repoints how the application presents itself, which
# is the class of change that produced a visible production surprise and the class a
# fork wants to review one by one.
#
# The set is deliberately tight, and the number behind that is worth keeping: across the
# 65 migrations the real 18.4.1 -> 19.3.4 upgrade added, these three tables are written
# twice in total, while LavaShortcode is written 59 times, DefinedValue 16 and Page 10.
# Widening this to Attribute, AttributeValue and Block -- all defensible on paper -- takes
# the report from two findings to roughly thirty, and a thirty-line report of mostly
# routine migration activity is one that gets skimmed. Widen it deliberately if a future
# upgrade proves the tight set missed something, and move this note with it.
CONFIGURATION_TABLES = ("Site", "Theme", "Layout")

# An optional `dbo.` / `[dbo].` qualifier, because both forms appear in Rock's migrations
# and a pattern that only reads the bare table name silently reports nothing for the
# qualified ones. The trailing (?!\w) is what keeps [SiteDomain] and [LayoutBlock] out.
CONFIGURATION_WRITE = re.compile(
    r"\bUPDATE\s+(?:\[?\w+\]?\s*\.\s*)?\[?("
    + "|".join(CONFIGURATION_TABLES)
    + r")\]?(?!\w)",
    re.IGNORECASE,
)

# How much raw source to summarise a matched statement from, and how wide the summarised
# line may be. Rock writes these across several lines inside `Sql( @"..." )`, so reporting
# the matched line alone reports the word `UPDATE` and nothing that says what it does.
STATEMENT_WINDOW = 400
STATEMENT_WIDTH = 140

# Rock names migrations `<timestamp>_<Name>.cs`, where the timestamp is the value that
# lands in __MigrationHistory and orders the run.
MIGRATION_TIMESTAMP = re.compile(r"^(\d{12,})_")

DEFAULT_MIN_TRACKED = 5
DEFAULT_LOSS_THRESHOLD = 0.9


class EmptiedDirectory(NamedTuple):
    """A directory that lost effectively all of its tracked contents."""

    path: str
    before: int
    after: int
    is_newly_ignored: bool


class IgnoreRule(NamedTuple):
    """One rule, and the .gitignore file it was added to."""

    file: str
    rule: str


class ConfigWrite(NamedTuple):
    """A migration statement that rewrites site configuration."""

    migration: str
    table: str
    line: int
    statement: str


def deleted_paths(old_files, new_files):
    """Paths tracked on the old ref and not on the new one, sorted.

    Only deletions. An upgrade adds thousands of files and listing those would bury the
    handful that matter.
    """
    return sorted(set(old_files) - set(new_files))


def _counts_by_directory(files):
    """Tracked file count for every directory prefix, so a loss can be measured at any
    depth. `a/b/c.cs` counts towards both `a` and `a/b`, because a directory's contents
    include everything beneath it -- measuring only immediate children would miss a tree
    that emptied one level down, which is exactly the styles-v2 shape."""
    counts = {}
    for path in files:
        parts = path.split("/")[:-1]
        for depth in range(1, len(parts) + 1):
            directory = "/".join(parts[:depth])
            counts[directory] = counts.get(directory, 0) + 1
    return counts


def emptied_directories(
    old_files,
    new_files,
    *,
    newly_ignored=frozenset(),
    min_tracked=DEFAULT_MIN_TRACKED,
    loss_threshold=DEFAULT_LOSS_THRESHOLD,
):
    """Directories that lost effectively everything, reported once each.

    `min_tracked` keeps small directories out: a two-file directory going to zero is a
    deletion, and `deleted_paths` already names both files.

    `loss_threshold` is what separates this from ordinary upgrade churn. `RockWeb/Blocks`
    lost 95 of 448 blocks at the 19.3.4 cutover because they were converted to Obsidian,
    and reporting that would train the reader to skim.

    `newly_ignored` is the set of paths a rule added between the refs now covers, from
    `paths_newly_ignored`. It only annotates -- it never decides whether something is
    reported -- but it is the most useful column in the report, because a directory whose
    lost files became ignored has become generated, while one that emptied without that
    was deleted.
    """
    before = _counts_by_directory(old_files)
    after = _counts_by_directory(new_files)

    qualifying = {
        directory: (count, after.get(directory, 0))
        for directory, count in before.items()
        if count >= min_tracked
        and (count - after.get(directory, 0)) / count >= loss_threshold
    }

    # One emptied directory makes every ancestor and every descendant of it look emptied
    # too, so the raw set describes one event many times over. Two passes collapse it.
    #
    # First, drop a directory when some descendant reports the identical before/after
    # pair: the descendant is the more precise statement of the same loss. Without this,
    # a tree whose only content sits three levels down is reported at all four levels.
    most_specific = {
        directory: counts
        for directory, counts in qualifying.items()
        if not any(
            other != directory
            and other.startswith(directory + "/")
            and other_counts == counts
            for other, other_counts in qualifying.items()
        )
    }

    # Then drop anything a surviving ancestor already covers. This only bites when the
    # counts differ -- a parent that lost more than its child did is the bigger story,
    # and reporting both would split one event in two.
    outermost = [
        directory
        for directory in most_specific
        if not any(directory.startswith(other + "/") for other in most_specific)
    ]

    return [
        EmptiedDirectory(
            path=directory,
            before=most_specific[directory][0],
            after=most_specific[directory][1],
            is_newly_ignored=any(
                path == directory or path.startswith(directory + "/")
                for path in newly_ignored
            ),
        )
        for directory in sorted(outermost)
    ]


def _ignore_regex(rule, base):
    """Compile one .gitignore `rule` into a regex over repository-root-relative paths.

    `base` is the directory holding the .gitignore, since a rule is relative to its own
    file -- the reason the previous exact-filename check could not see a rule added to
    the repository root .gitignore covering a path several directories down.

    Supports the forms Rock's ignore files actually use: a trailing slash for
    directory-only, a leading or embedded slash for anchored, `*` and `?` that stop at a
    separator, and `**` that does not. Negations are filtered out before they reach here;
    they un-ignore, which is not what this is looking for.
    """
    directory_only = rule.endswith("/")
    body = rule.rstrip("/")
    anchored = body.startswith("/") or "/" in body.strip("/")
    body = body.lstrip("/")

    expression = []
    index = 0
    while index < len(body):
        if body.startswith("**/", index):
            # Zero or more directories, which is what git means: `a/**/b` matches `a/b`
            # as well as `a/x/b`. Translating it as `.*` requires at least the separator
            # and so misses the zero-directory case entirely.
            expression.append("(?:[^/]+/)*")
            index += 3
        elif body.startswith("**", index):
            expression.append(".*")
            index += 2
        elif body[index] == "*":
            expression.append("[^/]*")
            index += 1
        elif body[index] == "?":
            expression.append("[^/]")
            index += 1
        else:
            expression.append(re.escape(body[index]))
            index += 1

    prefix = re.escape(f"{base}/") if base else ""
    head = prefix + ("" if anchored else "(?:.*/)?") + "".join(expression)
    # A directory rule covers everything beneath it, so it matches as a path prefix. A
    # file rule must end at a separator or the end of the path, or `core.css` would also
    # claim `core.css.map`.
    return re.compile("^" + head + ("/" if directory_only else "(?:/|$)"))


def added_ignore_rules(old_ref, new_ref, repo_root):
    """Every rule a .gitignore gained between the two refs."""
    changed = changed_ignore_files(old_ref, new_ref, repo_root)
    if not changed:
        return ()

    before = _read_at_ref(changed, old_ref, repo_root)
    after = _read_at_ref(changed, new_ref, repo_root)

    added = []
    for path in sorted(changed):
        existing = {line.strip() for line in before.get(path, "").split("\n")}
        for line in after.get(path, "").split("\n"):
            rule = line.strip()
            if not rule or rule.startswith("#") or rule.startswith("!"):
                continue
            if rule in existing:
                continue
            added.append(IgnoreRule(file=path, rule=rule))
    return tuple(added)


def paths_newly_ignored(deleted, added_rules):
    """`{path: IgnoreRule}` for deleted paths a newly added ignore rule now covers.

    This is the Class A signal at its most direct: a file that stopped being tracked *and*
    became ignored in the same span did not get deleted, it became a build output. Reading
    the rules against the paths is what makes that a finding rather than a guess -- the
    check this replaces only noticed a .gitignore sitting in the same directory, so a rule
    added at the repository root covering a path several levels down produced nothing.
    """
    covered = {}
    for entry in added_rules:
        base = entry.file.rsplit("/", 1)[0] if "/" in entry.file else ""
        matcher = _ignore_regex(entry.rule, base)
        for path in deleted:
            if path not in covered and matcher.match(path):
                covered[path] = entry
    return covered


def references_to(paths, corpus):
    """Which sources still name each deleted path, as `{path: [source, ...]}`.

    Paths nobody references are left out entirely. That filter is the point: a major
    upgrade deletes thousands of files and the ones worth a human's attention are the
    ones our own tooling still points at.

    Backslash forms are matched as well as forward-slash ones. Half the deploy tooling is
    PowerShell, and a forward-slash-only match would miss precisely the scripts that
    break hardest when a path goes away.
    """
    found = {}
    for path in paths:
        windows_form = path.replace("/", "\\")
        sources = sorted(
            name
            for name, text in corpus.items()
            if path in text or windows_form in text
        )
        if sources:
            found[path] = sources
    return found


def _summarise_statement(text, start):
    """One line describing the statement at `start`, however it is laid out in source.

    Stops at the closing quote of the SQL literal so the summary does not run on into the
    C# that follows it, then collapses the newlines and indentation Rock writes these
    with. Without this the report's most useful column reads `UPDATE` for exactly the
    multi-line shape the check exists to catch.
    """
    window = text[start:start + STATEMENT_WINDOW]
    end_of_literal = window.find('"')
    if end_of_literal != -1:
        window = window[:end_of_literal]

    collapsed = " ".join(window.split())
    if len(collapsed) > STATEMENT_WIDTH:
        collapsed = collapsed[:STATEMENT_WIDTH].rstrip() + "..."
    return collapsed


def config_writing_migrations(migrations):
    """Statements in `{path: text}` that rewrite one of `CONFIGURATION_TABLES`.

    Matching is on the table alone and never on the `SET` that follows it, because Rock
    writes these inside `Sql( @"..." )` blocks with the table on its own line -- the
    statement this was written for reads `UPDATE [Site]\\nSET [Theme] = ...`, and anything
    anchored on `UPDATE [Site] SET` scans the file and reports nothing.
    """
    writes = []
    for path in sorted(migrations):
        text = migrations[path]
        for match in CONFIGURATION_WRITE.finditer(text):
            # count("\n") and splitlines() disagree: splitlines() also breaks on \x0c,
            # \u2028 and a lone \r, so mixing the two reports one line's number beside a
            # different line's text. Both sides read the same split.
            line_number = text.count("\n", 0, match.start()) + 1
            statement = _summarise_statement(text, match.start())
            writes.append(
                ConfigWrite(
                    migration=path,
                    table=match.group(1),
                    line=line_number,
                    statement=statement,
                )
            )
    return writes


def _is_later(stamp, mark):
    """Whether migration timestamp `stamp` sorts after `mark`.

    Rock's timestamps are `yyyyMMddHHmmssf`, but the pattern accepts shorter ones and
    comparing those as integers compares magnitude rather than time -- a 12-digit 2027
    stamp is numerically smaller than a 15-digit 2026 one, so the newer migration gets
    dropped as already run. Padding to a common width restores chronological order.
    """
    width = max(len(stamp), len(mark))
    return stamp.ljust(width, "0") > mark.ljust(width, "0")


def migrations_after(paths, high_water_mark):
    """Migrations that will actually run, given the target's `__MigrationHistory` high
    water mark.

    Migrations *added between two refs* and migrations *that will run* are different
    sets, and the difference is the one that bit: Rock 18.4.1 already carried the rollup
    that repoints the internal site to RockNextGen. It was added upstream long before the
    cutover and had simply never run here, so a pure ref diff says nothing about it.

    The mark is a value the operator reads out of `__MigrationHistory` and passes in, so
    this tool never needs database access of its own -- which keeps it runnable against
    production's version without holding production's credentials.

    A path whose timestamp cannot be parsed is kept. Erring towards a false positive is
    the whole point: a migration this cannot read is one it must not quietly decide is
    old, since being quietly decided old is how the rollup got missed in the first place.
    """
    if not high_water_mark:
        return list(paths)

    mark = str(high_water_mark).strip()
    kept = []
    for path in paths:
        match = MIGRATION_TIMESTAMP.match(path.split("/")[-1])
        if not match or _is_later(match.group(1), mark):
            kept.append(path)
    return kept


def fork_local_changes(upstream_blobs, fork_blobs):
    """Rock's own files that this fork has edited, as `{path: blob_id}` on each side.

    Only files present on both sides with different content. Additions are the fork's own
    -- the entire CI pipeline is one -- and they cannot be lost to a merge the way an edit
    to an upstream file can. Deletions are upstream's, and `deleted_paths` covers those.

    Modifications are the interesting set because they are the ones a merge resolves *for*
    you. The list this derived was longer than anyone expected: the working belief was
    that the Tabler icon migration's narrowed cursor was the only place the fork changes
    Rock's behaviour, and it is one of six files across two unrelated changes.
    """
    return sorted(
        path
        for path, blob in fork_blobs.items()
        if path in upstream_blobs
        and upstream_blobs[path] != blob
        and not path.startswith(FORK_INFRASTRUCTURE)
        and path not in FORK_INFRASTRUCTURE_FILES
    )


def _git(args, repo_root):
    """Run git in `repo_root` and return its stdout, raising on a non-zero exit.

    Every git call in this module goes through here so a bad ref fails loudly at the
    point it was asked for, rather than as an empty result some check then reads as
    "nothing changed".
    """
    return subprocess.run(
        ["git", "-C", str(repo_root), *args],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def tracked_files(ref, repo_root):
    """Every path git tracks at `ref`."""
    return [line for line in _git(["ls-tree", "-r", "--name-only", ref], repo_root).splitlines() if line]


def tracked_blobs(ref, repo_root):
    """`{path: blob_id}` at `ref`.

    Blob ids rather than contents, because the only question is whether two files differ
    and git has already answered that for every path in the tree. Comparing ids is exact
    and reads the whole tree in one process.
    """
    blobs = {}
    for line in _git(["ls-tree", "-r", ref], repo_root).splitlines():
        if not line:
            continue
        meta, path = line.split("\t", 1)
        blobs[path] = meta.split()[2]
    return blobs


def changed_ignore_files(old_ref, new_ref, repo_root):
    """.gitignore paths added or modified between the refs."""
    out = _git(["diff", "--name-only", f"{old_ref}..{new_ref}", "--", "*.gitignore"], repo_root)
    return {line for line in out.splitlines() if line}


def added_migrations(old_ref, new_ref, repo_root, high_water_mark=None):
    """`{path: text}` for migrations added between the refs, filtered by the mark.

    `.Designer.cs` files are skipped. They are generated model snapshots, they contain no
    hand-written SQL, and they roughly double the file count for nothing.
    """
    out = _git(
        ["diff", "--name-only", "--diff-filter=A", f"{old_ref}..{new_ref}", "--", MIGRATIONS_DIRECTORY],
        repo_root,
    )
    paths = [
        line for line in out.splitlines()
        if line.endswith(".cs") and not line.endswith(".Designer.cs")
    ]
    return _read_at_ref(migrations_after(paths, high_water_mark), new_ref, repo_root)


def reference_corpus(ref, repo_root):
    """`{path: text}` for every text file in `REFERENCE_DIRECTORIES` at `ref`.

    Read at the *new* ref deliberately. The question is whether the tooling as it will
    exist after the cutover still names something that will not.
    """
    paths = [
        path for path in tracked_files(ref, repo_root)
        if path.startswith(tuple(d + "/" for d in REFERENCE_DIRECTORIES))
        and path.endswith(TEXT_SUFFIXES)
    ]
    return _read_at_ref(paths, ref, repo_root)


def _read_at_ref(paths, ref, repo_root):
    """Contents of many paths at one ref, in a single git process.

    `git show` per file would be correct and would also be several hundred processes on
    a corpus this size. `cat-file --batch` reads a request per line and answers with a
    header line then the raw bytes, which is the documented way to do this in bulk.
    """
    if not paths:
        return {}

    request = "".join(f"{ref}:{path}\n" for path in paths)
    completed = subprocess.run(
        ["git", "-C", str(repo_root), "cat-file", "--batch"],
        input=request.encode(),
        capture_output=True,
        check=True,
    )

    contents = {}
    stream = completed.stdout
    offset = 0
    for path in paths:
        newline = stream.index(b"\n", offset)
        header = stream[offset:newline].decode()
        offset = newline + 1
        if header.endswith(("missing", "ambiguous")):
            continue
        size = int(header.split()[2])
        # errors="replace" rather than a decode guess. A stray byte in one runbook should
        # cost that runbook a mangled character, not cost the whole report an exception.
        contents[path] = stream[offset:offset + size].decode("utf-8", errors="replace")
        offset += size + 1
    return contents


def render_report(*, old_ref, new_ref, referenced, emptied, config_writes, newly_ignored=None):
    """The report text and the exit code that goes with it.

    Findings exit 1. This is dispatched by hand before a cutover, so the exit code is
    what shows up as a red run, and a report with findings that exits 0 is the same
    failure shape as `should_run=false` exiting successfully -- which this pipeline has
    now rediscovered more than once.
    """
    lines = [
        f"Upgrade diff: {old_ref} -> {new_ref}",
        "",
    ]

    if referenced:
        lines += [
            "## Deleted paths that tooling still names",
            "",
            "Each of these stopped being tracked on the new ref while a workflow, script,",
            "runbook or test still refers to it. This is the finding that fails silently:",
            "a path filter matching nothing still passes. Ones marked as build output are",
            "the benign case -- the path is generated now, so check the build emits it.",
            "",
        ]
        # A path inside a directory that became generated is not a broken reference --
        # it is a reference to a build output, and the reference is usually the point.
        # Two of the real cutover's findings are the artifact gate checking that the
        # build emitted styles-v2/core.css, which is exactly what that gate is for.
        # Without this note the loudest findings in the report are false alarms.
        generated = tuple(
            entry.path + "/" for entry in emptied if entry.is_newly_ignored
        )

        for path, sources in sorted(referenced.items()):
            note = "  <- build output now; confirm the build emits it" if path.startswith(generated) else ""
            lines.append(f"  {path}{note}")
            for source in sources:
                lines.append(f"      named by {source}")
        lines.append("")

    if emptied:
        lines += [
            "## Directories that emptied",
            "",
            "`generated` means an ignore rule added in the same span covers what the",
            "directory lost, so the contents moved to a build step rather than being",
            "deleted. Those need a build that produces them, not a revert.",
            "",
        ]
        for entry in emptied:
            note = "  <- generated now, a build step must produce these" if entry.is_newly_ignored else ""
            lines.append(f"  {entry.path}: {entry.before} tracked -> {entry.after}{note}")
        lines.append("")

    newly_ignored = newly_ignored or {}
    # Grouped by rule rather than listed per path: styles-v2 alone accounts for 177 of
    # these at the real cutover, and 177 lines saying the same thing is not a finding, it
    # is a wall the reader scrolls past.
    by_rule = {}
    for path in sorted(newly_ignored):
        by_rule.setdefault(newly_ignored[path], []).append(path)

    if by_rule:
        lines += [
            "## Deleted paths that a new ignore rule now covers",
            "",
            "These stopped being tracked and became ignored in the same span, so they are",
            "generated now rather than gone. Each rule needs a build step that emits what it",
            "covers -- this is the shape of change that leaves an ordinary-looking tree.",
            "",
        ]
        for entry in sorted(by_rule):
            covered = by_rule[entry]
            lines.append(f"  {entry.rule}  ({entry.file})")
            lines.append(f"      {len(covered)} path(s), e.g. {covered[0]}")
        lines.append("")

    if config_writes:
        lines += [
            "## Migrations that repoint site configuration",
            "",
            "These rewrite how the application presents itself, and they run without asking.",
            "Read each one and decide before the upgrade, not after: this is the check that",
            "would have caught the internal site being repointed to RockNextGen.",
            "",
        ]
        for write in config_writes:
            lines.append(f"  {write.migration}:{write.line}")
            lines.append(f"      [{write.table}]  {write.statement}")
        lines.append("")

    findings = len(referenced) + len(emptied) + len(config_writes) + len(by_rule)
    if not findings:
        lines += [
            "Nothing to review.",
            "",
            "No deleted path is still named by tooling or newly covered by an ignore rule,",
            "no directory emptied, and no added migration writes to site configuration. That",
            "is a statement about what this tool checks, not a clean bill of health.",
        ]
        return "\n".join(lines), 0

    lines.append(f"{findings} finding(s) to review before moving the trunk.")
    return "\n".join(lines), 1


def _report_fork_local(args):
    """The list Documentation/Fork-Local-Changes.md is derived from.

    Always exits 0. This is a derivation, not a gate -- having fork-local edits is normal
    and expected. What is checked is whether the register still matches, and that check
    lives in the test suite where it runs on its own.
    """
    modified = fork_local_changes(
        tracked_blobs(args.upstream_ref, args.repo_root),
        tracked_blobs(args.fork_ref, args.repo_root),
    )

    print(f"Rock files this fork has edited, {args.upstream_ref} -> {args.fork_ref}")
    print()
    if not modified:
        print("  none")
    for path in modified:
        print(f"  {path}")
    print()
    print(f"{len(modified)} file(s). Each one is something a merge can resolve away.")
    print("Documentation/Fork-Local-Changes.md says why each exists; keep the two in step.")
    return 0


def _add_repo_root(parser):
    """Give `parser` the --repo-root option every subcommand needs."""
    parser.add_argument(
        "--repo-root",
        default=pathlib.Path(__file__).resolve().parents[2],
        type=pathlib.Path,
        help="the Rock checkout to read (default: the one holding this script)",
    )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Report what a Rock upgrade removed, before the trunk moves.",
    )
    subcommands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    cutover = subcommands.add_parser(
        "cutover",
        help="what moving the trunk from one release to the next removes",
        description="What moving the trunk from one release to the next removes.",
    )
    cutover.add_argument("old_ref", help="the outgoing trunk")
    cutover.add_argument("new_ref", help="the incoming trunk")
    cutover.add_argument(
        "--since-migration",
        # Parsed here rather than deep inside migrations_after, so a mistyped mark is
        # argparse's clean "invalid int value" and not a traceback out of the middle of
        # a filter. `migrations_after` still accepts the string form the tests use.
        type=int,
        default=None,
        help=(
            "the target database's highest __MigrationHistory id. Without it, migrations "
            "already present on the old ref but never run are not considered -- which is "
            "the gap that let the internal site's theme repoint through."
        ),
    )
    cutover.add_argument(
        "--min-tracked",
        type=int,
        default=DEFAULT_MIN_TRACKED,
        help=(
            "smallest directory that can be reported as emptied "
            f"(default: {DEFAULT_MIN_TRACKED})"
        ),
    )
    cutover.add_argument(
        "--loss-threshold",
        type=float,
        default=DEFAULT_LOSS_THRESHOLD,
        help=(
            "fraction of a directory's tracked files that must go for it to count as "
            f"emptied (default: {DEFAULT_LOSS_THRESHOLD})"
        ),
    )
    _add_repo_root(cutover)

    fork_local = subcommands.add_parser(
        "fork-local",
        help="Rock's own files this fork has edited",
        description=(
            "List Rock's own files this fork has edited, against an upstream release. "
            "Needs the SparkDevNetwork/Rock remote. This is what "
            "Documentation/Fork-Local-Changes.md is derived from."
        ),
    )
    fork_local.add_argument("upstream_ref", help="the upstream release to measure against")
    fork_local.add_argument(
        "--fork-ref",
        default="HEAD",
        help="the fork side of the comparison (default: HEAD)",
    )
    _add_repo_root(fork_local)

    args = parser.parse_args(argv)

    if args.command == "fork-local":
        return _report_fork_local(args)

    old_files = tracked_files(args.old_ref, args.repo_root)
    new_files = tracked_files(args.new_ref, args.repo_root)
    deleted = deleted_paths(old_files, new_files)
    newly_ignored = paths_newly_ignored(
        deleted, added_ignore_rules(args.old_ref, args.new_ref, args.repo_root)
    )

    report, exit_code = render_report(
        old_ref=args.old_ref,
        new_ref=args.new_ref,
        referenced=references_to(deleted, reference_corpus(args.new_ref, args.repo_root)),
        emptied=emptied_directories(
            old_files,
            new_files,
            newly_ignored=frozenset(newly_ignored),
            min_tracked=args.min_tracked,
            loss_threshold=args.loss_threshold,
        ),
        config_writes=config_writing_migrations(
            added_migrations(args.old_ref, args.new_ref, args.repo_root, args.since_migration)
        ),
        newly_ignored=newly_ignored,
    )

    print(report)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
