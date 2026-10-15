"""One reader for the Rock version a checkout declares.

Two deploy guards refuse a deploy whose Rock minor does not match what the target
is already running: production-deploy.yml against the branch `productionBranch`
pins, staging-deploy.yml against the catalog the pr-* fleet shares. Rock migrates
its database on the first request after a deploy, so both of them are the last
thing between a mismatched artifact and an irreversible migration.

Each one read the version itself. They probed the two candidate files in opposite
orders, with different sed expressions, and each carried a comment explaining why
its own order was the correct one -- production's pinned oldest-first by
test_environment_deploy.py, staging's pinned newest-first by a test in
test_staging_catalog_version_guard.py asserting the exact opposite. Neither test
failed, because on this tree only one of the two files exists and any order
returns the same answer. The disagreement was real and the tree was hiding it.

Settling it: props first. The orders differ only where both files carry a version,
and the way that happens here is a 19.x tree that still has an
AssemblySharedInfo.cs -- one plausible build fix away, since Rock.Client,
Rock.Mandrill and CheckScannerUtility still <Compile Include> the file Rock 19
deleted and pr-test-artifact.yml works around it by excluding the project. Under
oldest-first, that tree reads 18.x: production refuses every deploy, and staging
matches an 18.x pin and lets a 19.x artifact migrate the 18.x catalog, which is
the incident the staging guard was written after.

The oldest-first argument was that 18.x ships a Directory.Build.props carrying no
<Version>, so the historical path has to be probed first for an 18.x ref to answer
18.x. True premise, and the conclusion does not follow: with no <Version> to find,
props-first falls through to the attribute and answers 18.x too.

These tests run the reader rather than matching its source. A shape assertion is
what both guards already had, and what they had was two shapes.
"""

import pathlib
import re
import shlex
import tempfile
import unittest

import yaml

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
READER = REPO_ROOT / ".github" / "scripts" / "rock-version.sh"
# The two places Rock has declared its version across this upgrade, named here so
# the tests below can check the reader against whichever one this branch really
# carries rather than against a fixture that can drift from it.
BUILD_PROPS = REPO_ROOT / "Directory.Build.props"
ASSEMBLY_INFO = REPO_ROOT / "Rock.Version" / "AssemblySharedInfo.cs"

WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
ACTION_DIR = REPO_ROOT / ".github" / "actions"
SCRIPT_DIR = REPO_ROOT / ".github" / "scripts"
PRODUCTION_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "production-deploy.yml"
STAGING_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "staging-deploy.yml"

# The 18.x props really does exist; it just carries no <Version>. Reproducing that
# is the point -- it is the whole of why an 18.x ref still answers 18.x under a
# props-first order.
PROPS_WITHOUT_VERSION = (
    "<Project>\n"
    "  <PropertyGroup>\n"
    "    <LangVersion>latest</LangVersion>\n"
    "  </PropertyGroup>\n"
    "</Project>\n"
)


def props_with_version(version):
    """Rock 19's props, including the two neighbours that also say "Version"."""
    return (
        "<Project>\n"
        "  <!-- Versioning information -->\n"
        "  <PropertyGroup>\n"
        f"    <Version>{version}</Version>\n"
        f"    <InformationalVersion>Rock McKinley {version.rsplit('.', 1)[0]}</InformationalVersion>\n"
        "    <FileVersion>$(Version)</FileVersion>\n"
        "  </PropertyGroup>\n"
        "</Project>\n"
    )


def assembly_info(version):
    """The 18.x file, with the same two misleading neighbours."""
    return (
        "// The AssemblyVersion number should change only when we are\n"
        "// shipping a new major or minor release.\n"
        f'[assembly: AssemblyVersion( "{version}" )]\n'
        f'[assembly: AssemblyFileVersion( "{version}" )]\n'
        f'[assembly: AssemblyInformationalVersion( "Rock McKinley {version.rsplit(".", 1)[0]}" )]\n'
    )


def write_tree(root, props=None, attribute=None):
    """Lay out a throwaway checkout carrying either declaration, or both."""
    root = pathlib.Path(root)
    if props is not None:
        (root / "Directory.Build.props").write_text(props)
    if attribute is not None:
        version_path = root / "Rock.Version" / "AssemblySharedInfo.cs"
        version_path.parent.mkdir(parents=True, exist_ok=True)
        version_path.write_text(attribute)


