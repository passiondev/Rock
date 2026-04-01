#!/usr/bin/env bash
#
# pull-rock-build.sh
#
# Downloads the latest compiled Rock build artifacts from GitHub Actions
# for the current branch (or a specified branch). Devs run this locally
# on Mac to get fresh DLLs without building on Windows.
#
# Prerequisites: gh CLI (brew install gh), authenticated (gh auth login)
#
# Usage:
#   ./scripts/pull-rock-build.sh              # uses current git branch
#   ./scripts/pull-rock-build.sh my-branch    # uses specified branch
#   ./scripts/pull-rock-build.sh --latest     # uses the most recent successful run across all branches

set -euo pipefail

REPO="passiondev/Rock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROCK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROCK_ROOT/.local-build"

# Parse arguments
USE_LATEST=false
BRANCH=""

if [[ "${1:-}" == "--latest" ]]; then
  USE_LATEST=true
elif [[ -n "${1:-}" ]]; then
  BRANCH="$1"
else
  BRANCH="$(git -C "$ROCK_ROOT" rev-parse --abbrev-ref HEAD)"
fi

# Check prerequisites
if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI is required. Install with: brew install gh"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "Error: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi

echo "Repository: $REPO"
if [[ "$USE_LATEST" == true ]]; then
  echo "Mode: latest successful run (any branch)"
else
  echo "Branch: $BRANCH"
fi
echo ""

# Find the latest successful workflow run
if [[ "$USE_LATEST" == true ]]; then
  RUN_ID=$(gh run list \
    --repo "$REPO" \
    --workflow "build-develop.yml" \
    --status success \
    --limit 1 \
    --json databaseId,headBranch,createdAt \
    --jq '.[0].databaseId')
  RUN_BRANCH=$(gh run list \
    --repo "$REPO" \
    --workflow "build-develop.yml" \
    --status success \
    --limit 1 \
    --json headBranch \
    --jq '.[0].headBranch')
else
  RUN_ID=$(gh run list \
    --repo "$REPO" \
    --workflow "build-develop.yml" \
    --branch "$BRANCH" \
    --status success \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId')
fi

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "Error: no successful build found."
  if [[ "$USE_LATEST" != true ]]; then
    echo "Push your branch to trigger a build, or use --latest for the most recent build from any branch."
  fi
  exit 1
fi

# Get run details
RUN_INFO=$(gh run view "$RUN_ID" --repo "$REPO" --json displayTitle,headBranch,createdAt,headSha)
RUN_TITLE=$(echo "$RUN_INFO" | jq -r '.displayTitle')
RUN_SHA=$(echo "$RUN_INFO" | jq -r '.headSha' | cut -c1-8)
RUN_DATE=$(echo "$RUN_INFO" | jq -r '.createdAt')
ACTUAL_BRANCH=$(echo "$RUN_INFO" | jq -r '.headBranch')

echo "Found build:"
echo "  Run:    #$RUN_ID"
echo "  Branch: $ACTUAL_BRANCH"
echo "  Commit: $RUN_SHA"
echo "  Title:  $RUN_TITLE"
echo "  Date:   $RUN_DATE"
echo ""

# Clean previous download
if [[ -d "$OUTPUT_DIR" ]]; then
  echo "Removing previous build..."
  rm -r "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# Download artifacts
echo "Downloading artifacts (this may take a few minutes)..."
gh run download "$RUN_ID" \
  --repo "$REPO" \
  --dir "$OUTPUT_DIR"

# The artifact is nested inside a directory named after the artifact
# Find the RockWeb directory wherever it landed
ROCKWEB_DIR=$(find "$OUTPUT_DIR" -type d -name "RockWeb" -maxdepth 3 | head -1)

if [[ -z "$ROCKWEB_DIR" ]]; then
  echo "Error: could not find RockWeb directory in downloaded artifacts."
  echo "Contents of $OUTPUT_DIR:"
  ls -la "$OUTPUT_DIR"
  exit 1
fi

# Move RockWeb to a predictable location if it's nested
if [[ "$ROCKWEB_DIR" != "$OUTPUT_DIR/RockWeb" ]]; then
  mv "$ROCKWEB_DIR" "$OUTPUT_DIR/RockWeb.tmp"
  # Clean up the artifact wrapper directory
  find "$OUTPUT_DIR" -maxdepth 1 -mindepth 1 -type d ! -name "RockWeb.tmp" -exec rm -r {} +
  mv "$OUTPUT_DIR/RockWeb.tmp" "$OUTPUT_DIR/RockWeb"
fi

# Count what we got
DLL_COUNT=$(find "$OUTPUT_DIR/RockWeb/bin" -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
TOTAL_FILES=$(find "$OUTPUT_DIR/RockWeb" -type f 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "Done."
echo "  Location: $OUTPUT_DIR/RockWeb"
echo "  DLLs:     $DLL_COUNT"
echo "  Files:    $TOTAL_FILES"
echo ""
echo "To use: point your local Rock/IIS config at $OUTPUT_DIR/RockWeb"
