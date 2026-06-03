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

config="$(python3 - "$POLICY_FILE" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"```json[ \t]+drawbridge-config[ \t]*\n(.*?)\n```", text, re.DOTALL)
if not m:
    sys.exit("no drawbridge-config block in policy file")
z = json.loads(m.group(1))["zulip"]
print("\n".join([z["site"], z["channel"], z["topic"], z["bot_email"]]))
PY
)"
SITE="$(sed -n 1p <<<"$config")"
CHANNEL="$(sed -n 2p <<<"$config")"
TOPIC="$(sed -n 3p <<<"$config")"
BOT_EMAIL="$(sed -n 4p <<<"$config")"

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
