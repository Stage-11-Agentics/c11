#!/usr/bin/env bash
# Behavioral coverage for ci.yml's PR scope and required-check verdict.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci-pr-scope.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-ci-pr-scope.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO="Stage-11-Agentics/c11"
PR=42
ENDPOINT="repos/$REPO/pulls/$PR/files?per_page=100"

# A stub gh that answers the files endpoint from $TEST_FILES, already in the
# filename<TAB>previous_filename form the script's --jq produces. A missing
# fixture is an API error.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]] || exit 2
for arg in "$@"; do
  if [[ "$arg" == repos/* ]]; then
    printf '%s\n' "$arg" >> "$TEST_GH_LOG"
    [[ "$arg" == "$TEST_ENDPOINT" ]] || { echo "HTTP 404" >&2; exit 1; }
  fi
done
[[ -f "$TEST_FILES" ]] || { echo "HTTP 502" >&2; exit 1; }
cat "$TEST_FILES"
EOF
chmod +x "$TMP_DIR/bin/gh"

FILES="$TMP_DIR/files.tsv"

files() {
  : > "$FILES"
  local entry
  for entry in "$@"; do
    printf '%s\n' "$entry" >> "$FILES"
  done
}

scope() {
  local event="${1:-pull_request}"
  : > "$TMP_DIR/gh.log"
  : > "$TMP_DIR/output"
  env -i PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR" \
    GITHUB_EVENT_NAME="$event" GITHUB_REPOSITORY="$REPO" PR_NUMBER="$PR" \
    GITHUB_OUTPUT="$TMP_DIR/output" \
    TEST_FILES="$FILES" TEST_ENDPOINT="$ENDPOINT" TEST_GH_LOG="$TMP_DIR/gh.log" \
    "$SCRIPT" scope 2>"$TMP_DIR/reason"
}

expect_scope() {
  local want="$1" label="$2"
  shift 2
  local got
  got="$(scope "$@")" || fail "$label: scope exited nonzero"
  [[ "$got" == "code=$want" ]] || fail "$label: got '$got', want code=$want ($(cat "$TMP_DIR/reason"))"
  grep -qx "code=$want" "$TMP_DIR/output" || fail "$label: GITHUB_OUTPUT lacks code=$want"
  echo "ok: $label -> code=$want"
}

# Documentation only: every path the old paths-ignore list covered.
files $'README.md\t' $'skills/c11/SKILL.md\t' $'docs/ci.png\t' $'notes/x/y.txt\t' \
  $'Resources/Localizable.xcstrings\t'
expect_scope false "docs-only PR"
grep -qx "$ENDPOINT" "$TMP_DIR/gh.log" || fail "scope did not read the PR's files"

files $'docs/a.md\tdocs/b.md'
expect_scope false "docs rename within docs"

# Anything else is code.
files $'README.md\t' $'Sources/App.swift\t'
expect_scope true "mixed PR"
files $'.github/workflows/ci.yml\t'
expect_scope true "workflow-only PR"
files $'scripts/ghosttykit-checksums.txt\t'
expect_scope true "GhosttyKit checksum commit"
files $'Resources/Info.plist\t'
expect_scope true "other Resources file"
files $'docs.swift\t'
expect_scope true "docs prefix without the directory"
files $'notes/old.md\tSources/Old.swift'
expect_scope true "code renamed into notes"

# Fail closed.
files
expect_scope true "no files listed"
/bin/rm -f "$FILES"
expect_scope true "files API error"
files $'README.md\t'
expect_scope true "push event" push
expect_scope true "workflow_dispatch event" workflow_dispatch

: > "$FILES"
for i in $(seq 1 3000); do printf 'docs/f%s.md\t\n' "$i" >> "$FILES"; done
expect_scope true "3000 files reaches the API cap"
: > "$FILES"
for i in $(seq 1 2999); do printf 'docs/f%s.md\t\n' "$i" >> "$FILES"; done
expect_scope false "2999 docs files"

# Verdict: NEEDS_JSON is toJSON(needs) from the aggregate job.
verdict() {
  NEEDS_JSON="$1" "$SCRIPT" verdict >/dev/null 2>"$TMP_DIR/verdict.err"
}

expect_pass() {
  verdict "$2" || fail "$1: verdict failed ($(cat "$TMP_DIR/verdict.err"))"
  echo "ok: $1 passes"
}

expect_fail() {
  if verdict "$2"; then
    fail "$1: verdict passed"
  fi
  echo "ok: $1 fails"
}

needs() {
  local code="$1" scope_result="$2"
  shift 2
  local jobs="" pair
  for pair in "$@"; do
    jobs="$jobs,\"${pair%%=*}\":{\"result\":\"${pair#*=}\",\"outputs\":{}}"
  done
  printf '{"scope":{"result":"%s","outputs":{"code":"%s"}}%s}' "$scope_result" "$code" "$jobs"
}

expect_pass "docs-only, all skipped" "$(needs false success guards=skipped runtime=skipped daemon=skipped web=skipped)"
expect_pass "code, all green" "$(needs true success guards=success runtime=success daemon=success web=success)"
expect_fail "code, one failed" "$(needs true success guards=success runtime=failure daemon=success web=success)"
expect_fail "code, one skipped" "$(needs true success guards=success runtime=success daemon=skipped web=success)"
expect_fail "code, one cancelled" "$(needs true success guards=success runtime=success daemon=success web=cancelled)"
expect_fail "docs-only, one ran" "$(needs false success guards=success runtime=skipped daemon=skipped web=skipped)"
expect_fail "scope failed" "$(needs true failure guards=skipped runtime=skipped daemon=skipped web=skipped)"
expect_fail "scope failed after writing code=false" "$(needs false failure guards=skipped runtime=skipped daemon=skipped web=skipped)"
expect_fail "scope skipped" "$(needs '' skipped guards=skipped runtime=skipped daemon=skipped web=skipped)"
expect_fail "scope missing" '{"guards":{"result":"success"}}'
expect_fail "no checks besides scope" "$(needs true success)"
expect_fail "bad JSON" 'not json'

echo "PASS: ci.yml PR scope and required-check verdict"
