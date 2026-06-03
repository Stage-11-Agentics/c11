#!/usr/bin/env bash
# Fetch an inbound item's context into a directory for the judge / deep review.
# Read-only: GitHub API GETs with whatever token GH_TOKEN carries.
#
# Usage: fetch-item.sh <owner/repo> <pr|issue> <number> <outdir>
set -euo pipefail

REPO="${1:?usage: fetch-item.sh <owner/repo> <pr|issue> <number> <outdir>}"
TYPE="${2:?}"
NUM="${3:?}"
OUT="${4:?}"
mkdir -p "$OUT"

DIFF_CAP_BYTES=300000

if [[ "$TYPE" == "pr" ]]; then
  gh api "repos/$REPO/pulls/$NUM" > "$OUT/item.json"
  gh api --paginate "repos/$REPO/pulls/$NUM/files" | jq -s 'add' > "$OUT/files.json"
  gh api "repos/$REPO/pulls/$NUM" -H "Accept: application/vnd.github.diff" \
    | head -c "$DIFF_CAP_BYTES" > "$OUT/item.diff" || true
  if [[ "$(wc -c < "$OUT/item.diff")" -ge "$DIFF_CAP_BYTES" ]]; then
    printf '\n\n[drawbridge: diff truncated at %s bytes]\n' "$DIFF_CAP_BYTES" >> "$OUT/item.diff"
  fi
else
  gh api "repos/$REPO/issues/$NUM" > "$OUT/item.json"
  : > "$OUT/item.diff"
fi

# Last 20 comments, trimmed to the fields the judge needs.
gh api --paginate "repos/$REPO/issues/$NUM/comments" \
  | jq -s 'add // [] | .[-20:] | map({user: .user.login, association: .author_association, created_at, body})' \
  > "$OUT/comments.json"

jq --arg type "$TYPE" '{
  type: $type,
  number: .number,
  title: .title,
  author: .user.login,
  author_type: .user.type,
  author_association: .author_association,
  html_url: .html_url,
  head_sha: (.head.sha // null),
  draft: (.draft // false)
}' "$OUT/item.json" > "$OUT/meta.json"

echo "fetched $TYPE #$NUM into $OUT"
