#!/usr/bin/env bash
# Build on the build host (--host, else C11_REMOTE_HOST: scripts/dev-hosts.sh) from this worktree;
# return attributable artifacts without a local build.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
# c11 (C11H-130): main stays shareable with a friend. The check takes under a second, runs
# before arguments are read and blocks the build on a finding (Atin, 2026-11-03).
# scripts/shareable-gate.sh explains the logged override for a known false alarm.
# A missing gate blocks too.
bash "$SCRIPTS/shareable-gate.sh" remote-build "$SCRIPTS/.." || exit 1
exec python3 "$SCRIPTS/remote_build.py" "$@"
