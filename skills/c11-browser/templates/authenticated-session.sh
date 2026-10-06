#!/usr/bin/env bash
set -euo pipefail

PANEL="${1:-panel:1}"
STATE_FILE="${2:-./auth-state.json}"
DASHBOARD_URL="${3:-https://app.example.com/dashboard}"

if [ -f "$STATE_FILE" ]; then
  c11 browser "$PANEL" state load "$STATE_FILE"
fi

c11 browser "$PANEL" goto "$DASHBOARD_URL"
c11 browser "$PANEL" get url
c11 browser "$PANEL" wait --load-state complete --timeout-ms 15000
c11 browser "$PANEL" snapshot --interactive

echo "If redirected to login, complete login flow then run:"
echo "  c11 browser $PANEL state save $STATE_FILE"
