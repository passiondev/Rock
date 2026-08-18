#!/usr/bin/env bash
#
# Authoritative verification of a PTP-14803 deploy set, read from .NET metadata
# rather than from bytes in the file.
#
# ptp-14803-build-artifact.yml already scans the compiled assemblies for marker
# strings, and labels that scan "necessary but not sufficient" on purpose. Two of
# its four markers pass on a completely unpatched build:
#
#   Rock.ViewModels.dll  'HeaderImage' -- three types in this assembly own a member
#                        by that name. InteractiveExperienceBag and
#                        ExperiencePlaceholderStyleBag have nothing to do with Form
#                        Builder and predate this work, so the string is present
#                        either way.
#   entryForm.obs.js     'col-md-12' -- stock Bootstrap. It does discriminate for
#                        this particular change, but only because upstream happens
#                        not to use it in that one file.
#
# A string scan cannot tell which type owns a name. Metadata can. This disassembles
# the assemblies and asserts the members sit on the types that were actually
# patched:
#
#   Rock.Blocks.dll      FormBuilderDetail declares GetHeaderImageViewModel and
#                        SaveHeaderImageAttributeValue
#   Rock.ViewModels.dll  FormGeneralViewModel declares HeaderImage, typed ListItemBag
#
# The reason this matters more here than it would elsewhere: prod's bin is a
# mixed-version assembly set, so "the DLL contains the string" is never enough to
# conclude a hot-swap landed the code you think it did. Run this against the
# downloaded artifact before anything is copied onto a VM.
#
# Usage:
#   ./verify-artifact.sh <deploy-set-dir>       # an extracted deploy set
#   ./verify-artifact.sh --run <run-id>         # download that run's artifact first
#   ./verify-artifact.sh --run <id> --repository owner/name
#
# Needs `ikdasm` (brew install mono). `--run` additionally needs `gh`, authenticated
# against the repository.
#
# Read-only. It reads a deploy set and, with --run, downloads one to a temp
# directory. It writes nothing into the deploy set and touches no VM, no database
# and no repository setting.

set -euo pipefail

# Overridable so the tests can put a fake disassembler in front of the real one
# without depending on mono being installed on the machine running them.
IKDASM="${IKDASM:-ikdasm}"

DEPLOY_SET=""
RUN_ID=""
REPOSITORY=""

usage() {
  sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --run)         RUN_ID="${2:-}"; shift 2 ;;
    --repository)  REPOSITORY="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    -*)            echo "unknown option: $1" >&2; usage ;;
    *)             DEPLOY_SET="$1"; shift ;;
  esac
done

if [ -n "$RUN_ID" ] && [ -n "$DEPLOY_SET" ]; then
  echo "give either a directory or --run, not both" >&2
  exit 2
fi
if [ -z "$RUN_ID" ] && [ -z "$DEPLOY_SET" ]; then
  usage
fi

if ! command -v "$IKDASM" >/dev/null 2>&1; then
  echo "ikdasm not found. It ships with mono: brew install mono" >&2
  echo "Without it this script can only do the same string scan CI already does," >&2
  echo "which is the thing it exists to improve on, so it stops instead." >&2
  exit 2
fi

if [ -n "$RUN_ID" ]; then
  command -v gh >/dev/null 2>&1 || { echo "--run needs the gh CLI" >&2; exit 2; }
  [ -n "$REPOSITORY" ] || REPOSITORY="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  DEPLOY_SET="$(mktemp -d)"
  trap 'rm -rf "$DEPLOY_SET"' EXIT
  echo "Downloading the artifact from run $RUN_ID ..."
  gh run download "$RUN_ID" --repo "$REPOSITORY" --dir "$DEPLOY_SET"
fi

[ -d "$DEPLOY_SET" ] || { echo "not a directory: $DEPLOY_SET" >&2; exit 2; }

# The artifact extracts into a directory named for the run, so the assemblies sit one
# level deeper than the path the caller hands over. Search rather than assume a depth,
# so both the extracted-artifact layout and a bare deploy set work.
find_one() {
  find "$DEPLOY_SET" -type f -name "$1" -print 2>/dev/null | head -1
}

