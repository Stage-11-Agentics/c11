#!/usr/bin/env bash
# Behavioral test for scripts/with-build-lock.sh: wrapped commands never overlap,
# a lock whose owner died is taken over, and C11_BUILD_LOCK=0 bypasses.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAP="$ROOT/scripts/with-build-lock.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export C11_BUILD_LOCK_DIR="$TMP/lock"
export C11_BUILD_LOCK_TIMEOUT=20
LOG="$TMP/log"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Serialization: B starts after A finishes even though B was launched while A ran.
"$WRAP" bash -c "echo A-start >> '$LOG'; sleep 1.5; echo A-end >> '$LOG'" &
A_PID=$!
sleep 0.4
"$WRAP" bash -c "echo B-start >> '$LOG'; echo B-end >> '$LOG'"
wait "$A_PID"
[[ "$(tr '\n' ' ' < "$LOG")" == "A-start A-end B-start B-end " ]] || fail "commands overlapped: $(tr '\n' ' ' < "$LOG")"
[[ ! -d "$C11_BUILD_LOCK_DIR" ]] || fail "lock not released after commands finished"

# 2. Exit code of the wrapped command propagates.
set +e; "$WRAP" bash -c "exit 7"; rc=$?; set -e
[[ "$rc" -eq 7 ]] || fail "expected exit 7, got $rc"

# 3. Stale lock (owner pid gone) is taken over instead of waited on.
mkdir -p "$C11_BUILD_LOCK_DIR"
echo 999999 > "$C11_BUILD_LOCK_DIR/pid"; echo stale > "$C11_BUILD_LOCK_DIR/label"; echo never > "$C11_BUILD_LOCK_DIR/since"
"$WRAP" true 2>"$TMP/err" || fail "stale lock was not taken over"
grep -q "taking over" "$TMP/err" || fail "stale takeover not reported"

# 4. Live lock blocks; C11_BUILD_LOCK=0 bypasses; timeout exits 75.
"$WRAP" sleep 3 &
HOLDER=$!
sleep 0.4
C11_BUILD_LOCK=0 "$WRAP" true || fail "bypass did not run"
set +e; C11_BUILD_LOCK_TIMEOUT=1 "$WRAP" true 2>/dev/null; rc=$?; set -e
[[ "$rc" -eq 75 ]] || fail "expected timeout exit 75 while lock held, got $rc"
wait "$HOLDER"

echo "with-build-lock: OK"
