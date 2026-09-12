#!/usr/bin/env bash
# with-build-lock.sh — run one command while holding the machine-wide c11 build lock.
#
#   scripts/with-build-lock.sh xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 ... build
#
# Only one c11 build may run on a machine at a time (C11-215). Two concurrent
# xcodebuilds, each spawning a swift-frontend per core, put the load average in
# the hundreds and starve both builds, the operator's c11, and every agent on the
# box. Every local build entry point (reload.sh, reloads.sh, reloadp.sh,
# test-unit-local.sh, test-unit.sh) runs xcodebuild through this wrapper; raw
# xcodebuild calls from prompts or shells must do the same.
#
# The lock is a directory (mkdir is atomic on APFS) holding the owner's pid, a
# label, and a start time. A waiter reports who holds the lock every 30 s, takes
# over a lock whose owner pid is gone, and gives up after C11_BUILD_LOCK_TIMEOUT
# seconds (default 90 min) with exit 75.
#
# Environment:
#   C11_BUILD_LOCK=0             bypass entirely (CI runners are single-tenant)
#   C11_BUILD_LOCK_DIR=<path>    lock location (default /tmp/c11-build.lock)
#   C11_BUILD_LOCK_TIMEOUT=<s>   how long to wait before giving up (default 5400)
#   C11_BUILD_LOCK_LABEL=<text>  what to show waiters (default: C11_TAG or the cwd name)
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: with-build-lock.sh <command> [args...]" >&2
  exit 2
fi

if [[ "${C11_BUILD_LOCK:-1}" == "0" ]]; then
  exec "$@"
fi

LOCK_DIR="${C11_BUILD_LOCK_DIR:-/tmp/c11-build.lock}"
TIMEOUT="${C11_BUILD_LOCK_TIMEOUT:-5400}"
LABEL="${C11_BUILD_LOCK_LABEL:-${C11_TAG:-$(basename "$PWD")}}"

read_meta() { cat "$LOCK_DIR/$1" 2>/dev/null || true; }

start=$(date +%s)
last_report=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  owner_pid="$(read_meta pid)"
  if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
    echo "[build-lock] owner pid $owner_pid ($(read_meta label)) is gone; taking over the lock" >&2
    rm -rf "$LOCK_DIR"
    continue
  fi
  now=$(date +%s)
  waited=$((now - start))
  if (( waited >= TIMEOUT )); then
    echo "[build-lock] gave up after ${waited}s: lock held by pid ${owner_pid:-?} ($(read_meta label), since $(read_meta since))" >&2
    exit 75
  fi
  if (( now - last_report >= 30 )); then
    echo "[build-lock] waiting: another c11 build is running (pid ${owner_pid:-?}, $(read_meta label), since $(read_meta since)); ${waited}s so far" >&2
    last_report=$now
  fi
  sleep 2
done

echo "$$" > "$LOCK_DIR/pid"
echo "$LABEL" > "$LOCK_DIR/label"
date '+%Y-%m-%dT%H:%M:%S' > "$LOCK_DIR/since"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM HUP

"$@"
