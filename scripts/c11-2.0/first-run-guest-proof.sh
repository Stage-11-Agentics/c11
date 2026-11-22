#!/bin/bash
# C11H-267 guest proof: the c11 2.0 upgrade note and Keep Terminals After Quit.
# Runs only inside a sandbox guest (scripts/sandbox-up.sh <run> <app>); anywhere else it refuses, because it
# deletes the app's defaults and stops the app at the path it is given. It needs the compiled guest-ui helper
# beside it (window list, activate, Cmd-Q); build that on the host and put both in the run's shared folder:
#   xcrun swiftc -O -target arm64-apple-macos14 scripts/c11-2.0/guest-ui.swift -o guest-ui
#   scripts/sandbox-exec.sh <run> /bin/bash "/Volumes/My Shared Files/out/first-run-guest-proof.sh" <guest app path>
# Writes RESULT lines, screenshots and a log to the shared folder.
# A: an upgrader (origin c11-1x) sees the note once, and a terminal works while it is up. B: a relaunch does not
# show it again. C: a QA launch never shows it. D: a fresh profile gets the standard sheet and welcome, never the
# note. E: switch off, an operator's Quit ends a nohup and a foreground job and leaves no hc process. F: switch on,
# they keep running. G: switch off, TERM (the update path) keeps them.
# On a real 1.8.1 -> 2.0 guest, skip the `defaults write ... c11.migration.origin` lines: the migration writes it.
set -u
APP="${1:?usage: first-run-guest-proof.sh <guest app path>}"
OUT="/Volumes/My Shared Files/out"
[[ "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" == VirtualMac* && -d "$OUT" ]] \
  || { echo "REFUSED: not a sandbox guest. Nothing was touched."; exit 3; }
BIN="$APP/Contents/MacOS/c11"
CLI="$APP/Contents/Resources/bin/c11"
# The helper is copied off the shared folder before it runs.
UI=/tmp/c11-2.0-guest-ui
/bin/cp "$(dirname "$0")/guest-ui" "$UI" 2>/dev/null && /bin/chmod 755 "$UI"
[[ -x "$UI" && -x "$BIN" && -x "$CLI" ]] || { echo "ABORT missing guest-ui beside this script, or no c11 app at $APP"; exit 1; }
BID="$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleIdentifier)"
LOG="$OUT/c267-guest.log"
: > "$LOG"
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }
say "app=$APP bid=$BID cli=$CLI"

# A failed launch or quit ends the proof: later stages would read another instance's state.
die() { say "ABORT $*"; exit 1; }

app_pid() { /usr/bin/pgrep -f "^$BIN" | head -1; }
# At most one instance may run; two would make every pid and window check ambiguous.
# Called in the main shell (never inside $(...)), so its die ends the proof.
one_instance() {
  local count; count="$(/usr/bin/pgrep -f "^$BIN" | grep -c .)"
  (( count > 1 )) && die "more than one app instance: $(/usr/bin/pgrep -f "^$BIN" | tr '\n' ' ')"
  return 0
}

stop_app() {
  one_instance
  local pid; pid="$(app_pid)"
  [[ -z "$pid" ]] && return 0
  kill -TERM "$pid"
  for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || { say "stopped pid=$pid"; return 0; }; sleep 0.5; done
  die "pid $pid still alive after TERM"
}

# $1 socket, $2 qa value ("" for none)
launch() {
  local socket="$1" qa="$2" uid user
  one_instance
  [[ -n "$(app_pid)" ]] && die "launch $socket: an instance is already running (pid $(app_pid))"
  uid="$(id -u)"; user="$(id -un)"
  /usr/bin/sudo -n /bin/rm -f "$socket"
  local qaenv=()
  [[ -n "$qa" ]] && qaenv=(C11_QA_LAUNCH="$qa")
  /usr/bin/sudo -n /bin/launchctl asuser "$uid" /usr/bin/sudo -n -u "$user" /usr/bin/env -i \
    HOME="$HOME" USER="$user" LOGNAME="$user" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    TMPDIR="${TMPDIR:-/tmp}" C11_SOCKET_MODE=automation C11_ALLOW_SOCKET_OVERRIDE=1 \
    C11_SOCKET="$socket" C11_SOCKET_PATH="$socket" ${qaenv[@]+"${qaenv[@]}"} \
    /bin/zsh -c 'nohup "$1" > "$2" 2>&1 &' _ "$BIN" "$OUT/c267-app-$(basename "$socket").out"
  for _ in $(seq 1 90); do [[ -S "$socket" ]] && break; sleep 1; done
  [[ -S "$socket" ]] || die "launch $socket: socket did not appear in 90 s"
  [[ -n "$(app_pid)" ]] || die "launch $socket: no app process"
  one_instance
  say "launched qa='${qa}' pid=$(app_pid) socket=$socket"
}

