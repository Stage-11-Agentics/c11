#!/usr/bin/env bash
# Choose the commit a native backstop run tests, and whether it already passed.
# Usage: ci-backstop-target.sh <owner/repo> <git-ref> <trigger-sha> <status-context>
#
# The target is the live tip of <git-ref> (refs/heads/main for a push to main,
# the dispatched ref for workflow_dispatch), resolved once after the run is
# admitted. Concurrency can admit an older push's run after a newer one, so the
# triggering commit is not necessarily main's newest. A run that passes posts a
# <status-context> success status on the commit it tested; "tested" reads that
# status, so it describes the tested commit, not the run's trigger.
#
# Prints GITHUB_OUTPUT lines: sha=<target> and tested=true|false. A tip that
# cannot be resolved fails selection (exit 1, no outputs): neither building nor
# skipping a possibly stale trigger is safe. Once the tip is resolved, an
# unreadable status list reports tested=false, so the tip builds.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <owner/repo> <git-ref> <trigger-sha> <status-context>" >&2
  exit 2
fi

REPO="$1"
REF="${2#refs/}"
TRIGGER_SHA="$3"
CONTEXT="$4"

target=""
if ref_json="$(gh api "repos/$REPO/git/ref/$REF")"; then
  target="$(jq -r '.object.sha // empty' <<<"$ref_json" 2>/dev/null || true)"
fi
if [[ ! "$target" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: could not resolve the tip of $REF (trigger $TRIGGER_SHA); failing instead of testing a possibly stale commit" >&2
  exit 1
elif [[ "$target" != "$TRIGGER_SHA" ]]; then
  echo "$REF moved past trigger $TRIGGER_SHA; testing its tip $target" >&2
fi

tested=false
if statuses_json="$(gh api "repos/$REPO/commits/$target/statuses?per_page=100")"; then
  if green="$(jq -r --arg context "$CONTEXT" '
      [.[] | select(.context == $context and .state == "success") | .target_url][0] // empty' \
      <<<"$statuses_json" 2>/dev/null)"; then
    if [[ -n "$green" ]]; then
      echo "$target already passed $CONTEXT: $green" >&2
      tested=true
    fi
  else
    echo "warning: unreadable statuses for $target; not skipping" >&2
  fi
else
  echo "warning: could not read statuses for $target; not skipping" >&2
fi

echo "sha=$target"
echo "tested=$tested"
