#!/usr/bin/env bash
# Clone the golden Tart image on the sandbox host, boot it headless, and launch a c11 .app inside it.
# Usage: scripts/sandbox-up.sh <run-id> <path-to.app> [--allow-second]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-up.sh <run-id> <path-to.app> [--allow-second]

Clone c11-sandbox-golden on C11_SANDBOX_HOST (default: atlas), boot that
clone headless, copy the .app in, and launch it with the automation socket.
The golden image is never booted. A second running guest needs --allow-second.
Two running guests is always refused.
EOF
}

run_id=""
app=""
allow_second=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --allow-second) allow_second=1; shift ;;
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
[[ -n "$run_id" && -n "$app" ]] || { usage >&2; exit 1; }
sandbox_validate_run_id "$run_id"
[[ -d "$app" ]] || sandbox_die "app not found: $app"
[[ "$app" == *.app ]] || sandbox_die "expected a .app bundle: $app"
[[ -f "$app/Contents/Info.plist" ]] || sandbox_die "not an app bundle: $app"

app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
app_base="$(basename "$app")"
rel=".c11-sandbox/apps/${run_id}"

ssh_host="$(sandbox_host_name)"
if [[ "$ssh_host" != "local" ]]; then
  ssh -o BatchMode=yes -o ConnectTimeout=25 -o LogLevel=ERROR "$ssh_host" \
    "rm -rf \"\$HOME/${rel}\" && mkdir -p \"\$HOME/${rel}\""
else
  rm -rf "${HOME:?}/${rel}"
  mkdir -p "${HOME}/${rel}"
fi
COPYFILE_DISABLE=1 tar -C "$(dirname "$app")" -cf - "$app_base" | sandbox_extract_tar "$rel"

guest_b64="$(
  {
    sandbox_guest_runtime_zsh
    cat <<'GUEST'
set -eu
setopt pipefail
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
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
tart="\$(tart_bin)" || die "tart is not installed on this host"
golden_state="\$(vm_field "\$golden" || true)"
[[ -n "\$golden_state" ]] || die "golden image \$golden is not on this host. See docs/c11-sandbox-research.md"
[[ "\$golden_state" == stopped ]] || die "golden image \$golden is \$golden_state. It must stay stopped. Runs clone it; they do not boot it."
[[ -f "\$key" ]] || die "missing \$key on the Tart host. Golden-image setup installs this key."
existing="\$(vm_field "\$vm" || true)"
[[ -z "\$existing" ]] || die "\$vm already exists (\$existing). Run sandbox-down.sh \$run_id first."
n="\$(running_count)"
if (( n >= 2 )); then
  die "two guests are already running. macOS allows two. Refusing to start a third."
fi
if (( n >= 1 && allow_second != 1 )); then
  die "a guest is already running. Pass --allow-second to start another, or stop the one that is up."
fi
mkdir -p "\$root/runs/\$run_id" "\$root/out/\$run_id"
log="\$root/runs/\$run_id/tart.log"
pidfile="\$root/runs/\$run_id/tart.pid"
failed=1
cleanup() {
  [[ "\$failed" == 1 ]] || return 0
  print -u2 -- "sandbox: bringing the failed clone down"
  if [[ -f "\$pidfile" ]]; then
    kill "\$(cat "\$pidfile")" 2>/dev/null || true
  fi
  "\$tart" stop "\$vm" >/dev/null 2>&1 || true
  "\$tart" delete "\$vm" >/dev/null 2>&1 || true
  if [[ -f "\$log" ]]; then
    print -u2 -- "sandbox: last lines of \$log"
    tail -n 40 "\$log" >&2 || true
  fi
}
trap cleanup EXIT
clone_start="\$EPOCHSECONDS"
"\$tart" clone "\$golden" "\$vm"
clone_secs=\$((EPOCHSECONDS - clone_start))
"\$tart" set "\$vm" --cpu 4 --memory 8192 --display 1440x900 --random-mac --random-serial
nohup "\$tart" run --no-graphics --no-audio --no-clipboard \
  --dir "out:\${root}/out/\${run_id}" \
  "\$vm" >"\$log" 2>&1 &
print -r -- \$! > "\$pidfile"
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
  "BOOT_SECS=\$boot_secs"
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