def run_reader(script, cwd):
    """Source the reader and run `script`, the way both guard steps do.

    Pipefail and `$GITHUB_WORKSPACE` are not decoration: they are what the guards
    run under, and the reader has to behave under both -- a `| head -1` inside it
    would fail a whole deploy on sed's SIGPIPE only when pipefail is set. Neither
    guard is given `-u`, so neither is this.

    Returns `(exit code, stdout, stdout + stderr)`. The split matters: the version
    is the stdout, and everything the run log shows is the combined stream.
    """
    result = harness.run_bash(
        f'. "$GITHUB_WORKSPACE/.github/scripts/rock-version.sh"\n{script}\n', cwd=cwd
    )
    return result.returncode, result.stdout.strip(), result.output


class ReaderAnswersTests(unittest.TestCase):
    def test_a_v19_tree_answers_from_the_build_props(self):
        with tempfile.TemporaryDirectory() as workdir:
            write_tree(workdir, props=props_with_version("19.4.4"))
            code, version, output = run_reader("rock_version_of_tree", workdir)

        self.assertEqual(0, code, output)
        self.assertEqual("19.4.4", version, output)
        self.assertIn(
            "Directory.Build.props",
            output,
            f"the reader did not say which file answered:\n{output}",
        )

    def test_an_18x_tree_answers_from_the_assembly_attribute(self):
        """The props exists on 18.x too and carries no version, so the reader has to
        fall through it rather than stop at it. A reader that stopped would refuse
        every 18.x deploy -- and the guards are least dispensable mid-upgrade,
        when one line is on each side of the comparison."""
        with tempfile.TemporaryDirectory() as workdir:
            write_tree(
                workdir,
                props=PROPS_WITHOUT_VERSION,
                attribute=assembly_info("18.4.1"),
            )
            code, version, output = run_reader("rock_version_of_tree", workdir)

        self.assertEqual(0, code, output)
        self.assertEqual("18.4.1", version, output)
        self.assertIn("AssemblySharedInfo.cs", output, output)

    def test_a_stale_assembly_attribute_does_not_outvote_the_build_props(self):
        """The case the two readers disagreed about, and the only one where the
        order decides anything. A 19.x tree that still carries an 18.x attribute is
        a 19.x tree: three .csproj files on this branch still <Compile Include> the
        file Rock 19 deleted, so someone restoring it to fix the build is a likely
        next commit rather than a thought experiment.

        Answering 18.4.1 here is not a wrong label. It is a 19.x artifact matching
        an 18.x pin on the staging guard, which migrates the shared catalog."""
        with tempfile.TemporaryDirectory() as workdir:
            write_tree(
                workdir,
                props=props_with_version("19.4.4"),
                attribute=assembly_info("18.4.1"),
            )
            code, version, output = run_reader("rock_version_of_tree", workdir)

        self.assertEqual(0, code, output)
        self.assertEqual("19.4.4", version, output)

    def test_a_tree_that_declares_nothing_refuses(self):
        """An unreadable version is a refusal at both call sites, so it must never
        arrive as an empty string that compares equal to nothing. Both halves are
        checked: the non-zero status the guards branch on, and the empty stdout --
        a reader that printed an empty line and exited 0 would wave every deploy
        through while looking like it had answered."""
        with tempfile.TemporaryDirectory() as workdir:
            write_tree(workdir, props=PROPS_WITHOUT_VERSION)
            code, version, output = run_reader("rock_version_of_tree", workdir)

        self.assertNotEqual(0, code, f"a tree declaring no version was accepted:\n{output}")
        self.assertEqual("", version, f"the reader answered with something:\n{output}")
        self.assertIn(
            "::error::",
            output,
            "the reader failed without a GitHub error annotation, so the reason is "
            f"only visible to someone reading the raw log:\n{output}",
        )

    def test_the_pattern_reads_the_version_and_nothing_else(self):
        """Both formats bury the real version among lines that also say "version".
        `<FileVersion>$(Version)</FileVersion>` is the sharp one: it is a real line
        in Rock 19's props, and the looser `<Version>\\([^<]*\\)` the production
        guard used to carry reports the literal string "$(Version)" from it. A
        guard comparing that against a minor refuses forever."""
        cases = {
            "19.4.4": props_with_version("19.4.4"),
            "19.0.3": props_with_version("19.0.3"),
            "18.4.1": assembly_info("18.4.1"),
            "17.6.1": assembly_info("17.6.1"),
        }
        for expected, text in cases.items():
            with self.subTest(version=expected):
                with tempfile.TemporaryDirectory() as workdir:
                    candidate = pathlib.Path(workdir) / "declaration"
                    candidate.write_text(text)
                    code, version, output = run_reader(
                        "rock_version_of_file declaration", workdir
                    )
                self.assertEqual(0, code, output)
                self.assertEqual(
                    expected,
                    version,
                    f"the pattern is over-broad; it read {version!r}:\n{output}",
                )

    def test_the_reader_answers_the_version_this_checkout_declares(self):
        """Every case above builds its own fixture, so all of them would still pass
        if the real declaration moved -- which is exactly what happened between
        18.4.1 and 19.3.4. Read this checkout with the reader and require it to
        agree with what the checkout actually says.

        Whichever file this branch declares it in, so the check cannot drift and
        cannot become a FileNotFoundError at the next cutover."""
        declarations = [
            (BUILD_PROPS, r"<Version>\s*([0-9][0-9.]*)\s*</Version>"),
            (ASSEMBLY_INFO, r'AssemblyVersion\(\s*"([0-9][0-9.]*)"\s*\)'),
        ]
        declared = None
        for path, pattern in declarations:
            if not path.exists():
                continue
            match = re.search(pattern, path.read_text())
            if match:
                declared = match.group(1)
                break

        self.assertIsNotNone(
            declared,
            f"neither {BUILD_PROPS.name} nor {ASSEMBLY_INFO} declares a Rock version "
            "in a form this test can read; the guards would refuse every deploy",
        )

        code, version, output = run_reader("rock_version_of_tree", REPO_ROOT)

        self.assertEqual(0, code, f"the reader could not read this checkout:\n{output}")
        self.assertEqual(
            declared,
            version,
            f"the reader reads a different version out of this checkout than it "
            f"declares ({declared}):\n{output}",
        )


