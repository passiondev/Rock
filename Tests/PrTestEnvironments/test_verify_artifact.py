import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPO_ROOT / "Deployment" / "Repository" / "verify-artifact.sh"
BUILD_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ptp-14803-build-artifact.yml"


def _class(fullname, body):
    """One top-level type, in the shape ikdasm emits: the `.class` line and the
    closing brace both at column 0, everything between them indented."""
    return (
        f".class public auto ansi beforefieldinit {fullname}\n"
        f"       extends [mscorlib]System.Object\n"
        f"{{\n{body}\n}} // end of class {fullname}\n"
    )


# The unrelated type that makes the CI string scan useless. This is real: the shipped
# Rock.ViewModels.dll has three types owning a HeaderImage member, and two of them
# have nothing to do with Form Builder.
DECOY = _class(
    "Rock.ViewModels.Event.InteractiveExperiences.ExperiencePlaceholderStyleBag",
    "  .field private class Rock.ViewModels.Utility.ListItemBag "
    "'<HeaderImage>k__BackingField'\n"
    "  .property instance class Rock.ViewModels.Utility.ListItemBag HeaderImage()",
)

PATCHED_VIEWMODELS = DECOY + _class(
    "Rock.ViewModels.Blocks.WorkFlow.FormBuilder.FormGeneralViewModel",
    "  .field private string '<Name>k__BackingField'\n"
    "  .field private class Rock.ViewModels.Utility.ListItemBag "
    "'<HeaderImage>k__BackingField'",
)

UNPATCHED_VIEWMODELS = DECOY + _class(
    "Rock.ViewModels.Blocks.WorkFlow.FormBuilder.FormGeneralViewModel",
    "  .field private string '<Name>k__BackingField'",
)


def _blocks(methods, filler_lines=0):
    body = methods + "\n" + "\n".join(
        f"    IL_{i:04x}:  nop" for i in range(filler_lines)
    )
    return _class("Rock.Blocks.Workflow.FormBuilder.FormBuilderDetail", body)


# ikdasm wraps a long signature, so the method NAME lands on its own indented
# continuation line rather than on the `.method` line. Reproduced here because a
# fixture that puts the name on the `.method` line would pass against a checker that
# could not cope with the real output.
PATCHED_METHODS = (
    "  .method private hidebysig static class "
    "[Rock.ViewModels]Rock.ViewModels.Utility.ListItemBag\n"
    "          GetHeaderImageViewModel([Rock]Rock.Model.WorkflowType workflowType,\n"
    "                                  class [Rock]Rock.Data.RockContext ctx) cil managed\n"
    "  {\n"
    "  } // end of method FormBuilderDetail::GetHeaderImageViewModel\n"
    "  .method private hidebysig static void\n"
    "          SaveHeaderImageAttributeValue([Rock]Rock.Model.WorkflowType wt) cil managed\n"
    "  {\n"
    "  } // end of method FormBuilderDetail::SaveHeaderImageAttributeValue"
)

UNPATCHED_METHODS = (
    "  .method public hidebysig instance void GetEntityBag() cil managed\n"
    "  {\n"
    "  } // end of method FormBuilderDetail::GetEntityBag"
)


class VerifyArtifactScriptTests(unittest.TestCase):
    """The build workflow's own string scan is labelled "necessary but not sufficient",
    and points at this script for the part it cannot do. That pointer was dead for a
    while, which is worse than having no pointer: it reads as though the authoritative
    check exists and someone ran it."""

    def setUp(self):
        self.assertTrue(
            VERIFY_SCRIPT.exists(),
            "verify-artifact.sh is missing, and ptp-14803-build-artifact.yml tells "
            "the operator to run it before deploying",
        )
        self.text = VERIFY_SCRIPT.read_text()

    def test_the_build_workflow_points_at_a_path_that_exists(self):
        """The comment names the script by path. If either moves without the other,
        the operator is sent to a file that is not there, at the point in the process
        where they are deciding whether to deploy."""
        workflow = BUILD_WORKFLOW.read_text()
        rel = VERIFY_SCRIPT.relative_to(REPO_ROOT).as_posix()
        self.assertIn(
            rel,
            workflow,
            f"{BUILD_WORKFLOW.name} does not reference {rel}; the pointer and the "
            f"script have drifted apart",
        )

    def test_it_is_executable(self):
        self.assertTrue(
            os.access(VERIFY_SCRIPT, os.X_OK),
            "verify-artifact.sh is not executable",
        )

    def test_it_reads_metadata_rather_than_scanning_bytes(self):
        """The entire reason it exists. A rewrite that reached for `strings` would
        pass every test that only checks the exit code, and would be exactly as blind
        as the scan it replaces."""
        self.assertIn(
            "ikdasm",
            self.text,
            "the script no longer disassembles anything, so it cannot tell which type "
            "owns a name -- which is the only thing it was for",
        )


