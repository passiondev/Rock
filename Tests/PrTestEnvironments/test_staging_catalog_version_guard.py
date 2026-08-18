"""The staging deploy must refuse a Rock *minor* change while it is still sharing
the sandbox catalog with the pr-* fleet.

Written after the 2026-08-18 v19 staging deploy. `vars.STAGING_DB_NAME` was never
set, so `db_name` resolved empty and fell back to the prod-derived shared catalog
(`DB_NAME_SOURCE: shared sandbox fallback (secrets.DB_NAME)` in run 32127109855).
Rock migrates at Application_Start, so a 19.3.4 artifact pointed at an 18.4.1
catalog started migrating it the moment IIS served the first request. A core EF
migration then died on `The data types text and nvarchar are incompatible in the
equal to operator`, which rolled back that one migration and left every migration
before it committed -- a catalog stranded between two minors, and the shared one.

pr-test-deploy.yml already refuses this. staging-deploy.yml carried the invariant
only as a header comment and a `::warning::`, and a warning does not stop a deploy.

The guard is tested by *running* it rather than by matching the YAML, because what
matters is the exit code for a given combination of catalog and version -- a shape
assertion would have passed against a guard that printed the right words and
exited 0."""

import os
import pathlib
import re
import subprocess
import tempfile
import unittest

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGING_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "staging-deploy.yml"
PR_TEST_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-test-deploy.yml"
# Both places Rock has declared its version across this upgrade. 18.4.1 uses the
# assembly attribute; 19.3.4 deleted that file and moved to <Version> in
# Directory.Build.props. The guard has to read whichever the branch it is deploying
# actually has -- the cutover it protects is the same commit that moves this.
BUILD_PROPS = REPO_ROOT / "Directory.Build.props"
ASSEMBLY_INFO = REPO_ROOT / "Rock.Version" / "AssemblySharedInfo.cs"
LAYOUTS = ("props", "assemblyinfo")

GUARD_STEP_NAME = "Refuse a Rock minor change on the shared catalog"


def _guard_script():
    """Pull the guard's `run:` block out of the workflow so the test executes the
    same text CI does. Keyed to the step *name* rather than a line range so the
    step can move within the job without silently unhooking the test."""
    workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())
    for job in workflow["jobs"].values():
        for step in job.get("steps", []):
            if step.get("name") == GUARD_STEP_NAME:
                return step["run"]
    raise AssertionError(
        f"no step named {GUARD_STEP_NAME!r} in {STAGING_WORKFLOW.name}; "
        "the staging deploy no longer guards the shared catalog"
    )


def _write_version(workdir, version, layout):
    """Lay out a throwaway tree the way the named branch really looks.

    The `props` case writes the 18.4.1-shaped Directory.Build.props alongside it --
    that file exists on 18.4.1 too, it just carries no <Version>. Reproducing that
    is the point: it is what makes "props first, attribute second" resolve both
    branches instead of one."""
    root = pathlib.Path(workdir)
    if layout == "props":
        (root / "Directory.Build.props").write_text(
            "<Project>\n  <PropertyGroup>\n"
            f"    <Version>{version}</Version>\n"
            "    <FileVersion>$(Version)</FileVersion>\n"
            "  </PropertyGroup>\n</Project>\n"
        )
    elif layout == "assemblyinfo":
        (root / "Directory.Build.props").write_text(
            "<Project>\n  <PropertyGroup>\n"
            "    <LangVersion>latest</LangVersion>\n"
            "  </PropertyGroup>\n</Project>\n"
        )
        version_path = root / "Rock.Version" / "AssemblySharedInfo.cs"
        version_path.parent.mkdir(parents=True)
        version_path.write_text(
            "using System.Reflection;\n"
            f'[assembly: AssemblyVersion( "{version}" )]\n'
            f'[assembly: AssemblyFileVersion( "{version}" )]\n'
        )
    else:
        raise AssertionError(f"unknown layout {layout!r}")


