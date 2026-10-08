#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://example.com/form}"
PANEL="${2:-panel:1}"

c11 browser "$PANEL" goto "$URL"
c11 browser "$PANEL" get url
c11 browser "$PANEL" wait --load-state complete --timeout-ms 15000
c11 browser "$PANEL" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
