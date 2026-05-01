#!/usr/bin/env bash
# list-merged.sh — list upstream cmux PRs merged after a given point.
#
# Usage:
#   list-merged.sh --since <YYYY-MM-DD>
#   list-merged.sh --since <commit-sha>      (uses commit's date)
#   list-merged.sh --since <pr-number>       (uses that PR's mergedAt)
#
# Output: TSV — one row per PR.
#   <pr-number>\t<merged-at>\t<author>\t<title>
#
# Sorted oldest-first so processing order matches upstream timeline.

set -euo pipefail

SINCE=""
LIMIT="${LIMIT:-500}"
UPSTREAM_REPO="manaflow-ai/cmux"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SINCE" ]]; then
  echo "error: --since is required" >&2
  exit 2
fi

# Resolve SINCE to an ISO timestamp.
SINCE_ISO=""
if [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  # Bare date — assume start of UTC day.
  SINCE_ISO="${SINCE}T00:00:00Z"
elif [[ "$SINCE" =~ ^[0-9]+$ ]]; then
  # PR number.
  SINCE_ISO="$(gh pr view "$SINCE" --repo "$UPSTREAM_REPO" --json mergedAt -q '.mergedAt' 2>/dev/null || echo '')"
  if [[ -z "$SINCE_ISO" || "$SINCE_ISO" == "null" ]]; then
    echo "error: PR $SINCE has no mergedAt timestamp" >&2
    exit 1
  fi
elif [[ "$SINCE" =~ ^[0-9a-f]{7,40}$ ]]; then
  # Commit SHA — use commit date.
  SINCE_ISO="$(git show -s --format='%cI' "$SINCE" 2>/dev/null || echo '')"
  if [[ -z "$SINCE_ISO" ]]; then
    echo "error: commit $SINCE not found" >&2
    exit 1
  fi
else
  # Pass through as-is and hope GH parses it.
  SINCE_ISO="$SINCE"
fi

# Use gh pr list with the search qualifier — exposes mergedAt directly.
# Strip time portion if present; GH search accepts date-level granularity well.
SINCE_DATE="${SINCE_ISO%%T*}"

gh pr list \
  --repo "$UPSTREAM_REPO" \
  --state merged \
  --search "merged:>${SINCE_DATE}" \
  --limit "$LIMIT" \
  --json number,title,author,mergedAt \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
for pr in sorted(data, key=lambda p: p.get("mergedAt") or ""):
    n = pr["number"]
    merged = pr.get("mergedAt") or ""
    author = (pr.get("author") or {}).get("login", "")
    title = (pr.get("title") or "").replace("\t", " ").replace("\n", " ")
    print(f"{n}\t{merged}\t{author}\t{title}")
'
