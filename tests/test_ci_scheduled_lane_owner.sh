#!/usr/bin/env bash
# The scheduled-lane owner opens one issue, comments on the next failure,
# closes it on green, and does nothing when a green run has no open issue.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci-scheduled-lane-owner.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-lane-owner.XXXXXX")"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
echo 1 > "$TMP_DIR/state/next"

cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh. Records issue state as one JSON file per issue.
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_GH_LOG"
[[ "${1:-}" == "issue" ]] || { echo "unexpected gh $*" >&2; exit 2; }
sub="${2:-}"
shift 2

repo="" title="" body="" assignee="" state_filter="" reason="" comment="" number="" add_assignee=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --assignee) assignee="$2"; shift 2 ;;
    --add-assignee) add_assignee="$2"; shift 2 ;;
    --state) state_filter="$2"; shift 2 ;;
    --limit) shift 2 ;;
    --search) shift 2 ;;
    --json) shift 2 ;;
    --reason) reason="$2"; shift 2 ;;
    --comment) comment="$2"; shift 2 ;;
    -*) echo "unexpected flag $1" >&2; exit 2 ;;
    *)
      [[ -z "$number" ]] || { echo "unexpected arg $1" >&2; exit 2; }
      number="$1"
      shift
      ;;
  esac
done
[[ -n "$repo" ]] || { echo "missing --repo" >&2; exit 2; }

issue_file() {
  printf '%s/%s.json' "$TEST_GH_STATE" "$1"
}

