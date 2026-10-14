#!/usr/bin/env bash
# Open, comment on, or close the one GitHub issue that owns a scheduled lane.
# Usage: ci-scheduled-lane-owner.sh <lane> <failure|success>
#
# A failure creates "CI scheduled lane failed: <lane>", assigned to
# BenevolentFutures, or comments on that open issue. A success closes it
# with a comment. A success with no open issue does nothing.
#
# Callers: the report-lane-owner job in ci-hourly.yml, ci-macos-compat.yml,
# and nightly.yml. Those jobs run only on schedule and workflow_dispatch.
# This script refuses any other GITHUB_EVENT_NAME so a push or pull_request
# cannot open issues. An empty event name is the local fake-gh proof.
#
# The lane job's own result is what fails the run. This script exits 0 after
# a successful report, including a report that the lane failed.
set -euo pipefail

ASSIGNEE="BenevolentFutures"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <lane> <failure|success>" >&2
  exit 2
fi

LANE="$1"
RESULT="$2"

if [[ ! "$LANE" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then
  echo "error: lane must be a short slug, got ${LANE}" >&2
  exit 2
fi
case "$RESULT" in
  failure | success) ;;
  *)
    echo "error: result must be failure or success, got ${RESULT}" >&2
    exit 2
    ;;
esac

if [[ -n "${GITHUB_EVENT_NAME:-}" ]]; then
  case "$GITHUB_EVENT_NAME" in
    schedule | workflow_dispatch) ;;
    *)
      echo "error: lane owner does not run for event ${GITHUB_EVENT_NAME}" >&2
      exit 2
      ;;
  esac
fi

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
if [[ ! "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]]; then
  echo "error: GITHUB_RUN_ID must be numeric, got ${GITHUB_RUN_ID}" >&2
  exit 2
fi
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
RUN_URL="${SERVER}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
TITLE="CI scheduled lane failed: ${LANE}"

# The open-issue list, not search. Search is not read-your-writes, so a second
# failure before the index updates would open a duplicate. Exact title is the
# dedupe. The list cap is 100; this repo stays far under that.
existing_issue() {
  gh issue list \
    --repo "$GITHUB_REPOSITORY" \
    --state open \
    --limit 100 \
    --json number,title \
    | jq -r --arg title "$TITLE" 'first(.[] | select(.title == $title) | .number) // empty'
}

STANDING="$(printf 'This issue tracks failures of the %s scheduled lane.\nEach failure adds a comment with the run URL.\nThe issue is closed when the lane next passes.\n' "$LANE")"

if [[ "$RESULT" == "failure" ]]; then
  BODY="$(printf 'Scheduled lane %s failed.\n\nRun: %s\n' "$LANE" "$RUN_URL")"
  number="$(existing_issue)"
  if [[ -z "$number" ]]; then
    url="$(gh issue create \
      --repo "$GITHUB_REPOSITORY" \
      --title "$TITLE" \
      --assignee "$ASSIGNEE" \
      --body "$STANDING")"
    number="${url##*/}"
    if [[ ! "$number" =~ ^[0-9]+$ ]]; then
      echo "error: issue create did not return an issue URL: ${url}" >&2
      exit 1
    fi
    echo "lane-owner: opened #${number} for ${LANE}"
  else
    gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --add-assignee "$ASSIGNEE" >/dev/null
  fi
  gh issue comment "$number" --repo "$GITHUB_REPOSITORY" --body "$BODY" >/dev/null
  echo "lane-owner: commented on #${number} for ${LANE}"
  exit 0
fi

number="$(existing_issue)"
if [[ -z "$number" ]]; then
  echo "lane-owner: ${LANE} passed with no open issue"
  exit 0
fi
BODY="$(printf 'Scheduled lane %s passed. Closing.\n\nRun: %s\n' "$LANE" "$RUN_URL")"
gh issue close "$number" \
  --repo "$GITHUB_REPOSITORY" \
  --reason completed \
  --comment "$BODY" >/dev/null
echo "lane-owner: closed #${number} for ${LANE}"
