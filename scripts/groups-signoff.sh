#!/usr/bin/env bash
set -euo pipefail

# C11-261 owner runner. This script is an evidence collector, not an approval
# writer: H1-H3 remain null until Atin records them outside the harness.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PYTHON="${PYTHON:-python3}"
TAG=""
RESULTS_DIR=""
BASELINE_ARTIFACT=""
PERF_ARTIFACT=""
LIFECYCLE_TIMEOUT="60"
SKIP_RESTORE="0"

usage() {
  cat <<'EOF'
Usage: ./scripts/groups-signoff.sh <tag> [options]

Runs the C11-261 g60-v1 socket oracle, tagged fresh/resume restore checks, and
leaves the C1-C6 computer-use chapters for the independent reviewer.

Options:
  --results <absolute-dir>          Evidence directory (default: /tmp/c11-groups-signoff-<tag>-<utc>)
  --perf-artifact <absolute>        Completed targeted candidate-versus-main comparison
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
    --perf-artifact)
      [[ $# -ge 2 ]] || die "--perf-artifact requires a path"
      PERF_ARTIFACT="$2"
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
  local chapter="${1:-cleanup}"
  local outcome="graceful"
  if [[ -z "$(tagged_pids)" ]]; then outcome="already_absent"; fi
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
      record_quit "$chapter" "$outcome"
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
    outcome="forced_term"
    kill $pids 2>/dev/null || true
  fi
  deadline=$(( $(epoch_seconds) + 10 ))
  while (( $(epoch_seconds) < deadline )); do
    if [[ -z "$(tagged_pids)" ]]; then
      record_quit "$chapter" "$outcome"
      return 0
    fi
    sleep 0.25
  done

  pids="$(tagged_pids)"
  if [[ -n "$pids" ]]; then
    outcome="forced_kill"
    kill -KILL $pids 2>/dev/null || true
  fi
  deadline=$(( $(epoch_seconds) + 5 ))
  while (( $(epoch_seconds) < deadline )); do
    if [[ -z "$(tagged_pids)" ]]; then
      record_quit "$chapter" "$outcome"
      return 0
    fi
    sleep 0.25
  done
  record_quit "$chapter" "still_running"
  return 1
}

record_quit() {
  QUIT_OUTCOME="$2"
  "$PYTHON" - "$RESULTS_DIR/termination.jsonl" "$1" "$2" <<'PY'
import json, sys, time
with open(sys.argv[1], "a") as stream:
    stream.write(json.dumps({"chapter": sys.argv[2], "outcome": sys.argv[3],
                            "at": time.time(), "clean_quit": sys.argv[3] == "graceful"}) + "\n")
PY
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
        "artifact_sha256": {relative: hashlib.sha256((Path(app) / relative).read_bytes()).hexdigest()
                            for relative in ("Contents/MacOS/c11", "Contents/MacOS/c11.debug.dylib", "Contents/Resources/bin/c11")
                            if (Path(app) / relative).is_file()},
        "bundle_info": run("/usr/bin/plutil", "-convert", "json", "-o", "-", str(Path(app) / "Contents/Info.plist")),
        "running_build_identity": run(cli, "--socket", socket_path, "--json", "capabilities"),
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
  quit_tagged A11
  a11_quit="$QUIT_OUTCOME"
  launch_tagged resume
  run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/post-resume.json" \
    > "$RESULTS_DIR/post-resume-save.json"
  run_logged "$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" compare-session \
    --mode groups --expected "$RESULTS_DIR/post-mutation.json" --actual "$RESULTS_DIR/post-resume.json" \
    > "$RESULTS_DIR/a11-semantics.json"
  "$PYTHON" - "$RESULTS_DIR/a11-semantics.json" "$RESULTS_DIR/a11-compare.json" "$a11_quit" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
result["termination_outcome"] = sys.argv[3]
result["restart_kind"] = "clean-restart" if sys.argv[3] == "graceful" else "forced-restore"
if sys.argv[3] != "graceful":
    result.update(status="UNVERIFIED", reason="A11 requires a graceful quit; forced cleanup is not clean-restart proof")
Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")
PY

  quit_tagged A12
  cp "$ROOT_DIR/tests_v2/fixtures/pre-group-session.json" "$SESSION_PATH"
  launch_tagged resume
  run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/pre-group-resume.json" \
    > "$RESULTS_DIR/pre-group-save.json"
  run_logged "$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" compare-session \
    --mode pre-group --expected "$ROOT_DIR/tests_v2/fixtures/pre-group-session.json" \
    --actual "$RESULTS_DIR/pre-group-resume.json" > "$RESULTS_DIR/a12-compare.json"

  quit_tagged A13
  cp "$ROOT_DIR/tests_v2/fixtures/empty-group-session.json" "$SESSION_PATH"
  launch_tagged resume
  run_logged "$CLI" --socket "$SOCKET" --json state save --out "$RESULTS_DIR/empty-group-resume.json" \
    > "$RESULTS_DIR/empty-group-save.json"
  run_logged "$PYTHON" "$ROOT_DIR/tests_v2/test_workspace_groups_scale.py" compare-session \
    --mode empty-group --expected "$ROOT_DIR/tests_v2/fixtures/empty-group-session.json" \
    --actual "$RESULTS_DIR/empty-group-resume.json" > "$RESULTS_DIR/a13-compare.json"
fi

"$PYTHON" - "$RESULTS_DIR/perf.json" "$PERF_ARTIFACT" <<'PY'
import json, sys
from pathlib import Path
path, artifact = sys.argv[1:]
result = json.loads(Path(artifact).read_text()) if artifact else {
    "status": "unverified", "reason": "targeted candidate-versus-main comparison not supplied"}
result["operator_signoff"] = None
Path(path).write_text(json.dumps(result, indent=2) + "\n")
PY

run_logged "$ROOT_DIR/scripts/groups-fixture.sh" "$TAG" cleanup --state "$STATE" \
  --out "$RESULTS_DIR/cleanup.json" > "$RESULTS_DIR/cleanup-summary.json"
CLEANUP_DONE="1"
quit_tagged

write_manifest "complete"
printf '%s\n' "C11-261 sign-off evidence: $RESULTS_DIR"
printf '%s\n' "A1-A10 socket oracle, A11-A13 restore artifacts, and AC5 record are in that directory."
printf '%s\n' "C1-C6 remain pending independent computer-use review; H1-H3 remain blank."
