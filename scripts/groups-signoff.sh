#!/usr/bin/env bash
set -euo pipefail

# C11-261 owner runner. This script is an evidence collector, not an approval
# writer: H1-H3 remain null until Atin records them outside the harness.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHON="${PYTHON:-python3}"
TAG=""
RESULTS_DIR=""
BASELINE_ARTIFACT=""
LIFECYCLE_TIMEOUT="60"
SKIP_RESTORE="0"

usage() {
  cat <<'EOF'
Usage: ./scripts/groups-signoff.sh <tag> [options]

Runs the C11-261 g60-v1 socket oracle, tagged fresh/resume restore checks, and
leaves the C1-C6 computer-use chapters for the independent reviewer.

Options:
  --results <absolute-dir>          Evidence directory (default: /tmp/c11-groups-signoff-<tag>-<utc>)
  --baseline-artifact <absolute>    C11-270 registered performance baseline artifact
  --lifecycle-timeout <seconds>     A8 native waiting probe bound (default: 60)
  --skip-restore                    Record restore chapters as unverified; use only for a partial run
EOF
}

die() {
  echo "groups-signoff: $*" >&2
  exit 2
}

sanitize_path() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

epoch_seconds() {
  /bin/date +%s
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
TAG="$1"
shift
[[ "$TAG" =~ ^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$ ]] || die "tag must be a simple tagged-build name"
TAG_SLUG="$(sanitize_path "$TAG")"
[[ -n "$TAG_SLUG" ]] || die "tag produced an empty socket slug"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --results)
      [[ $# -ge 2 ]] || die "--results requires a directory"
      RESULTS_DIR="$2"
      shift 2
      ;;
    --baseline-artifact)
      [[ $# -ge 2 ]] || die "--baseline-artifact requires a path"
      BASELINE_ARTIFACT="$2"
      shift 2
      ;;
    --lifecycle-timeout)
      [[ $# -ge 2 ]] || die "--lifecycle-timeout requires seconds"
      LIFECYCLE_TIMEOUT="$2"
      shift 2
      ;;
    --skip-restore)
      SKIP_RESTORE="1"
      shift
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

if [[ -z "$RESULTS_DIR" ]]; then
  RESULTS_DIR="/tmp/c11-groups-signoff-${TAG_SLUG}-$(date -u +%Y%m%dT%H%M%SZ)"
fi

[[ "$RESULTS_DIR" = /* && "$RESULTS_DIR" != *".."* ]] || die "results must be an absolute path without traversal"
mkdir -p "$RESULTS_DIR"
[[ ! -L "$RESULTS_DIR" ]] || die "results directory must not be a symlink"

SOCKET="/tmp/c11-debug-${TAG_SLUG}.sock"
APP="$HOME/Library/Developer/Xcode/DerivedData/c11-${TAG_SLUG}/Build/Products/Debug/c11 DEV ${TAG}.app"
CLI="${C11_CLI:-${APP}/Contents/Resources/bin/c11}"
BUNDLE_ID="com.stage11.c11.debug.$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
SESSION_PATH="$HOME/Library/Application Support/c11/session-${BUNDLE_ID}.json"
STATE="/tmp/c11-groups-g60-${TAG_SLUG}/state.json"
FIXTURE_ROOT="/tmp/c11-groups-g60-${TAG_SLUG}"
COMMANDS="$RESULTS_DIR/commands.txt"
MANIFEST="$RESULTS_DIR/run.json"
CLEANUP_DONE="0"

[[ -d "$APP" ]] || die "tagged app is missing; build it on Atlas first: $APP"
[[ -f "$CLI" && -x "$CLI" ]] || die "tagged CLI is missing or not executable: $CLI"
[[ "$SOCKET" != "$HOME/Library/Application Support/c11/c11.sock" ]] || die "production socket is forbidden"
[[ "$RESULTS_DIR" != "$FIXTURE_ROOT" && "$RESULTS_DIR" != /tmp/c11-groups-g60-* ]] || die "results must not be inside the disposable fixture root"

export C11_SOCKET="$SOCKET"
export C11_CLI="$CLI"
export C11_GROUPS_TEST_TAG="$TAG_SLUG"
export PYTHONPATH="$ROOT_DIR/tests_v2${PYTHONPATH:+:$PYTHONPATH}"

: > "$COMMANDS"

run_logged() {
  {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
  } >> "$COMMANDS"
  "$@"
}

quit_tagged() {
  # AppleScript can wait indefinitely when the tagged app has already exited
  # but LaunchServices still has a stale bundle registration. The process
  # probe below is authoritative, so keep the courtesy quit request bounded.
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 &
  local quit_pid=$!
  local quit_deadline=$(( $(epoch_seconds) + 5 ))
  while kill -0 "$quit_pid" 2>/dev/null; do
    if (( $(epoch_seconds) >= quit_deadline )); then
      kill "$quit_pid" 2>/dev/null || true
      break
    fi
    sleep 0.25
  done
  wait "$quit_pid" 2>/dev/null || true
  local deadline=$(( $(epoch_seconds) + 30 ))
  while (( $(epoch_seconds) < deadline )); do
    if [[ -z "$(tagged_pids)" ]]; then
      return 0
    fi
    sleep 0.25
  done

  # A disposable tagged QA app may keep an AppKit quit request pending (for
  # example while a lifecycle probe still owns a terminal). Once the graceful
  # window has elapsed, terminate only this exact tagged executable so restore
  # chapters cannot be skipped and no operator-owned c11 process is touched.
  local pids
  pids="$(tagged_pids)"
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
  fi
  deadline=$(( $(epoch_seconds) + 10 ))
  while (( $(epoch_seconds) < deadline )); do
    if [[ -z "$(tagged_pids)" ]]; then
      return 0
    fi
    sleep 0.25
  done

  pids="$(tagged_pids)"
  if [[ -n "$pids" ]]; then
    kill -KILL $pids 2>/dev/null || true
  fi
  deadline=$(( $(epoch_seconds) + 5 ))
  while (( $(epoch_seconds) < deadline )); do
    if [[ -z "$(tagged_pids)" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

tagged_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v target="$APP/Contents/MacOS/c11" \
    '{ command = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command); if (command == target) print $1 }'
}

launch_tagged() {
  local mode="$1"
  run_logged "$ROOT_DIR/scripts/launch-tagged-automation.sh" "$TAG" --qa "$mode" --wait-socket 30
  [[ -S "$SOCKET" ]] || die "tagged socket did not appear after QA launch: $SOCKET"
  local deadline=$(( $(epoch_seconds) + 60 ))
  while (( $(epoch_seconds) < deadline )); do
    if "$CLI" --socket "$SOCKET" --json tree --all >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  die "tagged app did not finish session restoration within 60 seconds: $SOCKET"
}

write_manifest() {
  local status="$1"
  local reason="${2:-}"
  python3 - "$MANIFEST" "$ROOT_DIR" "$TAG" "$TAG_SLUG" "$SOCKET" "$CLI" "$APP" "$RESULTS_DIR" "$status" "$reason" "$BASELINE_ARTIFACT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

path, root, tag, slug, socket_path, cli, app, results, status, reason, baseline = sys.argv[1:]

def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=False, timeout=5).stdout.strip()
    except Exception:
        return ""

manifest = {
    "schema": "c11-261-signoff-v1",
    "ticket": "C11-261",
    "tag": tag,
    "tag_slug": slug,
    "status": status,
    "status_reason": reason or None,
    "started_at_unix": time.time(),
    "host": platform.node(),
    "platform": platform.platform(),
    "display_identity": {
        "source": "system_profiler SPDisplaysDataType",
        "value": run("/usr/sbin/system_profiler", "SPDisplaysDataType"),
    },
    "source": {
        "root": root,
        "head": run("git", "-C", root, "rev-parse", "HEAD"),
        "origin_main": run("git", "-C", root, "rev-parse", "origin/main"),
        "worktree_status": run("git", "-C", root, "status", "--short"),
    },
    "candidate": {
        "app": app,
        "app_exists": Path(app).is_dir(),
        "cli": cli,
        "cli_sha256": hashlib.sha256(Path(cli).read_bytes()).hexdigest() if Path(cli).is_file() else None,
        "socket": socket_path,
        "socket_is_production": socket_path == os.path.expanduser("~/Library/Application Support/c11/c11.sock"),
    },
    "results_dir": results,
    "baseline_artifact": baseline or None,
    "chapters": {"A1-A10": None, "A11": None, "A12": None, "A13": None,
                  "C1-C6": "pending independent computer-use reviewer", "AC5": None},
    "operator_signoff": {"H1": None, "H2": None, "H3": None, "recorded_by": None, "recorded_at": None},
    "approval_written_by_harness": False,
}

Path(path).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

cleanup_on_exit() {
  local rc=$?
  if [[ "$CLEANUP_DONE" != "1" ]]; then
    if [[ -f "$STATE" && -S "$SOCKET" ]]; then
      groups_cleanup=("$ROOT_DIR/scripts/groups-fixture.sh" "$TAG" cleanup --state "$STATE" --out "$RESULTS_DIR/cleanup.json")
      "${groups_cleanup[@]}" >> "$COMMANDS" 2>&1 || true
    fi
    quit_tagged || true
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

write_manifest "running"
launch_tagged fresh

run_logged "$ROOT_DIR/scripts/groups-fixture.sh" "$TAG" provision \
  --state "$STATE" --fixture-root "$FIXTURE_ROOT" > "$RESULTS_DIR/provision-summary.json"
run_logged "$ROOT_DIR/scripts/groups-fixture.sh" "$TAG" automated \
  --state "$STATE" --out "$RESULTS_DIR/steps.jsonl" --lifecycle-timeout "$LIFECYCLE_TIMEOUT" \
  > "$RESULTS_DIR/automation-summary.json"
run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/post-mutation.json" \
  > "$RESULTS_DIR/post-mutation-save.json"
write_manifest "automated_complete"

if [[ "$SKIP_RESTORE" = "1" ]]; then
  printf '%s\n' '{"status":"UNVERIFIED","reason":"--skip-restore was requested; A11-A13 were not run","operator_signoff":null}' \
    > "$RESULTS_DIR/restore.json"
else
  quit_tagged
  launch_tagged resume
  run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/post-resume.json" \
    > "$RESULTS_DIR/post-resume-save.json"
  run_logged "$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" compare-session \
    --mode groups --expected "$RESULTS_DIR/post-mutation.json" --actual "$RESULTS_DIR/post-resume.json" \
    > "$RESULTS_DIR/a11-compare.json"

  quit_tagged
  cp "$ROOT_DIR/tests_v2/fixtures/pre-group-session.json" "$SESSION_PATH"
  launch_tagged resume
  run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/pre-group-resume.json" \
    > "$RESULTS_DIR/pre-group-save.json"
  run_logged "$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" compare-session \
    --mode pre-group --expected "$ROOT_DIR/tests_v2/fixtures/pre-group-session.json" \
    --actual "$RESULTS_DIR/pre-group-resume.json" > "$RESULTS_DIR/a12-compare.json"

  quit_tagged
  cp "$ROOT_DIR/tests_v2/fixtures/empty-group-session.json" "$SESSION_PATH"
  launch_tagged resume
  run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/empty-group-resume.json" \
    > "$RESULTS_DIR/empty-group-save.json"
  run_logged "$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" compare-session \
    --mode empty-group --expected "$ROOT_DIR/tests_v2/fixtures/empty-group-session.json" \
    --actual "$RESULTS_DIR/empty-group-resume.json" > "$RESULTS_DIR/a13-compare.json"
fi

if [[ -n "$BASELINE_ARTIFACT" ]]; then
  [[ -f "$BASELINE_ARTIFACT" && ! -L "$BASELINE_ARTIFACT" ]] || die "baseline artifact is missing or a symlink"
  baseline_status="provided; AC5 measurement still belongs to the registered C11-270 harness"
  baseline_sha="$(shasum -a 256 "$BASELINE_ARTIFACT" | awk '{print $1}')"
else
  baseline_status="unverified: no C11-270 baseline artifact was supplied"
  baseline_sha=""
fi
python3 - "$RESULTS_DIR/perf.json" "$baseline_status" "$BASELINE_ARTIFACT" "$baseline_sha" <<'PY'
import json
from pathlib import Path
import sys

path, status, artifact, sha = sys.argv[1:]
Path(path).write_text(json.dumps({
    "schema": "c11-261-ac5-record-v1",
    "status": "unverified",
    "reason": status,
    "baseline_artifact": artifact or None,
    "baseline_sha256": sha or None,
    "registered_owner": "C11-270",
    "same_host_display_pair": None,
    "operator_signoff": None,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

run_logged "$ROOT_DIR/scripts/groups-fixture.sh" "$TAG" cleanup --state "$STATE" \
  --out "$RESULTS_DIR/cleanup.json" > "$RESULTS_DIR/cleanup-summary.json"
CLEANUP_DONE="1"
quit_tagged

write_manifest "complete"
printf '%s\n' "C11-261 sign-off evidence: $RESULTS_DIR"
printf '%s\n' "A1-A10 socket oracle, A11-A13 restore artifacts, and AC5 record are in that directory."
printf '%s\n' "C1-C6 remain pending independent computer-use review; H1-H3 remain blank."
