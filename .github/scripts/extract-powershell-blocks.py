"""Write every embedded PowerShell block in the workflows and actions to a file.

The suite asserts on the *text* of these blocks. Nothing had ever asked whether
they parse. That gap is why this exists: the six copies of the command-queue wait
were moved into `.github/actions/await-vm-command` on 2026-08-21, and a typo in
that hundred-line block would have been found by the production deploy that ran it.

PowerShell that lives in a `.ps1` needs no help from here -- pwsh parses those
directly. Only the blocks inside YAML do, because they are strings until a runner
expands them.

Usage: extract-powershell-blocks.py <output-directory>
"""

import pathlib
import re
import sys

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
ACTIONS_DIR = REPO_ROOT / ".github" / "actions"

# `${{ ... }}` is a runner expression, not PowerShell. Substituting a string
# literal keeps the surrounding syntax intact wherever the expression stood: an
# argument, a right-hand side, or part of an interpolated string.
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.DOTALL)
PLACEHOLDER = "RUNNER_EXPRESSION"


def substitute(script):
    """Replace every runner expression with something PowerShell can parse.

    The expression gets quotes of its own, except where the author already
    wrote quotes around it -- `\'${{ x }}\'` would otherwise come out as
    `\'\'RUNNER_EXPRESSION\'\'`, which is two empty strings around a bareword and
    means something quite different from the one argument that was written.
    """

    def replacement(match):
        """One expression, quoted unless a neighbouring character already quotes it."""
        before = script[match.start() - 1] if match.start() else ""
        after = script[match.end()] if match.end() < len(script) else ""
        # `x in y` is True for an empty x, and an expression at the very start or
        # end of a block has no neighbour -- so test the character, not the slice.
        if before in ("\"", "'") or after in ("\"", "'"):
            return PLACEHOLDER
        return f"'{PLACEHOLDER}'"

    return EXPRESSION.sub(replacement, script)


def default_shell(container):
    """The `defaults: run: shell:` a workflow or a job sets, or None.

    Every level of that walk is optional and any of them can be present but null,
    so `.get()` alone is not enough -- `(x or {})` at each hop is what keeps a
    `defaults:` with nothing under it from raising."""
    return ((container.get("defaults") or {}).get("run") or {}).get("shell")


def powershell_steps(parsed, source):
    """(label, script) for every step in `parsed` that a runner will hand to pwsh."""
    workflow_shell = default_shell(parsed)

    def collect(steps, container, container_shell):
        """Every pwsh step in one flat step list, labelled by its container.

        `container_shell` is what the step inherits when it declares no shell of
        its own -- the job's default, or the workflow's."""
        for index, step in enumerate(steps or []):
            run = step.get("run")
            if not run:
                continue
            shell = step.get("shell") or container_shell
            if shell != "pwsh":
                continue
            name = step.get("name") or f"step{index}"
            slug = re.sub(r"[^A-Za-z0-9]+", "-", f"{source}-{container}-{name}").strip("-")
            yield slug, run

    for job_name, job in (parsed.get("jobs") or {}).items():
        job_shell = default_shell(job) or workflow_shell
        yield from collect(job.get("steps"), job_name, job_shell)

    # A composite action has one flat step list and no `defaults`, so a step there
    # carries its own shell or is not PowerShell at all.
    runs = parsed.get("runs") or {}
    if runs.get("using") == "composite":
        yield from collect(runs.get("steps"), "runs", None)


def main():
    """Write every extracted block to the output directory named on the command line."""
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    sources = sorted(WORKFLOWS_DIR.glob("*.yml")) + sorted(ACTIONS_DIR.glob("*/action.yml"))
    written = 0
    for path in sources:
        source = path.parent.name if path.name == "action.yml" else path.stem
        parsed = yaml.safe_load(path.read_text())
        for slug, script in powershell_steps(parsed, source):
            target = out / f"{slug}.ps1"
            # The original path goes in a comment so a parse error names a file
            # somebody can open, rather than a slug from a temp directory.
            target.write_text(
                f"# extracted from {path.relative_to(REPO_ROOT)}\n"
                + substitute(script)
            )
            written += 1

    # A run that writes nothing looks identical to a clean run from the parse
    # step's side, and it would keep looking clean while every embedded block went
    # unchecked. The workflows have had PowerShell in them since the fleet existed,
    # so zero here means this script stopped understanding their shape.
    if not written:
        print(f"Found no PowerShell in {len(sources)} files. Refusing to report success.", file=sys.stderr)
        return 1

    print(f"wrote {written} PowerShell blocks from {len(sources)} files to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
