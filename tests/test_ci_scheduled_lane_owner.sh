#!/usr/bin/env bash
# The lane watcher opens one issue, comments on the next failure, closes it
# on green, does nothing when green has no issue, treats a quiet lane as
# stale, and ignores a superseded cancel until three cancels in a row.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci-scheduled-lane-owner.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-lane-owner.XXXXXX")"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

NOW=1700000000
iso_at() {
  python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}
RECENT="$(iso_at $((NOW - 60)))"
OLDER="$(iso_at $((NOW - 120)))"
OLDEST="$(iso_at $((NOW - 180)))"
STALE="$(iso_at $((NOW - 5 * 3600)))"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
echo 1 > "$TMP_DIR/state/next"

cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_GH_LOG"
[[ "${1:-}" == "issue" || "${1:-}" == "run" ]] || { echo "unexpected gh $*" >&2; exit 2; }
kind="$1"
sub="${2:-}"
shift 2

repo="" title="" body="" assignee="" state_filter="" reason="" comment="" number="" add_assignee="" workflow=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --assignee) assignee="$2"; shift 2 ;;
    --add-assignee) add_assignee="$2"; shift 2 ;;
    --state) state_filter="$2"; shift 2 ;;
    --limit) shift 2 ;;
    --json) shift 2 ;;
    --reason) reason="$2"; shift 2 ;;
    --comment) comment="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --branch) shift 2 ;;
    --status) shift 2 ;;
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

case "$kind $sub" in
  "run list")
    [[ -n "$workflow" ]] || { echo "run list missing workflow" >&2; exit 2; }
    fixture="$TEST_GH_STATE/runs-${workflow}"
    if [[ -f "$fixture" ]]; then
      cat "$fixture"
    else
      echo '[]'
    fi
    ;;
  "issue list")
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
  "issue create")
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
  "issue comment")
    [[ -n "$number" && -n "$body" ]] || { echo "comment missing fields" >&2; exit 2; }
    [[ -f "$(issue_file "$number")" ]] || { echo "no issue $number" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg body "$body" '.comments += [$body]' "$(issue_file "$number")" > "$tmp"
    /bin/mv -f "$tmp" "$(issue_file "$number")"
    ;;
  "issue edit")
    [[ -n "$number" && -n "$add_assignee" ]] || { echo "edit missing fields" >&2; exit 2; }
    [[ -f "$(issue_file "$number")" ]] || { echo "no issue $number" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg assignee "$add_assignee" '.assignee = $assignee' "$(issue_file "$number")" > "$tmp"
    /bin/mv -f "$tmp" "$(issue_file "$number")"
    ;;
  "issue close")
    [[ -n "$number" && -n "$comment" && "$reason" == "completed" ]] || { echo "close missing fields" >&2; exit 2; }
    [[ -f "$(issue_file "$number")" ]] || { echo "no issue $number" >&2; exit 1; }
    tmp="$(mktemp)"
    jq --arg body "$comment" '.state = "closed" | .comments += [$body]' "$(issue_file "$number")" > "$tmp"
    /bin/mv -f "$tmp" "$(issue_file "$number")"
    ;;
  *)
    echo "unexpected gh $kind $sub" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

export PATH="$TMP_DIR/bin:$PATH"
export TEST_GH_LOG="$TMP_DIR/gh.log"
export TEST_GH_STATE="$TMP_DIR/state"
export GITHUB_REPOSITORY="Stage-11-Agentics/c11"
export C11_LANE_NOW="$NOW"
unset GITHUB_EVENT_NAME CI_LANE_OWNER

run_owner() {
  "$SCRIPT" "$@"
}

put_runs() {
  local workflow="$1" json="$2"
  printf '%s\n' "$json" > "$TMP_DIR/state/runs-${workflow}"
}

run_json() {
  local conclusion="$1" when="$2" id="$3"
  printf '{"conclusion":"%s","updatedAt":"%s","url":"https://github.com/Stage-11-Agentics/c11/actions/runs/%s","databaseId":%s,"headSha":"abc"}' \
    "$conclusion" "$when" "$id" "$id"
}

fresh_success() {
  printf '[%s]\n' "$(run_json success "$RECENT" 1)"
}

put_runs ci-hourly.yml "$(fresh_success)"
put_runs ci-macos-compat.yml "$(fresh_success)"
put_runs nightly.yml "$(fresh_success)"

count_writes() {
  local n
  n="$(grep -cE '^issue (create|comment|close|edit) ' "$TMP_DIR/gh.log" || true)"
  printf '%s' "${n:-0}"
}

issue_json() {
  cat "$TMP_DIR/state/$1.json"
}

# Dry-run is read-only. A failing lane says it would open, and gh is not asked to write.
put_runs ci-hourly.yml "$(printf '[%s]\n' "$(run_json failure "$RECENT" 101)")"
: > "$TMP_DIR/gh.log"
dry="$(run_owner --dry-run)"
printf '%s\n' "$dry" | grep -q 'lane-owner: ci-hourly fail failure .* -> would open' \
  || fail "dry-run did not say it would open: $dry"
[[ "$(count_writes)" == "0" ]] || fail "dry-run wrote an issue"

# Open: one failure creates one issue and one comment.
: > "$TMP_DIR/gh.log"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly fail failure .* -> opened #1' \
  || fail "failure did not open: $live"
