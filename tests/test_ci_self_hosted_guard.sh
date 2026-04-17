#!/usr/bin/env bash
# Regression test originally for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid/gated CI jobs (macos-15-xlarge, billed) are never run for
# cross-repo fork pull requests — the fork guard `if:` clause must remain.
# For the Stage-11-Agentics/c11mux fork, the paid runner is macos-15-xlarge.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

if ! grep -Fq "$EXPECTED_IF" "$WORKFLOW_FILE"; then
  echo "FAIL: Missing fork pull_request guard in $WORKFLOW_FILE"
  echo "Expected line:"
  echo "  $EXPECTED_IF"
  exit 1
fi

# Every job that uses `runs-on: macos-15-xlarge` must carry the fork guard.
# Parsing: track job name (two-space indent), its runs-on value, and whether
# the fork guard appears within the same job block.
awk '
  /^  [a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
    if (job != "" && runner == "macos-15-xlarge" && !guard) {
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
    if (job != "" && runner == "macos-15-xlarge" && !guard) {
      print job
      failed = 1
    }
    exit failed
  }
' "$WORKFLOW_FILE" | while read -r offender; do
  echo "FAIL: job '$offender' uses macos-15-xlarge without fork guard"
done

# Re-run to set exit code
if ! awk '
  /^  [a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$/ {
    if (job != "" && runner == "macos-15-xlarge" && !guard) { failed = 1 }
    job = $0
    sub(/^  /, "", job); sub(/:.*/, "", job)
    runner = ""; guard = 0
    next
  }
  /runs-on:/ {
    if (job != "") { r = $0; sub(/^.*runs-on:[[:space:]]*/, "", r); runner = r }
  }
  /github\.event\.pull_request\.head\.repo\.full_name == github\.repository/ {
    if (job != "") guard = 1
  }
  END {
    if (job != "" && runner == "macos-15-xlarge" && !guard) failed = 1
    exit failed
  }
' "$WORKFLOW_FILE"; then
  exit 1
fi

echo "PASS: all macos-15-xlarge jobs carry the fork guard"
