#!/bin/zsh
# Run one phase of the crash-resume e2e driver (guest.py) inside a sandbox guest.
# Usage, on the Tart host (Atlas) from a c11 checkout or build source:
#   C11_SANDBOX_HOST=local scripts/sandbox-resume-e2e/run.sh <run-id> <phase> [key=value ...]
# Phases and keys: see guest.py. The guest needs a c11 app from scripts/sandbox-up.sh.
set -eu
run_id=$1; shift
here=${0:A:h}
b64=$(base64 < "$here/guest.py" | tr -d '\n')
cd "$here/../.."
export PATH=/opt/homebrew/bin:$PATH
exec scripts/sandbox-exec.sh "$run_id" /bin/zsh -c 'print -r -- "$1" | /usr/bin/base64 -D > /tmp/c11-resume-e2e.py; shift; exec /usr/bin/python3 -u /tmp/c11-resume-e2e.py "$@"' _ "$b64" "$@"
