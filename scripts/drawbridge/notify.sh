#!/usr/bin/env bash
# Drawbridge notifier (lane 4) — posts a message to the maintainer's channels.
#
# Channels are configured in TRIAGE_POLICY.md's machine config block. Currently:
# Zulip only. Add a channel by extending this script and documenting it in the
# policy file.
#
# Usage: notify.sh <policy-file> <content-file>
# Env:   ZULIP_BOT_API_KEY (required; from forge secret storage — never a file)
set -euo pipefail

POLICY_FILE="${1:?usage: notify.sh <policy-file> <content-file>}"
CONTENT_FILE="${2:?usage: notify.sh <policy-file> <content-file>}"
: "${ZULIP_BOT_API_KEY:?ZULIP_BOT_API_KEY is required}"

# Single source of truth for policy parsing: gates.py owns the config block.
zulip="$(python3 "$(dirname "$0")/gates.py" --emit-config-key zulip --policy "$POLICY_FILE")"
SITE="$(jq -r '.site' <<<"$zulip")"
CHANNEL="$(jq -r '.channel' <<<"$zulip")"
TOPIC="$(jq -r '.topic' <<<"$zulip")"
BOT_EMAIL="$(jq -r '.bot_email' <<<"$zulip")"

# Zulip caps messages at 10000 chars; truncate defensively.
content="$(head -c 9000 "$CONTENT_FILE")"

response="$(curl -sS -X POST "$SITE/api/v1/messages" \
  -u "$BOT_EMAIL:$ZULIP_BOT_API_KEY" \
  --data-urlencode type=stream \
  --data-urlencode "to=$CHANNEL" \
  --data-urlencode "topic=$TOPIC" \
  --data-urlencode "content=$content")"

if [[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))' <<<"$response")" != "success" ]]; then
  echo "zulip send failed: $response" >&2
  exit 1
fi
echo "notified: $CHANNEL > $TOPIC"
