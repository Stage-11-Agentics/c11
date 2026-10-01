#!/usr/bin/env bash
# Stop and delete the clone for a run. Refuses to delete the golden image or scanner VMs.
# Usage: scripts/sandbox-down.sh <run-id>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-down.sh <run-id>

Stop c11-sb-<run-id>, delete that clone, and remove the copied .app.
Screenshots and test logs under the host's .c11-sandbox/out/<run-id> stay.
This is also the recovery when sandbox-up is cut off and its cleanup does not run.
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 1; }
run_id="$1"
sandbox_validate_run_id "$run_id"

sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
run_id=$(printf '%q' "$run_id")
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
tart="\$(tart_bin)" || die "tart is not installed on this host"
state="\$(vm_field "\$vm" || true)"
if [[ -n "\$state" ]]; then
  if [[ "\$state" == running ]]; then
    "\$tart" stop "\$vm"
    deadline=\$((SECONDS + 120))
    while (( SECONDS < deadline )); do
      state="\$(vm_field "\$vm" || true)"
      [[ "\$state" != running ]] && break
      sleep 2
    done
    state="\$(vm_field "\$vm" || true)"
    if [[ "\$state" == running ]]; then
      die "\$vm is still running after tart stop. The macOS guest slot may be stuck. Do not reboot the host from this script."
    fi
  fi
  "\$tart" delete "\$vm"
fi
rm -rf "\$root/apps/\$run_id"
rm -f "\$(meta_path "\$run_id")"
lock="\$root/clone.lock"
if [[ -d "\$lock" ]]; then
  owner="\$(cat "\$lock/run" 2>/dev/null || true)"
  oldpid="\$(cat "\$lock/pid" 2>/dev/null || true)"
  if [[ "\$owner" == "\$run_id" ]] || [[ -z "\$oldpid" ]] || ! kill -0 "\$oldpid" 2>/dev/null; then
    rm -rf "\$lock"
  fi
fi
printf 'deleted=%s\n' "\$vm"
EOF