class LineAndMinorTests(unittest.TestCase):
    """What part of a version each guard compares, answered in one place.

    The two guards read the version through the reader above and then sliced it
    themselves: staging with `${version%%.*}`, which keeps the major, and
    production with `${version%.*}`, which drops the last part. Both were commented
    as comparing "the minor". Only production's does -- staging's is the line, and
    test_staging_catalog_version_guard.py has allowed 18.4.1 -> 18.5.0 since the
    guard was written. Two slices that look alike and mean different things are
    how that went unread, so the reader names both and each guard calls the one it
    means.

    The expected values are worked by hand, not derived: a test that split the
    version in Python to get its answer would agree with any reader that split it
    the same wrong way."""

    # (version, its line, its minor)
    VERSIONS = (
        ("19.4.4", "19", "19.4"),
        ("18.4.1", "18", "18.4"),
        # A trunk can be named for a two-part version -- TRUNK_BRANCH_PATTERN in
        # test_base_branch_config.py allows passion-19.4 -- and production's old
        # `${version%.*}` sliced that to "19", the line, while calling it the minor.
        ("19.4", "19", "19.4"),
    )

    # Nothing either declaration has ever carried, and nothing a guard should
    # compare. "19" is here on purpose: a bare major has no minor, and a reader that
    # produced one has misread something, so the line is not answered either.
    NOT_VERSIONS = ("", "19", "19.", "19..4", ".19.4", "v19.4.4", "19.4.4-beta", "$(Version)")

    # (branch, the version it is named for)
    BRANCHES = (
        ("passion-19.4.4", "19.4.4"),
        ("passion-18.4.1", "18.4.1"),
        ("passion-19.4", "19.4"),
    )

    # Branches that are not named for a version. `develop` and `staging` are real
    # branches here that declare 19.0.3 and 17.6.1 -- nothing about their names
    # says so. A suffix is refused rather than trimmed: the guard reading the pin
    # refuses when it cannot tell, and passion-19.4.4-anything is a name it would
    # have to guess at.
    NOT_VERSION_BRANCHES = (
        "",
        "develop",
        "staging",
        "passion-19",
        "passion-19.x",
        "passion-19.4.4-hotfix",
        "fix/passion-19.4.4",
        "Passion-19.4.4",
    )

    def assertAnswers(self, call, expected):
        code, answer, output = run_reader(call, REPO_ROOT)
        self.assertEqual(0, code, output)
        self.assertEqual(expected, answer, output)

    def assertRefuses(self, call):
        """The same refusal rock_version_of_tree makes: non-zero, nothing on stdout,
        and a GitHub annotation saying why. An empty answer with a zero status
        would compare equal to another empty answer and wave a deploy through."""
        code, answer, output = run_reader(call, REPO_ROOT)
        self.assertNotEqual(0, code, f"{call} answered instead of refusing:\n{output}")
        self.assertEqual("", answer, f"{call} refused but still answered:\n{output}")
        self.assertIn("::error::", output, f"{call} refused without an annotation:\n{output}")

    def test_the_line_of_a_version_is_its_major(self):
        for version, line, _ in self.VERSIONS:
            with self.subTest(version=version):
                self.assertAnswers(f"rock_line_of_version {shlex.quote(version)}", line)

    def test_the_minor_of_a_version_is_its_major_and_minor(self):
        for version, _, minor in self.VERSIONS:
            with self.subTest(version=version):
                self.assertAnswers(f"rock_minor_of_version {shlex.quote(version)}", minor)

    def test_something_that_is_not_a_version_has_no_line_or_minor(self):
        for text in self.NOT_VERSIONS:
            for function in ("rock_line_of_version", "rock_minor_of_version"):
                with self.subTest(function=function, text=text):
                    self.assertRefuses(f"{function} {shlex.quote(text)}")

    def test_a_branch_answers_the_version_it_is_named_for(self):
        for branch, version in self.BRANCHES:
            with self.subTest(branch=branch):
                self.assertAnswers(f"rock_version_of_branch {shlex.quote(branch)}", version)

    def test_a_branch_not_named_for_a_version_refuses(self):
        for branch in self.NOT_VERSION_BRANCHES:
            with self.subTest(branch=branch):
                self.assertRefuses(f"rock_version_of_branch {shlex.quote(branch)}")


