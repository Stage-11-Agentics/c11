#!/usr/bin/env bash
# Run a command in the guest Aqua session (launchctl asuser). Exit status is the remote status.
# Usage: scripts/sandbox-exec.sh <run-id> <command> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-exec.sh <run-id> <command> [args...]

The command runs in the guest's Aqua session, so cliclick, osascript, and
screencapture hit the guest display. A pipeline has to be wrapped:
  scripts/sandbox-exec.sh <run-id> zsh -c 'cmd | other'
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -ge 2 ]] || { usage >&2; exit 1; }
run_id="$1"
shift
sandbox_validate_run_id "$run_id"
argv_b64="$(printf '%s\0' "$@" | base64 | tr -d '\n')"

sandbox_guest_script "$run_id" <<EOF
set -eu
setopt pipefail
command -v python3 >/dev/null || { print -u2 -- "python3 is missing in the guest"; exit 1 }
export SANDBOX_ARGV_B64='${argv_b64}'
/usr/bin/python3 - <<'PY'
import base64, os, sys
raw = base64.b64decode(os.environ["SANDBOX_ARGV_B64"])
args = [part.decode() for part in raw.split(b"\0") if part]
if not args:
    sys.exit("sandbox-exec: empty command")
uid = str(os.getuid())
home = os.environ.get("HOME", "")
user = os.environ.get("USER") or "admin"
env = [
    "HOME=" + home,
    "USER=" + user,
    "LOGNAME=" + user,
    "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "TMPDIR=" + os.environ.get("TMPDIR", "/tmp"),
]
# asuser keeps root's uid. Drop to the console user so the command is not root.
os.execvp(
    "/usr/bin/sudo",
    [
        "sudo", "-n", "/bin/launchctl", "asuser", uid,
        "/usr/bin/sudo", "-n", "-u", user,
        "/usr/bin/env", *env, *args,
    ],
)
PY
EOF
