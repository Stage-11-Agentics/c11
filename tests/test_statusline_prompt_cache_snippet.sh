#!/bin/bash
# The statusline snippet operators paste from skills/c11/references/api.md
# (the exact Claude prompt cache tap), run under `set -euo pipefail` with a
# fake c11: it must never fail or stall the statusline, send once per change,
# and retry a failed send. A pasted copy can never be fixed, so this gates it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNIP=$(mktemp)
sed -n '/^c11_panel=/,/^fi$/p' "$ROOT/skills/c11/references/api.md" > "$SNIP"
[ -s "$SNIP" ] || { echo "FAIL: snippet not found in api.md"; exit 1; }
T=$(mktemp -d); mkdir -p $T/bin $T/nojq
cat > $T/bin/c11 <<FAKE
#!/bin/bash
echo "deadline=\${C11_DEFAULT_SOCKET_DEADLINE_MS:-} \$*" >> $T/calls
[ -f $T/slow ] && /bin/sleep 3
[ -f $T/fail ] && exit 1
exit 0
FAKE
chmod +x $T/bin/c11
JQ="$(command -v jq)" || { echo "FAIL: this test needs jq"; exit 1; }
ln -s "$JQ" $T/bin/jq
ln -s $T/bin/c11 $T/nojq/c11
WITH_JQ="$T/bin:/usr/bin:/bin"
statusline() { # $1 the statusline's whole PATH, $2 its input or __unset__
  env -i HOME="$HOME" TMPDIR=$T C11_PANEL_ID=p1 PATH="$1" IN="$2" /bin/bash -c '
    set -euo pipefail
    [ "$IN" = "__unset__" ] || input="$IN"
    '"$(cat "$SNIP")"'
    echo statusline-ok'
}
calls() { if [ -f $T/calls ]; then wc -l < $T/calls | tr -d " "; else echo 0; fi; }
# Sends run in the background: wait (up to 5 s) for an expected count, or a
# moment before checking that nothing more arrived.
expect_calls() { local i; for i in $(seq 50); do [ "$(calls)" = "$1" ] && break; /bin/sleep 0.1; done; check "$(calls)" "$1" "$2"; }
settle() { /bin/sleep 0.5; }
GOOD='{"prompt_cache":{"warm":true,"ttl":"1h","expires_at":1790003600,"misses":0}}'
pass=0; fail=0; check() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $3: got $1 want $2"; fi; }

check "$(statusline $T/nojq "$GOOD")" statusline-ok "no jq on PATH"; settle
check "$(calls)" 0 "no jq sends nothing"
check "$(statusline "$WITH_JQ" 'not json {{{')" statusline-ok "invalid input"
check "$(statusline "$WITH_JQ" __unset__)" statusline-ok "input unset under set -u"
check "$(statusline "$WITH_JQ" '{"session_id":"x"}')" statusline-ok "no prompt_cache yet"; settle
check "$(calls)" 0 "nothing to send"

check "$(statusline "$WITH_JQ" "$GOOD")" statusline-ok "send"
expect_calls 1 "sent once"
grep -q "^deadline=1500 rpc agent.prompt_cache.report" $T/calls && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL deadline/args: $(cat $T/calls)"; }
statusline "$WITH_JQ" "$GOOD" >/dev/null; settle
check "$(calls)" 1 "unchanged object is not resent"

NEXT='{"prompt_cache":{"warm":true,"ttl":"1h","expires_at":1790007200,"misses":0}}'
touch $T/slow
SECONDS=0
statusline "$WITH_JQ" "$NEXT" >/dev/null; statusline "$WITH_JQ" "$NEXT" >/dev/null; statusline "$WITH_JQ" "$NEXT" >/dev/null
check "$(( SECONDS < 2 ))" 1 "the statusline never waits on a 3 s send"
/bin/sleep 3.5; rm -f $T/slow
check "$(calls)" 2 "redraws during a slow send do not resend"

touch $T/fail
THIRD='{"prompt_cache":{"warm":false,"ttl":"1h","expires_at":1790010800,"misses":1}}'
statusline "$WITH_JQ" "$THIRD" >/dev/null
expect_calls 3 "failed send attempted"
settle; rm -f $T/fail
statusline "$WITH_JQ" "$THIRD" >/dev/null
expect_calls 4 "a failed send is retried on the next redraw"
statusline "$WITH_JQ" "$THIRD" >/dev/null; settle
check "$(calls)" 4 "then not again"
echo "snippet: $pass passed, $fail failed"
rm -rf $T "$SNIP"
[ $fail -eq 0 ]
