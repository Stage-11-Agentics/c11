#!/bin/zsh
# Replay a recorded Claude Code screen in a c11 terminal, for proving `c11 fleet`'s `blocked`
# and `input` fields (C11H-320) without waiting for a real seat to reach that screen.
#
# Run it with argv0 `claude`, so c11's agent detector classifies the panel as Claude Code
# (a real binary keeps argv0; /usr/bin/python3 is a shim that would not):
#
#   exec -a claude /bin/zsh scripts/fleet-screen-replay.zsh resume
#
# Screens: resume (recorded from a live c11h panel, 2026-11-15, Claude Code 2.1.325),
# auto_continue (the recorded bottom of a real 5-hour-limit wait), permission (Claude Code
# 2.1.316's recorded permission menu, the classifier's fixture), usage_limit (built from
# Claude Code 2.1.325's own rate-limit menu strings; no live capture exists yet), idle.
# The screen is drawn at the bottom with the cursor hidden, as Claude draws it. Any key
# replaces it with Claude's idle composer (the dialog clears); q exits.

emulate -L zsh
setopt no_unset

local name=${1:-idle}
local -a lines
case $name in
  resume) lines=(
    $'✻ Cooked for 2m 55s · done Saturday 11:41 PM' ''
    RULE
    '  Resume this conversation?' ''
    '  This conversation has been inactive for 11h 50m and is 535.5k tokens long. Resuming it will use about 7% of your 5-hour usage limit.'
    ''
    $'  ❯ 1. Resume'
    '    2. Start a new conversation  Claude can look this one up if you refer to it later'
    ''
    $'  Enter to confirm · Esc to resume') ;;
  auto_continue) lines=(
    $'⏺ Background command "Wait for run B fill" completed (exit code 0)'
    $'  ⎿  You\'ve hit your 5-hour limit · resets 8:10am (America/Los_Angeles)'
    ''
    $'⏺ Usage limit reached · continuing automatically at 8:10am · esc to cancel'
    '' ''
    $'  ⚠ Usage limit reached · limit resets 8:10am'
    $'    Continuing automatically at 8:10am · Esc to cancel · /usage-credits to continue now') ;;
  permission) lines=(
    $'⏺ Bash(touch /tmp/c11h320-permission-proof)' ''
    RULE
    ' Bash command' ''
    '   touch /tmp/c11h320-permission-proof' ''
    ' Do you want to proceed?'
    $' ❯ 1. Yes'
    '   2. Yes, and always allow access'
    '   3. Yes, and switch to auto mode'
    '   4. No' ''
    $' Esc to cancel · Tab to amend') ;;
  usage_limit) lines=(
    $'⏺ Usage limit reached'
    $'  ⎿  You\'ve hit your 5-hour limit · resets 12:20pm (America/Los_Angeles)'
    ''
    RULE
    '  What do you want to do?' ''
    $'  ❯ 1. Stop and wait for limit to reset'
    '    2. Add funds to continue with usage credits'
    '    3. Upgrade your plan' ''
    $'  Enter to confirm · Esc to cancel') ;;
  idle) lines=() ;;
  *) print -u2 "unknown screen $name; use resume, auto_continue, permission, usage_limit or idle"; exit 2 ;;
esac

local size rows cols rule
size=$(stty size 2>/dev/null) || size="30 100"
rows=${size% *}; cols=${size#* }
rule=''
integer n
for (( n = 0; n < cols; n++ )); do rule+='─'; done

draw_idle() {
  printf '\e[2J\e[%d;1H%s\e[%d;1H❯  \e[%d;1H%s\e[%d;1H  ? for shortcuts\e[%d;4H\e[?25h' \
    $((rows - 3)) "$rule" $((rows - 2)) $((rows - 1)) "$rule" $rows $((rows - 2))
}

draw_dialog() {
  # Long rows are printed whole and wrap at the panel's width, as Claude's do.
  local i line total=0 top row
  local -a heights
  for (( i = 1; i <= ${#lines}; i++ )); do
    line=${lines[i]}
    [[ $line == RULE ]] && line=$rule
    heights[i]=$(( ${#line} > 0 ? (${#line} + cols - 1) / cols : 1 ))
    (( total += heights[i] ))
  done
  top=$(( rows - total + 1 ))
  (( top < 1 )) && top=1
  printf '\e[?25l\e[2J'
  row=$top
  for (( i = 1; i <= ${#lines}; i++ )); do
    line=${lines[i]}
    [[ $line == RULE ]] && line=$rule
    printf '\e[%d;1H%s' $row "$line"
    (( row += heights[i] ))
  done
}

stty raw -echo 2>/dev/null
trap 'stty sane 2>/dev/null; printf "\e[?25h\n"' EXIT
if [[ $name == idle ]]; then draw_idle; else draw_dialog; fi
local key
while read -rs -k 1 key; do
  [[ $key == q ]] && break
  draw_idle
done
