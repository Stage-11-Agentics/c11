#!/usr/bin/env bash
# Clone the golden Tart image on the sandbox host, boot it headless, and launch a c11 .app inside it.
# Usage: scripts/sandbox-up.sh <run-id> <path-to.app> [--allow-second] [--agents claude,codex,grok,pi,omp,pi-live,omp-live,opencode-live]
#        scripts/sandbox-up.sh <run-id> --app-source <name> [--allow-second] [--agents ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

# Started with a signal ignored (a background job of a non-interactive shell ignores SIGINT,
# `nohup` ignores SIGHUP), bash cannot trap it: a signal ignored on entry stays ignored, and
# Ctrl-C or kill -INT during agent staging would leave a credential-bearing clone running.
# Re-exec once with INT, TERM and HUP at their defaults, so the staging trap below sees them.
if [[ -z "${C11_SANDBOX_SIGNALS_RESET:-}" ]]; then
  export C11_SANDBOX_SIGNALS_RESET=1
  exec /usr/bin/python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, signal.SIG_DFL)
os.execv("/bin/bash", ["/bin/bash"] + sys.argv[1:])' "$0" "$@"
fi

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-up.sh <run-id> <path-to.app> [--allow-second] [--agents claude,codex,grok,pi,omp,pi-live,omp-live,opencode-live]
       scripts/sandbox-up.sh <run-id> --app-source <name> [--allow-second] [--agents ...]

Clone c11-sandbox-golden on C11_SANDBOX_HOST (from the environment or
~/.config/c11/dev-hosts; `local` is this machine), boot that
clone headless, place one .app on the Tart host, copy it into the guest,
and launch it with the automation socket. The golden image is never booted.
A second running guest needs --allow-second and clones c11-sandbox-golden-b,
which has its own serial. Both goldens must exist and be stopped, or this
fails before upload (re-provision with docs/c11-sandbox-research.md step 9).
A third running guest is always refused. If this command is cut
off, scripts/sandbox-down.sh <run-id> removes the clone.

C11_SANDBOX_IMAGE and C11_SANDBOX_IMAGE_B name what each serial slot clones
from: a copy of that slot's golden (same serial) with more installed, such as
c11's agent image (docs/c11-guest-agents.md). Unset, each slot clones its
golden, as above. The run still records the slot's golden as its serial, so
every copy of these scripts keeps two running guests off one serial. A named
image must exist and be stopped, like the goldens.

--agents stages logged-in agent CLIs into the clone once the app is up
(scripts/sandbox-agent.sh <run-id> stage). A kind that cannot be staged
fails the whole command and the clone is removed.

--app-source (or C11_SANDBOX_APP_SOURCE) names where the .app comes from.
Every source leaves one bundle at ~/.c11-sandbox/apps/<run-id>/ on the Tart
host. The boot path only reads that directory.
  local-app    A .app path on this machine, copied up. This is the default.
  atlas-build  Reserved for a later branch build on the Tart host.
               Not implemented: exits before SSH, does not install Xcode,
               and does not wait for Xcode.
EOF
}

# A live run id must fail before anything deletes its VM, its tart process, or its staged app.
refuse_existing_clone() {
  local run_id="$1" state
  state="$(
    sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
run_id=$(printf '%q' "$run_id")
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
vm_field "\$vm" || true
EOF
  )" || sandbox_die "could not read VM state for ${run_id}"
  if [[ -n "$state" ]]; then
    sandbox_die "c11-sb-${run_id} already exists (${state}). Run sandbox-down.sh ${run_id} first."
  fi
}

