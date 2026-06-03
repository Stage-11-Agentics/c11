#!/usr/bin/env bash
# Create or update a single marker-identified comment on an issue/PR, so
# re-triage runs edit in place instead of stacking comments.
#
# Usage: upsert-comment.sh <owner/repo> <number> <marker> <body-file>
# Prints the comment html_url on success.
set -euo pipefail

REPO="${1:?usage: upsert-comment.sh <owner/repo> <number> <marker> <body-file>}"
NUM="${2:?}"
MARKER="${3:?}"
BODY_FILE="${4:?}"

# Only match bot-authored comments: a contributor pasting the literal marker
# into their own comment must not become the PATCH target (403 + griefing).
existing="$(gh api --paginate "repos/$REPO/issues/$NUM/comments" \
  | jq -r --arg m "$MARKER" '.[] | select((.body | contains($m)) and (.user.type == "Bot")) | .id' | head -1)"

if [[ -n "$existing" ]]; then
  gh api -X PATCH "repos/$REPO/issues/comments/$existing" \
    -F "body=@$BODY_FILE" --jq '.html_url'
else
  gh api -X POST "repos/$REPO/issues/$NUM/comments" \
    -F "body=@$BODY_FILE" --jq '.html_url'
fi
