#!/usr/bin/env bash
# Regression test originally for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid/gated CI jobs (GitHub paid runners and Atlas self-hosted jobs)
# are never run for cross-repo fork pull requests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILES=(
  "$ROOT_DIR/.github/workflows/ci-hourly.yml"
  "$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
  "$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
)

EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

for workflow in "${WORKFLOW_FILES[@]}"; do
  if ! grep -Fq "$EXPECTED_IF" "$workflow"; then
    echo "FAIL: Missing fork pull_request guard in $workflow"
    echo "Expected line:"
    echo "  $EXPECTED_IF"
    exit 1
  fi
done

# Every job that uses a paid macOS runner or the Atlas self-hosted labels must
# carry the fork guard. Parsing tracks each two-space job block, its runs-on
# value, and whether the guard appears within that job block.
GUARD_AWK='
  /^  [a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
    if (job != "" && runner ~ /(macos-15-xlarge|self-hosted|atlas)/ && !guard) {
      print job
      failed = 1
    }
    job = $0
    sub(/^  /, "", job); sub(/:.*/, "", job)
    runner = ""; guard = 0
    next
  }
  /runs-on:/ {
    if (job != "") {
      r = $0
      sub(/^.*runs-on:[[:space:]]*/, "", r)
      runner = r
    }
  }
  /github\.event\.pull_request\.head\.repo\.full_name == github\.repository/ {
    if (job != "") guard = 1
  }
  END {
    if (job != "" && runner ~ /(macos-15-xlarge|self-hosted|atlas)/ && !guard) {
      print job
      failed = 1
    }
    exit failed
  }
 '

for workflow in "${WORKFLOW_FILES[@]}"; do
  offenders="$(awk "$GUARD_AWK" "$workflow" || true)"
  if [[ -n "$offenders" ]]; then
    while read -r offender; do
      echo "FAIL: job '$offender' in $workflow uses a paid/self-hosted runner without fork guard"
    done <<< "$offenders"
    exit 1
  fi
done

echo "PASS: all paid/self-hosted macOS jobs carry the fork guard"
