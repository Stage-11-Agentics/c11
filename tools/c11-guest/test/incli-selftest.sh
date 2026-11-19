#!/bin/bash
# Host self-test of the gated kit mode (C11H-33): guest.sh `launch-env` (the environment `launch` gives the app; the gated mode is
# C11_SOCKET_GATE=1 -> C11_SOCKET_MODE=c11Only) and `incli` (the bundled c11 run inside one of the app's hc terminals, typed there
# with hc send). guest.sh runs only through its own overrides: HOME = scratch, C11_APP = a scratch .app holding an Info.plist and a
# fake c11 script, C11_HC_BIN = a fake hc (ls/get from the real-shaped fixtures; `send` runs the typed line with that terminal's
# C11_* values, as the terminal's shell would), C11_HC_SOCK = a socket file bound in scratch (nothing listens). Nothing is
# launched or signalled: `launch-env` never opens the app, and the only processes are the fakes.
# Usage: tools/c11-guest/test/incli-selftest.sh  -> "INCLI SELFTEST PASS n" or the failures, exit 0/1.
set -u
K="$(cd "$(dirname "$0")/.." && pwd)"; FX="$K/test/fixtures"
W="$(mktemp -d "${TMPDIR:-/tmp}/c11-incli.XXXXXX")"
n=0; bad=0
check() { if eval "$2"; then n=$((n + 1)); else echo "INCLI SELFTEST FAIL: $1 [$2]"; bad=1; fi; }
J() { python3 -I -c "import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))" "$1"; }

GH="$W/gh"; GA="$W/c11 DEV t.app"; mkdir -p "$GH/c11-guest" "$GA/Contents/Resources/bin"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.stage11.c11.debug.t' -c 'Add :CFBundleExecutable string c11' "$GA/Contents/Info.plist" >/dev/null
cp "$K/hcrecs.py" "$GH/c11-guest/"
# fake c11: one line per argument, bracketed, and the panel it was run for; `fail` exits 3 with a stderr line
cat > "$GA/Contents/Resources/bin/c11" <<'EOF'
#!/bin/bash
for a in "$@"; do printf '[%s]\n' "$a"; done
echo "panel=${C11_PANEL_ID:-}"
[ "${1:-}" = fail ] && { echo "Error: something refused this" >&2; exit 3; }
exit 0
EOF
chmod +x "$GA/Contents/Resources/bin/c11"
# fake hc (run by guest.sh under env -i, so its paths are baked in): records argv and env; `send <addr> <text>` runs <text> with
# that terminal's C11_* values in the background (unless $W/send-noop exists), as the terminal's shell would after a paste
cat > "$W/hc" <<EOF
#!/bin/bash
echo "\$* | HC_SESSION=\${HC_SESSION:-} HC_SOCKET=\${HC_SOCKET:-}" >> "$W/argv"
case "\$1" in
  ls) cat "$FX/hcls-6-live.json" ;;
  get) python3 -I -c 'import json,os,sys; r=json.load(open(sys.argv[1])).get(sys.argv[2]); r and os.path.exists(sys.argv[3] + "/ended-" + sys.argv[2]) and r.update(state="finished", pid=None); print(json.dumps(r)) if r else sys.exit(1)' "$FX/get-records.json" "\$2" "$W" ;;
  send) [ -e "$W/send-fail" ] && { echo "Error: terminal \$2 is not idle" >&2; exit 1; }
        [ -e "$W/send-noop" ] && exit 0
        p=\$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["labels"]["c11.panel"])' "$FX/get-records.json" "\$2")
        ( env -i PATH=/usr/bin:/bin C11_PANEL_ID="\$p" C11_WORKSPACE_ID="WS-\$2" C11_SOCKET_PATH=/tmp/c11-t.sock /bin/sh -c "\$3" ) >/dev/null 2>&1 &
        echo sent ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$W/hc"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$W/c.sock"
GE() { local sock="$1"; shift; env HOME="$GH" C11_APP="$GA" C11_HC_BIN="$W/hc" C11_HC_SOCK="$sock" C11_INCLI_S="${INCLI_S:-5}" /bin/zsh "$K/guest.sh" "$@"; }
LE() { env HOME="$GH" C11_APP="$GA" "$@"; }
T1P=7329BF55-2299-4695-B948-DFD6AD63E836; T3P=19926033-47EA-4781-8857-AE8CB0C5F2E2

# --- launch-env: the gated kit mode
le() { LE "$@" /bin/zsh "$K/guest.sh" launch-env "${LEARGS[@]}"; }
LEARGS=(fresh); out=$(le)
check "launch-env default: automation, QA fresh"         'echo "$out" | grep -qx C11_SOCKET_MODE=automation && echo "$out" | grep -qx C11_QA_LAUNCH=fresh'
out=$(le C11_SOCKET_GATE=1)
check "launch-env C11_SOCKET_GATE=1: c11Only (the gated mode)" 'echo "$out" | grep -qx C11_SOCKET_MODE=c11Only && [ "$(echo "$out" | grep -c ^C11_SOCKET_MODE=)" = 1 ]'
LEARGS=(resume C11_SOCKET_MODE=allowAll); out=$(le C11_SOCKET_GATE=1)
check "launch-env: a VAR=val on the line still wins, QA resume" 'echo "$out" | grep -qx C11_SOCKET_MODE=allowAll && echo "$out" | grep -qx C11_QA_LAUNCH=resume'
LEARGS=(normal); out=$(le C11_SOCKET_GATE=1)
check "launch-env normal: gated, no C11_QA_LAUNCH"        'echo "$out" | grep -qx C11_SOCKET_MODE=c11Only && ! echo "$out" | grep -q ^C11_QA_LAUNCH='
LEARGS=(bogus); le >/dev/null 2>&1; rc=$?
check "launch-env: a bad mode is refused (exit 2)"       '[ $rc = 2 ]'
out=$(LE C11_SOCKET_GATE=1 /bin/zsh "$K/guest.sh" env)
check "env: prints SOCKET_MODE of the kit mode"          'echo "$out" | grep -qx SOCKET_MODE=c11Only'

