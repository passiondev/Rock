#!/usr/bin/env bash
#
# Blocks force-pushes and deletion on the repository's trunk.
#
# As of 2026-08-17 passiondev/Rock has no rulesets and no branch protection at all --
# repos/passiondev/Rock/rulesets returns an empty list and the trunk's protection
# endpoint 404s with "Branch not protected". Anyone with write access can force-push
# over the trunk or delete it.
#
# This creates (or updates) one repository ruleset holding exactly two rules:
# non_fast_forward and deletion. Nothing else changes. In particular it does NOT
# require pull request review, and that omission is deliberate -- the trunk cutover
# lands commits directly on the trunk, so a review requirement switched on beforehand
# would block the work it was meant to protect. Requiring approvals is a separate
# decision for after the cutover settles.
#
# Shell rather than PowerShell, unlike the scripts in Deployment/PrTestEnvironments:
# those run on the Windows IIS host, this one runs from a workstation against the
# GitHub API, and the workstations here do not have pwsh installed.
#
# Usage:
#   ./set-trunk-protection.sh              # dry run -- prints what it would write
#   ./set-trunk-protection.sh --apply      # writes it, then reads it back
#
# Needs `gh` authenticated as a repository admin.
# Reversible: Settings > Rules, or `gh api --method DELETE repos/<repo>/rulesets/<id>`.

set -euo pipefail

# Fixed, not a flag. The name is how a re-run finds the ruleset it wrote last time;
# making it configurable would mean a second run under a different name silently
# missed the lookup and posted a duplicate ruleset beside the first -- the exact
# thing the update path below exists to prevent.
RULESET_NAME="Trunk history protection"

# The dry run prints the ruleset already in place and then the one it would send, and
# this labels the second. Tests/PrTestEnvironments/test_trunk_protection.py splits the
# output on it to check the payload specifically -- a preserved rule appears in both
# halves, so a test reading all of stdout would pass either way.
WOULD_WRITE_LABEL="Would write:"

REPOSITORY=""
APPLY=0

usage() {
  cat <<'USAGE'
Blocks force-pushes and deletion on the repository's trunk.

  ./set-trunk-protection.sh                 dry run -- prints what it would write
  ./set-trunk-protection.sh --apply         writes it, then reads it back
  ./set-trunk-protection.sh --repository owner/name

Creates or updates one ruleset holding exactly two rules: non_fast_forward and
deletion, targeting ~DEFAULT_BRANCH so it follows the trunk when it moves. It does
not add a review requirement, so it cannot block commits landing on the trunk.

Needs `gh` authenticated as a repository admin.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)      APPLY=1; shift ;;
    --repository) REPOSITORY="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPOSITORY" ]; then
  REPOSITORY="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
fi

# Read the trunk from the repository rather than hardcoding it. Branch names here do
# not tell you the Rock version and the default branch is about to move; a hardcoded
# name would protect the retired branch, leave the new trunk open, and report success
# either way.
trunk="$(gh api "repos/$REPOSITORY" --jq '.default_branch')"
if [ -z "$trunk" ]; then
  echo "Could not resolve the default branch for $REPOSITORY." >&2
  exit 1
fi

echo "Repository : $REPOSITORY"
echo "Trunk      : $trunk (read from the repository's default branch)"

# Piped into jq rather than `gh api --jq`: gh's own --jq takes a single argument and
# rejects --arg, so passing the name through it fails. Swallowing that failure is
# worse than the failure -- the lookup would return empty every time, the script
# would always take the create path, and re-running it after the cutover would post a
# second ruleset alongside the first instead of updating it. No `|| true` here.
#
# --paginate because the list endpoint returns 30 at a time. Unpaginated, a
# repository holding more than that reads as "no ruleset by this name" and takes the
# create path -- two rulesets with one name, and nothing anywhere says so. It emits
# one array per page, hence `-s ... add` to flatten them before searching.
existing_id="$(gh api --paginate "repos/$REPOSITORY/rulesets" \
  | jq -rs --arg name "$RULESET_NAME" 'add | map(select(.name == $name)) | first | .id // empty')"

existing=""
existing_rules="[]"
if [ -n "$existing_id" ]; then
  existing="$(gh api "repos/$REPOSITORY/rulesets/$existing_id")"
  existing_rules="$(printf '%s' "$existing" | jq -c '.rules // []')"
