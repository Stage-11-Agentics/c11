#!/usr/bin/env bash
set -euo pipefail

PANEL="${1:-panel:1}"
OUT_DIR="${2:-./browser-artifacts}"
mkdir -p "$OUT_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
c11 browser "$PANEL" snapshot --interactive > "$OUT_DIR/snapshot-$TS.txt"
c11 browser "$PANEL" screenshot --out "$OUT_DIR/screenshot-$TS.png"

echo "Wrote: $OUT_DIR/snapshot-$TS.txt"
echo "Wrote: $OUT_DIR/screenshot-$TS.png"
