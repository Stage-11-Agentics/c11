#!/usr/bin/env bash
# Raw-file-write equivalent of `c11 mailbox send --to <surface> --body <text>`.
# Uses three `c11 mailbox` helpers instead of any c11-provided env vars so the
# example works identically in any shell, any language. See
# `docs/c11-messaging-primitive-design.md` §3.
set -euo pipefail

OUTBOX=$(c11 mailbox outbox-dir)
MY_NAME=$(c11 mailbox surface-name)
ULID=$(c11 mailbox new-id)
cat > "$OUTBOX/.$ULID.tmp" <<EOF
{"version":1,"id":"$ULID","from":"$MY_NAME","to":"${1:-watcher}","ts":"$(date -u +%FT%TZ)","body":"${2:-hello}"}
EOF
mv "$OUTBOX/.$ULID.tmp" "$OUTBOX/$ULID.msg"
echo "$ULID"