# local-app: copy a bundle from this machine into the host staging directory.
stage_local_app() {
  local app="$1" rel="$2"
  [[ -d "$app" ]] || sandbox_die "app not found: $app"
  [[ "$app" == *.app ]] || sandbox_die "expected a .app bundle: $app"
  [[ -f "$app/Contents/Info.plist" ]] || sandbox_die "not an app bundle: $app"
  refuse_existing_clone "$run_id"
  app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  local app_base ssh_host
  app_base="$(basename "$app")"
  ssh_host="$(sandbox_host_name)" || exit 2
  if [[ "$ssh_host" != "local" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=25 -o LogLevel=ERROR "$ssh_host" \
      "rm -rf \"\$HOME/${rel}\" && mkdir -p \"\$HOME/${rel}\""
  else
    rm -rf "${HOME:?}/${rel}"
    mkdir -p "${HOME}/${rel}"
  fi
  COPYFILE_DISABLE=1 tar -C "$(dirname "$app")" -cf - "$app_base" | sandbox_extract_tar "$rel"
}

run_id=""
app=""
allow_second=0
app_source="${C11_SANDBOX_APP_SOURCE:-local-app}"
agents=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --allow-second) allow_second=1; shift ;;
    --agents)
      [[ $# -ge 2 ]] || sandbox_die "--agents needs a list such as claude,codex,grok"
      agents="$2"
      shift 2
      ;;
    --agents=*) agents="${1#--agents=}"; shift ;;
    --app-source)
      [[ $# -ge 2 ]] || sandbox_die "--app-source needs a name"
      app_source="$2"
      shift 2
      ;;
    --app-source=*)
      app_source="${1#--app-source=}"
      [[ -n "$app_source" ]] || sandbox_die "--app-source needs a name"
      shift
      ;;
    --) shift; break ;;
    -*) sandbox_die "unknown flag: $1" ;;
    *)
      if [[ -z "$run_id" ]]; then
        run_id="$1"
      elif [[ -z "$app" ]]; then
        app="$1"
      else
        sandbox_die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
if [[ $# -gt 0 ]]; then
  sandbox_die "unexpected argument: $1"
fi
[[ -n "$run_id" ]] || { usage >&2; exit 1; }
sandbox_validate_run_id "$run_id"
if [[ -n "$agents" ]]; then
  [[ "$agents" =~ ^(claude|codex|grok|pi|omp|pi-live|omp-live|opencode-live)(,(claude|codex|grok|pi|omp|pi-live|omp-live|opencode-live))*$ ]] || sandbox_die "--agents takes a comma-separated list of claude, codex, grok, pi, omp, pi-live, omp-live, opencode-live"
fi
rel=".c11-sandbox/apps/${run_id}"

# Check both serial-safe sources before a local app is uploaded to the Tart
# host. The host script repeats this check under clone.lock before cloning.
require_goldens_stopped() {
  sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
require_stopped() {
  local name="\$1" state
  state="\$(vm_field "\$name" || true)"
  [[ -n "\$state" ]] || die "golden image \$name is missing. Re-provision it using docs/c11-sandbox-research.md step 9."
  [[ "\$state" == stopped ]] || die "golden image \$name is \$state; both goldens must be stopped. See docs/c11-sandbox-research.md step 9."
}
require_stopped "\$golden"
require_stopped "\$golden_b"
[[ "\$image" == "\$golden" ]] || require_stopped "\$image"
[[ "\$image_b" == "\$golden_b" ]] || require_stopped "\$image_b"
EOF
}

# The case is the seam. Add a source by staging one .app into $rel on the
# Tart host. Do not teach the boot path about the source.
case "$app_source" in
  local-app)
    [[ -n "$app" ]] || { usage >&2; exit 1; }
    require_goldens_stopped
    stage_local_app "$app" "$rel"
    ;;
  atlas-build)
    sandbox_die "app source atlas-build is not implemented. It will build a branch on the Tart host and leave the .app in ${rel}. This script does not install Xcode and does not wait for it. Pass a local .app path."
    ;;
  *)
    sandbox_die "unknown app source: $app_source. Known sources: local-app, atlas-build."
    ;;
esac