class NobodyElseReadsTheVersionTests(harness.HarnessAssertions, unittest.TestCase):
    """The reader is only one reader while nothing else grows a second one.

    Derived rather than listed. A hand-kept list of the readers that existed when
    this was written is what the tree already had -- two of them, each pinned by a
    test naming only itself, neither test able to see the other.
    """

    # How a Rock version is spelled where it is declared. Anything reaching for one
    # of these outside the reader is reading a version, whatever it does with it.
    DECLARATIONS = ("AssemblyVersion(", "<Version>")

    # Keyed on the line as written, because what is excused is the line and not the
    # file around it. Empty today: the sweep found nothing when the reader was
    # extracted, and an entry here is the argument for why a second reader is
    # allowed to exist.
    ALLOWED = {}

    @staticmethod
    def label(path):
        """Repo-relative where that means anything. The plant below lives in a
        temporary directory, and a sweep that could only name files inside the
        repository could not be handed one."""
        try:
            return path.relative_to(REPO_ROOT).as_posix()
        except ValueError:
            return path.name

    @classmethod
    def run_blocks(cls, path):
        """`(step name, body)` for every `run:` block in a workflow or action."""
        parsed = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        groups = list((parsed.get("jobs") or {}).values())
        runs = parsed.get("runs") or {}
        if runs.get("steps"):
            groups.append(runs)
        for group in groups:
            for step in group.get("steps") or []:
                if step.get("run"):
                    yield step.get("name") or "(unnamed)", step["run"]

    @classmethod
    def readers_in(cls, workflows, actions, scripts):
        """Every line outside the reader that names a version declaration.

        Comments are skipped. Several of them quote a declaration to explain the
        reader, including the reader's own header, and a sweep that could not tell
        prose from code would be answered by deleting the prose.
        """
        found = []
        for path in list(workflows) + list(actions):
            for name, body in cls.run_blocks(path):
                for line in body.splitlines():
                    stripped = line.strip()
                    if stripped.startswith("#"):
                        continue
                    if any(mark in stripped for mark in cls.DECLARATIONS):
                        found.append(f"{cls.label(path)} :: {name} :: {stripped}")
        for path in scripts:
            if path == READER:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#") or stripped.startswith("//"):
                    continue
                if any(mark in stripped for mark in cls.DECLARATIONS):
                    found.append(f"{cls.label(path)}:{number} :: {stripped}")
        return found

    def setUp(self):
        self.workflows = sorted(WORKFLOW_DIR.glob("*.yml"))
        self.actions = sorted(ACTION_DIR.glob("*/action.yml"))
        self.scripts = sorted(p for p in SCRIPT_DIR.rglob("*") if p.is_file() and p.suffix in (".sh", ".ps1", ".py", ".js"))
        self.assertNotVacuous(self.workflows, "there are no workflows to sweep")
        self.assertNotVacuous(self.scripts, "there are no workflow scripts to sweep")

    def test_no_second_reader_has_grown(self):
        offenders = [
            hit
            for hit in self.readers_in(self.workflows, self.actions, self.scripts)
            if hit.split(" :: ", 2)[-1] not in self.ALLOWED
        ]

        self.assertEqual(
            [],
            offenders,
            "a Rock version is being read somewhere other than "
            ".github/scripts/rock-version.sh. Two readers is what this file exists "
            "to stop: they drifted into opposite probe orders and stayed that way "
            "because the tree carries only one of the two files they read. Source "
            "the reader instead, or add the line to ALLOWED with the reason:\n  "
            + "\n  ".join(offenders),
        )

    def test_the_sweep_catches_a_second_reader(self):
        """Handed a workflow that reads the version itself, the sweep has to say so.
        The plant is the production guard's own retired reader, so this fails if
        the sweep stops recognising the thing it was written to find."""
        retired = (
            """          version_of() {\n"""
            """            sed -n 's/.*AssemblyVersion( *"\\([^"]*\\)".*/\\1/p' "$1" | head -1\n"""
            """          }\n"""
        )
        with tempfile.TemporaryDirectory() as workdir:
            planted = pathlib.Path(workdir) / "planted.yml"
            planted.write_text(
                "name: Planted\non: workflow_dispatch\njobs:\n  plant:\n"
                "    runs-on: ubuntu-latest\n    steps:\n"
                "      - name: Read the version itself\n        run: |\n" + retired
            )
            offenders = self.readers_in([planted], [], [])

        self.assertTrue(offenders, "the sweep did not report a reader it was handed")

    def test_a_declaration_quoted_in_a_comment_is_not_read_as_a_reader(self):
        """The reader's header quotes both declarations to explain itself, and so do
        several workflow comments. If prose counted, the cheapest way to pass this
        file would be to delete the reasoning -- so check that at least one comment
        naming a declaration survives the sweep."""
        mentions = 0
        for path in self.workflows + self.scripts + [READER]:
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                stripped = line.strip()
                if not (stripped.startswith("#") or stripped.startswith("//")):
                    continue
                if any(mark in stripped for mark in self.DECLARATIONS):
                    mentions += 1

        self.assertTrue(
            mentions,
            "no comment anywhere quotes a version declaration, so this check proves "
            "nothing about the sweep skipping comments",
        )
        self.assertEqual([], self.readers_in(self.workflows, self.actions, self.scripts))


