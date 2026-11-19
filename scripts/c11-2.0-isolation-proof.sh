#!/bin/zsh
# C11H-265: a tagged c11 2.0 Debug build, launched beside a running c11h, touches nothing
# of c11h's: no file or socket under c11h's names, no c11h hc core, no c11h defaults.
#
#   zsh scripts/c11-2.0-isolation-proof.sh <c11h.app> <tagged 2.0 .app> [out-dir] [seconds]
#
# Runs INSIDE a sandbox guest only (it uses sudo for fs_usage and launchctl asuser); never on
# a host. c11h must already be running from <c11h.app> with at least one terminal. The script
# launches the 2.0 app with its own automation socket, drives it briefly, quits it by PID, and
# writes evidence to out-dir (default /tmp/c11-2.0-isolation). It deletes nothing but its own
# files under out-dir and its own socket. A hard watchdog ends it after [seconds] (default 300).
# Exit 0: pass. Exit 1: c11 2.0 touched c11h. Exit 2: usage or setup. Exit 3: watchdog.
emulate -L zsh
setopt no_unset pipefail

old_app="${1:-}"; new_app="${2:-}"; out="${3:-/tmp/c11-2.0-isolation}"; limit="${4:-300}"
[[ -d "$old_app" && -d "$new_app" ]] || { print -u2 "usage: $0 <c11h.app> <tagged 2.0 .app> [out-dir] [seconds]"; exit 2 }
mkdir -p "$out" || exit 2
log="$out/proof.log"; : > "$log"
say() { print -r -- "$(date +%H:%M:%S) $*" | tee -a "$log" }
uid="$(id -u)"; user="$(id -un)"
sock="/tmp/c11-isolation-$$.sock"
new_pid=""; fsu_pid=""; fail=0

cleanup() {
  [[ -n "$new_pid" ]] && kill -TERM "$new_pid" 2>/dev/null
  [[ -n "$fsu_pid" ]] && /usr/bin/sudo -n /bin/kill -INT "$fsu_pid" 2>/dev/null
  [[ -n "${dog_pid:-}" ]] && kill "$dog_pid" 2>/dev/null
  /bin/rm -f "$sock"
}
trap cleanup EXIT
( sleep "$limit"; print -r -- "WATCHDOG after ${limit}s" >> "$log"; kill -TERM $$ ) &
dog_pid=$!
trap 'say "watchdog fired"; exit 3' TERM

new_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist")"
old_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$old_app/Contents/Info.plist")"
say "c11h: $old_id $(/usr/libexec/PlistBuddy -c 'Print :C11HVersion' "$old_app/Contents/Info.plist" 2>/dev/null)"
say "c11 2.0: $new_id $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$new_app/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$new_app/Contents/Info.plist"))"
[[ "$old_id" == com.stage11.c11h ]] || { say "setup: $old_app is not c11h"; exit 2 }
[[ "$new_id" == com.stage11.c11.debug.* ]] || { say "setup: $new_app is not a tagged c11 2.0 Debug build"; exit 2 }
old_pid="$(pgrep -f "$old_app/Contents/MacOS/c11h\$" | head -1)"
[[ -n "$old_pid" ]] || { say "setup: c11h is not running from $old_app"; exit 2 }

cores() { ps -axo pid=,args= | grep '[h]erdr-core' }
old_cores="$(cores)"
print -r -- "$old_cores" > "$out/cores-before.txt"
old_core_pids=(${(f)"$(print -r -- "$old_cores" | awk '{print $1}')"})
say "c11h pid $old_pid; hc cores before: ${#old_core_pids} (${old_core_pids[*]})"
old_terms=()
for p in $old_core_pids; do old_terms+=(${(f)"$(pgrep -P "$p")"}); done
say "terminals under those cores: ${old_terms[*]:-none}"
defaults read com.stage11.c11h 2>/dev/null | grep -oE '^    "?[A-Za-z0-9_.-]+"? =' | sort > "$out/c11h-defaults-keys-before.txt"

# Every file and socket path a process named `c11` opens while c11 2.0 runs: the 2.0 app and the
# CLI this script calls (c11h's app is `c11h`). Its hc cores share c11h's process name, so they are
# judged by lsof on their PIDs and by their arguments below. Agents calling c11h's own bundled CLI
# (also named `c11`) during the run would show here too; stage 0 runs before any such work.
/usr/bin/sudo -n /usr/bin/fs_usage -w -f pathname c11 > "$out/fs_usage-c11-2.0.txt" 2>/dev/null &
fsu_pid=$!
sleep 2

/usr/bin/sudo -n /bin/launchctl asuser "$uid" /usr/bin/sudo -n -u "$user" /usr/bin/env -i \
  HOME="$HOME" USER="$user" LOGNAME="$user" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
  TMPDIR="${TMPDIR:-/tmp}" C11_QA_LAUNCH=fresh C11_SOCKET_MODE=automation C11_ALLOW_SOCKET_OVERRIDE=1 \
  C11_SOCKET="$sock" C11_SOCKET_PATH="$sock" \
  /bin/zsh -c 'nohup "$1" > "$2" 2>&1 & echo $!' _ "$new_app/Contents/MacOS/c11" "$out/c11-stdout.txt" > "$out/c11.pid"
