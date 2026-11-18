#!/usr/bin/env bash
# C11H-197 end to end on a tagged dev build: window names, window themes,
# placement across displays, and their survival across a relaunch.
#
#   scripts/e2e-windows.sh <tag> [--out <dir>]
#
# Launches "c11 DEV <tag>.app" in the background (open -g: it never takes
# focus), drives it only through its own bundled CLI and socket, quits it,
# relaunches it with --qa resume, and verifies. The production c11, its hc
# cores and the operator's windows are never touched; only the dev build's
# windows move. Run it on a Mac with the displays you want covered (the operator's
# laptop has three); with one display the cross-display step moves within it.
set -euo pipefail

TAG="${1:?usage: e2e-windows.sh <tag> [--out <dir>]}"
shift
OUT="${TMPDIR:-/tmp}/c11-e2e-windows-${TAG}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
BID="com.stage11.c11.debug.$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g')"
APP="$HOME/Library/Developer/Xcode/DerivedData/c11-${SLUG}/Build/Products/Debug/c11 DEV ${TAG}.app"
SOCK="/tmp/c11-debug-${SLUG}.sock"
STATE="$OUT/state.json"
[[ -d "$APP" ]] || { echo "no tagged app at $APP (build it with scripts/remote-build.sh --tag $TAG)" >&2; exit 2; }
/bin/rm -rf "$OUT"
mkdir -p "$OUT"

quit_dev() {
  /usr/bin/osascript -e "tell application id \"${BID}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f "c11 DEV ${TAG}.app/Contents/MacOS/" >/dev/null || return 0
    sleep 0.2
  done
  echo "dev build did not quit in 10 s" >&2
  return 1
}
# The dev bundle's own hc core (session c11-<tag>), never production's. A
# rebuilt bundle cannot attach to a core an older binary started, so each run
# starts and ends without one.
stop_dev_core() {
  local pid
  for pid in $(pgrep -f "c11 DEV ${TAG}.app/Contents/Helpers/herdr-core" || true); do
    ps -o command= -p "$pid" | grep -q "c11 DEV ${TAG}.app/Contents/Helpers/herdr-core" && kill "$pid" || true
  done
}
cleanup() { quit_dev || true; stop_dev_core; }
trap cleanup EXIT
quit_dev
stop_dev_core

# The dev build's own defaults domain: no quit prompt, so Quit is scriptable.
defaults write "$BID" warnBeforeQuitShortcut -bool false

started=$SECONDS
"$ROOT/scripts/launch-tagged-automation.sh" "$TAG" --qa fresh --wait-socket 20 >"$OUT/launch-1.log"
grep -q "socket_ready: yes" "$OUT/launch-1.log" || { cat "$OUT/launch-1.log"; exit 1; }
set +e
python3 "$ROOT/scripts/e2e-windows.py" setup --app "$APP" --socket "$SOCK" --state "$STATE" --out "$OUT"
setup_status=$?
set -e

quit_dev
"$ROOT/scripts/launch-tagged-automation.sh" "$TAG" --qa resume --wait-socket 20 >"$OUT/launch-2.log"
grep -q "socket_ready: yes" "$OUT/launch-2.log" || { cat "$OUT/launch-2.log"; exit 1; }
# The resumed session restores its windows just after the socket opens.
for _ in $(seq 1 50); do
  count=$(env -i HOME="$HOME" PATH=/usr/bin:/bin "$APP/Contents/Resources/bin/c11h" --socket "$SOCK" list-windows --json 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
  [[ "$count" -ge 2 ]] && break
  sleep 0.2
done
set +e
python3 "$ROOT/scripts/e2e-windows.py" verify --app "$APP" --socket "$SOCK" --state "$STATE" --out "$OUT"
verify_status=$?
set -e

echo "e2e-windows: setup=$setup_status verify=$verify_status in $((SECONDS - started)) s; screenshots in $OUT"
[[ $setup_status -eq 0 && $verify_status -eq 0 ]]
