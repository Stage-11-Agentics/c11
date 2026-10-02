#!/usr/bin/env bash
# Behavioral policy guard for the CI split: PRs are cheap, while the native
# macOS lanes are scheduled/manual and isolated to the internal Atlas runner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAST="$ROOT_DIR/.github/workflows/ci.yml"
FULL_WORKFLOWS=(
  "$ROOT_DIR/.github/workflows/ci-hourly.yml"
  "$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
  "$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if grep -Eq '^  (push|schedule|workflow_dispatch):' "$FAST"; then
  fail "PR fast lane has a push, schedule, or manual full-run trigger"
fi
if grep -Eq '^  build:' "$FAST"; then
  fail "PR fast lane still contains a native build job"
fi
for job in workflow-guard-tests remote-daemon-tests web-typecheck; do
  grep -Eq "^  ${job}:" "$FAST" || fail "PR fast lane is missing $job"
done

for workflow in "${FULL_WORKFLOWS[@]}"; do
  grep -Fq "cron: '0 * * * *'" "$workflow" \
    || fail "$workflow is not hourly"
  if grep -Eq '^  (push|pull_request):' "$workflow"; then
    fail "$workflow still runs from push/pull_request"
  fi
  grep -Fq 'runs-on: [self-hosted, macOS, atlas]' "$workflow" \
    || fail "$workflow is not isolated to the Atlas labels"
  grep -Fq 'ci-atlas-run.sh' "$workflow" \
    || fail "$workflow does not use Atlas admission"
  if grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' "$workflow"; then
    fail "$workflow attempts a system install"
  fi
done

grep -Fq '"required_checks": ["workflow-guard-tests", "remote-daemon-tests", "web-typecheck"]' \
  "$ROOT_DIR/TRIAGE_POLICY.md" \
  || fail "Drawbridge required checks still require the hourly build"

echo "PASS: PR fast lane and hourly Atlas lane are separated"
