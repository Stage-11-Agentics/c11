#!/usr/bin/env bash
set -euo pipefail

# C11-261's fixture boundary. This wrapper is explicit about the tagged
# socket and CLI: production c11 is never a fallback target.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHON="${PYTHON:-python3}"
TAG=""
PHASE=""
STATE=""
FIXTURE_ROOT=""
OUT=""
LIFECYCLE_TIMEOUT="60"

usage() {
  cat <<'EOF'
Usage: ./scripts/groups-fixture.sh <tag> <provision|snapshot|automated|cleanup> [options]

Options:
  --state <absolute-path>          Ownership state (default: /tmp/c11-groups-g60-<tag>/state.json)
  --fixture-root <absolute-path>   Synthetic files and default state directory
  --out <absolute-path>            JSON/JSONL result destination
  --lifecycle-timeout <seconds>    A8 native waiting probe bound (default: 60)

The wrapper requires C11_SOCKET and C11_CLI when they are set. Otherwise it
derives the exact tagged socket and CLI for <tag>. It never uses the stable
production socket.
EOF
}

sanitize_path() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

die() {
  echo "groups-fixture: $*" >&2
  exit 2
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
TAG="$1"
PHASE="$2"
shift 2

[[ "$TAG" =~ ^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$ ]] || die "tag must be a simple tagged-build name"
case "$PHASE" in
  provision|snapshot|automated|cleanup) ;;
  *) die "unknown phase: $PHASE" ;;
esac

TAG_SLUG="$(sanitize_path "$TAG")"
[[ -n "$TAG_SLUG" ]] || die "tag produced an empty socket slug"
DEFAULT_ROOT="/tmp/c11-groups-g60-${TAG_SLUG}"
FIXTURE_ROOT="${DEFAULT_ROOT}"
STATE="${DEFAULT_ROOT}/state.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)
      [[ $# -ge 2 ]] || die "--state requires a path"
      STATE="$2"
      shift 2
      ;;
    --fixture-root)
      [[ $# -ge 2 ]] || die "--fixture-root requires a path"
      FIXTURE_ROOT="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || die "--out requires a path"
      OUT="$2"
      shift 2
      ;;
    --lifecycle-timeout)
      [[ $# -ge 2 ]] || die "--lifecycle-timeout requires seconds"
      LIFECYCLE_TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

[[ "$STATE" = /* && "$FIXTURE_ROOT" = /* ]] || die "state and fixture-root must be absolute"
[[ "$STATE" != *".."* && "$FIXTURE_ROOT" != *".."* ]] || die "parent traversal is not allowed"

SOCKET="${C11_SOCKET:-/tmp/c11-debug-${TAG_SLUG}.sock}"
APP="${HOME}/Library/Developer/Xcode/DerivedData/c11-${TAG_SLUG}/Build/Products/Debug/c11 DEV ${TAG}.app"
CLI="${C11_CLI:-${APP}/Contents/Resources/bin/c11}"

[[ "$SOCKET" = /* ]] || die "C11_SOCKET must be absolute"
[[ "$SOCKET" != "${HOME}/Library/Application Support/c11/c11.sock" ]] || die "production socket is forbidden"
[[ "$SOCKET" = "/tmp/c11-debug-${TAG_SLUG}.sock" || "$SOCKET" = /tmp/c11-sandbox-*.sock ]] || \
  die "socket must be the exact tagged socket /tmp/c11-debug-${TAG_SLUG}.sock or a sandbox socket"
[[ -f "$CLI" && -x "$CLI" ]] || die "candidate CLI is missing or not executable: $CLI"
[[ -S "$SOCKET" ]] || die "tagged QA socket is not listening: $SOCKET"

export C11_SOCKET="$SOCKET"
export C11_CLI="$CLI"
export C11_GROUPS_TEST_TAG="$TAG_SLUG"
export PYTHONPATH="${ROOT_DIR}/tests_v2${PYTHONPATH:+:${PYTHONPATH}}"

args=("$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" "$PHASE" --state "$STATE")
case "$PHASE" in
  provision)
    args+=(--fixture-root "$FIXTURE_ROOT" --tag "$TAG_SLUG")
    ;;
  snapshot)
    ;;
  automated)
    [[ -n "$OUT" ]] || OUT="${FIXTURE_ROOT}/automated.jsonl"
    args+=(--out "$OUT" --lifecycle-timeout "$LIFECYCLE_TIMEOUT")
    ;;
  cleanup)
    ;;
esac
[[ -n "$OUT" && "$PHASE" != automated ]] && args+=(--out "$OUT")

"${args[@]}"

if [[ "$PHASE" = cleanup && "$FIXTURE_ROOT" = "$DEFAULT_ROOT" ]]; then
  # The Python cleanup has already written any requested report and retained
  # foreign content. Only remove this exact, ticket-owned temp root.
  case "$FIXTURE_ROOT" in
    /tmp/c11-groups-g60-*) rm -rf -- "$FIXTURE_ROOT" ;;
    *) die "refusing to remove an unexpected fixture root: $FIXTURE_ROOT" ;;
  esac
fi
