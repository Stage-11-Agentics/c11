#!/usr/bin/env bash
# Behavioral coverage for the native main backstop's target and skip selection.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci-backstop-target.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-ci-backstop-target.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO="Stage-11-Agentics/c11"
CONTEXT="CI main (macOS)"
OLDER_SHA="b000000000000000000000000000000000000000"
NEWER_SHA="c000000000000000000000000000000000000000"

# A stub gh serving canned responses per endpoint. A missing fixture is an API
# error; every requested endpoint is logged.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/api"
cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]] || exit 2
printf '%s\n' "$2" >> "$TEST_GH_LOG"
fixture="$TEST_GH_API/$(printf '%s' "$2" | tr '/?&=' '____')"
[[ -f "$fixture" ]] || { echo "HTTP 502" >&2; exit 1; }
cat "$fixture"
EOF
chmod +x "$TMP_DIR/bin/gh"

fixture() {
  printf '%s' "$2" > "$TMP_DIR/api/$(printf '%s' "$1" | tr '/?&=' '____')"
}

tip_is() {
  fixture "repos/$REPO/git/ref/heads/main" "{\"object\":{\"sha\":\"$1\"}}"
}

statuses_for() {
  fixture "repos/$REPO/commits/$1/statuses?per_page=100" "$2"
}

green_status() {
  printf '[{"context":"%s","state":"success","target_url":"https://example.invalid/runs/%s"}]' "$CONTEXT" "$1"
}

reset() {
  rm -f "$TMP_DIR/api/"* "$TMP_DIR/gh.log"
}

run_target() {
  PATH="$TMP_DIR/bin:$PATH" TEST_GH_LOG="$TMP_DIR/gh.log" TEST_GH_API="$TMP_DIR/api" \
    "$SCRIPT" "$REPO" refs/heads/main "$1" "$CONTEXT" 2>/dev/null
}

expect() {
  local output="$1" sha="$2" tested="$3" label="$4"
  [[ "$output" == "sha=$sha"$'\n'"tested=$tested" ]] || fail "$label: got '$output'"
}

# An older push's run admitted after main moved on tests main's tip, and the
# older commit's green record does not skip the untested tip.
reset
tip_is "$NEWER_SHA"
statuses_for "$OLDER_SHA" "$(green_status 1)"
statuses_for "$NEWER_SHA" '[]'
expect "$(run_target "$OLDER_SHA")" "$NEWER_SHA" false "older trigger after newer main"
grep -Fxq "repos/$REPO/commits/$NEWER_SHA/statuses?per_page=100" "$TMP_DIR/gh.log" \
  || fail "green lookup did not read the tip: $(cat "$TMP_DIR/gh.log")"

# A tip that already passed skips, whichever commit triggered the run.
reset
tip_is "$NEWER_SHA"
statuses_for "$NEWER_SHA" "$(green_status 2)"
expect "$(run_target "$OLDER_SHA")" "$NEWER_SHA" true "tip already green"

# The trigger is the tip and has no green record: build it.
reset
tip_is "$NEWER_SHA"
statuses_for "$NEWER_SHA" '[]'
expect "$(run_target "$NEWER_SHA")" "$NEWER_SHA" false "untested tip"

# Only a success status in this context counts.
reset
tip_is "$NEWER_SHA"
statuses_for "$NEWER_SHA" "[{\"context\":\"$CONTEXT\",\"state\":\"failure\"},{\"context\":\"$CONTEXT\",\"state\":\"pending\"},{\"context\":\"other\",\"state\":\"success\"}]"
expect "$(run_target "$NEWER_SHA")" "$NEWER_SHA" false "non-success or other-context statuses"

# An unresolvable tip falls back to the trigger and still checks its record.
reset
statuses_for "$OLDER_SHA" '[]'
expect "$(run_target "$OLDER_SHA")" "$OLDER_SHA" false "tip lookup failure"
fixture "repos/$REPO/git/ref/heads/main" '{"object":{}}'
expect "$(run_target "$OLDER_SHA")" "$OLDER_SHA" false "tip without a sha"

# Status lookup failures build instead of skipping.
reset
tip_is "$NEWER_SHA"
expect "$(run_target "$NEWER_SHA")" "$NEWER_SHA" false "status API failure"
statuses_for "$NEWER_SHA" 'not json'
expect "$(run_target "$NEWER_SHA")" "$NEWER_SHA" false "unreadable statuses"

# A dispatched branch resolves its own tip, so branch proof runs test the branch.
reset
fixture "repos/$REPO/git/ref/heads/followup/proof" "{\"object\":{\"sha\":\"$NEWER_SHA\"}}"
statuses_for "$NEWER_SHA" '[]'
output="$(PATH="$TMP_DIR/bin:$PATH" TEST_GH_LOG="$TMP_DIR/gh.log" TEST_GH_API="$TMP_DIR/api" \
  "$SCRIPT" "$REPO" refs/heads/followup/proof "$OLDER_SHA" "$CONTEXT" 2>/dev/null)"
expect "$output" "$NEWER_SHA" false "dispatched branch"

echo "PASS: backstop tests the ref's live tip and skips only on that tip's green status"