guest_b64="$(
  {
    sandbox_guest_runtime_zsh
    cat <<'GUEST'
set -eu
setopt pipefail
# One .app, staged by whichever app source sandbox-up selected.
dest_parent="$HOME/c11-sandbox/apps/$SANDBOX_RUN_ID"
setopt null_glob
srcs=("$dest_parent"/*.app)
unsetopt null_glob
(( ${#srcs} > 0 )) || { print -u2 -- "no .app in $dest_parent"; exit 1 }
dest="$srcs[1]"
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
command -v python3 >/dev/null || { print -u2 -- "python3 is missing in the guest"; exit 1 }
if [[ ! -x /opt/homebrew/bin/cliclick ]] && ! command -v cliclick >/dev/null 2>&1; then
  print -u2 -- "cliclick is missing in the guest"
  exit 1
fi
socket="/tmp/c11-sandbox-$SANDBOX_RUN_ID.sock"
dbglog="/tmp/c11-sandbox-$SANDBOX_RUN_ID.log"
stdout="/tmp/c11-sandbox-$SANDBOX_RUN_ID.stdout"
dsock="$HOME/Library/Application Support/c11/c11d-sandbox-$SANDBOX_RUN_ID.sock"
sandbox_launch_app "$dest" "$socket" "$dbglog" "$stdout" "$dsock"
cli="$dest/Contents/Resources/bin/c11"
[[ -x "$cli" ]] || cli="$dest/Contents/MacOS/c11"
printf 'GUEST_APP=%q\n' "$dest"
printf 'SOCKET=%q\n' "$socket"
printf 'CLI=%q\n' "$cli"
printf 'LOG=%q\n' "$dbglog"
printf 'STDOUT=%q\n' "$stdout"
printf 'DSOCK=%q\n' "$dsock"
GUEST
  } | base64 | tr -d '\n'
)"

sandbox_on_host <<EOF
set -eu
setopt pipefail no_hup no_monitor
$(sandbox_host_prelude)
run_id=$(printf '%q' "$run_id")
allow_second=$(printf '%q' "$allow_second")
app_source=$(printf '%q' "$app_source")
lane_yield_s=$(printf '%q' "${C11_SANDBOX_LANE_YIELD_S:-30}")
[[ "\$lane_yield_s" == <-> ]] || die "C11_SANDBOX_LANE_YIELD_S must be a whole number of seconds"
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
tart="\$(tart_bin)" || die "tart is not installed on this host"
require_stopped_golden() {
  local name="\$1" state
  state="\$(vm_field "\$name" || true)"
  [[ -n "\$state" ]] || die "golden image \$name is missing. Re-provision it using docs/c11-sandbox-research.md step 9."
  [[ "\$state" == stopped ]] || die "golden image \$name is \$state; both goldens must be stopped. See docs/c11-sandbox-research.md step 9."
}
require_stopped_golden "\$golden"
require_stopped_golden "\$golden_b"
[[ "\$image" == "\$golden" ]] || require_stopped_golden "\$image"
[[ "\$image_b" == "\$golden_b" ]] || require_stopped_golden "\$image_b"
[[ -f "\$key" ]] || die "missing \$key on the Tart host. Golden-image setup installs this key."
lock="\$root/clone.lock"
lock_held=0
# The host-test lane (scripts/c11-host-tests.py) records each guest it may create in
# host-tests/owned/<vm>.json before it takes clone.lock, and always yields to an owner. One
# wall-clock deadline (lane_yield_s from the first request) covers lock admission, the lane's own
# cleanup and our forced cleanup. Only recorded lane guests are touched, never a VM by its name.
# lane_deadline is one monotonic-enough wall-clock instant (EPOCHREALTIME) set at the first request.
# Takeover starts at lane_takeover_at, leaving the reserve for forced cleanup, which must end by
# lane_cleanup_end so the owner's own clone still lands inside the deadline. Past it, no step gets time.
typeset -F lane_deadline=0 lane_takeover_at=0 lane_cleanup_end=0
typeset -A lane_ignored
lane_claims() {
  local c
  for c in "\$root"/host-tests/owned/*.json(N); do print -r -- "\${c:t:r}"; done
}
# Identity of a recorded process: the claim stores each PID (lane, producer) with its start time
# and exact command line. Prints the PID and succeeds only while that same process still runs;
# gone, a zombie, reused or never recorded all fail, and a failure never authorizes a signal.
identity_pid() {
  /usr/bin/python3 -c 'import json, os, subprocess, sys
try:
    claim = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
pid = claim.get("pid" if sys.argv[2] == "lane" else "producer_pid")
rec = claim.get(sys.argv[2])
if type(pid) is not int or type(rec) is not dict or not rec.get("start"):
    sys.exit(1)
def ps(field):
    # The same pinned locale and zone the lane records under (lstart prints by LC_TIME and TZ).
    env = dict(os.environ, LC_ALL="C", TZ="UTC0")
    return subprocess.run(["/bin/ps", "-o", field + "=", "-p", str(pid)], capture_output=True, text=True, env=env).stdout.strip()
stat = ps("stat")
if not stat or stat.startswith("Z") or ps("lstart") != rec.get("start") or ps("command") != rec.get("command"):
    sys.exit(1)
print(pid)' "\$root/host-tests/owned/\$1.json" "\$2"
}
lane_alive() {
  identity_pid "\$1" lane >/dev/null
}
cleanup_left() {
  print -r -- \$(( lane_cleanup_end - EPOCHREALTIME ))
}
# Run a command for at most \$1 seconds (fractional). With no time left it does not run at all.
bounded() {
  local secs="\$1"
  shift
  (( secs > 0.05 )) || return 124
  /usr/bin/perl -MTime::HiRes=alarm -e 'alarm shift; exec @ARGV' "\$secs" "\$@"
}
request_lane_yield() {
  local name reserve
  local -a names
  names=(\${(f)"\$(lane_claims)"})
  (( \${#names} )) || return 0
  if (( lane_deadline == 0 )); then
    lane_deadline=\$(( EPOCHREALTIME + lane_yield_s ))
    reserve=\$(( lane_yield_s / 4.0 ))
    (( reserve >= 2.5 )) || reserve=2.5
    lane_takeover_at=\$(( lane_deadline - reserve ))
    lane_cleanup_end=\$(( lane_deadline - 1.0 ))
  fi
  mkdir -p "\$root/lane-yield"
  for name in \$names; do
    [[ -e "\$root/lane-yield/\$name" ]] && continue
    print -r -- "\$run_id" > "\$root/lane-yield/\$name"
    print -u2 -- "sandbox: host-test lane guest \$name yields to \$run_id"
  done
}
# Kill a recorded process (\$2: lane or producer) only while it is provably that process, then
# wait until it is gone. KILL, not TERM: it is past its deadline and may be stopped.
stop_recorded() {
  local name="\$1" role="\$2" pid
  (( \$(cleanup_left) > 0.05 )) || return 0
  pid="\$(identity_pid "\$name" "\$role")" || return 0
  kill -KILL "\$pid" 2>/dev/null || true
  while (( EPOCHREALTIME < lane_cleanup_end )); do
    identity_pid "\$name" "\$role" >/dev/null || return 0
    sleep 0.05
  done
}
# Take a recorded lane guest back: stop its lane process and its VM producer first, so nothing can
# recreate the VM, then stop and delete the VM, then drop the claim once the VM is gone.
force_lane_guest() {
  local name="\$1"
  # A claim never authorizes touching anything but a lane guest: no golden, image or owner guest.
  if [[ "\$name" != c11-ht-* || "\$name" == "\$golden" || "\$name" == "\$golden_b" \
        || "\$name" == "\$image" || "\$name" == "\$image_b" ]]; then
    (( \${+lane_ignored[\$name]} )) || print -u2 -- "sandbox: ignoring a lane claim for \$name: not a lane guest"
    lane_ignored[\$name]=1
    return 0
  fi
  local claim="\$root/host-tests/owned/\$name.json"
  # The lane releases its claim only after its VM is gone: a vanished claim means nothing to do.
  [[ -e "\$claim" ]] || return 0
  stop_recorded "\$name" lane
  stop_recorded "\$name" producer
  [[ -e "\$claim" ]] || return 0
  bounded \$(( \$(cleanup_left) / 2 )) "\$tart" stop "\$name" --timeout 1 >/dev/null 2>&1 || true
  bounded "\$(cleanup_left)" "\$tart" delete "\$name" >/dev/null 2>&1 || true
  local listing
  (( \$(cleanup_left) > 0.05 )) || return 0
  if ! lane_alive "\$name"; then
    listing="\$(bounded "\$(cleanup_left)" "\$tart" list 2>/dev/null)" || return 0
    print -r -- "\$listing" | awk -v n="\$name" '\$2==n {found=1} END {exit found ? 1 : 0}' \
      && rm -f "\$root/host-tests/owned/\$name.json"
  fi
}
finish_lane_preemption() {
  request_lane_yield
  (( lane_deadline > 0 )) || return 0
  local name pid
  while (( EPOCHREALTIME < lane_takeover_at )); do
    [[ -z "\$(lane_claims)" ]] && return 0
    # A dead lane will not clean up: stop waiting for it.
    for name in \${(f)"\$(lane_claims)"}; do
      lane_alive "\$name" || force_lane_guest "\$name"
    done
    sleep 0.2
  done
  for name in \${(f)"\$(lane_claims)"}; do
    print -u2 -- "sandbox: \$name did not yield in time; taking it back"
    force_lane_guest "\$name"
  done
}
release_lock() {
  (( lock_held )) || return 0
  rm -rf "\$lock"
  lock_held=0
}
acquire_lock() {
  local oldpid name lock_pid
  local -F started=\$EPOCHREALTIME
  while true; do
    if mkdir "\$lock" 2>/dev/null; then
      print -r -- \$\$ > "\$lock/pid"
      print -r -- "\$run_id" > "\$lock/run"
      lock_held=1
      return 0
    fi
    # The lane holding the lock (booting its clone) is asked to yield; at takeover time it loses the
    # lock, after its run and producer are stopped. That wait is bounded by the lane deadline.
    if [[ "\$(cat "\$lock/run" 2>/dev/null || true)" == host-tests ]]; then
      request_lane_yield
      if (( lane_deadline > 0 )); then
        if (( EPOCHREALTIME >= lane_takeover_at )); then
          lock_pid="\$(cat "\$lock/pid" 2>/dev/null || true)"
          print -u2 -- "sandbox: the host-test lane kept \$lock; taking the guest and the lock back"
          for name in \${(f)"\$(lane_claims)"}; do force_lane_guest "\$name"; done
          # Only the lane's lock, as it was when we decided: another owner may have taken it since.
          if [[ -n "\$lock_pid" && "\$(cat "\$lock/run" 2>/dev/null || true)" == host-tests \
                && "\$(cat "\$lock/pid" 2>/dev/null || true)" == "\$lock_pid" ]]; then
            rm -rf "\$lock"
          fi
          continue
        fi
        sleep 0.2
        continue
      fi
    fi
    (( EPOCHREALTIME - started < 120 )) || die "timed out waiting for \$lock. If no sandbox-up is running, sandbox-down.sh <run-id> removes a clone left by a dropped session."
    oldpid="\$(cat "\$lock/pid" 2>/dev/null || true)"
    # Empty means the owner is between mkdir and the pid write. Do not steal it.
    if [[ -z "\$oldpid" ]]; then
      sleep 1
      continue
    fi
    if ! kill -0 "\$oldpid" 2>/dev/null; then
      rm -rf "\$lock"
      continue
    fi
    sleep 1
  done
}
log="\$root/runs/\$run_id/tart.log"
pidfile="\$root/runs/\$run_id/tart.pid"
failed=1
cleanup() {
  release_lock
  [[ "\$failed" == 1 ]] || return 0
  print -u2 -- "sandbox: bringing the failed clone down"
  if [[ -f "\$pidfile" ]]; then
    kill "\$(cat "\$pidfile")" 2>/dev/null || true
  fi
  "\$tart" stop "\$vm" >/dev/null 2>&1 || true
  "\$tart" delete "\$vm" >/dev/null 2>&1 || true
  rm -rf "\$root/apps/\$run_id"
  rm -f "\$(meta_path "\$run_id")"
  if [[ -f "\$log" ]]; then
    print -u2 -- "sandbox: last lines of \$log"
    tail -n 40 "\$log" >&2 || true
  fi
}
trap 'failed=1; exit 1' INT HUP TERM
trap cleanup EXIT
request_lane_yield
acquire_lock
require_stopped_golden "\$golden"
require_stopped_golden "\$golden_b"
[[ "\$image" == "\$golden" ]] || require_stopped_golden "\$image"
[[ "\$image_b" == "\$golden_b" ]] || require_stopped_golden "\$image_b"
existing="\$(vm_field "\$vm" || true)"
if [[ -n "\$existing" ]]; then
  # This VM is already live. failed=0 keeps cleanup from stopping it or removing its app.
  failed=0
  die "\$vm already exists (\$existing). Run sandbox-down.sh \$run_id first."
fi
finish_lane_preemption
n="\$(running_count)"
if (( n >= 2 )); then
  die "two guests are already running. macOS allows two. Refusing to start a third."
fi
if (( n >= 1 && allow_second != 1 )); then
  die "a guest is already running. Pass --allow-second to start another, or stop the one that is up."
fi
mkdir -p "\$root/runs/\$run_id" "\$root/out/\$run_id"
# Two golden images, each with its own serial and Setup Assistant already done
# under it. A clone keeps its golden's serial, so pick the golden no running
# guest came from: two running guests never share a machine identifier and
# neither shows Setup Assistant. The choice is recorded under the clone lock,
# before boot, so a concurrent sandbox-up sees it. A guest with no record
# predates the second golden and is counted against the first.
golden_in_use() {
  local want="\$1" line name used
  while IFS= read -r line; do
    [[ -z "\$line" || "\$line" == Source* ]] && continue
    local -a f
    f=("\${(z)line}")
    name="\${f[2]:-}"
    [[ "\${f[-1]}" != stopped ]] || continue
    # A host-test lane guest (c11-ht-*) always clones the first golden.
    if [[ "\$name" == c11-ht-* ]]; then
      [[ "\$golden" == "\$want" ]] && return 0
      continue
    fi
    [[ "\$name" == c11-sb-* ]] || continue
    used="\$(cat "\$root/runs/\${name#c11-sb-}/golden" 2>/dev/null || print -r -- "\$golden")"
    [[ "\$used" == "\$want" ]] && return 0
  done < <("\$tart" list)
  return 1
}
source_golden="\$golden"
if golden_in_use "\$golden"; then
  golden_in_use "\$golden_b" && die "both golden images are already in use; no serial-safe source is available"
  source_golden="\$golden_b"
fi
# The slot decides the serial; the image is that slot's clone source.
source_image="\$image"
[[ "\$source_golden" == "\$golden" ]] || source_image="\$image_b"
print -r -- "\$source_golden" > "\$root/runs/\$run_id/golden"
print -r -- "\$source_image" > "\$root/runs/\$run_id/image"
clone_start="\$EPOCHSECONDS"
"\$tart" clone "\$source_image" "\$vm"
clone_secs=\$((EPOCHSECONDS - clone_start))
"\$tart" set "\$vm" --cpu 4 --memory 8192 --display 1440x900 --random-mac
# setsid, then drop the ssh session's stdin and stdout, so tart outlives this script.
/usr/bin/python3 -c 'import os,sys
tart, log, vm, directory = sys.argv[1:5]
os.setsid()
fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.dup2(fd, 1)
os.dup2(fd, 2)
os.close(fd)
null = os.open(os.devnull, os.O_RDONLY)
os.dup2(null, 0)
os.close(null)
os.execv(tart, [tart, "run", "--no-graphics", "--no-audio", "--no-clipboard", "--dir", directory, vm])
' "\$tart" "\$log" "\$vm" "out:\${root}/out/\${run_id}" &
print -r -- \$! > "\$pidfile"
disown 2>/dev/null || true
seen=0
visible_deadline=\$((SECONDS + 30))
while (( SECONDS < visible_deadline )); do
  state="\$(vm_field "\$vm" || true)"
  if [[ -n "\$state" && "\$state" != stopped ]]; then
    seen=1
    break
  fi
  sleep 0.5
done
(( seen )) || die "tart run did not leave \$vm unstopped"
release_lock
boot_start="\$EPOCHSECONDS"
ip=""
deadline=\$((SECONDS + 360))
while (( SECONDS < deadline )); do
  if ! kill -0 "\$(cat "\$pidfile")" 2>/dev/null; then
    die "tart run exited before \$vm got an IP"
  fi
  ip="\$("\$tart" ip "\$vm" --wait 3 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  [[ -n "\$ip" ]] && break
done
[[ -n "\$ip" ]] || die "timed out waiting for an IP for \$vm"
ssh_ok=0
ssh_deadline=\$((SECONDS + 180))
while (( SECONDS < ssh_deadline )); do
  if print -r -- 'print -r -- ok' | guest_ssh "\$ip" | grep -q '^ok$'; then
    ssh_ok=1
    break
  fi
  sleep 3
done
[[ "\$ssh_ok" == 1 ]] || die "SSH to \$guest_user@\$ip did not accept the sandbox key"
guest_app_dir="/Users/\${guest_user}/c11-sandbox/apps/\${run_id}"
COPYFILE_DISABLE=1 /usr/bin/tar -C "\$root/apps/\$run_id" -cf - . | guest_receive_tar "\$ip" "\$guest_app_dir"
guest_out="\$(
  {
    printf 'SANDBOX_RUN_ID=%q\n' "\$run_id"
    print -r -- '${guest_b64}' | /usr/bin/base64 -D
  } | guest_ssh "\$ip"
)" || die "guest launch failed"
guest_out="\$(print -r -- "\$guest_out" | grep -E '^(GUEST_APP|SOCKET|CLI|LOG|STDOUT|DSOCK)=' || true)"
[[ -n "\$guest_out" ]] || die "guest launch did not report an app and socket"
eval "\$guest_out"
[[ -n "\${SOCKET:-}" && -n "\${GUEST_APP:-}" ]] || die "guest launch did not report an app and socket"
boot_secs=\$((EPOCHSECONDS - boot_start))
write_meta "\$(meta_path "\$run_id")" \
  "VM=\$vm" \
  "IP=\$ip" \
  "GUEST_APP=\${GUEST_APP:-}" \
  "SOCKET=\${SOCKET:-}" \
  "CLI=\${CLI:-}" \
  "LOG=\${LOG:-}" \
  "STDOUT=\${STDOUT:-}" \
  "DSOCK=\${DSOCK:-}" \
  "CLONE_SECS=\$clone_secs" \
  "BOOT_SECS=\$boot_secs" \
  "APP_SOURCE=\$app_source" \
  "GOLDEN=\$source_golden" \
  "IMAGE=\$source_image"
failed=0
printf 'run_id=%s\n' "\$run_id"
printf 'vm=%s\n' "\$vm"
printf 'golden=%s\n' "\$source_golden"
printf 'image=%s\n' "\$source_image"
printf 'guest_ip=%s\n' "\$ip"
printf 'guest_app=%s\n' "\${GUEST_APP:-}"
printf 'socket=%s\n' "\${SOCKET:-}"
printf 'cli=%s\n' "\${CLI:-}"
printf 'clone_secs=%s\n' "\$clone_secs"
printf 'boot_secs=%s\n' "\$boot_secs"
EOF

# From here the clone is up and staging may write credentials into it. Until staging
# succeeds, any failure or signal tears the clone down, and a failed teardown says so.
agents_teardown() {
  trap - INT TERM HUP
  echo "sandbox: $1; removing the clone" >&2
  if ! "$SCRIPT_DIR/sandbox-down.sh" "$run_id" >&2; then
    echo "sandbox: TEARDOWN FAILED for ${run_id}. The clone may still be running with staged credentials. Run scripts/sandbox-down.sh ${run_id} until it reports deleted=." >&2
    exit 2
  fi
  exit 1
}
stage_pid=""
stop_stage() {
  # The staging child and its direct children (the host ssh); the clone delete ends the rest.
  [[ -n "$stage_pid" ]] || return 0
  pkill -TERM -P "$stage_pid" 2>/dev/null || true
  kill -TERM "$stage_pid" 2>/dev/null || true
  wait "$stage_pid" 2>/dev/null || true
}
if [[ -n "$agents" ]]; then
  # Armed before the child starts. The child runs in the background and is waited
  # on, so a signal reaches the trap at once instead of after staging finishes.
  trap 'stop_stage; agents_teardown "interrupted while staging agents"' INT TERM HUP
  "$SCRIPT_DIR/sandbox-agent.sh" "$run_id" stage "$agents" &
  stage_pid=$!
  if ! wait "$stage_pid"; then
    agents_teardown "staging agents ($agents) failed"
  fi
  trap - INT TERM HUP
fi
