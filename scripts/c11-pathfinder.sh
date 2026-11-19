#!/bin/bash
# c11-pathfinder.sh: prove that an agent launched from c11 on each linked machine actually answers.
#
#   scripts/c11-pathfinder.sh [--json] [--keep] [--strict] [--timeout S] [--model M] [--type K] [--cwd P] [machine ...]
#
# With no machine named, every connected machine in `c11 machine list` (plus `local` with --local).
# Per machine, in parallel: launch the agent through the real c11 path (`c11 launch-agent --on <m>`)
# with a short zany prompt that must come back in under one paragraph and end with a fresh token
# (e.g. ATLAS-OK-7f3a), then read the panel's screen until the token appears or a failure shows.
#
# PASS: the token is on screen in the agent's answer. An answer over one paragraph (120 words) is
#       reported as a warning; --strict makes it a failure.
# FAIL: c11's launch watch reports failed or needs_operator, a failure signature on screen (command
#       not found, usage limit, login, trust dialog, API error), or no answer before the timeout.
#       The watch (`c11 rpc agent.launch_status`) is read on every look at the screen, so it fails
#       a launch fast but never holds up a pass: an agent passes as soon as its reply shows, even
#       where the watch cannot see turn edges (the Linux host's containers until C11H-198). An app without
#       the watch is judged by the screen alone. A failed panel stays open for the operator; a
#       passed one is closed (its session ends) unless --keep.
# Each verdict, with the watch's last word, is appended as one JSON line to ~/Library/Logs/c11/pathfinder.jsonl.
# Exit status: 0 when every machine passed, 1 otherwise, 2 on bad usage.
set -uo pipefail

C11="${C11_CLI:-c11}"
TIMEOUT=120 MODEL=sonnet TYPE=claude-code KEEP=0 JSON=0 LOCAL=0 CWD="" STRICT=0 MAXWORDS=120
MACHINES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1;; --keep) KEEP=1;; --local) LOCAL=1;; --strict) STRICT=1;;
    --timeout) TIMEOUT="$2"; shift;; --model) MODEL="$2"; shift;; --type) TYPE="$2"; shift;;
    --cwd) CWD="$2"; shift;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d'; exit 0;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) MACHINES+=("$1");;
  esac
  shift
done
[ -n "${C11_WORKSPACE_ID:-}" ] || { echo "run this from a c11 terminal (no C11_WORKSPACE_ID)" >&2; exit 2; }