fi

# ~DEFAULT_BRANCH is GitHub's own token for "whatever the default branch is right
# now". Using it rather than the resolved name means the ruleset follows the trunk
# when it moves, instead of guarding the branch that used to be the trunk.
#
# The rules are a union with whatever is already there, not the two on their own.
# This endpoint replaces the ruleset rather than patching it, so a literal two-rule
# payload deletes anything added since -- and the obvious candidate is the review
# requirement this script deliberately leaves for after the cutover. Somebody adds it
# in the UI, somebody else re-runs this to check the trunk is protected, and it goes
# away while the script prints that protection is in place. Adding is this script's
# job; removing is not.
payload="$(jq -n --arg name "$RULESET_NAME" --argjson existing_rules "$existing_rules" '{
  name: $name,
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
  rules: ($existing_rules + [{ type: "deletion" }, { type: "non_fast_forward" }] | unique_by(.type))
}')"

rollback_file="trunk-protection-rollback-$(date -u +%Y%m%dT%H%M%SZ).json"

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "DRY RUN - nothing has been changed. Re-run with --apply to write it."
  echo
  if [ -z "$existing_id" ]; then
    echo "Would create a new ruleset '$RULESET_NAME'."
    echo "Rollback would be: gh api --method DELETE repos/$REPOSITORY/rulesets/<new id>"
  else
    echo "Would update the existing ruleset '$RULESET_NAME' (id $existing_id)."
    echo "Rollback would be written to $rollback_file before anything is sent."
    echo
    echo "Currently in place:"
    printf '%s\n' "$existing"
  fi
  echo
  echo "$WOULD_WRITE_LABEL"
  printf '%s\n' "$payload"
  echo
  echo "Blocks: force-pushes (non_fast_forward) and branch deletion, on $trunk."
  echo "Leaves alone: direct pushes, review requirements, status checks."
  exit 0
fi

if [ -z "$existing_id" ]; then
  echo "Creating ruleset '$RULESET_NAME'..."
  written_id="$(printf '%s' "$payload" \
    | gh api --method POST "repos/$REPOSITORY/rulesets" --input - --jq '.id')"
  echo "Rollback: gh api --method DELETE repos/$REPOSITORY/rulesets/$written_id"
else
  # Save the ruleset before replacing it. A repository setting is no less worth a way
  # back than a database row, and "what did this look like before" is not a question
  # the GitHub UI answers afterwards.
  printf '%s\n' "$existing" > "$rollback_file"
  echo "Saved the current ruleset to $rollback_file"
  echo "Rollback: gh api --method PUT repos/$REPOSITORY/rulesets/$existing_id --input $rollback_file"

  # PUT against the existing id, so a second run after the cutover updates the
  # ruleset instead of stacking a duplicate beside it.
  echo "Updating ruleset '$RULESET_NAME' (id $existing_id)..."
  written_id="$(printf '%s' "$payload" \
    | gh api --method PUT "repos/$REPOSITORY/rulesets/$existing_id" --input - --jq '.id')"
fi

# A 200 is not proof the rules are in force: the wrong target, or an enforcement
# silently left at "evaluate", both come back looking like success. Read it back.
confirmed="$(gh api "repos/$REPOSITORY/rulesets/$written_id")"

enforcement="$(printf '%s' "$confirmed" | jq -r '.enforcement')"
applies_to="$(printf '%s' "$confirmed" | jq -r '.conditions.ref_name.include | join(", ")')"
active_rules="$(printf '%s' "$confirmed" | jq -r '[.rules[].type] | sort | join(", ")')"

echo
echo "Ruleset id  : $written_id"
echo "Enforcement : $enforcement"
echo "Applies to  : $applies_to"
echo "Rules       : $active_rules"

if [ "$enforcement" != "active" ]; then
  echo "Ruleset $written_id came back as '$enforcement' rather than active; it is not blocking anything." >&2
  exit 1
fi

for required in deletion non_fast_forward; do
  if ! printf '%s' "$confirmed" | jq -e --arg r "$required" 'any(.rules[]; .type == $r)' >/dev/null; then
    echo "Ruleset $written_id is missing the '$required' rule after write-back." >&2
    exit 1
  fi
done

echo
echo "Trunk history is protected. Direct pushes and merges are unaffected."
