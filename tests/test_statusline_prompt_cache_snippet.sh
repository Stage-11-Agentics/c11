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
[ -f $T/slow ] && sleep 1
[ -f $T/fail ] && exit 1
exit 0
FAKE
chmod +x $T/bin/c11
ln -s "$(command -v jq)" $T/bin/jq
ln -s $T/bin/c11 $T/nojq/c11
statusline() { # $1 PATH, $2 input or __unset__
  local path="$1" in="$2"
  env -i HOME="$HOME" TMPDIR=$T C11_PANEL_ID=p1 PATH="$path:/usr/bin:/bin" IN="$in" bash -c '
    set -euo pipefail
    [ "$IN" = "__unset__" ] || input="$IN"
    '"$(cat "$SNIP")"'
    echo statusline-ok'
}
calls() { if [ -f $T/calls ]; then wc -l < $T/calls | tr -d " "; else echo 0; fi; }
GOOD='{"prompt_cache":{"warm":true,"ttl":"1h","expires_at":1790003600,"misses":0}}'
pass=0; fail=0; check() { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $3: got $1 want $2"; fi; }
check "$(statusline $T/nojq "$GOOD")" statusline-ok "no jq on PATH"
check "$(calls)" 0 "no jq sends nothing"
check "$(statusline $T/bin 'not json {{{')" statusline-ok "invalid input"
check "$(statusline $T/bin __unset__)" statusline-ok "input unset under set -u"
check "$(statusline $T/bin '{"session_id":"x"}')" statusline-ok "no prompt_cache yet"
check "$(calls)" 0 "nothing to send"
check "$(statusline $T/bin "$GOOD")" statusline-ok "send"; sleep 0.3
check "$(calls)" 1 "sent once"
grep -q "^deadline=1500 rpc agent.prompt_cache.report" $T/calls && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL deadline/args: $(cat $T/calls)"; }
statusline $T/bin "$GOOD" >/dev/null; sleep 0.3
check "$(calls)" 1 "unchanged object is not resent"
NEXT='{"prompt_cache":{"warm":true,"ttl":"1h","expires_at":1790007200,"misses":0}}'
touch $T/slow
start=$(date +%s)
statusline $T/bin "$NEXT" >/dev/null; statusline $T/bin "$NEXT" >/dev/null; statusline $T/bin "$NEXT" >/dev/null
check "$(( $(date +%s) - start < 1 ))" 1 "statusline never waits on a slow send"
sleep 1.3; rm -f $T/slow
check "$(calls)" 2 "redraws during a slow send do not resend"
touch $T/fail
THIRD='{"prompt_cache":{"warm":false,"ttl":"1h","expires_at":1790010800,"misses":1}}'
statusline $T/bin "$THIRD" >/dev/null; sleep 0.3
check "$(calls)" 3 "failed send attempted"
rm -f $T/fail
statusline $T/bin "$THIRD" >/dev/null; sleep 0.3
check "$(calls)" 4 "a failed send is retried on the next redraw"
statusline $T/bin "$THIRD" >/dev/null; sleep 0.3
check "$(calls)" 4 "then not again"
echo "snippet: $pass passed, $fail failed"
rm -rf $T "$SNIP"
[ $fail -eq 0 ]
