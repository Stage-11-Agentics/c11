#!/bin/bash
# C11H-335 guest proof: the What's New in c11 2.0 sheet, one page per concept, for each profile.
# Runs only inside a sandbox guest (scripts/sandbox-up.sh <run> <app>); anywhere else it refuses, because it
# deletes the app's defaults and stops the app at the path it is given. It needs the compiled guest-ui helper
# beside it (window list, AX press); build that on the host and put both in the run's shared folder:
#   xcrun swiftc -O -target arm64-apple-macos14 scripts/c11-2.0/guest-ui.swift -o guest-ui
#   scripts/sandbox-exec.sh <run> /bin/bash "/Volumes/My Shared Files/out/whats-new-guest-proof.sh" <guest app path> [language]
# [language] (uk, ru, ja, ...) runs the app in that language: c11's own language setting (appLanguage, which
# c11 applies at launch) and -AppleLanguages on the command line, for this app only.
# Writes RESULT lines, a window shot of every page and a log to the shared folder, each named by language, run
# (RUN, default the guest's clock as HHMMSS) and the stages run, so a rerun never overwrites an earlier one.
# A: a c11 1.x upgrader reads three pages (terminals, machines, mail) and a terminal works while the sheet is up.
# B: an adopted profile reads the one adoption page. C: a relaunch shows nothing. D: a fresh profile reads the
# three pages and no note is recorded; the hc Core link opens a terminal, the Herder Topography link opens
# Settings on that page, and Back and Next/Got It hold their frames from page 2 to page 3. E: Close on page 1
# closes the sheet. F: Esc on page 2 closes it. G: Esc belongs to the key window: with Panel Details key and the
# sheet main behind it, Esc leaves the sheet open; with the sheet key, Esc closes it.
set -u
APP="${1:?usage: whats-new-guest-proof.sh <guest app path> [language]}"
LANGUAGE="${2:-en}"
# STAGES (default ABCDEFG) runs only the named stages, e.g. STAGES=G for the key-window stage alone.
STAGES="${STAGES:-ABCDEFG}"
RUN="${RUN:-$(date +%H%M%S)}"
stage() { [[ "$STAGES" == *"$1"* ]]; }
OUT="/Volumes/My Shared Files/out"
[[ "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" == VirtualMac* && -d "$OUT" ]] \
  || { echo "REFUSED: not a sandbox guest. Nothing was touched."; exit 3; }
BIN="$APP/Contents/MacOS/c11"
CLI="$APP/Contents/Resources/bin/c11"
UI=/tmp/c11-2.0-guest-ui
/bin/cp "$(dirname "$0")/guest-ui" "$UI" 2>/dev/null && /bin/chmod 755 "$UI"
[[ -x "$UI" && -x "$BIN" && -x "$CLI" ]] || { echo "ABORT missing guest-ui beside this script, or no c11 app at $APP"; exit 1; }
BID="$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleIdentifier)"
NAME="$LANGUAGE-$RUN"
LOG="$OUT/c335-guest-$NAME-$STAGES.log"
[[ -e "$LOG" ]] && { echo "ABORT $LOG exists; pick another RUN"; exit 1; }
say() { echo "$(date +%H:%M:%S) $*" | tee -a "$LOG"; }
die() { say "ABORT $*"; exit 1; }
say "app=$APP bid=$BID language=$LANGUAGE run=$RUN stages=$STAGES"
# A string in that language, from the app's own string table.
loc() {
  /usr/bin/plutil -convert json -o - "$APP/Contents/Resources/$LANGUAGE.lproj/Localizable.strings" 2>/dev/null \
    | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" 2>/dev/null
}
TITLE="$(loc whatsDifferent.upgrade.windowTitle)"
SETTINGS_TITLE="$(loc settings.title)"
DETAILS_TITLE="$(loc surfaceManifest.windowTitle)"
[[ -n "$TITLE" && -n "$SETTINGS_TITLE" && -n "$DETAILS_TITLE" ]] \
  || die "a window title or command is missing for $LANGUAGE in the app's string tables"