BLOCKS_DLL="$(find_one Rock.Blocks.dll)"
VIEWMODELS_DLL="$(find_one Rock.ViewModels.dll)"
FORMBUILDER_JS="$(find_one formBuilderDetail.obs.js)"
ENTRYFORM_JS="$(find_one entryForm.obs.js)"
MANIFEST="$(find_one manifest.json)"

failed=()
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failed+=("$1"); }

# ikdasm indents nested types and their closing braces. Anchoring both ends of the
# range at column 0 therefore selects exactly one top-level type and stops at its own
# end rather than running on into whatever is declared next.
members_of() {
  local assembly="$1" type="$2"
  "$IKDASM" "$assembly" 2>/dev/null | awk -v t="$type" '
    $0 ~ "^\\.class .*[.]" t "([ \t]|$)" { inside = 1 }
    inside                               { print }
    inside && /^\} \/\/ end of class/    { inside = 0 }
  '
}

assert_declares() {
  local assembly="$1" type="$2" pattern="$3" description="$4"
  local label; label="$(basename "$assembly")"
  local body; body="$(members_of "$assembly" "$type")"

  if [ -z "$body" ]; then
    fail "$label: no type named $type -- wrong assembly, or the type was renamed"
    return
  fi
  # A here-string, not `printf ... | grep`. `grep -q` exits at the first match and
  # closes the pipe; with `set -o pipefail` the writer's SIGPIPE then becomes the
  # pipeline's exit status, so a *successful* match reports as a failed check. It only
  # shows up once the body outgrows the 64K pipe buffer -- FormGeneralViewModel is a
  # few dozen lines and passes, FormBuilderDetail is ~4400 and does not.
  if grep -q "$pattern" <<<"$body"; then
    pass "$label: $type declares $description"
  else
    fail "$label: $type does NOT declare $description -- stale or unpatched build"
  fi
}

echo "Verifying deploy set: $DEPLOY_SET"
if [ -n "$MANIFEST" ]; then
  # Which build this is, not whether it is correct. Printed because verifying the
  # right artifact and verifying the artifact right are separate mistakes.
  # -E because BSD sed has no \| alternation in a basic regex, and this runs on the
  # macOS workstations as well as in CI.
  sed -E -n 's/.*"(sha|ref|runId)": *"?([^",]*)"?.*/  \1: \2/p' "$MANIFEST"
fi
echo

echo "Metadata checks (authoritative):"
if [ -n "$BLOCKS_DLL" ]; then
  assert_declares "$BLOCKS_DLL" FormBuilderDetail \
    GetHeaderImageViewModel "GetHeaderImageViewModel"
  assert_declares "$BLOCKS_DLL" FormBuilderDetail \
    SaveHeaderImageAttributeValue "SaveHeaderImageAttributeValue"
else
  fail "Rock.Blocks.dll is not in the deploy set"
fi

if [ -n "$VIEWMODELS_DLL" ]; then
  # Both halves on one line deliberately. 'HeaderImage' alone is what the CI scan
  # already asserts and it passes unpatched; pinning the ListItemBag type alongside
  # it is what makes this the Form Builder property rather than any HeaderImage.
  assert_declares "$VIEWMODELS_DLL" FormGeneralViewModel \
    'ListItemBag.*HeaderImage' "a HeaderImage member typed ListItemBag"
else
  fail "Rock.ViewModels.dll is not in the deploy set"
fi

echo
echo "String checks (bundled JavaScript has no metadata to read):"
if [ -n "$FORMBUILDER_JS" ] && grep -q 'headerImage' "$FORMBUILDER_JS"; then
  pass "formBuilderDetail.obs.js contains headerImage"
else
  fail "formBuilderDetail.obs.js is missing headerImage"
fi
if [ -n "$ENTRYFORM_JS" ] && grep -q 'col-md-12' "$ENTRYFORM_JS"; then
  pass "entryForm.obs.js contains the PTP-14804 layout change"
else
  fail "entryForm.obs.js is missing the PTP-14804 layout change"
fi

echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "${#failed[@]} check(s) failed. Do not deploy this artifact."
  exit 1
fi
echo "All checks passed. The patched members are on the expected types."