def _run_guard(version, pinned_branch, staging_db_name, layout="assemblyinfo"):
    """Run the guard against a throwaway version file. Returns (exit code, output)."""
    script = _guard_script()

    with tempfile.TemporaryDirectory() as workdir:
        _write_version(workdir, version, layout)

        env = dict(os.environ)
        env["PINNED_BASE_BRANCH"] = pinned_branch
        env["STAGING_DB_NAME"] = staging_db_name
        env["GITHUB_OUTPUT"] = str(pathlib.Path(workdir) / "github_output")

        completed = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            cwd=workdir,
            env=env,
            capture_output=True,
            text=True,
        )
        return completed.returncode, completed.stdout + completed.stderr


class StagingCatalogVersionGuardTests(unittest.TestCase):
    def test_same_minor_on_the_shared_catalog_is_allowed(self):
        """The steady state. Everything on the shared catalog is one minor, which is
        what makes sharing it safe at all."""
        for layout in LAYOUTS:
            with self.subTest(layout=layout):
                code, output = _run_guard("18.4.1", "passion-18.4.1", "", layout)
                self.assertEqual(code, 0, f"a same-minor staging deploy was refused:\n{output}")

    def test_a_patch_bump_within_the_pinned_minor_is_allowed(self):
        """18.4.1 -> 18.5.0 does not cross a minor, so it does not migrate the
        catalog onto a version the pr-* fleet cannot read. Blocking this would make
        the guard a blanket freeze on staging, and a guard that stops ordinary work
        gets switched off."""
        for layout in LAYOUTS:
            with self.subTest(layout=layout):
                code, output = _run_guard("18.5.0", "passion-18.4.1", "", layout)
                self.assertEqual(code, 0, f"an in-minor staging deploy was refused:\n{output}")

    def test_a_minor_change_on_the_shared_catalog_is_refused(self):
        """The 2026-08-18 deploy, exactly. This is the case the guard exists for."""
        for layout in LAYOUTS:
            with self.subTest(layout=layout):
                code, output = _run_guard("19.3.4", "passion-18.4.1", "", layout)
                self.assertNotEqual(
                    code,
                    0,
                    "a 19.x artifact was allowed onto the shared 18.x catalog -- this is "
                    f"the deploy that stranded the sandbox catalog between two minors:\n{output}",
                )
                self.assertIn("19", output)
                self.assertIn("18", output)

    def test_a_minor_change_is_allowed_once_staging_owns_its_catalog(self):
        """The escape hatch, and the whole point of failing in this direction: the
        way past the guard is to give staging its own database, which is the
        documented migration path off the shared catalog rather than a bypass."""
        for layout in LAYOUTS:
            with self.subTest(layout=layout):
                code, output = _run_guard("19.3.4", "passion-18.4.1", "RockStaging19", layout)
                self.assertEqual(
                    code,
                    0,
                    f"staging was refused a v19 deploy onto its own dedicated catalog:\n{output}",
                )

    def test_an_unreadable_version_file_refuses_rather_than_waves_through(self):
        """A guard that cannot tell which minor it is deploying must not assume the
        safe answer. Renaming or reformatting AssemblySharedInfo.cs would otherwise
        turn this into a no-op that still reports success on every run."""
        script = _guard_script()
        with tempfile.TemporaryDirectory() as workdir:
            env = dict(os.environ)
            env["PINNED_BASE_BRANCH"] = "passion-18.4.1"
            env["STAGING_DB_NAME"] = ""
            env["GITHUB_OUTPUT"] = str(pathlib.Path(workdir) / "github_output")
            completed = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", script],
                cwd=workdir,
                env=env,
                capture_output=True,
                text=True,
            )
        output = completed.stdout + completed.stderr
        self.assertNotEqual(
            completed.returncode,
            0,
            f"the guard passed with no version file at all, so it would pass against "
            f"a renamed one too:\n{output}",
        )
        # Exit code alone does not pin this. Deleting the file check leaves sed to
        # fail the script on its own, which still exits non-zero -- the mutation
        # survives an exit-code-only assertion. What is lost is the annotation: the
        # run fails with "sed: can't read ..." buried in the log instead of a
        # GitHub error surfaced on the run.
        self.assertIn(
            "::error::",
            output,
            "the guard failed without a GitHub error annotation, so the reason is "
            f"only visible to someone reading the raw log:\n{output}",
        )

    def test_an_unreadable_pin_refuses_rather_than_waves_through(self):
        """Same argument for the other input. If the step that reads the fleet's
        pinned branch fails or returns empty, the guard has nothing to compare
        against and must not treat that as agreement."""
        code, output = _run_guard("19.3.4", "", "")
        self.assertNotEqual(
            code, 0, f"the guard passed with no pinned branch to compare against:\n{output}"
        )
        # Also exit-code-invisible: drop the check and an empty pin falls into the
        # mismatch branch, where "19" != "" refuses anyway -- but it refuses by
        # reporting a version mismatch against a catalog minor it never read,
        # telling whoever is on the deploy to go fix the wrong thing.
        self.assertIn(
            "pinned Rock minor",
            output,
            f"the guard did not say the pin was the unreadable part:\n{output}",
        )
        self.assertNotIn(
            "would land on the sandbox catalog",
            output,
            "the guard reported a version mismatch it never established, because it "
            f"compared against an empty pin:\n{output}",
        )

    def test_the_guard_reads_a_version_this_repository_actually_declares(self):
        """_run_guard fabricates the version file, so every test above would still
        pass if the real one moved -- which is exactly what happened between 18.4.1
        and 19.3.4. Run the guard against the real tree and require it to agree with
        the version this branch really declares."""
        declared = None
        if BUILD_PROPS.exists():
            match = re.search(r"<Version>\s*([0-9][0-9.]*)\s*</Version>", BUILD_PROPS.read_text())
            if match:
                declared = match.group(1)
        if declared is None and ASSEMBLY_INFO.exists():
            match = re.search(r'AssemblyVersion\(\s*"([0-9][0-9.]*)"\s*\)', ASSEMBLY_INFO.read_text())
            if match:
                declared = match.group(1)

        self.assertIsNotNone(
            declared,
            f"neither {BUILD_PROPS.name} nor {ASSEMBLY_INFO} declares a Rock version in a "
            "form the guard can parse; the guard would refuse every staging deploy",
        )

        script = _guard_script()
        env = dict(os.environ)
        env["PINNED_BASE_BRANCH"] = f"passion-{declared}"
        env["STAGING_DB_NAME"] = ""
        env["GITHUB_OUTPUT"] = os.devnull
        completed = subprocess.run(
            ["bash", "-eo", "pipefail", "-c", script],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        output = completed.stdout + completed.stderr
        self.assertEqual(
            completed.returncode,
            0,
            f"the guard could not read the version this branch declares ({declared}):\n{output}",
        )
        self.assertIn(declared, output, f"the guard reported a version other than {declared}:\n{output}")

    def test_a_props_version_wins_over_a_stale_assembly_attribute(self):
        """Both files can coexist mid-cutover. Directory.Build.props is the newer
        declaration, so a leftover attribute must not out-vote it -- reading the
        stale one would let a 19.x artifact look like 18.x and walk straight past
        the guard, which is the failure this whole change exists to stop."""
        script = _guard_script()
        with tempfile.TemporaryDirectory() as workdir:
            _write_version(workdir, "19.3.4", "props")
            stale = pathlib.Path(workdir) / "Rock.Version" / "AssemblySharedInfo.cs"
            stale.parent.mkdir(parents=True)
            stale.write_text('[assembly: AssemblyVersion( "18.4.1" )]\n')

            env = dict(os.environ)
            env["PINNED_BASE_BRANCH"] = "passion-18.4.1"
            env["STAGING_DB_NAME"] = ""
            env["GITHUB_OUTPUT"] = str(pathlib.Path(workdir) / "github_output")
            completed = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", script],
                cwd=workdir,
                env=env,
                capture_output=True,
                text=True,
            )
        output = completed.stdout + completed.stderr
        self.assertNotEqual(
            completed.returncode,
            0,
            f"a stale 18.4.1 attribute masked the real 19.3.4 version in props:\n{output}",
        )

    def test_the_guard_runs_before_anything_is_built_or_deployed(self):
        """A guard that runs after the build still costs 30 minutes, and one that
        runs after the deploy costs the catalog. It has to sit in the job the build
        and deploy jobs both wait on."""
        workflow = yaml.safe_load(STAGING_WORKFLOW.read_text())
        jobs = workflow["jobs"]

        guard_jobs = [
            name
            for name, job in jobs.items()
            if any(step.get("name") == GUARD_STEP_NAME for step in job.get("steps", []))
        ]
        self.assertEqual(len(guard_jobs), 1, f"expected exactly one guard step, found in {guard_jobs}")
        guard_job = guard_jobs[0]

        def needs_of(name):
            needs = jobs[name].get("needs", [])
            return [needs] if isinstance(needs, str) else needs

        for downstream in ("build", "deploy"):
            self.assertIn(
                guard_job,
                needs_of(downstream),
                f"the {downstream} job does not wait on {guard_job}, so the guard cannot stop it",
            )


