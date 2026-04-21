#!/usr/bin/env bash
set -euo pipefail

SURFACE="${1:-surface:1}"
STATE_FILE="${2:-./auth-state.json}"
DASHBOARD_URL="${3:-https://app.example.com/dashboard}"

if [ -f "$STATE_FILE" ]; then
  c11 browser "$SURFACE" state load "$STATE_FILE"
fi

c11 browser "$SURFACE" goto "$DASHBOARD_URL"
c11 browser "$SURFACE" get url
c11 browser "$SURFACE" wait --load-state complete --timeout-ms 15000
c11 browser "$SURFACE" snapshot --interactive

echo "If redirected to login, complete login flow then run:"
echo "  c11 browser $SURFACE state save $STATE_FILE"
