#!/usr/bin/env bash
# Screenshot the guest Aqua session and copy the PNG back to this machine.
# Usage: scripts/sandbox-shot.sh <run-id> <host-png> [screencapture args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-shot.sh <run-id> <host-png> [screencapture args...]

Default capture is the guest's main display, with no shutter sound (-x).
Pass extra screencapture arguments, such as -l <windowid>, to narrow it.
The PNG is written on the Tart host and copied to <host-png>.
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -ge 2 ]] || { usage >&2; exit 1; }
run_id="$1"
dest="$2"
shift 2
sandbox_validate_run_id "$run_id"
shot_name="shot-$(date +%Y%m%d%H%M%S)-$$.png"
if [[ $# -gt 0 ]]; then
  argv_b64="$(printf '%s\0' screencapture "$@" "$shot_name" | base64 | tr -d '\n')"
else
  argv_b64="$(printf '%s\0' screencapture -x "$shot_name" | base64 | tr -d '\n')"
fi

sandbox_guest_script "$run_id" <<EOF
set -eu
setopt pipefail
export SANDBOX_ARGV_B64='${argv_b64}'
export SANDBOX_SHOT_NAME=$(printf '%q' "$shot_name")
/usr/bin/python3 - <<'PY'
import base64, os, subprocess, sys
raw = base64.b64decode(os.environ["SANDBOX_ARGV_B64"])
args = [part.decode() for part in raw.split(b"\0") if part]
name = os.environ["SANDBOX_SHOT_NAME"]
out_dir = "/Volumes/My Shared Files/out"
dest = os.path.join(out_dir, name)
if not os.path.isdir(out_dir):
    sys.exit("virtiofs out share is not mounted at " + out_dir)
# The last argv slot is the file name. Put it in the shared directory.
args[-1] = dest
uid = str(os.getuid())
home = os.environ.get("HOME", "")
user = os.environ.get("USER") or "admin"
env = [
    "HOME=" + home,
    "USER=" + user,
    "LOGNAME=" + user,
    "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
]
# asuser keeps root's uid. Drop to the console user so the capture is not root.
cmd = [
    "sudo", "-n", "/bin/launchctl", "asuser", uid,
    "/usr/bin/sudo", "-n", "-u", user,
    "/usr/bin/env", *env, *args,
]
raise SystemExit(subprocess.call(cmd))
PY
EOF

sandbox_fetch ".c11-sandbox/out/${run_id}/${shot_name}" "$dest"
printf 'screenshot=%s\n' "$dest"
