#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://example.com/form}"
TAB="${2:-tab:1}"

c11 browser "$TAB" goto "$URL"
c11 browser "$TAB" get url
c11 browser "$TAB" wait --load-state complete --timeout-ms 15000
c11 browser "$TAB" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