windows() {
  local pid; pid="$(app_pid)"
  [[ -n "$pid" ]] || return 0
  "$UI" windows "$pid" 2>/dev/null | /usr/bin/python3 -c 'import json, sys
for w in json.load(sys.stdin):
    print(w.get("id"), "|", w.get("title"))' 2>/dev/null
}

shot() { /usr/sbin/screencapture -x "$OUT/$1.png"; say "shot $1.png"; }
win_shot() {
  local id; id="$(windows | grep -F "$2" | head -1 | cut -d' ' -f1)"
  [[ -n "$id" ]] && /usr/bin/perl -e 'alarm 6; exec @ARGV' /usr/sbin/screencapture -x -o -l"$id" "$OUT/$1.png" && say "window shot $1.png ($2)"; return 0
}
has_window() { windows | grep -qF "$1"; }
pref() { /usr/bin/defaults read "$BID" "$1" 2>/dev/null || echo "(unset)"; }

result() { say "RESULT $1: $2"; }

# --- A: c11 1.x upgrader, first 2.0 launch -----------------------------------------------------
stop_app
/usr/bin/defaults write "$BID" c11.migration.origin -string c11-1x
/usr/bin/defaults delete "$BID" c11.upgradeNote.shown 2>/dev/null
launch /tmp/c11-c267-a.sock ""
sleep 14
say "A windows:"; windows | tee -a "$LOG"
shot A-upgrader-screen
win_shot A-upgrader-sheet "What's New in c11 2.0"
has_window "What's New in c11 2.0" && result A-sheet-shows pass || result A-sheet-shows FAIL
[[ "$(pref c11.upgradeNote.shown)" == "1" ]] && result A-marked-shown pass || result A-marked-shown FAIL
# Nothing waits on a click: with the sheet up, a terminal takes input and runs it.
export C11_SOCKET=/tmp/c11-c267-a.sock
PANEL="$("$CLI" tree --json 2>>"$LOG" | /usr/bin/python3 -c '
import json,sys
def walk(o):
    if isinstance(o,dict):
        if o.get("type")=="terminal" and o.get("ref"): print(o["ref"]); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(json.load(sys.stdin))')"
say "A terminal panel=$PANEL"
"$CLI" send --panel "$PANEL" "echo c267-alive-\$((6*7))" >>"$LOG" 2>&1
sleep 2
"$CLI" read-screen --panel "$PANEL" --lines 20 > "$OUT/A-read-screen.txt" 2>&1
grep -q "c267-alive-42" "$OUT/A-read-screen.txt" && result A-terminal-works-under-sheet pass || result A-terminal-works-under-sheet FAIL
has_window "What's New in c11 2.0" && result A-sheet-still-open-unclicked pass || result A-sheet-still-open-unclicked FAIL
/usr/bin/perl -e 'alarm 10; exec @ARGV' /usr/bin/osascript -e "tell application \"System Events\" to get name of every menu item of menu \"Help\" of menu bar 1 of (first process whose unix id is $(app_pid))" >> "$LOG" 2>&1

# --- B: relaunch does not show it again ---------------------------------------------------------
stop_app
launch /tmp/c11-c267-b.sock ""
sleep 14
say "B windows:"; windows | tee -a "$LOG"
shot B-relaunch-screen
has_window "What's New in c11 2.0" && result B-not-shown-again FAIL || result B-not-shown-again pass

