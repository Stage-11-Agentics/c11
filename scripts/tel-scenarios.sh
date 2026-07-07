#!/usr/bin/env bash
# C11-162 (Telemetry truth) — repeatable scenario harness for TEL-2/3/4/7.
#
# Drives a *tagged* c11 build's socket to reproduce the two TEL-7 scenarios and
# captures a get-metadata transcript + window screenshots at each decay stage.
#
# Requires a tagged build already running with ACCELERATED thresholds, e.g.:
#   C11_QA_LAUNCH=fresh C11_SIDEBAR_STALE_SECONDS=3 C11_SIDEBAR_EXPIRE_SECONDS=6 \
#     ./scripts/reload.sh --tag tel-post
# then:
#   scripts/tel-scenarios.sh --tag tel-post --out /tmp/tel-artifacts
#
# The file/socket is the contract; this is a driver, not a test oracle. The
# c11-logic suite is the deterministic oracle for the same logic.
set -euo pipefail

TAG="tel-post"; OUT="/tmp/tel-artifacts"
while [ $# -gt 0 ]; do case "$1" in
  --tag) TAG="$2"; shift 2;; --out) OUT="$2"; shift 2;;
  --socket) SOCK="$2"; shift 2;; *) echo "unknown arg $1"; exit 2;; esac; done
SOCK="${SOCK:-/tmp/c11-debug-${TAG}.sock}"
export C11_SOCKET="$SOCK"
mkdir -p "$OUT"
STALE="${C11_SIDEBAR_STALE_SECONDS:-3}"; EXPIRE="${C11_SIDEBAR_EXPIRE_SECONDS:-6}"

c11() { command c11 "$@"; }               # uses C11_SOCKET
shot() { # shot <name> — capture the frontmost c11 window (no focus steal on our side)
  local f="$OUT/$1.png"
  # -o omits window shadow; -l<id> targets a window. Fall back to interactive-free full capture.
  local wid
  wid="$(osascript -e 'tell application "System Events" to get id of first window of (first process whose name contains "c11")' 2>/dev/null || true)"
  if [ -n "${wid:-}" ]; then screencapture -x -o -l"$wid" "$f" 2>/dev/null || screencapture -x "$f"; else screencapture -x "$f"; fi
  echo "  shot -> $f"
}
line() { echo "----- $* -----" | tee -a "$OUT/transcript.txt"; }
rec()  { echo "$*" | tee -a "$OUT/transcript.txt"; }

: > "$OUT/transcript.txt"
line "ENV  socket=$SOCK stale=${STALE}s expiry=${EXPIRE}s  $(date)"
c11 identify --json | tee -a "$OUT/transcript.txt" >/dev/null || { echo "socket unreachable at $SOCK"; exit 1; }

# Resolve a target surface (first surface of the focused workspace).
SURF="$(c11 ls --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("surfaces") or [{}])[0].get("ref",""))' 2>/dev/null || true)"
rec "target surface: ${SURF:-<none, will use focused>}"
SFLAG=(); [ -n "$SURF" ] && SFLAG=(--surface "$SURF")

line "SCENARIO A — explicit status decays then flips to derived (TEL-2/4/7a)"
c11 set-status "${SFLAG[@]}" phase "running smoke" --icon hammer 2>&1 | tee -a "$OUT/transcript.txt" >/dev/null
sleep 1; rec "[t=1s FRESH] status just set"; shot "A1-fresh"
c11 get-metadata "${SFLAG[@]}" --sources --json 2>&1 | tee -a "$OUT/transcript.txt" >/dev/null
sleep "$STALE"; rec "[t=$((1+STALE))s STALE] past stale threshold — pill should dim + show age"; shot "A2-stale"
sleep "$EXPIRE"; rec "[t=$((1+STALE+EXPIRE))s EXPIRED] past expiry — derived activity should take over the pill"; shot "A3-expired-derived"
rec "derived activity now:"; c11 get-metadata "${SFLAG[@]}" --key activity --json 2>&1 | tee -a "$OUT/transcript.txt" >/dev/null

line "SCENARIO B — derived working with NO agent self-report (TEL-3/7b)"
# Produce output in the surface without ever calling set-status; derived should read 'working'.
c11 send "${SFLAG[@]}" "for i in 1 2 3 4 5; do echo tel-output \$i; sleep 0.3; done" 2>&1 | tee -a "$OUT/transcript.txt" >/dev/null || rec "(send unavailable; drive output manually)"
sleep 2; rec "[during output] derived activity (expect working):"
c11 get-metadata "${SFLAG[@]}" --key activity --json 2>&1 | tee -a "$OUT/transcript.txt" >/dev/null
shot "B1-derived-working"
sleep 3; rec "[after output, at prompt] derived activity (expect idle):"
c11 get-metadata "${SFLAG[@]}" --key activity --json 2>&1 | tee -a "$OUT/transcript.txt" >/dev/null
shot "B2-derived-idle"

line "DONE — artifacts in $OUT"
ls -la "$OUT"
