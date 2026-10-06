#!/usr/bin/env bash
# Report whether a workflow already passed on a commit, so a repeat run can skip.
# Usage: ci-commit-tested-green.sh <owner/repo> <workflow-file> <sha> [current-run-id]
# Prints "true" when another successful run of <workflow-file> has head <sha>,
# otherwise "false". Any API failure prints "false": the build runs rather than
# skipping on a guess.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <owner/repo> <workflow-file> <sha> [current-run-id]" >&2
  exit 2
fi

REPO="$1"
WORKFLOW="$2"
SHA="$3"
CURRENT_RUN_ID="${4:-}"

if ! runs_json="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?head_sha=$SHA&status=success&per_page=100")"; then
  echo "warning: could not list runs of $WORKFLOW for $SHA; not skipping" >&2
  echo false
  exit 0
fi

if ! green_run="$(jq -r --arg sha "$SHA" --arg current "$CURRENT_RUN_ID" '
  [.workflow_runs[]
    | select(.head_sha == $sha and .conclusion == "success" and (.id | tostring) != $current)
    | .id][0] // empty' <<<"$runs_json")"; then
  echo "warning: unreadable run list for $WORKFLOW; not skipping" >&2
  echo false
  exit 0
fi

if [[ -n "$green_run" ]]; then
  echo "$SHA already passed $WORKFLOW in run $green_run" >&2
  echo true
else
  echo false
fi
