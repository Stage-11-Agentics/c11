#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://example.com/form}"
SURFACE="${2:-surface:1}"

c11 browser "$SURFACE" goto "$URL"
c11 browser "$SURFACE" get url
c11 browser "$SURFACE" wait --load-state complete --timeout-ms 15000
c11 browser "$SURFACE" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
