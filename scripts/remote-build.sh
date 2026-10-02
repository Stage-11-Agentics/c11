#!/usr/bin/env bash
# Build on Atlas from this worktree; return attributable artifacts without a local build.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/remote_build.py" "$@"
