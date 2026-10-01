#!/usr/bin/env bash
set -euo pipefail

TAB="${1:-tab:1}"
STATE_FILE="${2:-./auth-state.json}"
DASHBOARD_URL="${3:-https://app.example.com/dashboard}"

if [ -f "$STATE_FILE" ]; then
  c11 browser "$TAB" state load "$STATE_FILE"
fi

c11 browser "$TAB" goto "$DASHBOARD_URL"
c11 browser "$TAB" get url
c11 browser "$TAB" wait --load-state complete --timeout-ms 15000
c11 browser "$TAB" snapshot --interactive

echo "If redirected to login, complete login flow then run:"
echo "  c11 browser $TAB state save $STATE_FILE"