# --- C: a QA launch never shows it ---------------------------------------------------------------
stop_app
/usr/bin/defaults delete "$BID" c11.upgradeNote.shown 2>/dev/null
/usr/bin/defaults delete "$BID" c11.whatsDifferent.shownVersion 2>/dev/null
launch /tmp/c11-c267-c.sock fresh
sleep 14
say "C windows:"; windows | tee -a "$LOG"
shot C-qa-screen
has_window "What's New in c11 2.0" && result C-qa-never FAIL || result C-qa-never pass
[[ "$(pref c11.upgradeNote.shown)" == "(unset)" ]] && result C-qa-not-marked pass || result C-qa-not-marked FAIL

# --- D: fresh profile: welcome and the standard sheet, never the upgrade note -------------------
stop_app
/usr/bin/defaults delete "$BID" 2>/dev/null
launch /tmp/c11-c267-d.sock ""
sleep 16
say "D windows:"; windows | tee -a "$LOG"
shot D-fresh-screen
# C11H-335: every profile's sheet is titled What's New in c11 2.0; a fresh one records no upgrade note.
win_shot D-fresh-sheet "What's New in c11 2.0"
[[ "$(pref c11.upgradeNote.shown)" == "(unset)" ]] && result D-fresh-no-upgrade-note pass || result D-fresh-no-upgrade-note FAIL
has_window "What's New in c11 2.0" && result D-fresh-standard-sheet pass || result D-fresh-standard-sheet FAIL
C11_SOCKET=/tmp/c11-c267-d.sock "$CLI" list-workspaces > "$OUT/D-workspaces.txt" 2>&1
grep -qi welcome "$OUT/D-workspaces.txt" && result D-fresh-welcome-workspace pass || result D-fresh-welcome-workspace "check D-workspaces.txt"

# --- E/F/G: Keep Terminals After Quit ------------------------------------------------------------
first_terminal() {
  "$CLI" tree --json 2>>"$LOG" | /usr/bin/python3 -c '
import json,sys
def walk(o):
    if isinstance(o,dict):
        if o.get("type")=="terminal" and o.get("ref"): print(o["ref"]); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(json.load(sys.stdin))'
}
hc_procs() { /usr/bin/pgrep -fl herdr 2>/dev/null; }
# After a launch: wait up to 60 s for a terminal. If none comes, keep what the operator would see (the screen,
# the window list, the tree's answer), fail the stage, then open a window as they would so the stage can go on.
wait_terminal() {
  local label="$1" t i
  for i in $(seq 1 30); do
    t="$(first_terminal 2>/dev/null)"
    [[ -n "$t" ]] && { say "$label: first terminal $t, $((i * 2 - 2)) s after the launch returned"; return 0; }
    sleep 2
  done
  say "$label: no terminal 60 s after launch; windows: $(windows | tr '\n' ';')"
  "$CLI" tree >>"$LOG" 2>&1
  "$CLI" list-windows >>"$LOG" 2>&1
  shot "$label-no-window-screen"
  result "$label-no-window-after-launch" FAIL
  "$CLI" new-window >>"$LOG" 2>&1
  sleep 6
  say "$label: after new-window, first terminal '$(first_terminal 2>/dev/null)'"
}
# $1 tag for the sleeps. A nohup job and a foreground job in the first terminal.
all_terminals() {
  "$CLI" tree --json 2>>"$LOG" | /usr/bin/python3 -c '
import json,sys
def walk(o):
    if isinstance(o,dict):
        if o.get("type")=="terminal" and o.get("ref"): print(o["ref"])
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(json.load(sys.stdin))' | sort -u
}
fresh_terminal() {
  local before after new
  before="$(all_terminals)"
  "$CLI" new-split down --panel "$(first_terminal)" >>"$LOG" 2>&1
  sleep 3
  after="$(all_terminals)"
  new="$(comm -13 <(echo "$before") <(echo "$after") | head -1)"
  [[ -n "$new" ]] || { say "no new terminal from new-split; using the first terminal" >&2; new="$(first_terminal)"; }
  echo "$new"
}
start_jobs() {
  local panel; panel="$(fresh_terminal)"
  say "jobs ${1} go to panel $panel"
  "$CLI" send --panel "$panel" "nohup sleep ${1}1 >/dev/null 2>&1 & sleep ${1}2" >>"$LOG" 2>&1
  sleep 2
  say "jobs ${1}: $(/usr/bin/pgrep -fl "sleep ${1}" | tr '\n' ';')"
}
jobs_alive() { /usr/bin/pgrep -f "sleep ${1}[12]" >/dev/null; }
operator_quit() {
  one_instance
  local pid; pid="$(app_pid)"
  [[ -n "$pid" ]] || die "operator quit: no app running"
  /usr/bin/perl -e 'alarm 10; exec @ARGV' /usr/bin/osascript -e "tell application id \"$BID\" to quit" >>"$LOG" 2>&1
  for _ in $(seq 1 8); do kill -0 "$pid" 2>/dev/null || { say "operator quit done pid=$pid (Apple Event)"; return 0; }; sleep 0.5; done
  say "Apple Event quit did not end pid=$pid; pressing Cmd-Q"
  "$UI" activate "$pid" >>"$LOG" 2>&1; sleep 1
  "$UI" key 12 cmd >>"$LOG" 2>&1
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || { say "operator quit done pid=$pid (Cmd-Q)"; return 0; }; sleep 0.5; done
  die "operator quit: pid $pid still alive after 15 s"
}

