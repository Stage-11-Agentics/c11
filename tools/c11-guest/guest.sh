#!/bin/zsh
# c11 guest helper, GUEST SIDE. Runs inside the Tart guest as `admin`; g.sh (host side) ships and calls it.
# Never run this on the host. Matrix Conventions: $G = launch|quit|apppid|coreenv|procenv|envscan|axtext|kill9-app|crash-app|kill9-core|kill9-holder|stop-core|cont-core|procs|keys|shot|cli|hc.
# Ported from the spike's hc-guest.sh and the Pathfinders' pf/tools/hc-guest.sh, with the spike env removed.
set -u
setopt null_glob
zmodload zsh/datetime      # $EPOCHSECONDS under set -u

# ---------------------------------------------------------------- variables block (one edit per name change)
# Names that come from the contract / ticket plans and may still move. Override any with an env var.
APP_GLOB="${C11_APP_GLOB:-$HOME/c11-sandbox/apps/${C11_RUN:-*}/*.app}"        # where sandbox-up put the tagged app
HC_ROOT="${C11_HC_ROOT:-$HOME/.local/share/c11/hc}"                              # contract L1: <root>/<pin>/herdr-core
RUN_DIR="${C11_RUN_DIR:-$HOME/.local/share/c11/run}"                            # contract L1: S.sock, S.holder.<instance>.sock
CRUMB="${C11_CRUMB:-/tmp/c11-last-socket-path}"                                 # ticket 1 plan: c11 breadcrumb
PROD_SOCK="$HOME/Library/Application Support/c11/c11.sock"                       # ticket 1 plan: Release socket
DEBUG_LOG="$HOME/c11-guest/c11-debug.log"                                      # c11 debug log in the guest (C11_DEBUG_LOG; ticket 9 may rename)
# Socket mode of a launch. automation admits every caller, so the kit's ssh shell may drive the socket. C11_SOCKET_GATE=1 is the
# gated kit mode (C11H-33): c11Only, the app's normal default, which admits only callers inside c11's own terminals; the kit's ssh
# caller (`cli`) is then refused, and rows drive the app with `incli` from inside a terminal. A VAR=val on the launch line still wins.
SOCKET_MODE=automation; [[ "${C11_SOCKET_GATE:-}" == 1 ]] && SOCKET_MODE=c11Only
DEFAULT_LAUNCH_ENV=( "C11_SOCKET_MODE=$SOCKET_MODE" "C11_DEBUG_LOG=$DEBUG_LOG" )                                 # T7 rows may override on the launch line
INCLI_S="${C11_INCLI_S:-20}"                                                       # incli: seconds to wait for the command's exit code
DIAG_VERB="${C11_DIAG_VERB:-}"                                                    # ticket 9's per-panel listing verb; empty = tree JOIN hcrecs (hc get records) by c11.panel, diagjoin.py
GROOT="$HOME/c11-guest"                                                           # scratch inside the guest
# ---------------------------------------------------------------- end variables block

mkdir -p "$GROOT/shots"
die() { print -u2 -- "g: $*"; exit "${2:-1}"; }

resolve_app() {
  if [[ -n "${C11_APP:-}" ]]; then APP="$C11_APP"
  else
    local -a c; c=( ${~APP_GLOB}(N) )
    (( ${#c} == 1 )) || die "cannot pick the app: set C11_APP (candidates: ${c[*]:-none})" 3
    APP="${c[1]}"
  fi
  [[ -d "$APP" ]] || die "app not found: $APP" 3
  BID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null) || die "no Info.plist in $APP" 3
  EXE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)
  local base="${APP:t:r}"
  if [[ -n "${C11_GUEST_TAG+x}" ]]; then TAG="$C11_GUEST_TAG"
  elif [[ "$base" == "c11 DEV "* ]]; then TAG="${base#c11 DEV }"
  elif [[ "$base" == "c11 DEV "* ]]; then TAG="${base#c11 DEV }"
  else TAG=""; fi
  SESSION="${C11_SESSION:-c11${TAG:+-$TAG}}"
  CLI="$APP/Contents/Resources/bin/c11"
}

# A socket FILE proves nothing (a dead app leaves it behind); wait for a successful connect.
sock_alive() { /usr/bin/python3 -I -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])" "$1" 2>/dev/null; }

app_pids() { /usr/bin/pgrep -f "^${APP}/Contents/MacOS/" 2>/dev/null; }