class CatalogVariablesStayDecoupledTests(unittest.TestCase):
    """Before 2026-08-18 one variable moved both: pr-test-deploy.yml read
    vars.STAGING_DB_NAME, so the variable documented as staging's actually moved the
    whole pr-* fleet -- and staging is where a new Rock minor is supposed to be tried
    first, which left nowhere to try it. PR #13 split them.

    The split is the thing that makes a staging-first v19 rehearsal possible at all, so
    it is worth more than a comment. These pin each side to its own variable."""

    def test_staging_passes_its_own_variable(self):
        text = STAGING_WORKFLOW.read_text()

        self.assertIn("db_name: ${{ vars.STAGING_DB_NAME }}", text)

        # Comments stripped for the same reason as below, and here it is not
        # hypothetical: the header names PR_TEST_DB_NAME on purpose, because an
        # operator reading it needs to know which variable moves the other side.
        code = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
        self.assertNotIn(
            "PR_TEST_DB_NAME",
            code,
            "staging reads the fleet's catalog variable",
        )

    def test_the_pr_fleet_passes_its_own_variable(self):
        text = PR_TEST_WORKFLOW.read_text()

        self.assertIn("vars.PR_TEST_DB_NAME", text)

        # Comments are stripped: pr-test-deploy.yml explains the 2026-08-18 split in
        # prose that has to name the variable it stopped reading.
        code = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
        self.assertNotIn(
            "vars.STAGING_DB_NAME",
            code,
            "the pr-* fleet reads staging's catalog variable again; setting "
            "STAGING_DB_NAME would move the whole fleet with it",
        )

    def test_the_staging_header_does_not_still_describe_the_coupling(self):
        """The header block is where an operator looks before setting the variable. It
        described the pre-split behaviour -- "staging and every pr-* site move together
        onto that catalog" -- for as long as the split existed. Getting that backwards
        during a version rehearsal is how two Rock minors end up on one catalog, which
        is the exact failure the split exists to prevent.

        Pinned as "the header must name both variables" rather than as an exact
        sentence, so it survives rewording but not a return to describing one variable
        as moving everything."""
        header = STAGING_WORKFLOW.read_text().split('"on":', 1)[0]

        self.assertIn("STAGING_DB_NAME", header)
        self.assertIn(
            "PR_TEST_DB_NAME",
            header,
            "the header explains which catalog staging lands on without mentioning "
            "the variable that moves the pr-* fleet, so it reads as though one "
            "variable still moves both",
        )


if __name__ == "__main__":
    unittest.main()
