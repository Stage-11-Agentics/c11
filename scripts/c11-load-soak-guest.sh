#!/usr/bin/env bash
# Run scripts/c11-load-soak.py inside a sandbox guest started by sandbox-up.sh.
# Usage: scripts/c11-load-soak-guest.sh <run-id> <label> [--env KEY=VALUE]... [-- <soak args>]
#
# In the guest: turns hc shards on for the app's own defaults domain, relaunches
# the guest app (sandbox_quit_app is path-scoped to that bundle), runs the soak
# and copies its JSON and samples to the run's shared folder. Prints the JSON row.
# The row and samples land on the Tart host in ~/.c11-sandbox/out/<run-id>/soak/
# and locally in build-remote/soak/<run-id>/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

run_id="${1:?usage: c11-load-soak-guest.sh <run-id> <label> [--env K=V]... [-- soak args]}"
label="${2:?label}"
shift 2
extra_env=()
soak_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ "${2:-}" == *=* ]] || sandbox_die "--env needs KEY=VALUE"; extra_env+=("$2"); shift 2 ;;
    --) shift; soak_args=("$@"); break ;;
    *) sandbox_die "unknown option: $1" ;;
  esac
done
sandbox_validate_token label "$label" '^[A-Za-z0-9._-]+$'

rel_out=".c11-sandbox/out/${run_id}/soak"
ssh_host="$(sandbox_host_name)" || exit 2

# The Tart host must be quiet too: a guest shares its cores (one-minute load under
# C11_SOAK_MAX_HOST_LOAD, default 10; waits up to 20 minutes).
host_load() {
  if [[ "$ssh_host" != "local" ]]; then
    ssh -o BatchMode=yes -o LogLevel=ERROR "$ssh_host" "sysctl -n vm.loadavg" | awk '{print $2}'
  else
    sysctl -n vm.loadavg | awk '{print $2}'
  fi
}
max_host_load="${C11_SOAK_MAX_HOST_LOAD:-10}"
deadline=$((SECONDS + 1200))
while :; do
  load="$(host_load)"
  awk -v l="$load" -v m="$max_host_load" 'BEGIN { exit !(l < m) }' && break
  (( SECONDS < deadline )) || sandbox_die "host load $load stayed at or above $max_host_load"
  echo "host load $load >= $max_host_load; waiting" >&2
  sleep 30
done
echo "host_load_at_start=$load"
if [[ "$ssh_host" != "local" ]]; then
  ssh -o BatchMode=yes -o ConnectTimeout=25 -o LogLevel=ERROR "$ssh_host" "mkdir -p \"\$HOME/${rel_out}\""
else
  mkdir -p "${HOME}/${rel_out}"
fi
# The script travels inline: a file just written to the share can read stale or short in the guest.
script_b64="$(base64 < "$REPO_ROOT/scripts/c11-load-soak.py" | tr -d '\n')"

env_b64="$(printf '%s\0' "${extra_env[@]+"${extra_env[@]}"}" | base64 | tr -d '\n')"
args_b64="$(printf '%s\0' "${soak_args[@]+"${soak_args[@]}"}" | base64 | tr -d '\n')"

guest_rc=0
sandbox_guest_script "$run_id" <<EOF || guest_rc=$?
set -eu
setopt pipefail
$(sandbox_guest_runtime_zsh)
share="/Volumes/My Shared Files/out/soak"
mkdir -p "\$share"
work="\$HOME/c11-sandbox/soak-${label}"
rm -rf "\$work"; mkdir -p "\$work"
print -rn -- '${script_b64}' | /usr/bin/base64 -D > "\$work/c11-load-soak.py"
bundle_id="\$(/usr/bin/defaults read "\$SANDBOX_GUEST_APP/Contents/Info" CFBundleIdentifier)"
/usr/bin/defaults write "\$bundle_id" c11.shards.enabled -bool true
extra=()
while IFS= read -r -d '' kv; do [[ -n "\$kv" ]] && extra+=("\$kv"); done < <(print -rn -- '${env_b64}' | /usr/bin/base64 -D)
soak_args=()
while IFS= read -r -d '' a; do [[ -n "\$a" ]] && soak_args+=("\$a"); done < <(print -rn -- '${args_b64}' | /usr/bin/base64 -D)
sandbox_quit_app
/bin/rm -f /tmp/c11-graph-churn.log /tmp/c11-portal.log
app="\$SANDBOX_GUEST_APP"; socket="\$SANDBOX_SOCKET"
/usr/bin/sudo -n /bin/rm -f "\$socket" "\$SANDBOX_DSOCK"
uid="\$(id -u)"; user="\$(id -un)"
/usr/bin/sudo -n /bin/launchctl asuser "\$uid" \
  /usr/bin/sudo -n -u "\$user" /usr/bin/env -i \
  HOME="\$HOME" USER="\$user" LOGNAME="\$user" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" TMPDIR="\${TMPDIR:-/tmp}" \
  C11_SOCKET_MODE=automation C11_ALLOW_SOCKET_OVERRIDE=1 \
  C11_SOCKET="\$socket" C11_SOCKET_PATH="\$socket" CMUXD_UNIX_PATH="\$SANDBOX_DSOCK" \
  C11_HANG_LOG="\$work/hang.log" C11_QA_LAUNCH=fresh "\${extra[@]}" \
  /bin/zsh -c 'nohup "\$1" > "\$2" 2>&1 & echo \$!' _ "\$app/Contents/MacOS/c11" "\$SANDBOX_STDOUT" >/dev/null
for i in {1..90}; do [[ -S "\$socket" ]] && break; sleep 1; done
[[ -S "\$socket" ]] || { print -u2 -- "socket did not appear"; exit 1 }
sleep 5
soak_rc=0
/usr/bin/python3 "\$work/c11-load-soak.py" --cli "\$SANDBOX_CLI" --socket "\$socket" --label "${label}" \
  --out "\$work" --hang-log "\$work/hang.log" "\${soak_args[@]}" || soak_rc=\$?
for f in "\$work"/soak-*.json(N) "\$work"/sample-*.txt(N); do cp "\$f" "\$share/"; done
[[ -f /tmp/c11-graph-churn.log ]] && cp /tmp/c11-graph-churn.log "\$share/graph-churn-${label}.log" || true
[[ -f "\$SANDBOX_STDOUT" ]] && tail -c 4000000 "\$SANDBOX_STDOUT" > "\$share/app-stdout-${label}.log" || true
for r in "\$HOME"/Library/Logs/DiagnosticReports/c11*.ips(N); do cp "\$r" "\$share/" || true; done
[[ -d "\$work/shots" ]] && mkdir -p "\$share/shots-${label}" && cp "\$work"/shots/*.png "\$share/shots-${label}/" 2>/dev/null || true
[[ -f /tmp/c11-portal.log ]] && cp /tmp/c11-portal.log "\$share/portal-${label}.log" || true
[[ -f "\$work/hang.log" ]] && cp "\$work/hang.log" "\$share/hang-${label}.log" || true
print -- "soak_rc=\$soak_rc"
exit \$soak_rc
EOF

mkdir -p "$REPO_ROOT/build-remote/soak/$run_id"
if [[ "$ssh_host" != "local" ]]; then
  ssh -o BatchMode=yes -o LogLevel=ERROR "$ssh_host" "tar -C \"\$HOME/${rel_out}\" -cf - ." \
    | tar -C "$REPO_ROOT/build-remote/soak/$run_id" -xf -
fi
# The soak's own result, after its outputs are copied back.
exit "$guest_rc"