say "title=$TITLE settings=$SETTINGS_TITLE details=$DETAILS_TITLE"
# A fresh profile in the chosen language: the app's defaults deleted, AppleLanguages set for it alone.
reset_profile() {
  /usr/bin/defaults delete "$BID" 2>/dev/null
  [[ "$LANGUAGE" == en ]] || /usr/bin/defaults write "$BID" appLanguage -string "$LANGUAGE"
}
LANGUAGE_ARGS=()
[[ "$LANGUAGE" == en ]] || LANGUAGE_ARGS=(-AppleLanguages "($LANGUAGE)")
# The origin the first-launch migration records for a profile it took over (C11Migration).
ADOPTED_ORIGIN="c11h"  # c11-2.0:legacy

app_pid() { /usr/bin/pgrep -f "^$BIN" | head -1; }
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
launch() {
  local socket="$1" uid user
  one_instance
  [[ -n "$(app_pid)" ]] && die "launch $socket: an instance is already running (pid $(app_pid))"
  uid="$(id -u)"; user="$(id -un)"
  /usr/bin/sudo -n /bin/rm -f "$socket"
  /usr/bin/sudo -n /bin/launchctl asuser "$uid" /usr/bin/sudo -n -u "$user" /usr/bin/env -i \
    HOME="$HOME" USER="$user" LOGNAME="$user" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    TMPDIR="${TMPDIR:-/tmp}" C11_SOCKET_MODE=automation C11_ALLOW_SOCKET_OVERRIDE=1 \
    C11_SOCKET="$socket" C11_SOCKET_PATH="$socket" \
    /bin/zsh -c 'nohup "$1" "${@:3}" > "$2" 2>&1 &' _ "$BIN" "$OUT/c335-app-$NAME-$(basename "$socket").out" \
    ${LANGUAGE_ARGS[@]+"${LANGUAGE_ARGS[@]}"}
  for _ in $(seq 1 90); do [[ -S "$socket" ]] && break; sleep 1; done
  [[ -S "$socket" ]] || die "launch $socket: socket did not appear in 90 s"
  [[ -n "$(app_pid)" ]] || die "launch $socket: no app process"
  one_instance
  export C11_SOCKET="$socket"
  say "launched pid=$(app_pid) socket=$socket"
}
windows() {
  local pid; pid="$(app_pid)"
  [[ -n "$pid" ]] || return 0
  "$UI" windows "$pid" 2>/dev/null | /usr/bin/python3 -c 'import json, sys
for w in json.load(sys.stdin):
    print(w.get("id"), "|", w.get("title"))' 2>/dev/null
}
has_window() { windows | grep -qF "$1"; }
win_shot() {
  local id; id="$(windows | grep -F "$2" | head -1 | cut -d' ' -f1)"
  [[ -n "$id" ]] && /usr/bin/perl -e 'alarm 6; exec @ARGV' /usr/sbin/screencapture -x -o -l"$id" "$OUT/$NAME-$1.png" && say "window shot $NAME-$1.png"; return 0
}
# The whole screen, for a step that involves more than one window.
screen_shot() { /usr/bin/perl -e 'alarm 6; exec @ARGV' /usr/sbin/screencapture -x "$OUT/$NAME-$1.png" && say "screen shot $NAME-$1.png"; return 0; }
# The AX frame of one identifier, as "x,y,w,h" (empty when not on screen).
ax_frame() { "$UI" find "$(app_pid)" "$1" 2>/dev/null | /usr/bin/python3 -c 'import json, sys
for e in json.load(sys.stdin):
    if e.get("identifier") == sys.argv[1] and isinstance(e.get("frame"), list):
        print(",".join(str(round(float(v), 1)) for v in e["frame"])); break' "$1" 2>/dev/null; }
# Make the sheet the key window, as an operator's click on it would: activate the app, then raise the sheet
# and make it main (activating brings the main window in front of it, so a click at its title bar misses).
focus_sheet() {
  "$UI" activate "$(app_pid)" >> "$LOG" 2>&1; sleep 1
  "$UI" raise "$(app_pid)" "$TITLE" >> "$LOG" 2>&1; sleep 1
}
# The key and main windows' titles, as "key|main".
key_main() { "$UI" focus "$(app_pid)" 2>/dev/null | /usr/bin/python3 -c 'import json, sys
f = json.load(sys.stdin); print(f.get("key", "") + "|" + f.get("main", ""))' 2>/dev/null; }
# The AX frame of the window with this exact title, as "x y w h".
win_frame() { "$UI" focus "$(app_pid)" 2>/dev/null | /usr/bin/python3 -c 'import json, sys
for w in json.load(sys.stdin).get("windows", []):
    if w.get("title") == sys.argv[1] and isinstance(w.get("frame"), list): print(" ".join(str(v) for v in w["frame"])); break' "$1" 2>/dev/null; }
pref() { /usr/bin/defaults read "$BID" "$1" 2>/dev/null || echo "(unset)"; }
result() { say "RESULT $1: $2"; }
# The AX identifiers under a prefix that are on screen now (a hidden page is not in the AX tree).
# A failed helper call or unreadable output prints "helper-error" and nothing else.
ax_ids() {
  local raw ids
  raw="$("$UI" find "$(app_pid)" "$1" 2>/dev/null)" || { echo helper-error; return; }
  ids="$(/usr/bin/python3 -c 'import json, sys
for e in json.load(sys.stdin): print(e.get("identifier"))' <<< "$raw" 2>/dev/null)" || { echo helper-error; return; }
  printf '%s\n' "$ids" | sed '/^$/d' | sort -u
}
# Exactly this identifier: 0 on screen, 1 not on screen, 2 the helper failed.
ax_has() { local ids; ids="$(ax_ids "$1")"; [[ "$ids" == helper-error ]] && return 2; grep -qx -- "$1" <<< "$ids"; }
present() { ax_has "$1"; [[ $? -eq 0 ]] && echo pass || echo FAIL; }
absent() { ax_has "$1"; [[ $? -eq 1 ]] && echo pass || echo FAIL; }
press() { "$UI" press "$(app_pid)" "$1" >> "$LOG" 2>&1; sleep 1; }
terminal_count() { "$CLI" tree --json 2>>"$LOG" | /usr/bin/python3 -c '
import json,sys
n=0
def walk(o):
    global n
    if isinstance(o,dict):
        if o.get("type")=="terminal": n+=1
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(json.load(sys.stdin)); print(n)'; }
# The first terminal panel's ref.
first_terminal() { "$CLI" tree --json 2>>"$LOG" | /usr/bin/python3 -c '
import json,sys
def walk(o):
    if isinstance(o,dict):
        if o.get("type")=="terminal" and o.get("ref"): print(o["ref"]); sys.exit()
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(json.load(sys.stdin))'; }

# Page through a three-page sheet: the page on screen, its shot, then Next; Got It on the last closes it.
read_three_pages() {
  local stage="$1" want=(terminals machines mail) i
  for i in 0 1 2; do
    local on; on="$(ax_ids whatsDifferent.page. | tr '\n' ' ')"
    say "$stage page $((i + 1)) on screen: $on"
    [[ "$on" == "whatsDifferent.page.${want[$i]} " ]] && result "$stage-page$((i + 1))-${want[$i]}" pass \
      || result "$stage-page$((i + 1))-${want[$i]}" "FAIL ($on)"
    win_shot "$stage-page$((i + 1))-${want[$i]}" "$TITLE"
    if (( i == 1 )); then back2="$(ax_frame whatsDifferent.back)"; next2="$(ax_frame whatsDifferent.next)"; fi
    if (( i == 2 )); then back3="$(ax_frame whatsDifferent.back)"; next3="$(ax_frame whatsDifferent.done)"; fi
    (( i < 2 )) && press whatsDifferent.next
  done
  result "$stage-last-page-says-got-it" "$(present whatsDifferent.done)"
  say "$stage Back frame page 2 [$back2] page 3 [$back3]; Next [$next2] Got It [$next3]"
  [[ -n "$back2" && "$back2" == "$back3" ]] && result "$stage-back-holds-still" pass || result "$stage-back-holds-still" FAIL
  [[ -n "$next2" && "$next2" == "$next3" ]] && result "$stage-default-button-holds-still" pass || result "$stage-default-button-holds-still" FAIL
  press whatsDifferent.done
  sleep 1
  has_window "$TITLE" && result "$stage-got-it-closes" FAIL || result "$stage-got-it-closes" pass
}

if stage A; then
# --- A: c11 1.x upgrader ------------------------------------------------------------------------
stop_app
reset_profile
/usr/bin/defaults write "$BID" c11.migration.origin -string c11-1x
launch /tmp/c11-c335-a.sock
sleep 14
say "A windows:"; windows | tee -a "$LOG"
has_window "$TITLE" && result A-sheet-shows pass || result A-sheet-shows FAIL
[[ "$(pref c11.upgradeNote.shown)" == "1" ]] && result A-upgrade-note-marked pass || result A-upgrade-note-marked FAIL
result A-hidden-pages-not-in-ax "$(absent whatsDifferent.page.machines)"
# Nothing waits on a click: with the sheet up, a terminal takes input and runs it.
PANEL="$(first_terminal)"
# Wait for the shell's prompt first: a send that lands before zsh's line editor is up arrives as raw
# bracketed-paste bytes ("bad pattern: [200~echo"). One retry covers a prompt drawn a moment late.
for _ in $(seq 1 15); do "$CLI" read-screen --panel "$PANEL" --lines 5 2>/dev/null | grep -qE '[%$#] *$' && break; sleep 1; done
for attempt in 1 2; do
  "$CLI" send --panel "$PANEL" "echo c335-alive-\$((6*7))" >>"$LOG" 2>&1
  sleep 2
  "$CLI" read-screen --panel "$PANEL" --lines 20 > "$OUT/$NAME-A-read-screen.txt" 2>&1
  grep -q "c335-alive-42" "$OUT/$NAME-A-read-screen.txt" && break
  say "A send attempt $attempt: no output yet"
done
grep -q "c335-alive-42" "$OUT/$NAME-A-read-screen.txt" && result A-terminal-works-under-sheet pass || result A-terminal-works-under-sheet FAIL
read_three_pages A
fi

if stage B; then
# --- B: a profile c11 took over from the earlier app --------------------------------------------
stop_app
reset_profile
/usr/bin/defaults write "$BID" c11.migration.origin -string "$ADOPTED_ORIGIN"
launch /tmp/c11-c335-b.sock
sleep 14
say "B windows:"; windows | tee -a "$LOG"
has_window "$TITLE" && result B-sheet-shows pass || result B-sheet-shows FAIL
win_shot B-adopted-page "$TITLE"
on="$(ax_ids whatsDifferent.page. | tr '\n' ' ')"
[[ "$on" == "whatsDifferent.page.adopted " ]] && result B-one-adoption-page pass || result B-one-adoption-page "FAIL ($on)"
result B-no-next "$(absent whatsDifferent.next)"
[[ "$(pref c11.adoptNote.shown)" == "1" ]] && result B-adopt-note-marked pass || result B-adopt-note-marked FAIL
[[ "$(pref c11.upgradeNote.shown)" == "(unset)" ]] && result B-not-the-upgrade-note pass || result B-not-the-upgrade-note FAIL
fi

if stage C; then
# --- C: relaunch shows nothing ------------------------------------------------------------------
stop_app
launch /tmp/c11-c335-c.sock
sleep 14
has_window "$TITLE" && result C-not-shown-again FAIL || result C-not-shown-again pass
fi

if stage D; then
# --- D: fresh profile ---------------------------------------------------------------------------
stop_app
reset_profile
launch /tmp/c11-c335-d.sock
sleep 16
say "D windows:"; windows | tee -a "$LOG"
has_window "$TITLE" && result D-sheet-shows pass || result D-sheet-shows FAIL
[[ "$(pref c11.upgradeNote.shown)$(pref c11.adoptNote.shown)" == "(unset)(unset)" ]] && result D-no-note-marked pass || result D-no-note-marked FAIL
before="$(terminal_count)"
press whatsDifferent.link.terminals
sleep 3
after="$(terminal_count)"
say "D terminals before=$before after=$after"
(( after > before )) && result D-core-link-opens-a-terminal pass || result D-core-link-opens-a-terminal FAIL
press whatsDifferent.next
win_count_before="$(windows | grep -c .)"
press whatsDifferent.link.machines
sleep 3
say "D windows after the machines link:"; windows | tee -a "$LOG"
(( $(windows | grep -c .) > win_count_before )) && has_window "$SETTINGS_TITLE" \
  && result D-machines-link-opens-settings pass || result D-machines-link-opens-settings FAIL
# Herder Topography's own controls are on screen only on that page.
result D-settings-on-herder-topography "$(present SettingsMachineAdd)"
win_shot D-settings-herder-topography "$SETTINGS_TITLE"
press whatsDifferent.back
read_three_pages D
fi

if stage E; then
# --- E: Close on page 1 closes the sheet --------------------------------------------------------
stop_app
reset_profile
launch /tmp/c11-c335-e.sock
sleep 16
has_window "$TITLE" && result E-sheet-shows pass || result E-sheet-shows FAIL
press whatsDifferent.close
sleep 1
has_window "$TITLE" && result E-close-closes FAIL || result E-close-closes pass
fi

if stage F; then
# --- F: Esc on page 2 closes the sheet ----------------------------------------------------------
stop_app
reset_profile
launch /tmp/c11-c335-f.sock
sleep 16
has_window "$TITLE" && result F-sheet-shows pass || result F-sheet-shows FAIL
press whatsDifferent.next
focus_sheet
"$UI" key 53 >> "$LOG" 2>&1
sleep 1
has_window "$TITLE" && result F-esc-closes FAIL || result F-esc-closes pass
fi

if stage G; then
# --- G: Esc belongs to the key window -----------------------------------------------------------
stop_app
reset_profile
launch /tmp/c11-c335-g.sock
sleep 16
has_window "$TITLE" && result G-sheet-shows pass || result G-sheet-shows FAIL
# Panel Details for a terminal, from the command palette in the workspace window. The terminal takes focus
# first, so the palette's text goes nowhere else (a fresh profile focuses a browser's address field).
for _ in $(seq 1 10); do
  MAIN_TITLE="$(windows | grep -vF "$TITLE" | head -1 | cut -d'|' -f2- | sed 's/^ //')"
  [[ -n "$MAIN_TITLE" ]] && break; sleep 1
done
G_PANEL="$(first_terminal)"
"$CLI" focus-panel --panel "$G_PANEL" >> "$LOG" 2>&1
say "G workspace window: $MAIN_TITLE; terminal $G_PANEL focused"
"$UI" activate "$(app_pid)" >> "$LOG" 2>&1; sleep 1
"$UI" raise "$(app_pid)" "$MAIN_TITLE" >> "$LOG" 2>&1; sleep 1
say "G workspace raised key|main=$(key_main)"
"$UI" key 35 cmd-shift >> "$LOG" 2>&1; sleep 2
screen_shot G-palette-open
# Arrow down to the Panel Details command, checked against the palette's own results and selection (this Debug
# build's socket), then Return. No typed text: synthetic characters reach the app's shortcut handling.
WIN_ID="$("$CLI" rpc window.current 2>>"$LOG" | /usr/bin/python3 -c 'import json, sys
d = json.load(sys.stdin); d = d.get("result", d); print(d.get("window_id", ""))' 2>>"$LOG")"
palette() { "$CLI" rpc debug.command_palette.results "{\"window_id\":\"$WIN_ID\",\"limit\":100}" 2>>"$LOG" \
  | /usr/bin/python3 -c 'import json, sys
d = json.load(sys.stdin); d = d.get("result", d)
ids = [r.get("command_id") for r in d.get("results", [])]
print(d.get("visible"), d.get("selected_index"), ids.index("palette.surfaceDetails") if "palette.surfaceDetails" in ids else -1)' 2>>"$LOG"; }
read -r p_visible p_selected p_target <<< "$(palette)"
say "G palette window=$WIN_ID visible=$p_visible selected=$p_selected panel-details-at=$p_target"
if [[ "$p_visible" == True && "${p_target:--1}" -ge 0 ]]; then
  for _ in $(seq 1 $(( p_target - p_selected ))); do "$UI" key 125 >> "$LOG" 2>&1; done
  sleep 1
  read -r p_visible p_selected p_target <<< "$(palette)"
  say "G palette selected=$p_selected panel-details-at=$p_target"
  [[ "$p_selected" == "$p_target" ]] && { "$UI" key 36 >> "$LOG" 2>&1; sleep 3; }
fi
say "G after the palette key|main=$(key_main)"
[[ -n "$(win_frame "$DETAILS_TITLE")" ]] && result G-panel-details-opens pass || result G-panel-details-opens FAIL
# The sheet main, then Panel Details key in front of it, as a click on the panel leaves them.
"$UI" raise "$(app_pid)" "$TITLE" >> "$LOG" 2>&1; sleep 1
"$UI" keywin "$(app_pid)" "$DETAILS_TITLE" >> "$LOG" 2>&1; sleep 1
if [[ "$(key_main)" != "$DETAILS_TITLE|$TITLE" ]]; then
  say "G keywin left key|main=$(key_main); clicking Panel Details' title bar"
  read -r x y w _ <<< "$(win_frame "$DETAILS_TITLE")"
  [[ -n "${w:-}" ]] && "$UI" click "$(/usr/bin/python3 -c "print($x + $w / 2)")" "$(/usr/bin/python3 -c "print($y + 8)")" >> "$LOG" 2>&1
  sleep 1
fi
say "G before Esc key|main=$(key_main)"
[[ "$(key_main)" == "$DETAILS_TITLE|$TITLE" ]] && result G-panel-details-key-sheet-main pass || result G-panel-details-key-sheet-main FAIL
win_shot G-sheet-behind-panel-details "$TITLE"
screen_shot G-screen-panel-details-key
"$UI" key 53 >> "$LOG" 2>&1
sleep 1
say "G after Esc in Panel Details key|main=$(key_main) panel-details-open=$([[ -n "$(win_frame "$DETAILS_TITLE")" ]] && echo yes || echo no)"
has_window "$TITLE" && result G-esc-in-panel-details-leaves-sheet pass || result G-esc-in-panel-details-leaves-sheet FAIL
# Now the sheet key: Esc closes it.
focus_sheet
say "G sheet raised key|main=$(key_main)"
[[ "$(key_main)" == "$TITLE|$TITLE" ]] && result G-sheet-key pass || result G-sheet-key FAIL
"$UI" key 53 >> "$LOG" 2>&1
sleep 1
has_window "$TITLE" && result G-esc-in-sheet-closes FAIL || result G-esc-in-sheet-closes pass
fi

stop_app
say "done"