class BothGuardsReadThroughItTests(unittest.TestCase):
    """The two callers, named rather than derived -- there is no property of a
    workflow that says "this one compares a Rock minor", and the sweep above is
    what covers the ones nobody thought of."""

    GUARDS = {
        "production-deploy.yml": (
            PRODUCTION_WORKFLOW,
            "Refuse a ref from a different Rock version",
        ),
        "staging-deploy.yml": (
            STAGING_WORKFLOW,
            "Refuse a Rock minor change on the shared catalog",
        ),
    }

    def guard_body(self, path, step_name):
        """A missing step fails in `harness.step` -- which, here, means that deploy no
        longer guards the Rock version at all."""
        return harness.step(yaml.safe_load(path.read_text(encoding="utf-8")), step_name)["run"]

    def test_each_guard_sources_the_reader(self):
        for name, (path, step_name) in self.GUARDS.items():
            with self.subTest(workflow=name):
                body = self.guard_body(path, step_name)
                self.assertIn(
                    '. "$GITHUB_WORKSPACE/.github/scripts/rock-version.sh"',
                    body,
                    f"{name} no longer sources the shared reader",
                )
                self.assertRegex(
                    body,
                    r"rock_version_of_(tree|file)",
                    f"{name} sources the reader without calling it",
                )

    def test_the_reader_is_addressed_through_the_workspace(self):
        """Not style. The guards run with the checkout as their working directory,
        but the tests run them against fixture trees, and a relative source path
        would resolve to the fixture and fail there -- which would push the tests
        back to matching the guard's text instead of running it."""
        for name, (path, step_name) in self.GUARDS.items():
            with self.subTest(workflow=name):
                body = self.guard_body(path, step_name)
                self.assertNotRegex(
                    body,
                    r"^\s*\.\s+[\"']?\.github/scripts/rock-version\.sh",
                    f"{name} sources the reader by a relative path",
                )


if __name__ == "__main__":
    unittest.main()