resolve_sock() {
  local s slug suffix
  if [[ -n "${C11_PROOF_SOCKET:-}" ]]; then print -r -- "$C11_PROOF_SOCKET"; return 0; fi
  if [[ -r "$CRUMB" ]]; then s=$(<"$CRUMB"); [[ -S "$s" ]] && { print -r -- "$s"; return 0; }; fi
  # Tagged debug sockets. Until ticket 1 lands a tagged build listens on /tmp/c11-debug-<slug>.sock (slug = bundle-id suffix, dots to dashes);
  # after it, /tmp/c11-debug-<slug>.sock. The tag-based slug is a second guess.
  suffix="${BID#com.stage11.c11.debug.}"; [[ "$suffix" == "$BID" ]] && suffix="${BID#com.stage11.c11.debug.}"
  local -a slugs; slugs=()
  [[ "$suffix" != "$BID" ]] && slugs+=( "$(print -r -- "$suffix" | tr '.' '-' | sed -E 's/^-+|-+$//g')" )
  [[ -n "$TAG" ]] && slugs+=( "$(print -r -- "$TAG" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')" )
  for slug in "${slugs[@]}"; do
    for s in "/tmp/c11-debug-$slug.sock" "/tmp/c11-debug-$slug.sock"; do [[ -S "$s" ]] && { print -r -- "$s"; return 0; }; done
  done
  [[ -S "$PROD_SOCK" ]] && { print -r -- "$PROD_SOCK"; return 0; }
  local -a gs; gs=( /tmp/c11*.sock(N) ); [[ -S "${gs[1]:-}" ]] && { print -r -- "${gs[1]}"; return 0; }
  return 1
}