[[ "$(find "$TMP_DIR/state" -name '*.json' | wc -l | tr -d ' ')" == "1" ]] || fail "open created the wrong number of issues"
jq -e '.number == 1 and .title == "CI scheduled lane failed: ci-hourly" and .assignee == "BenevolentFutures" and (.comments | length) == 1' \
  "$TMP_DIR/state/1.json" >/dev/null || fail "opened issue shape: $(issue_json 1)"
jq -e '.comments[0] | contains("failed (failure)") and contains("actions/runs/101")' "$TMP_DIR/state/1.json" >/dev/null \
  || fail "open comment: $(issue_json 1)"

# Comment: a second look at the same failure adds a comment and does not open again.
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly fail failure .* -> commented #1' \
  || fail "second failure did not comment: $live"
jq -e '(.comments | length) == 2' "$TMP_DIR/state/1.json" >/dev/null \
  || fail "second failure comments: $(issue_json 1)"
creates="$(grep -c '^issue create ' "$TMP_DIR/gh.log" || true)"
[[ "$creates" == "1" ]] || fail "expected 1 create, got ${creates:-0}"

# Close: a success closes that issue.
put_runs ci-hourly.yml "$(printf '[%s]\n' "$(run_json success "$RECENT" 102)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly pass success .* -> closed #1' \
  || fail "success did not close: $live"
jq -e '.state == "closed" and (.comments | length) == 3 and (.comments[2] | contains("passed") and contains("actions/runs/102"))' \
  "$TMP_DIR/state/1.json" >/dev/null || fail "close comment: $(issue_json 1)"

# No-op: a success with no open issue does not write.
writes_before="$(count_writes)"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly pass success .* -> nothing' \
  || fail "quiet green said: $live"
[[ "$(count_writes)" == "$writes_before" ]] || fail "quiet green wrote an issue"

# Stale: a compat success older than 3h is a failure. ci-hourly has no stale window.
put_runs ci-macos-compat.yml "$(printf '[%s]\n' "$(run_json success "$STALE" 201)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-macos-compat fail stale .* -> opened #2' \
  || fail "stale success did not open: $live"
jq -e '.title == "CI scheduled lane failed: ci-macos-compat" and (.comments[0] | contains("stale"))' \
  "$TMP_DIR/state/2.json" >/dev/null || fail "stale issue: $(issue_json 2)"

# A cancelled run superseded by a success is not a failure, and it closes the stale issue.
put_runs ci-macos-compat.yml "$(printf '[%s,%s]\n' \
  "$(run_json cancelled "$RECENT" 301)" \
  "$(run_json success "$OLDER" 302)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-macos-compat pass success .* -> closed #2' \
  || fail "superseded cancel was reported: $live"

# Three cancelled runs in a row are a failure. startup_failure and timed_out are too.
put_runs nightly.yml "$(printf '[%s,%s,%s]\n' \
  "$(run_json cancelled "$RECENT" 401)" \
  "$(run_json cancelled "$OLDER" 402)" \
  "$(run_json cancelled "$OLDEST" 403)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: nightly fail cancelled .* -> opened #3' \
  || fail "three cancels were not a failure: $live"

put_runs ci-hourly.yml "$(printf '[%s,%s]\n' \
  "$(run_json skipped "$RECENT" 501)" \
  "$(run_json failure "$OLDER" 502)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly fail failure .* -> opened #4' \
  || fail "skipped run hid the failure: $live"

put_runs ci-hourly.yml "$(printf '[%s]\n' "$(run_json timed_out "$RECENT" 503)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly fail timed_out .* -> commented #4' \
  || fail "timed_out was not a failure: $live"

put_runs ci-hourly.yml "$(printf '[%s]\n' "$(run_json startup_failure "$RECENT" 504)")"
live="$(run_owner)"
printf '%s\n' "$live" | grep -q 'lane-owner: ci-hourly fail startup_failure .* -> commented #4' \
  || fail "startup_failure was not a failure: $live"

# The assignee follows CI_LANE_OWNER when a new issue is opened.
put_runs nightly.yml "$(fresh_success)"
run_owner >/dev/null
put_runs nightly.yml "$(printf '[%s]\n' "$(run_json failure "$RECENT" 601)")"
CI_LANE_OWNER=custom-owner run_owner >/dev/null
jq -e '.assignee == "custom-owner"' "$TMP_DIR/state/5.json" >/dev/null \
  || fail "owner env was ignored: $(issue_json 5)"
unset CI_LANE_OWNER

# push and pull_request cannot write.
log_lines="$(wc -l < "$TMP_DIR/gh.log" | tr -d ' ')"
set +e
GITHUB_EVENT_NAME=pull_request run_owner >"$TMP_DIR/pr.out" 2>"$TMP_DIR/pr.err"
pr_status=$?
GITHUB_EVENT_NAME=push run_owner >"$TMP_DIR/push.out" 2>"$TMP_DIR/push.err"
push_status=$?
set -e
[[ "$pr_status" == "2" ]] || fail "pull_request exited $pr_status"
[[ "$push_status" == "2" ]] || fail "push exited $push_status"
grep -q "does not run for event pull_request" "$TMP_DIR/pr.err" || fail "pull_request stderr: $(cat "$TMP_DIR/pr.err")"
[[ "$(wc -l < "$TMP_DIR/gh.log" | tr -d ' ')" == "$log_lines" ]] || fail "refused events called gh"

echo ok