new_pid="$(cat "$out/c11.pid")"
for i in {1..60}; do [[ -S "$sock" ]] && break; sleep 1; done
[[ -S "$sock" ]] || { say "setup: c11 2.0 socket did not appear"; exit 2 }
say "c11 2.0 pid $new_pid, socket $sock"
cli="$new_app/Contents/Resources/bin/c11"
c11() { C11_SOCKET="$sock" "$cli" "$@" }
sleep 6
c11 tree --all > "$out/c11-tree.txt" 2>&1
panel="$(c11 tree --all --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
def walk(n):
    if isinstance(n, dict):
        if n.get("type") == "terminal" and n.get("ref"): print(n["ref"]); raise SystemExit
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
walk(json.load(sys.stdin))')"
if [[ -n "$panel" ]]; then
  c11 send --panel "$panel" 'c11h version; c11h no-such-verb --help; echo "HC_SESSION=$HC_SESSION"' > /dev/null 2>&1
  sleep 4
  c11 read-screen --panel "$panel" --lines 30 > "$out/c11-terminal.txt" 2>&1
fi
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $new_pid) to true" > /dev/null 2>&1
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $new_pid) to get name of every menu bar item of menu bar 1" > "$out/c11-menubar.txt" 2>&1
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $new_pid) to get name of every menu item of menu 1 of menu bar item 2 of menu bar 1" > "$out/c11-appmenu.txt" 2>&1
screencapture -x "$out/01-c11-2.0-window.png"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $new_pid) to click menu item 1 of menu 1 of menu bar item 2 of menu bar 1" > /dev/null 2>&1
sleep 2
screencapture -x "$out/02-c11-2.0-about.png"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $new_pid) to get value of every static text of window 1" > "$out/c11-about-text.txt" 2>&1

during="$(cores)"
print -r -- "$during" > "$out/cores-during.txt"
new_core_pids=(${(f)"$(print -r -- "$during" | awk '{print $1}' | grep -vxF -f <(print -l -- $old_core_pids) )"})
say "hc cores started by c11 2.0: ${new_core_pids[*]:-none}"
lsof -nP -p "$new_pid${new_core_pids:+,${(j:,:)new_core_pids}}" > "$out/lsof-c11-2.0.txt" 2>/dev/null

kill -TERM "$new_pid"
for i in {1..20}; do kill -0 "$new_pid" 2>/dev/null || break; sleep 1; done
new_pid=""
sleep 2
/usr/bin/sudo -n /bin/kill -INT "$fsu_pid" 2>/dev/null; fsu_pid=""
sleep 1

# --- verdicts -----------------------------------------------------------------
say "c11 2.0 file operations seen: $(wc -l < "$out/fs_usage-c11-2.0.txt" | tr -d ' ')"
legacy='Application Support/c11h|/\.c11h|\.c11h-snapshots|\.config/c11h|\.local/share/c11h|Logs/c11h|/tmp/c11h|com\.stage11\.c11h|herdr-core/c11h'
if grep -E "$legacy" "$out/fs_usage-c11-2.0.txt" > "$out/violations-files.txt"; then
  say "FAIL: c11 2.0 opened c11h paths:"; head -20 "$out/violations-files.txt" | tee -a "$log"; fail=1
else
  say "pass: no file or socket path of c11h's in c11 2.0's file operations"
fi
if grep -E "$legacy" "$out/lsof-c11-2.0.txt" > "$out/violations-lsof.txt"; then
  say "FAIL: c11 2.0 held c11h paths open:"; head -20 "$out/violations-lsof.txt" | tee -a "$log"; fail=1
else
  say "pass: c11 2.0 and its cores held nothing of c11h's open"
fi
for p in $old_core_pids $old_terms; do
  kill -0 "$p" 2>/dev/null || { say "FAIL: c11h process $p ended"; fail=1 }
done
(( fail )) || say "pass: c11h's ${#old_core_pids} core(s) and ${#old_terms} terminal process(es) all alive, same PIDs"
kill -0 "$old_pid" 2>/dev/null && say "pass: c11h itself still running (pid $old_pid)" || { say "FAIL: c11h stopped"; fail=1 }
for p in $new_core_pids; do
  args="$(ps -o args= -p "$p" 2>/dev/null)"
  [[ "$args" == *c11h* ]] && { say "FAIL: a core c11 2.0 started names c11h: $args"; fail=1 }
done
defaults read com.stage11.c11h 2>/dev/null | grep -oE '^    "?[A-Za-z0-9_.-]+"? =' | sort > "$out/c11h-defaults-keys-after.txt"
if diff -q "$out/c11h-defaults-keys-before.txt" "$out/c11h-defaults-keys-after.txt" > /dev/null; then
  say "pass: c11h's defaults domain has the same keys"
else
  say "note: c11h's defaults keys changed (c11h itself was running):"; diff "$out/c11h-defaults-keys-before.txt" "$out/c11h-defaults-keys-after.txt" | tee -a "$log"
fi
grep -qi c11h "$out/c11-menubar.txt" "$out/c11-appmenu.txt" "$out/c11-about-text.txt" 2>/dev/null \
  && { say "FAIL: c11 2.0's menus or About name c11h"; fail=1 } || say "pass: menus and About name no c11h"
(( fail )) && { say "RESULT: FAIL"; exit 1 }
say "RESULT: PASS"
exit 0