@unittest.skipUnless(shutil.which("bash"), "bash is not installed")
class VerifyArtifactBehaviourTests(unittest.TestCase):
    """Run the script for real against a stubbed disassembler.

    Reading it as text cannot catch what actually broke it first time: `grep -q`
    closes the pipe at the first match, the writer takes SIGPIPE, and `set -o
    pipefail` turns a successful match into a failed check. It passed on the small
    type and failed on the large one, so any fixture under 64K would have missed it."""

    def _deploy_set(self, blocks_il, viewmodels_il, formbuilder_js="headerImage",
                    entryform_js="col-md-12"):
        root = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))

        # Nested one level down, the way the artifact actually extracts.
        base = root / "ptp-14803-deploy-set-999"
        (base / "bin").mkdir(parents=True)
        obs = base / "Obsidian" / "Blocks" / "WorkFlow"
        (obs / "FormBuilder").mkdir(parents=True)
        (obs / "WorkflowEntry" / "Actions").mkdir(parents=True)

        (base / "bin" / "Rock.Blocks.dll").write_text("not a real assembly")
        (base / "bin" / "Rock.ViewModels.dll").write_text("not a real assembly")
        (obs / "FormBuilder" / "formBuilderDetail.obs.js").write_text(formbuilder_js)
        (obs / "WorkflowEntry" / "Actions" / "entryForm.obs.js").write_text(entryform_js)
        (base / "manifest.json").write_text('{\n  "sha": "abc123",\n  "ref": "refs/heads/x"\n}')

        stub = root / "ikdasm"
        blocks_f, vm_f = root / "blocks.il", root / "viewmodels.il"
        blocks_f.write_text(blocks_il)
        vm_f.write_text(viewmodels_il)
        stub.write_text(
            "#!/usr/bin/env bash\n"
            "case \"$1\" in\n"
            f"  *Rock.Blocks.dll)     cat {blocks_f} ;;\n"
            f"  *Rock.ViewModels.dll) cat {vm_f} ;;\n"
            "  *) echo \"stub ikdasm: unhandled $1\" >&2; exit 1 ;;\n"
            "esac\n"
        )
        stub.chmod(0o755)
        return root, base, stub

    def _run(self, blocks_il, viewmodels_il, **kwargs):
        root, base, stub = self._deploy_set(blocks_il, viewmodels_il, **kwargs)
        return subprocess.run(
            [str(VERIFY_SCRIPT), str(root)],
            capture_output=True,
            text=True,
            env=dict(os.environ, IKDASM=str(stub)),
        )

    def test_a_patched_artifact_passes(self):
        result = self._run(_blocks(PATCHED_METHODS), PATCHED_VIEWMODELS)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All checks passed", result.stdout)

    def test_it_rejects_the_build_the_ci_string_scan_accepts(self):
        """The case the whole script exists for. `HeaderImage` is present in the
        assembly -- an unrelated view model contributes it -- so CI's marker check is
        satisfied, while FormGeneralViewModel never gained the property. Anything that
        greps the file as a whole says yes here."""
        self.assertIn(
            "HeaderImage",
            UNPATCHED_VIEWMODELS,
            "the fixture is not exercising the decoy; a plain grep must succeed on it "
            "or this test proves nothing",
        )

        result = self._run(_blocks(PATCHED_METHODS), UNPATCHED_VIEWMODELS)
        self.assertEqual(
            result.returncode,
            1,
            "the script accepted an artifact whose FormGeneralViewModel has no "
            "HeaderImage:\n" + result.stdout + result.stderr,
        )
        self.assertIn("FormGeneralViewModel does NOT declare", result.stdout)

    def test_it_rejects_missing_block_methods(self):
        result = self._run(_blocks(UNPATCHED_METHODS), PATCHED_VIEWMODELS)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("GetHeaderImageViewModel", result.stdout)

    def test_it_survives_a_type_body_larger_than_the_pipe_buffer(self):
        """Regression. FormBuilderDetail disassembles to about 4400 lines; the first
        version of this script reported both of its methods missing purely because the
        body did not fit in a 64K pipe. The markers here sit at the very top, so the
        only thing that can fail the check is the plumbing."""
        big = _blocks(PATCHED_METHODS, filler_lines=40000)
        self.assertGreater(len(big), 64 * 1024, "the fixture is too small to regress on")

        result = self._run(big, PATCHED_VIEWMODELS)
        self.assertEqual(
            result.returncode,
            0,
            "a large type body failed the check even though the markers are present "
            "-- the SIGPIPE/pipefail bug is back:\n" + result.stdout,
        )

    def test_a_renamed_type_is_reported_as_missing_rather_than_unpatched(self):
        """Different failure, different fix. 'the type is not here' means the wrong
        assembly or an upstream rename; 'the type is here without the member' means a
        stale build. Collapsing them sends whoever is mid-deploy the wrong way."""
        renamed = _class(
            "Rock.Blocks.Workflow.FormBuilder.FormBuilderDetailV2", PATCHED_METHODS
        )
        result = self._run(renamed, PATCHED_VIEWMODELS)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("no type named FormBuilderDetail", result.stdout)

    def test_missing_ikdasm_exits_differently_from_a_bad_artifact(self):
        """Exit 2, not 1. An operator scripting this must not read 'mono is not
        installed' as 'the artifact is broken', nor the reverse."""
        root, base, _ = self._deploy_set(
            _blocks(PATCHED_METHODS), PATCHED_VIEWMODELS
        )
        result = subprocess.run(
            [str(VERIFY_SCRIPT), str(root)],
            capture_output=True,
            text=True,
            env=dict(os.environ, IKDASM=str(root / "does-not-exist")),
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("ikdasm not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
