#!/usr/bin/env bash
# Clone the golden Tart image on the sandbox host, boot it headless, and launch a c11 .app inside it.
# Usage: scripts/sandbox-up.sh <run-id> <path-to.app> [--allow-second] [--agents claude,codex,grok]
#        scripts/sandbox-up.sh <run-id> --app-source <name> [--allow-second] [--agents ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-up.sh <run-id> <path-to.app> [--allow-second] [--agents claude,codex,grok]
       scripts/sandbox-up.sh <run-id> --app-source <name> [--allow-second] [--agents ...]

Clone c11-sandbox-golden on C11_SANDBOX_HOST (default: atlas), boot that
clone headless, place one .app on the Tart host, copy it into the guest,
and launch it with the automation socket. The golden image is never booted.
A second running guest needs --allow-second and is the only clone that gets
a new serial. Two running guests is always refused. If this command is cut
off, scripts/sandbox-down.sh <run-id> removes the clone.

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
  ssh_host="$(sandbox_host_name)"
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
  [[ "$agents" =~ ^(claude|codex|grok)(,(claude|codex|grok))*$ ]] || sandbox_die "--agents takes a comma-separated list of claude, codex, grok"
fi
rel=".c11-sandbox/apps/${run_id}"

# The case is the seam. Add a source by staging one .app into $rel on the
# Tart host. Do not teach the boot path about the source.
case "$app_source" in
  local-app)
    [[ -n "$app" ]] || { usage >&2; exit 1; }
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
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
tart="\$(tart_bin)" || die "tart is not installed on this host"
golden_state="\$(vm_field "\$golden" || true)"
[[ -n "\$golden_state" ]] || die "golden image \$golden is not on this host. See docs/c11-sandbox-research.md"
[[ "\$golden_state" == stopped ]] || die "golden image \$golden is \$golden_state. It must stay stopped. Runs clone it; they do not boot it."
[[ -f "\$key" ]] || die "missing \$key on the Tart host. Golden-image setup installs this key."
lock="\$root/clone.lock"
lock_held=0
release_lock() {
  (( lock_held )) || return 0
  rm -rf "\$lock"
  lock_held=0
}
acquire_lock() {
  local i oldpid
  for i in {1..120}; do
    if mkdir "\$lock" 2>/dev/null; then
      print -r -- \$\$ > "\$lock/pid"
      print -r -- "\$run_id" > "\$lock/run"
      lock_held=1
      return 0
    fi
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
  die "timed out waiting for \$lock. If no sandbox-up is running, sandbox-down.sh <run-id> removes a clone left by a dropped session."
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
acquire_lock
existing="\$(vm_field "\$vm" || true)"
if [[ -n "\$existing" ]]; then
  # This VM is already live. failed=0 keeps cleanup from stopping it or removing its app.
  failed=0
  die "\$vm already exists (\$existing). Run sandbox-down.sh \$run_id first."
fi
n="\$(running_count)"
if (( n >= 2 )); then
  die "two guests are already running. macOS allows two. Refusing to start a third."
fi
if (( n >= 1 && allow_second != 1 )); then
  die "a guest is already running. Pass --allow-second to start another, or stop the one that is up."
fi
mkdir -p "\$root/runs/\$run_id" "\$root/out/\$run_id"
clone_start="\$EPOCHSECONDS"
"\$tart" clone "\$golden" "\$vm"
clone_secs=\$((EPOCHSECONDS - clone_start))
# A single clone keeps the golden serial, so Setup Assistant stays done.
# A second concurrent guest must not share that serial.
if (( n >= 1 )); then
  "\$tart" set "\$vm" --cpu 4 --memory 8192 --display 1440x900 --random-mac --random-serial
else
  "\$tart" set "\$vm" --cpu 4 --memory 8192 --display 1440x900 --random-mac
fi
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
  "APP_SOURCE=\$app_source"
failed=0
printf 'run_id=%s\n' "\$run_id"
printf 'vm=%s\n' "\$vm"
printf 'guest_ip=%s\n' "\$ip"
printf 'guest_app=%s\n' "\${GUEST_APP:-}"
printf 'socket=%s\n' "\${SOCKET:-}"
printf 'cli=%s\n' "\${CLI:-}"
printf 'clone_secs=%s\n' "\$clone_secs"
printf 'boot_secs=%s\n' "\$boot_secs"
EOF

if [[ -n "$agents" ]]; then
  if ! "$SCRIPT_DIR/sandbox-agent.sh" "$run_id" stage "$agents"; then
    echo "sandbox: staging agents ($agents) failed; removing the clone" >&2
    "$SCRIPT_DIR/sandbox-down.sh" "$run_id" >&2 || true
    exit 1
  fi
fi
