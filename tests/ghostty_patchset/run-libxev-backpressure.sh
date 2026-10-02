#!/usr/bin/env bash
# Baseline: the exact libxev package pinned by C11-294's starting Ghostty SHA.
# --race adds a competing PTY writer, which forces advisory-readiness races but
# is deliberately NOT presented as a normal Ghostty workload.
set -euo pipefail
probe_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$probe_dir/../.." && pwd)"
xev_source="${C11_PROBE_LIBXEV_SOURCE:-$HOME/.cache/zig/p/libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs/src/main.zig}"
if [[ ! -f "$xev_source" ]]; then
    echo "Pinned libxev source unavailable; set C11_PROBE_LIBXEV_SOURCE explicitly." >&2
    exit 2
fi
exec "$repo_dir/scripts/with-build-lock.sh" zig run -lc \
    --dep xev "-Mroot=$probe_dir/libxev_backpressure.zig" \
    "-Mxev=$xev_source" -- "$@"