resolve_hc() {
  HCBIN="${C11_HC_BIN:-}"
  if [[ -z "$HCBIN" ]]; then
    local -a c; c=( $HC_ROOT/*/herdr-core(N) )
    HCBIN="${c[-1]:-}"
    # since #118 (C11H-66) the app serves hc from its own bundle; the user folder holds only a pre-bundle pin
    if [[ ! -x "$HCBIN" ]]; then resolve_app; [[ -x "$APP/Contents/Helpers/herdr-core" ]] && HCBIN="$APP/Contents/Helpers/herdr-core"; fi
  fi
  [[ -x "$HCBIN" ]] || die "pinned hc not found under $HC_ROOT or in the app bundle's Contents/Helpers (core not started yet?)" 4
  HCSOCK="${C11_HC_SOCK:-$RUN_DIR/$SESSION.sock}"
}

# Aqua session (open, osascript, screencapture need it); same recipe as scripts/sandbox-exec.sh.
aqua() {
  /usr/bin/sudo -n /bin/launchctl asuser "$(id -u)" /usr/bin/sudo -n -u "$(id -un)" /usr/bin/env \
    HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    TMPDIR="${TMPDIR:-/tmp}" "$@"
}

# macOS `ps eww` prints argv only, never the environment. The environment of a (non-SIP) process comes from sysctl KERN_PROCARGS2.
# proc_env <pid>: prints ARG:<argv i> and ENV:<k=v> lines. envscan <KEY...>: "<pid> <KEY=value>" for every own process that has one.
proc_env() {
  /usr/bin/python3 -I - "$@" <<'PY'
import ctypes, os, struct, subprocess, sys
libc = ctypes.CDLL("/usr/lib/libc.dylib")
def procargs(pid):
    mib = (ctypes.c_int * 3)(1, 49, int(pid)); size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value < 8: return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0: return None
    data = buf.raw[:size.value]; argc = struct.unpack("i", data[:4])[0]; rest = data[4:]
    i = rest.find(b"\0")
    if i < 0: return None
    while i < len(rest) and rest[i] == 0: i += 1
    parts = rest[i:].split(b"\0")
    return [a.decode(errors="replace") for a in parts[:argc]], [e.decode(errors="replace") for e in parts[argc:] if b"=" in e]
mode = sys.argv[1]
if mode == "one":
    r = procargs(sys.argv[2])
    if r is None: sys.exit(3)
    for a in r[0]: print("ARG:" + a)
    for e in r[1]: print("ENV:" + e)
else:   # scan: keys
    keys = sys.argv[2:]
    for pid in subprocess.run(["/bin/ps", "-axo", "pid="], capture_output=True, text=True).stdout.split():
        r = procargs(pid)
        if not r: continue
        got = [e for e in r[1] if e.split("=", 1)[0] in keys]
        if got: print(pid, " ".join(got))
PY
}
# c11's own pids only: the pinned path under HC_ROOT or the core shipped in THIS app's bundle (C11H-66, #118: $APP/Contents/Helpers/herdr-core;
# never another app's, the retained previous bundle's, or a stray helper), `serve` as a whole word, plus this session (its socket in argv,
# or HC_SESSION in the real environment). C11_PS_FIXTURE=<file> (host self-test only) replaces `ps` with the file's "pid command" lines,
# where a trailing " HC_SESSION=<s>" token stands in for the process environment.
ps_lines() { if [[ -n "${C11_PS_FIXTURE:-}" ]]; then cat "$C11_PS_FIXTURE"; else /bin/ps -axo pid=,command=; fi; }
core_pids() {
  local pid line
  ps_lines | /usr/bin/awk -v root="$HC_ROOT" -v helper="${APP:-/nonexistent}/Contents/Helpers/herdr-core" \
    '(index($0, root "/") || index($0, helper " ")) && / serve( |$)/ && !/ server / && !/awk/ {print $1}' | while read -r pid; do
    if [[ -n "${C11_PS_FIXTURE:-}" ]]; then
      line=$(ps_lines | /usr/bin/awk -v p="$pid" '$1 == p'); [[ "$line" == *"$RUN_DIR/$SESSION.sock"* || "$line" == *" HC_SESSION=$SESSION" ]] && print -r -- "$pid"
    elif /bin/ps -o command= -p "$pid" | grep -qF "$RUN_DIR/$SESSION.sock"; then print -r -- "$pid"
    elif proc_env one "$pid" 2>/dev/null | grep -qx "ENV:HC_SESSION=$SESSION"; then print -r -- "$pid"; fi
  done
}
holder_pids() {
  local out helper="${APP:-/nonexistent}/Contents/Helpers/herdr-core"
  out=$(/bin/ps -axo pid=,command= | /usr/bin/awk -v root="$HC_ROOT" -v helper="$helper" -v s="$SESSION" '(index($0, root "/") || index($0, helper " ")) && / hold( |$)/ && index($0, s ".holder.") && !/awk/ {print $1}')
  [[ -n "$out" ]] || out=$(/bin/ps -axo pid=,command= | /usr/bin/awk -v root="$HC_ROOT" -v helper="$helper" '(index($0, root "/") || index($0, helper " ")) && / hold( |$)/ && !/awk/ {print $1}')
  print -r -- "$out"
}
signal_set() {  # signal_set <SIG> <label> <pids...>
  local sig="$1" label="$2"; shift 2
  (( $# )) || die "$label: no c11 process found (session $SESSION)" 5
  print -r -- "$label sig=$sig pids=$*"
  kill -"$sig" "$@"
}

# launch_env [fresh|resume|normal] [VAR=val..]: sets mode and the assoc E (defaults, then C11_QA_LAUNCH, then the caller's VAR=val)
typeset -A E
launch_env() {
  mode="${1:-fresh}"; (( $# )) && shift
  [[ "$mode" == fresh || "$mode" == resume || "$mode" == normal ]] || die "launch mode must be fresh|resume|normal (normal = no C11_QA_LAUNCH, so startup dialogs and onboarding run)" 2
  local -a qa; qa=( "C11_QA_LAUNCH=$mode" ); [[ "$mode" == normal ]] && qa=()
  local kv; E=(); for kv in "${DEFAULT_LAUNCH_ENV[@]}" "${qa[@]}" "$@"; do E[${kv%%=*}]="${kv#*=}"; done
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  env)
    resolve_app; print "APP=$APP"; print "BUNDLE_ID=$BID"; print "EXE=$EXE"; print "TAG=$TAG"; print "SESSION=$SESSION"
    print "CLI=$CLI"; print "SOCKET=$(resolve_sock || print -- '(none yet)')"
    local -a hb; hb=( $HC_ROOT/*/herdr-core(N) ); local hcb="${hb[-1]:-}"; [[ -x "$hcb" ]] || { [[ -x "$APP/Contents/Helpers/herdr-core" ]] && hcb="$APP/Contents/Helpers/herdr-core"; }
    print "HC_SOCK=$RUN_DIR/$SESSION.sock"; print "HC_BIN=$hcb"; print "SOCKET_MODE=$SOCKET_MODE" ;;
  launch-env)  # launch-env [fresh|resume|normal] [VAR=val..]: the environment `launch` would give the app, one KEY=value per line; launches nothing
    launch_env "$@"; for k in ${(ko)E}; do print -r -- "$k=${E[$k]}"; done ;;
  launch)
    resolve_app
    launch_env "$@"; (( $# )) && shift
    if [[ -n "$(app_pids)" ]]; then print "launch: app already running, quitting it first"; "$0" quit >/dev/null 2>&1 || kill -9 $(app_pids); fi
    oargs=(); for k v in "${(@kv)E}"; do oargs+=(--env "$k=$v"); done
    : > "$GROOT/app.stdout"; t0=$EPOCHSECONDS
    aqua /usr/bin/open -g "$APP" "${oargs[@]}" --stdout "$GROOT/app.stdout" --stderr "$GROOT/app.stdout" || die "open failed" 6
    for i in {1..120}; do [[ -n "$(app_pids)" ]] && break; sleep 0.5; done
    [[ -n "$(app_pids)" ]] || die "app did not start" 6
    sock=""; for i in {1..90}; do sock=$(resolve_sock) && sock_alive "$sock" && break; sock=""; sleep 1; done
    [[ -n "$sock" ]] || die "no socket after 90 s (tail of stdout: $(tail -3 "$GROOT/app.stdout" 2>/dev/null | tr '\n' '|'))" 6
    print "launched pid=$(app_pids | head -1) socket=$sock mode=$mode socket_mode=${E[C11_SOCKET_MODE]:-} secs=$((EPOCHSECONDS-t0))" ;;
  quit)
    # A Quit can sit on a confirmation sheet, and an Apple event waits 120 s for its reply: bound it to 5 s, then answer the sheet.
    resolve_app
    aqua /usr/bin/osascript -e 'with timeout of 5 seconds' -e "tell application id \"$BID\" to quit" -e 'end timeout' >/dev/null 2>&1
    for i in {1..200}; do
      [[ -z "$(app_pids)" ]] && { print quit-ok; exit 0; }
      if (( i % 10 == 1 )); then
        pid=$(app_pids | head -1)
        [[ -n "$pid" ]] && aqua /usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid)" \
          -e "try" -e "click (first button of sheet 1 of window 1 whose name starts with \"Quit\")" -e "end try" \
          -e "try" -e "click (first button of window 1 whose name starts with \"Quit\")" -e "end try" \
          -e "try" -e "if $i > 60 then key code 36" -e "end try" -e "end tell" >/dev/null 2>&1
      fi
      sleep 0.2
    done
    print still-running; exit 1 ;;
  alive)  # the session check (C11H-31): exit 0 and "alive pid=<p>" when the app runs and its socket accepts a connect
    resolve_app; pid=$(app_pids | head -1); [[ -n "$pid" ]] || { print "down: no app process"; exit 1; }
    sock=$(resolve_sock) && sock_alive "$sock" || { print "down: pid=$pid, socket not answering"; exit 1; }
    print "alive pid=$pid socket=$sock" ;;
  apppid) resolve_app; app_pids | head -1 ;;
  coreenv) resolve_app; for p in $(core_pids); do print "core pid=$p"; proc_env one "$p"; done ;;
  procenv) proc_env one "${1:?pid}" ;;
  envscan) proc_env scan "$@" ;;
  axtext)  # all static-text values in the app's front window (accessibility), for notices that are not terminal text
    resolve_app; pid=$(app_pids | head -1); [[ -n "$pid" ]] || die "app not running" 5
    aqua /usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid)" \
      -e "set r to \"\"" -e "try" -e "repeat with t in (every static text of (entire contents of window 1))" -e "set r to r & (value of t as text) & linefeed" -e "end repeat" -e "end try" -e "return r" -e "end tell" 2>&1 ;;
  kill9-app) resolve_app; signal_set 9 kill9-app $(app_pids) ;;
  crash-app) resolve_app; signal_set SEGV crash-app $(app_pids) ;;
  core-pids) resolve_app; core_pids ;;   # the pids core_pids selects (self-test seam, read-only)
  kill9-core) resolve_app; signal_set 9 kill9-core $(core_pids) ;;
  kill9-holder) resolve_app; signal_set 9 kill9-holder $(holder_pids) ;;
  stop-core) resolve_app; signal_set STOP stop-core $(core_pids) ;;
  cont-core) resolve_app; signal_set CONT cont-core $(core_pids) ;;
  procs)
    resolve_app
    /bin/ps -axo pid,ppid,rss,%cpu,etime,command | /usr/bin/awk -v app="$APP" -v root="$HC_ROOT" 'NR==1 || index($0, app) || index($0, root)' | grep -v awk ;;
  keys)
    resolve_app; pid=$(app_pids | head -1); [[ -n "$pid" ]] || die "app not running" 5
    aqua /usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set frontmost to true" -e "delay 0.3" -e "tell application \"System Events\" to $1" ;;
  winbounds)  # "<windowid> <x> <y> <w> <h>" of the app's largest on-screen window
    resolve_app; pid=$(app_pids | head -1); [[ -n "$pid" ]] || die "app not running" 5
    aqua /usr/bin/osascript -l JavaScript -e "ObjC.import('CoreGraphics'); var l=ObjC.deepUnwrap(ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(\$.kCGWindowListOptionOnScreenOnly,0))); var b=null,a=0; l.forEach(function(w){ if(w.kCGWindowOwnerPID==$pid && w.kCGWindowLayer==0){ var s=w.kCGWindowBounds.Width*w.kCGWindowBounds.Height; if(s>a){a=s;b=w} } }); b===null?'':[b.kCGWindowNumber,b.kCGWindowBounds.X,b.kCGWindowBounds.Y,b.kCGWindowBounds.Width,b.kCGWindowBounds.Height].join(' ')" 2>/dev/null ;;
  log) tail -n "${1:-200}" "$DEBUG_LOG" 2>/dev/null ;;
  shot)
    resolve_app; name="${1:?shot <name>}"; out="$GROOT/shots/$name.png"
    wid=$("$0" winbounds 2>/dev/null | awk '{print $1}')
    if [[ -n "$wid" ]]; then aqua /usr/sbin/screencapture -x -o -l "$wid" "$out" || die "screencapture failed" 6
    else print -u2 "shot: no window id, capturing the display"; aqua /usr/sbin/screencapture -x "$out" || die "screencapture failed" 6; fi
    print -r -- "$out" ;;
  cli)
    resolve_app; [[ -x "$CLI" ]] || die "no CLI at $CLI" 3
    if [[ -n "${C11_CLI_BARE:-}" ]]; then exec "$CLI" "$@"; fi
    sock=$(resolve_sock) || die "no c11 socket (is it running?)" 5
    C11_SOCKET_PATH="$sock" C11_ALLOW_SOCKET_OVERRIDE=1 exec "$CLI" "$@" ;;
  hc)
    resolve_app; resolve_hc
    # `hc <anything>` autostarts a core when the socket is absent. Refuse unless the verb is a server verb or the caller opts in.
    if [[ ! -S "$HCSOCK" && "${1:-}" != server && -z "${C11_HC_ALLOW_START:-}" ]]; then die "core socket absent ($HCSOCK); not autostarting" 4; fi
    exec /usr/bin/env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/zsh LANG=en_US.UTF-8 \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" TMPDIR="${TMPDIR:-/tmp}" \
      HC_SESSION="$SESSION" HC_SOCKET="$HCSOCK" "$HCBIN" "$@" ;;
  hcrecs)  # hcrecs [--all]: hc ls with each terminal read by hc get (labels, pid); hc ls prints neither (C11H-31). Same shape as hc ls --json
    resolve_app; resolve_hc
    [[ -S "$HCSOCK" ]] || die "core socket absent ($HCSOCK); not autostarting" 4
    [[ -f "$GROOT/hcrecs.py" ]] || die "hcrecs.py missing in $GROOT (g.sh ships it with guest.sh)" 5
    exec /usr/bin/env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/zsh LANG=en_US.UTF-8 \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" TMPDIR="${TMPDIR:-/tmp}" \
      HC_SESSION="$SESSION" HC_SOCKET="$HCSOCK" /usr/bin/python3 -I "$GROOT/hcrecs.py" "$HCBIN" "$@" ;;
  incli)  # incli <panel UUID|any> <c11 args..>: the bundled c11 run INSIDE one of the app's own hc terminals, as an agent there runs it (C11H-33)
    # Typed into that terminal with `hc send`, so the command descends from the terminal's process: the gated socket (c11Only) must admit
    # it, where it refuses the kit's ssh caller (`cli`). The terminal's own environment is used (no socket override). Prints one JSON
    # record {panel, terminal, rc, out, err, env: the C11_* the terminal gave it}. Exit 4 no core socket (never autostarts), 5 no live
    # terminal labelled c11.panel=<panel> (any = the first live labelled one), 6 no exit code within C11_INCLI_S s, 7 hc send failed.
    resolve_app; resolve_hc
    [[ -S "$HCSOCK" ]] || die "core socket absent ($HCSOCK); not autostarting" 4
    want="${1:?incli <panel UUID|any> <c11 args..>}"; shift
    recs=$("$0" hcrecs) || die "incli: hcrecs failed" 5
    pick=$(print -r -- "$recs" | /usr/bin/python3 -I -c '
import json, sys
want = sys.argv[1].upper()
for t in json.loads(sys.stdin.read() or "{}", strict=False).get("terminals", []):
    if not isinstance(t, dict) or t.get("state") != "live":
        continue
    lab = t.get("labels") or {}
    if isinstance(lab, list):
        lab = dict(x.split("=", 1) for x in lab if isinstance(x, str) and "=" in x)
    p = str(lab.get("c11.panel", "")).upper() if isinstance(lab, dict) else ""
    if p and (want == "ANY" or p == want):
        print(t["address"], p); sys.exit(0)
sys.exit(1)' "$want") || die "incli: no live app terminal labelled c11.panel=$want" 5
    addr="${pick%% *}"; panel="${pick#* }"
    d="$GROOT/incli/$EPOCHREALTIME.$$"; mkdir -p "$d"
    { print -r -- "/usr/bin/env | /usr/bin/grep -E '^C11_(SOCKET_PATH|PANEL_ID|WORKSPACE_ID|SHELL_INTEGRATION)=' > ${(qq)d}/env"
      print -r -- "${(qq)CLI} ${(@qq)@} > ${(qq)d}/out 2> ${(qq)d}/err"
      print -r -- "echo \$? > ${(qq)d}/rc.part && mv ${(qq)d}/rc.part ${(qq)d}/rc"; } > "$d/cmd.sh"
    "$0" hc send "$addr" "/bin/sh ${(qq)d}/cmd.sh" > "$d/send.out" 2>&1 || { e=$(head -c 300 "$d/send.out" | tr '\n' ' '); rm -rf "$d"; die "incli: hc send to $addr failed: $e" 7; }
    for (( i = 0; i < INCLI_S * 5; i++ )); do [[ -f "$d/rc" ]] && break; sleep 0.2; done
    [[ -f "$d/rc" ]] || { rm -rf "$d"; die "incli: no exit code from terminal $addr within ${INCLI_S} s" 6; }
    /usr/bin/python3 -I -c '
import json, os, sys
d, panel, addr = sys.argv[1:4]
def r(f):
    p = os.path.join(d, f)
    return open(p, errors="replace").read() if os.path.exists(p) else ""
env = dict(l.split("=", 1) for l in r("env").splitlines() if "=" in l)
print(json.dumps({"panel": panel, "terminal": addr, "rc": int(r("rc").strip() or -1), "out": r("out"), "err": r("err"), "env": env}))' "$d" "$panel" "$addr"
    rm -rf "$d" ;;
  diag)
    resolve_app
    if [[ -n "$DIAG_VERB" ]]; then exec "$0" cli ${=DIAG_VERB} --json; fi
    tree=$("$0" cli --id-format both tree --json) || die "tree failed" 5
    recs=$("$0" hcrecs --all 2>/dev/null) || recs='{"terminals":[]}'
    hcdiag=$("$0" cli hc-diagnostics --json 2>/dev/null) || hcdiag=''
    C11_TREE="$tree" C11_HCRECS="$recs" C11_HCDIAG="$hcdiag" /usr/bin/python3 -I "$GROOT/diagjoin.py"
    ;;
  sh) /bin/zsh -c "$1" ;;
  aqua-sh) aqua /bin/zsh -c "$1" ;;
  *) print -u2 "usage: env|launch [fresh|resume] [VAR=val..]|quit|apppid|coreenv|procenv|envscan|axtext|kill9-app|crash-app|kill9-core|kill9-holder|stop-core|cont-core|procs|keys '<System Events body>'|shot <name>|winbounds|log [n]|launch-env [mode] [VAR=val..]|cli ..|incli <panel|any> ..|hc ..|hcrecs [--all]|diag|sh '<zsh>'|aqua-sh '<zsh>'"; exit 2 ;;
esac
