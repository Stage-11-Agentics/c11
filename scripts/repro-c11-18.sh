#!/usr/bin/env bash
#
# repro-c11-18.sh — Rapid-cycle reproduction harness for C11-18.
#
# Bug: a Ghostty terminal surface is occasionally drawn TWICE during portal
# sync — once at its proper pane location and once shifted upward, with the
# duplicate's top edge extending above the workspace title bar. Caught
# visually 2026-04-26 in tagged build "c11 DEV pane-close-overlay" after
# split + close + Reset Entire Pane sequences.
#
# This script does NOT directly trigger Reset Entire Pane via socket: c11's
# `pane-confirm` verb presents a NEW confirmation card, it does not drive an
# existing in-UI confirmation. So the script does the spawn-load half of the
# repro loop. Operator either:
#
#   (a) manually clicks "Reset Entire Pane" between iterations, or
#   (b) watches the workspace while iterations run rapidly to surface
#       portal lifecycle churn, then triggers Reset Entire Pane manually
#       once the artifact appears in /tmp/c11-portal.log (or visually).
#
# Usage:
#   C11_PORTAL_DEBUG=1 ./scripts/repro-c11-18.sh [iterations]
#   C11_PORTAL_DEBUG=1 ./scripts/repro-c11-18.sh 200
#   ./scripts/repro-c11-18.sh --help
#
# Prerequisites:
#   * c11 running, with a workspace and at least one pane.
#   * `c11` CLI on PATH (default install).
#   * Tagged build launched via ./scripts/reload.sh --tag <tag>; see
#     skills/c11-hotload/SKILL.md.
#
# Output:
#   * Spawn churn in the focused pane.
#   * /tmp/c11-portal.log (override with C11_PORTAL_LOG=<path>) accumulates
#     structured portal lifecycle events when C11_PORTAL_DEBUG=1.
#
# Refs: C11-18 (task_01KQ3Y77ATG09X67AKMNA2W2JV).

set -euo pipefail

print_help() {
  # Skip the shebang line, then strip the leading "# " or "#" from comments.
  sed -n '2,40p' "$0" | sed -e 's/^# \{0,1\}//'
  exit 0
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_help
fi

ITERATIONS="${1:-50}"
SLEEP_SECONDS="${C11_18_SLEEP:-0.15}"
SPAWNS_PER_ITER="${C11_18_SPAWNS:-3}"

if ! command -v c11 >/dev/null 2>&1; then
  echo "error: c11 CLI not found on PATH" >&2
  exit 1
fi

# Resolve workspace + pane targets. The `c11 list-*` verbs emit a leading "* "
# on the active/focused row; prefer that, otherwise take the first ref.
extract_ref() {
  local prefix="$1"
  local input="$2"
  # Pass 1: prefer rows starting with "*".
  local ref
  ref="$(awk -v pfx="$prefix" '
    /^\*[[:space:]]/ {
      for (i = 2; i <= NF; i++) {
        if ($i ~ "^"pfx":") { print $i; exit }
      }
    }
  ' <<<"$input")"
  if [[ -n "$ref" ]]; then
    printf '%s' "$ref"
    return 0
  fi
  # Pass 2: any row.
  ref="$(awk -v pfx="$prefix" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ "^"pfx":") { print $i; exit }
      }
    }
  ' <<<"$input")"
  printf '%s' "$ref"
}

WORKSPACE_LIST="$(c11 list-workspaces 2>/dev/null || true)"
WORKSPACE_REF="$(extract_ref workspace "$WORKSPACE_LIST")"
if [[ -z "$WORKSPACE_REF" ]]; then
  echo "error: could not resolve a workspace ref. Is c11 running with at least one workspace?" >&2
  exit 1
fi

PANE_LIST="$(c11 list-panes --workspace "$WORKSPACE_REF" 2>/dev/null || true)"
PANE_REF="$(extract_ref pane "$PANE_LIST")"
if [[ -z "$PANE_REF" ]]; then
  echo "error: could not resolve a pane ref in workspace $WORKSPACE_REF." >&2
  exit 1
fi

echo "C11-18 repro harness"
echo "  workspace=$WORKSPACE_REF"
echo "  pane=$PANE_REF"
echo "  iterations=$ITERATIONS"
echo "  spawns-per-iter=$SPAWNS_PER_ITER"
echo "  sleep-between-iter=${SLEEP_SECONDS}s"
echo "  C11_PORTAL_DEBUG=${C11_PORTAL_DEBUG:-unset}"
echo

if [[ "${C11_PORTAL_DEBUG:-}" == "" ]]; then
  echo "warning: C11_PORTAL_DEBUG is not set in this shell. The c11 process must" >&2
  echo "         have been launched with C11_PORTAL_DEBUG=1 in its environment for" >&2
  echo "         /tmp/c11-portal.log to be populated. Setting it here only affects" >&2
  echo "         the script's child commands, not the running c11 app." >&2
  echo
fi

trap 'echo; echo "Interrupted at iteration $i / $ITERATIONS."; exit 130' INT

for ((i = 1; i <= ITERATIONS; i++)); do
  for ((s = 1; s <= SPAWNS_PER_ITER; s++)); do
    c11 new-surface --type terminal --pane "$PANE_REF" >/dev/null 2>&1 || true
  done
  # Best-effort: ask c11 to surface a confirmation card on the pane. This does
  # NOT drive the Reset Entire Pane confirmation that the operator triggers
  # from the title-bar menu — pane-confirm presents a NEW dialog. Operator
  # must trigger Reset Entire Pane manually for the full repro path.
  # Sleep a frame to let SwiftUI/CA settle before the next spawn burst.
  sleep "$SLEEP_SECONDS"
  if (( i % 10 == 0 )); then
    echo "  iter=$i / $ITERATIONS"
  fi
done

echo
echo "Repro spawn cycles complete."
echo "Inspect /tmp/c11-portal.log for portal lifecycle events (sync.skip.orphan,"
echo "orphan.hide, bind.before/after, sync.result) to localize the duplicate-overdraw."
