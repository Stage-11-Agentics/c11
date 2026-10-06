#!/usr/bin/env bash
# Behavioral coverage for the native main backstop's already-green skip check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci-commit-tested-green.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-ci-tested-green.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SHA="6e2c1dc47fa2c69bc00ac1cb634c5ce28f3f9417"
OTHER_SHA="3782d294d6000000000000000000000000000000"

# A stub gh that serves a canned run list and records the requested endpoint.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]] || exit 2
printf '%s\n' "$2" >> "$TEST_GH_LOG"
[[ "${TEST_GH_FAIL:-0}" == 1 ]] && { echo "HTTP 502" >&2; exit 1; }
cat "$TEST_GH_RESPONSE"
EOF
chmod +x "$TMP_DIR/bin/gh"

run_check() {
  local response="$1" current="${2:-}" fail_api="${3:-0}"
  printf '%s' "$response" > "$TMP_DIR/response.json"
  PATH="$TMP_DIR/bin:$PATH" \
    TEST_GH_LOG="$TMP_DIR/gh.log" \
    TEST_GH_RESPONSE="$TMP_DIR/response.json" \
    TEST_GH_FAIL="$fail_api" \
    "$SCRIPT" Stage-11-Agentics/c11 ci-hourly.yml "$SHA" $current 2>/dev/null
}

# A green run on the same commit skips.
result="$(run_check "{\"workflow_runs\":[{\"id\":101,\"head_sha\":\"$SHA\",\"conclusion\":\"success\"}]}" 202)"
[[ "$result" == true ]] || fail "prior green run on $SHA reported '$result'"
grep -Fxq "repos/Stage-11-Agentics/c11/actions/workflows/ci-hourly.yml/runs?head_sha=$SHA&status=success&per_page=100" "$TMP_DIR/gh.log" \
  || fail "queried an unexpected endpoint: $(cat "$TMP_DIR/gh.log")"

# No runs on the commit builds.
result="$(run_check '{"workflow_runs":[]}' 202)"
[[ "$result" == false ]] || fail "no runs reported '$result'"

# The current run never counts as its own prior green.
result="$(run_check "{\"workflow_runs\":[{\"id\":202,\"head_sha\":\"$SHA\",\"conclusion\":\"success\"}]}" 202)"
[[ "$result" == false ]] || fail "current run counted as prior green: '$result'"

# Failed runs, or green runs of another commit, do not skip.
result="$(run_check "{\"workflow_runs\":[{\"id\":101,\"head_sha\":\"$SHA\",\"conclusion\":\"failure\"},{\"id\":102,\"head_sha\":\"$OTHER_SHA\",\"conclusion\":\"success\"}]}" 202)"
[[ "$result" == false ]] || fail "failed or other-commit runs reported '$result'"

# An API failure builds instead of skipping.
result="$(run_check '{}' 202 1)"
[[ "$result" == false ]] || fail "API failure reported '$result'"

# An unreadable response builds instead of skipping.
result="$(run_check 'not json' 202)"
[[ "$result" == false ]] || fail "unreadable response reported '$result'"

echo "PASS: already-green check skips only on a prior successful run of the same commit"