if [ ${#MACHINES[@]} -eq 0 ]; then
  while IFS=$'\t' read -r id _name _color state; do
    [ "$state" = connected ] && MACHINES+=("$id")
  done < <("$C11" machine list 2>/dev/null)
  [ "$LOCAL" = 1 ] && MACHINES+=(local)
fi
[ ${#MACHINES[@]} -gt 0 ] || { echo "no connected machine to test" >&2; exit 1; }

PROMPTS=(
  "Pitch a nature documentary narrated by a sourdough starter that has just learned which city it lives in."
  "Describe a thunderstorm as a jazz drummer who is also a very anxious librarian would."
  "Write the weather forecast for a planet whose clouds are made of forgotten passwords."
  "Explain the offside rule as a medieval herald announcing it to a court of pigeons."
  "Give a motivational speech from a houseplant to the human who keeps overwatering it."
  "Review a sandwich as if it were a Broadway musical on opening night."
  "Describe the Tailscale network as a gossip column about the machines on it."
)
# Signatures that mean the agent did not really start, read from the screen beside the watch (and
# alone for an app without it). Keep in step with AgentLaunchWatch.scan (Sources/AgentLaunchWatch.swift).
FAILS='command not found|not found in PATH|hit your [a-z ]*limit|Login expired|Not logged in|Please run /login|Is this a project you created or one you trust|Do you trust the files in this folder|API Error'

LOG="$HOME/Library/Logs/c11/pathfinder.jsonl"; mkdir -p "$(dirname "$LOG")"
OUT="$(mktemp -d)"; trap '/bin/rm -rf "$OUT"' EXIT

probe() {
  local m="$1" up token prompt start res ref pid verdict reason answer words secs s hit
  # The watch's last word, as logged: unread until it first answers, then its verdict (pending, ready,
  # quiet, failed, needs_operator); unavailable when the app has no watch for this panel.
  local watch=unavailable watch_msg="" w wmsg
  up="$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '-')"
  token="${up}-OK-$(openssl rand -hex 2)"
  prompt="${PROMPTS[$((RANDOM % ${#PROMPTS[@]}))]} Keep it under one paragraph: at most three sentences. End your reply with the exact token ${token}"
  start=$(date +%s)
  local on=(); [ "$m" = local ] || on=(--on "$m")
  local cwd=(); [ -n "$CWD" ] && cwd=(--cwd "$CWD")
  # --id-format both: the panel's UUID too, which agent.launch_status takes.
  res="$("$C11" --id-format both launch-agent --type "$TYPE" --model "$MODEL" ${on[@]+"${on[@]}"} ${cwd[@]+"${cwd[@]}"} \
          --title "Pathfinder $m" --delegated --prompt "$prompt" --json 2>"$OUT/$m.err")"
  read -r ref pid < <(printf '%s' "$res" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("panel_ref") or "-", d.get("panel_id") or d.get("surface_id") or "-")')
  [ "$ref" = - ] && ref=""
  if [ "$pid" = - ]; then pid=""; else watch=unread; fi
  verdict=FAIL reason="" answer=""
  if [ -z "$ref" ]; then
    reason="launch refused: $( { printf '%s' "$res"; cat "$OUT/$m.err"; } | tr '\n' ' ' | cut -c1-200)"
  else
    while :; do
      s="$("$C11" read-screen --panel "$ref" --workspace "$C11_WORKSPACE_ID" --lines 80 2>/dev/null)"
      # The token is only in the prompt file, never echoed, so seeing it means the agent wrote it.
      if printf '%s' "$s" | grep -qF "$token"; then
        answer="$(printf '%s\n' "$s" | python3 -c '
import sys,re
t=sys.argv[1]; text=sys.stdin.read()
i=text.rfind(t)
# The reply starts at the last assistant marker before the token (macOS draws U+23FA, a Linux font may draw U+25CF).
j=max(text.rfind(m,0,i) for m in ("⏺","●"))
seg=text[(j+1 if j>=0 else max(0,i-1500)):i+len(t)]
print(re.sub(r"\s+"," ",seg).strip())' "$token")"
        words=$(printf '%s' "${answer%"$token"}" | wc -w | tr -d ' ')
        verdict=PASS
        # Over ~one paragraph: the connection works but the agent ignored the brief. A warning, or a failure with --strict.
        if [ "$words" -gt "$MAXWORDS" ]; then
          reason="answer ran long ($words words)"; [ "$STRICT" = 1 ] && verdict=FAIL
        fi
        break
      fi
      # The launch watch, read on every look: a failure it names ends the run at once, while its
      # ready, quiet or pending never holds up the screen (the Linux host's agents give it no turn edges yet).
      if [ "$watch" != unavailable ]; then
        # stdout is the JSON alone; the error code (if any) is read from stderr once stdout has closed.
        read -r w wmsg < <("$C11" rpc agent.launch_status "{\"panel_id\":\"$pid\"}" 2>"$OUT/$m.rpcerr" | python3 -c 'import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception:
    # An app without the method (method_not_found), or no watch for this panel (not_found), will
    # never answer; anything else is a hiccup to retry.
    print("unavailable" if "not_found:" in open(sys.argv[1]).read() else "-"); sys.exit()
print(d.get("verdict") or "-", (d.get("message") or d.get("line") or "").replace("\n"," "))' "$OUT/$m.rpcerr")
        [ -z "$w" ] || [ "$w" = - ] || { watch="$w"; watch_msg="$wmsg"; }
        case "$watch" in failed|needs_operator) reason="$watch: ${watch_msg:-no message}"; break;; esac
      fi
      hit="$(printf '%s' "$s" | grep -oE "$FAILS" | head -1)"
      [ -n "$hit" ] && { reason="$hit"; break; }
      [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ] && { reason="no answer in ${TIMEOUT}s"; break; }
      /bin/sleep 2
    done
  fi
  secs=$(( $(date +%s) - start ))
  if [ "$verdict" = PASS ] && [ "$KEEP" = 0 ]; then
    "$C11" close-panel --panel "$ref" --workspace "$C11_WORKSPACE_ID" --expect-title "Pathfinder $m" >/dev/null 2>&1
  fi
  python3 -c 'import json,sys,datetime
k=["machine","verdict","seconds","panel","token","reason","answer","watch"]
d=dict(zip(k,sys.argv[1:]))
d["seconds"]=int(d["seconds"]); d["at"]=datetime.datetime.now().astimezone().isoformat(timespec="seconds")
print(json.dumps(d))' "$m" "$verdict" "$secs" "$ref" "$token" "$reason" "$answer" "$watch" > "$OUT/$m.json"
}

for m in "${MACHINES[@]}"; do probe "$m" & done
wait

rc=0
for m in "${MACHINES[@]}"; do
  line="$(cat "$OUT/$m.json")"; printf '%s\n' "$line" >> "$LOG"
  if [ "$JSON" = 1 ]; then printf '%s\n' "$line"; else
    printf '%s\n' "$line" | python3 -c 'import json,sys
d=json.load(sys.stdin)
detail=(("[warn: %s] "%d["reason"]) if d["reason"] else "")+d["answer"] if d["verdict"]=="PASS" else d["reason"]+(" (panel %s left open)"%d["panel"] if d["panel"] else "")
print("%-4s %-8s %4ss  %s"%(d["verdict"],d["machine"],d["seconds"],detail[:220]))'
  fi
  printf '%s' "$line" | grep -q '"verdict": "PASS"' || rc=1
done
exit $rc