# --- incli
: > "$W/argv"; err=$(GE "$W/no.sock" incli any identify 2>&1 >/dev/null); rc=$?
check "incli, no core socket: exit 4, hc never run"      '[ $rc = 4 ] && echo "$err" | grep -q "not autostarting" && [ ! -s "$W/argv" ]'
: > "$W/argv"; out=$(GE "$W/c.sock" incli any identify --json); rc=$?
check "incli any: exit 0, first live labelled terminal t1" '[ $rc = 0 ] && [ "$(echo "$out" | J "(d[\"terminal\"], d[\"panel\"], d[\"rc\"])")" = "('"'"'t1'"'"', '"'"'$T1P'"'"', 0)" ]'
check "incli: the CLI ran inside that terminal (its C11_PANEL_ID), args intact" '[ "$(echo "$out" | J "d[\"out\"]")" = "$(printf "[identify]\n[--json]\npanel=$T1P")" ]'
check "incli: the terminal's own env is recorded"         '[ "$(echo "$out" | J "(d[\"env\"][\"C11_PANEL_ID\"], d[\"env\"][\"C11_WORKSPACE_ID\"])")" = "('"'"'$T1P'"'"', '"'"'WS-t1'"'"')" ]'
check "incli: typed with hc send, in the app's session and socket" 'grep -qE "^send t1 /bin/sh .*/c11-guest/incli/.*/cmd\.sh.? \| HC_SESSION=c11-t HC_SOCKET=$W/c.sock$" "$W/argv"'
check "incli: its scratch dir is removed"                 '[ -z "$(ls -A "$GH/c11-guest/incli" 2>/dev/null)" ]'
: > "$W/ended-t1"; out=$(GE "$W/c.sock" incli any identify); rc=$?; rm -f "$W/ended-t1"
check "incli any: a terminal that ended between ls and get is skipped (t2)" '[ $rc = 0 ] && [ "$(echo "$out" | J "d[\"terminal\"]")" = t2 ]'
lc=$(echo "$T3P" | tr A-Z a-z)
out=$(GE "$W/c.sock" incli "$lc" echo "a b" "it's \"q\"" '$HOME' ';id'); rc=$?
check "incli <panel>: that panel's terminal t3 (UUID case-insensitive)" '[ $rc = 0 ] && [ "$(echo "$out" | J "d[\"terminal\"]")" = t3 ]'
check "incli: spaces, quotes, \$ and ; reach the CLI literally" '[ "$(echo "$out" | J "d[\"out\"]")" = "$(printf "%s\n" "[echo]" "[a b]" "[it'"'"'s \"q\"]" "[\$HOME]" "[;id]" "panel=$T3P")" ]'
out=$(GE "$W/c.sock" incli any fail now); rc=$?
check "incli: the CLI's exit code and stderr are the record's" '[ $rc = 0 ] && [ "$(echo "$out" | J "(d[\"rc\"], d[\"err\"].strip())")" = "(3, '"'"'Error: something refused this'"'"')" ]'
: > "$W/argv"; err=$(GE "$W/c.sock" incli 00000000-0000-0000-0000-000000000000 identify 2>&1 >/dev/null); rc=$?
check "incli, no terminal for that panel: exit 5, nothing sent" '[ $rc = 5 ] && echo "$err" | grep -q "no live app terminal" && ! grep -q "^send" "$W/argv"'
: > "$W/send-noop"; err=$(INCLI_S=1 GE "$W/c.sock" incli any identify 2>&1 >/dev/null); rc=$?; rm -f "$W/send-noop"
check "incli, the command never runs: exit 6 after C11_INCLI_S, dir removed" '[ $rc = 6 ] && echo "$err" | grep -q "no exit code" && [ -z "$(ls -A "$GH/c11-guest/incli" 2>/dev/null)" ]'

: > "$W/send-fail"; err=$(GE "$W/c.sock" incli any identify 2>&1 >/dev/null); rc=$?; rm -f "$W/send-fail"
check "incli, hc send fails: exit 7 with hc's error, dir removed" '[ $rc = 7 ] && echo "$err" | grep -q "hc send to t1 failed: Error: terminal t1 is not idle" && [ -z "$(ls -A "$GH/c11-guest/incli" 2>/dev/null)" ]'

rm -rf "$W"
if [ $bad = 0 ]; then echo "INCLI SELFTEST PASS $n"; exit 0; else exit 1; fi