case "$sub" in
  list)
    [[ "$state_filter" == "open" ]] || { echo "list must ask for open" >&2; exit 2; }
    files=()
    while IFS= read -r file; do
      files+=("$file")
    done < <(find "$TEST_GH_STATE" -name '*.json' -type f | sort)
    if [[ ${#files[@]} -eq 0 ]]; then
      echo '[]'
      exit 0
    fi
    jq -s --arg state "$state_filter" '[.[] | select(.state == $state) | {number, title}]' "${files[@]}"
    ;;
  create)
    [[ -n "$title" && -n "$body" && -n "$assignee" ]] || { echo "create missing fields" >&2; exit 2; }
    n="$(cat "$TEST_GH_STATE/next")"
    echo $((n + 1)) > "$TEST_GH_STATE/next"
    jq -n \
      --argjson number "$n" \
      --arg title "$title" \
      --arg body "$body" \
      --arg assignee "$assignee" \
      '{number:$number, title:$title, body:$body, assignee:$assignee, state:"open", comments:[]}' \
      > "$(issue_file "$n")"
    echo "https://github.com/${repo}/issues/${n}"
    ;;
  comment)
    [[ -n "$number" && -n "$body" ]] || { echo "comment missing fields" >&2; exit 2; }
    [[ -f "$(issue_file "$number")" ]] || { echo "no issue $number" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg body "$body" '.comments += [$body]' "$(issue_file "$number")" > "$tmp"
    /bin/mv -f "$tmp" "$(issue_file "$number")"
    ;;
  edit)
    [[ -n "$number" && -n "$add_assignee" ]] || { echo "edit missing fields" >&2; exit 2; }
    [[ -f "$(issue_file "$number")" ]] || { echo "no issue $number" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg assignee "$add_assignee" '.assignee = $assignee' "$(issue_file "$number")" > "$tmp"
    /bin/mv -f "$tmp" "$(issue_file "$number")"
    ;;
  close)
    [[ -n "$number" && -n "$comment" && "$reason" == "completed" ]] || { echo "close missing fields" >&2; exit 2; }
    [[ -f "$(issue_file "$number")" ]] || { echo "no issue $number" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg body "$comment" '.state = "closed" | .comments += [$body]' "$(issue_file "$number")" > "$tmp"
    /bin/mv -f "$tmp" "$(issue_file "$number")"
    ;;
  *)
    echo "unexpected issue subcommand $sub" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

export PATH="$TMP_DIR/bin:$PATH"
export TEST_GH_LOG="$TMP_DIR/gh.log"
export TEST_GH_STATE="$TMP_DIR/state"
export GITHUB_REPOSITORY="Stage-11-Agentics/c11"
export GITHUB_SERVER_URL="https://github.com"
unset GITHUB_EVENT_NAME

run_owner() {
  GITHUB_RUN_ID="$1" "$SCRIPT" "$2" "$3"
}

issue_json() {
  cat "$TMP_DIR/state/$1.json"
}

open_count() {
  find "$TMP_DIR/state" -name '*.json' -type f -print0 \
    | xargs -0 jq -s '[.[] | select(.state == "open")] | length'
}

# Two failures in a row: one issue, two comments, one assignee. Not two issues.
run_owner 101 ci-hourly failure >/dev/null
run_owner 102 ci-hourly failure >/dev/null
[[ "$(open_count)" == "1" ]] || fail "two failures opened $(open_count) issues"
[[ "$(find "$TMP_DIR/state" -name '*.json' | wc -l | tr -d ' ')" == "1" ]] || fail "a closed duplicate exists"
jq -e '.number == 1 and .title == "CI scheduled lane failed: ci-hourly" and .assignee == "BenevolentFutures" and (.comments | length) == 2' \
  "$TMP_DIR/state/1.json" >/dev/null || fail "issue 1 shape: $(issue_json 1)"
jq -e '.comments[0] | contains("failed") and contains("actions/runs/101")' "$TMP_DIR/state/1.json" >/dev/null \
  || fail "first comment: $(issue_json 1)"
jq -e '.comments[1] | contains("actions/runs/102")' "$TMP_DIR/state/1.json" >/dev/null \
  || fail "second comment: $(issue_json 1)"
creates="$(grep -c '^issue create ' "$TMP_DIR/gh.log")"
[[ "$creates" == "1" ]] || fail "expected 1 create, got $creates"

# A green run closes that issue with a comment.
run_owner 103 ci-hourly success >/dev/null
[[ "$(open_count)" == "0" ]] || fail "green run left $(open_count) open"
jq -e '.state == "closed" and (.comments | length) == 3 and (.comments[2] | contains("passed") and contains("actions/runs/103"))' \
  "$TMP_DIR/state/1.json" >/dev/null || fail "close comment: $(issue_json 1)"

# A green run with no open issue lists once and does not write.
count_writes() {
  local n
  n="$(grep -cE '^issue (create|comment|close|edit) ' "$TMP_DIR/gh.log" || true)"
  printf '%s' "${n:-0}"
}
writes_before="$(count_writes)"
out="$(run_owner 104 ci-hourly success)"
[[ "$out" == "lane-owner: ci-hourly passed with no open issue" ]] || fail "quiet green said: $out"
[[ "$(count_writes)" == "$writes_before" ]] || fail "quiet green wrote an issue"
last="$(grep '^issue ' "$TMP_DIR/gh.log" | tail -1)"
[[ "$last" == "issue list "* ]] || fail "quiet green last call: $last"

# schedule is allowed. push and pull_request are refused before gh runs.
GITHUB_EVENT_NAME=schedule run_owner 105 nightly failure >/dev/null
[[ "$(open_count)" == "1" ]] || fail "schedule failure did not open"
jq -e '.title == "CI scheduled lane failed: nightly"' "$TMP_DIR/state/2.json" >/dev/null \
  || fail "nightly issue: $(issue_json 2)"

log_lines="$(wc -l < "$TMP_DIR/gh.log" | tr -d ' ')"
set +e
GITHUB_EVENT_NAME=pull_request run_owner 106 ci-macos-compat failure >"$TMP_DIR/pr.out" 2>"$TMP_DIR/pr.err"
pr_status=$?
GITHUB_EVENT_NAME=push run_owner 107 ci-hourly failure >"$TMP_DIR/push.out" 2>"$TMP_DIR/push.err"
push_status=$?
set -e
[[ "$pr_status" == "2" ]] || fail "pull_request exited $pr_status"
[[ "$push_status" == "2" ]] || fail "push exited $push_status"
grep -q "does not run for event pull_request" "$TMP_DIR/pr.err" || fail "pull_request stderr: $(cat "$TMP_DIR/pr.err")"
grep -q "does not run for event push" "$TMP_DIR/push.err" || fail "push stderr: $(cat "$TMP_DIR/push.err")"
[[ "$(wc -l < "$TMP_DIR/gh.log" | tr -d ' ')" == "$log_lines" ]] || fail "refused events called gh"

# A bad result is a usage error.
set +e
GITHUB_RUN_ID=108 "$SCRIPT" ci-hourly exploded >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"
bad_status=$?
set -e
unset GITHUB_EVENT_NAME
[[ "$bad_status" == "2" ]] || fail "bad result exited $bad_status"

echo "ok"
