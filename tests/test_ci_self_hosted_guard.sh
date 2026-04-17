#!/usr/bin/env bash
# Regression test originally for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid/gated CI jobs (macos-15-xlarge, billed) are never run for
# cross-repo fork pull requests — the fork guard `if:` clause must remain.
# For the Stage-11-Agentics/c11mux fork, the paid runner is macos-15-xlarge
# (upstream used warp-macos-15-arm64-6x via WarpBuild).
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

# tests: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: macos-15-xlarge/ { saw_runner=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_runner && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests block must keep both macos-15-xlarge runner and fork guard"
  exit 1
fi

# tests-build-and-lag: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-build-and-lag:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: macos-15-xlarge/ { saw_runner=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_runner && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-build-and-lag block must keep both macos-15-xlarge runner and fork guard"
  exit 1
fi

# ui-display-resolution-regression: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  ui-display-resolution-regression:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: macos-15-xlarge/ { saw_runner=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_runner && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-display-resolution-regression block must keep both macos-15-xlarge runner and fork guard"
  exit 1
fi

echo "PASS: tests macos-15-xlarge runner fork guard is present"
echo "PASS: tests-build-and-lag macos-15-xlarge runner fork guard is present"
echo "PASS: ui-display-resolution-regression macos-15-xlarge runner fork guard is present"
