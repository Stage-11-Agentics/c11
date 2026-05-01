#!/usr/bin/env bash
# list-merged.sh — list upstream cmux PRs since a given point.
#
# Usage:
#   list-merged.sh --since <YYYY-MM-DD> [--state merged|open|all]
#   list-merged.sh --since <commit-sha>      (uses commit's date)
#   list-merged.sh --since <pr-number>       (uses that PR's mergedAt)
#
# State filter:
#   merged (default) — only merged PRs, ordered by mergedAt
#   open             — only open PRs, ordered by createdAt
#   all              — merged + open, deduped, ordered chronologically
#
# Output: TSV — one row per PR.
#   <pr-number>\t<when>\t<state>\t<author>\t<title>
#   where <when> = mergedAt for merged PRs, createdAt for open PRs.
#
# Sorted oldest-first so processing order matches upstream timeline.

set -euo pipefail

SINCE=""
STATE="merged"
LIMIT="${LIMIT:-500}"
UPSTREAM_REPO="manaflow-ai/cmux"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$SINCE" ]] && { echo "error: --since is required" >&2; exit 2; }

case "$STATE" in
  merged|open|all) ;;
  *) echo "error: --state must be merged, open, or all" >&2; exit 2 ;;
esac

# Resolve SINCE to an ISO timestamp.
if [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  SINCE_ISO="${SINCE}T00:00:00Z"
elif [[ "$SINCE" =~ ^[0-9]+$ ]]; then
  SINCE_ISO="$(gh pr view "$SINCE" --repo "$UPSTREAM_REPO" --json mergedAt -q '.mergedAt' 2>/dev/null || echo '')"
  [[ -z "$SINCE_ISO" || "$SINCE_ISO" == "null" ]] && { echo "error: PR $SINCE has no mergedAt" >&2; exit 1; }
elif [[ "$SINCE" =~ ^[0-9a-f]{7,40}$ ]]; then
  SINCE_ISO="$(git show -s --format='%cI' "$SINCE" 2>/dev/null || echo '')"
  [[ -z "$SINCE_ISO" ]] && { echo "error: commit $SINCE not found" >&2; exit 1; }
else
  SINCE_ISO="$SINCE"
fi

SINCE_DATE="${SINCE_ISO%%T*}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_state() {
  local state="$1" search="$2" out="$3"
  gh pr list \
    --repo "$UPSTREAM_REPO" \
    --state "$state" \
    --search "$search" \
    --limit "$LIMIT" \
    --json number,title,author,state,mergedAt,createdAt \
    > "$out" 2>/dev/null
}

case "$STATE" in
  merged) fetch_state merged "merged:>${SINCE_DATE}" "$TMP/merged.json" ;;
  open)   fetch_state open   "created:>${SINCE_DATE}" "$TMP/open.json" ;;
  all)
    fetch_state merged "merged:>${SINCE_DATE}"  "$TMP/merged.json"
    fetch_state open   "created:>${SINCE_DATE}" "$TMP/open.json"
    ;;
esac

python3 - "$TMP" "$STATE" <<'PY'
import json, os, sys
tmp_dir, state = sys.argv[1], sys.argv[2]
combined = []
for name in ("merged.json", "open.json"):
    path = os.path.join(tmp_dir, name)
    if not os.path.exists(path):
        continue
    with open(path) as f:
        try:
            combined.extend(json.load(f))
        except json.JSONDecodeError:
            pass

# Dedupe by PR number.
seen, uniq = set(), []
for pr in combined:
    n = pr.get("number")
    if n in seen:
        continue
    seen.add(n)
    uniq.append(pr)

def sort_key(p):
    return p.get("mergedAt") or p.get("createdAt") or ""

for pr in sorted(uniq, key=sort_key):
    n = pr["number"]
    pr_state = (pr.get("state") or "").lower()
    when = pr.get("mergedAt") or pr.get("createdAt") or ""
    author = (pr.get("author") or {}).get("login", "")
    title = (pr.get("title") or "").replace("\t", " ").replace("\n", " ")
    print(f"{n}\t{when}\t{pr_state}\t{author}\t{title}")
PY