/usr/bin/defaults write "$BID" c11.migration.origin -string c11-1x
/usr/bin/defaults write "$BID" c11.upgradeNote.shown -bool true
/usr/bin/defaults write "$BID" warnBeforeQuitShortcut -bool false

# E: switch off, operator quit: every terminal and job ends, no hc process is left.
stop_app   # D's instance
/usr/bin/defaults write "$BID" c11.quit.keepTerminals -bool false
launch /tmp/c11-c267-e.sock ""
export C11_SOCKET=/tmp/c11-c267-e.sock
sleep 4
wait_terminal E
start_jobs 7701
say "E hc before: $(hc_procs | tr '\n' ';')"
operator_quit
sleep 1
say "E hc after: $(hc_procs | tr '\n' ';')"
grep -h "app.quit.end_terminals" "$OUT"/c267-app-c11-c267-e.sock.out | tee -a "$LOG"
jobs_alive 7701 && result E-off-quit-ends-jobs FAIL || result E-off-quit-ends-jobs pass
[[ -z "$(hc_procs)" ]] && result E-off-no-hc-left pass || result E-off-no-hc-left FAIL
launch /tmp/c11-c267-e2.sock ""
sleep 14
shot E-off-relaunch-screen
say "E2 tree before TERM: $(C11_SOCKET=/tmp/c11-c267-e2.sock "$CLI" tree 2>&1 | head -12 | tr '\n' ';')"
stop_app

# F: switch on, operator quit: unchanged, jobs and hc keep running.
/usr/bin/defaults write "$BID" c11.quit.keepTerminals -bool true
launch /tmp/c11-c267-f.sock ""
export C11_SOCKET=/tmp/c11-c267-f.sock
sleep 4
wait_terminal F
start_jobs 7702
operator_quit
sleep 1
jobs_alive 7702 && result F-on-quit-keeps-jobs pass || result F-on-quit-keeps-jobs FAIL
[[ -n "$(hc_procs)" ]] && result F-on-hc-stays pass || result F-on-hc-stays FAIL

# G: switch off, TERM (the update path): terminals keep running.
/usr/bin/defaults write "$BID" c11.quit.keepTerminals -bool false
launch /tmp/c11-c267-g.sock ""
export C11_SOCKET=/tmp/c11-c267-g.sock
sleep 4
wait_terminal G
start_jobs 7703
stop_app
sleep 1
jobs_alive 7703 && result G-off-term-keeps-jobs pass || result G-off-term-keeps-jobs FAIL
jobs_alive 7702 && result G-earlier-jobs-reattached-and-alive pass || result G-earlier-jobs-reattached-and-alive FAIL
say "done"
