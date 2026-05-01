#!/usr/bin/env bash
# analyze-hotspots.sh — find files heavily modified in c11's unique commits.
# These are the "hot zones" where upstream cherry-picks are most likely to conflict.
#
# Usage:
#   analyze-hotspots.sh [--top N]
#
# Output (stdout, sorted by churn descending):
#   <commits-touching>  <lines-changed>  <path>

set -euo pipefail

TOP="${TOP:-50}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top) TOP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Find merge-base of HEAD with upstream/main.
if ! git rev-parse --verify upstream/main >/dev/null 2>&1; then
  echo "error: upstream/main not found. Run: git fetch upstream main" >&2
  exit 1
fi

BASE="$(git merge-base HEAD upstream/main)"

# For each c11-unique commit, list files changed with +/- counts.
# Aggregate: count of commits touching each file, and total lines changed.
git log --no-merges --numstat --format='format:__commit__' "${BASE}..HEAD" \
  | awk '
      /^__commit__/ { next }
      NF == 3 {
        adds = ($1 == "-") ? 0 : $1
        dels = ($2 == "-") ? 0 : $2
        commits[$3]++
        lines[$3] += adds + dels
      }
      END {
        for (f in commits) {
          printf "%d\t%d\t%s\n", commits[f], lines[f], f
        }
      }
    ' \
  | sort -k1,1nr -k2,2nr \
  | head -n "$TOP"
