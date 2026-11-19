#!/bin/bash
# C11H-16: scripts/c11-atlas-relay.sh in a throwaway HOME. No app, no hc, no
# signals: a fake CLI binary, a fake c11 that a .zprofile puts first (as
# Homebrew does on the build host), and zsh started with the env a c11 terminal gets.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/scripts/c11-atlas-relay.sh"
tmp="$(mktemp -d /tmp/c11-relay-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }

home="$tmp/home"; mkdir -p "$home/brew/bin"
cat > "$tmp/fake-cli" <<'CLI'
#!/bin/sh
# C11H-123: `agent-event append --stdin` records the event it would relay.
if [ "${1:-}" = agent-event ]; then cat >> "$C11_TEST_EVENTS"; echo >> "$C11_TEST_EVENTS"; exit 0; fi
echo "relay socket=$C11_RELAY_HC_SOCKET session=$C11_RELAY_SESSION args=$*"
CLI
chmod 755 "$tmp/fake-cli"
printf '#!/bin/sh\necho foreign c11\n' > "$home/brew/bin/c11"; chmod 755 "$home/brew/bin/c11"
# The user's own startup files put a foreign c11 first, in every phase.
printf 'export PATH="$HOME/brew/bin:$PATH"\nexport C11_TEST_ENV=1\n' > "$home/.zshenv"
printf 'export PATH="$HOME/brew/bin:$PATH"\n' > "$home/.zprofile"
printf 'export PATH="$HOME/brew/bin:$PATH"\nC11_TEST_RC=1\n' > "$home/.zshrc"
before="$(cd "$home" && find . -type f | sort | xargs shasum)"

run() { HOME="$home" /bin/sh "$script" "$@"; }
check "refuses the default session" "! run install --session default --cli '$tmp/fake-cli' 2>/dev/null"
check "refuses a path-like session" "! run install --session 'c11-../x' --cli '$tmp/fake-cli' 2>/dev/null"
check "installs" "run install --session c11-t --cli '$tmp/fake-cli' >/dev/null"
root="$home/.local/share/c11/relay/c11-t"
after="$(cd "$home" && find . -type f -not -path './.local/share/c11/relay/c11-t/*' | sort | xargs shasum)"
check "writes nothing outside the relay folder" "[ \"\$before\" = \"\$after\" ]"
check "manifest names the session, paths and CLI hash" \
  "python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m[\"relay_protocol\"]==2 and m[\"session\"]==\"c11-t\" and m[\"bin\"]==sys.argv[2]+\"/bin\" and len(m[\"cli_sha256\"])==64' '$root/manifest.json' '$root'"
check "sentinel is a regular file, not a socket" "[ -f '$root/no-socket' ] && [ ! -S '$root/no-socket' ]"
check "shim runs the CLI in relay mode for its session" \
  "'$root/bin/c11' identify | grep -q 'socket=$home/.local/share/c11/run/c11-t.sock session=c11-t args=identify'"

term_env=(env -i HOME="$home" USER=t LOGNAME=t SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin
          ZDOTDIR="$root/zdotdir" C11_SOCKET_PATH="$root/no-socket")
login="$("${term_env[@]}" /bin/zsh -l -i -c 'command -v c11; echo $C11_TEST_ENV$C11_TEST_RC' 2>/dev/null)"
check "login shell in a c11 terminal resolves the relay c11 first" "[ \"\$(echo \"\$login\" | head -1)\" = '$root/bin/c11' ]"
check "the user's own .zshenv and .zshrc still ran" "[ \"\$(echo \"\$login\" | tail -1)\" = 11 ]"
child="$("${term_env[@]}" /bin/zsh -l -i -c '/bin/zsh -c "command -v c11"' 2>/dev/null)"
check "a child zsh (an agent's tool shell) also resolves the relay c11" "[ \"\$child\" = '$root/bin/c11' ]"
plain="$(env -i HOME="$home" PATH=/usr/bin:/bin /bin/zsh -l -i -c 'command -v c11' 2>/dev/null)"
check "a shell outside c11 terminals is unchanged" "[ \"\$plain\" = '$home/brew/bin/c11' ]"

# A user .zshenv that moves ZDOTDIR keeps working, and the relay stays first.
mkdir -p "$home/zd"; printf 'export PATH="$HOME/brew/bin:$PATH"\nC11_TEST_RC=2\n' > "$home/zd/.zshrc"
printf 'ZDOTDIR=$HOME/zd\nexport PATH="$HOME/brew/bin:$PATH"\n' > "$home/.zshenv"
moved="$("${term_env[@]}" /bin/zsh -l -i -c 'command -v c11; echo rc=$C11_TEST_RC' 2>/dev/null)"
check "a user ZDOTDIR is honoured for later files" "echo \"\$moved\" | grep -q '^rc=2$'"
check "and the relay c11 is still first" "[ \"\$(echo \"\$moved\" | head -1)\" = '$root/bin/c11' ]"

# C11H-123: bin/codex. A fake real codex records its argv; the fake relay CLI
# records what `agent-event append --stdin` reads. `script` gives a terminal.
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$C11_TEST_ARGS"\n' > "$home/brew/bin/codex"
chmod 755 "$home/brew/bin/codex"
args="$tmp/codex-args"; events="$tmp/events"
codex_env=(env -i HOME="$home" PATH="$root/bin:$home/brew/bin:/usr/bin:/bin" C11_TEST_ARGS="$args" C11_TEST_EVENTS="$events")
notify="notify=[\"$root/bin/codex\",\"__c11-relay-notify\"]"
tty_codex() { rm -f "$args"; script -q /dev/null "${codex_env[@]}" "$@" "$root/bin/codex" "${codex_args[@]}" >/dev/null 2>&1 </dev/null; }
codex_args=(--model x); tty_codex
check "codex: an interactive launch gets the notify flag first, then its own args" \
  "[ \"\$(cat '$args')\" = \"\$(printf '%s\n' -c '$notify' --model x)\" ]"
codex_args=(-c 'notify=["mine"]'); tty_codex
check "codex: a notify the operator passes comes later in argv" \
  "[ \"\$(sed -n 4p '$args')\" = 'notify=[\"mine\"]' ] && [ \"\$(sed -n 2p '$args')\" = '$notify' ]"
codex_args=(exec hi); tty_codex
check "codex: a subcommand passes through unchanged" "[ \"\$(cat '$args')\" = \"\$(printf '%s\n' exec hi)\" ]"
codex_args=(--model x); tty_codex C11_RELAY_CODEX_WRAPPER_REENTRY=1
check "codex: a Codex started by Codex passes through unchanged" "[ \"\$(cat '$args')\" = \"\$(printf '%s\n' --model x)\" ]"
rm -f "$args"; "${codex_env[@]}" "$root/bin/codex" --model x </dev/null >/dev/null 2>&1
check "codex: a run without a terminal passes through unchanged" "[ \"\$(cat '$args')\" = \"\$(printf '%s\n' --model x)\" ]"

panel=0D3E2A5C-1111-4222-8333-944455556666; workspace=7A1B2C3D-AAAA-4BBB-8CCC-DDDDEEEEFFFF
callback() { "${codex_env[@]}" C11_PANEL_ID="$panel" C11_WORKSPACE_ID="$workspace" "$@" "$root/bin/codex" __c11-relay-notify "$payload"; }
# t0 in milliseconds just before the turn end: the stamp is never earlier, and
# a whole-second stamp (date +%s * 1000) is earlier unless a second turns over.
t0=$(python3 -I -c 'import time; print(int(time.time() * 1000))')
rm -f "$events"; payload='{"type":"agent-turn-complete","thread-id":"t1","last-assistant-message":"done"}'; callback
check "codex: a turn end appends exactly one journal event for its own panel" \
  "python3 -I -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; assert len(rows)==1; e=rows[0]; assert e[\"kind\"]==\"agent.turn.completed\" and e[\"panel_id\"]==sys.argv[2] and e[\"workspace_id\"]==sys.argv[3] and e[\"agent_kind\"]==\"codex\" and e[\"adapter\"]==\"codex_notify\" and e[\"source\"]==\"hook\" and e[\"native_event\"]==\"agent-turn-complete\" and \"session_id\" not in e and e[\"emitted_at_ms\"]>=int(sys.argv[4]) and e[\"schema_version\"]==1 and len(e[\"event_id\"])==36' '$events' '$panel' '$workspace' '$t0'"
rm -f "$events"; payload='{"type":"approval-requested"}'; callback
check "codex: another notify type appends nothing" "[ ! -s '$events' ]"
rm -f "$events"; payload='{"type":"approval-requested","inner":{"type":"agent-turn-complete"}}'; callback
check "codex: a turn-end type nested in another notify appends nothing" "[ ! -s '$events' ]"
rm -f "$events"; payload='{"type":"agent-turn-complete"}'; panel=not-a-panel; callback
check "codex: no panel id, nothing appended" "[ ! -s '$events' ]"

# C11H-134: Claude. A fake app bundle carries the real wrapper, note files and
# c11 skill beside its CLI; a fake real claude records its argv and two env values.
make_app() { # <dir> <cli>: a throwaway c11.app around <cli>
  mkdir -p "$1/Contents/Resources/bin" "$1/Contents/Resources/skills"
  cp "$2" "$1/Contents/Resources/bin/c11"
  for f in claude c11-agent-note.sh c11-agent-note.txt; do cp "$here/Resources/bin/$f" "$1/Contents/Resources/bin/$f"; done
  cp -R "$here/skills/c11" "$1/Contents/Resources/skills/c11"
  /usr/bin/plutil -create xml1 "$1/Contents/Info.plist"
  /usr/bin/plutil -insert C11Version -string 9.9.9-h1 "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 9.9.9 "$1/Contents/Info.plist"
}
app="$tmp/app.app/Contents"; make_app "$tmp/app.app" "$tmp/fake-cli"; mkdir -p "$tmp/tmpdir"
cat > "$home/brew/bin/claude" <<'REAL'
#!/bin/sh
{ echo CALL; for a in "$@"; do printf '%s\n' "$a"; done
  echo "ENV pid=${C11_AGENT_INTERACTIVE_PID-unset} tok=${CLAUDE_CODE_OAUTH_TOKEN-unset}"; } >> "$C11_TEST_ARGS"
REAL
chmod 755 "$home/brew/bin/claude"
kit="$root/c11-relay.app/Contents"; kit_bin="$kit/Resources/bin"
check "claude: install lays out the kit: the CLI as a real file, the wrapper, its note, the skill and the build" \
  "run install --session c11-t --cli '$app/Resources/bin/c11' >/dev/null &&
   [ -f '$kit_bin/c11' ] && [ ! -L '$kit_bin/c11' ] && cmp -s '$tmp/fake-cli' '$kit_bin/c11' &&
   cmp -s '$here/Resources/bin/claude' '$kit_bin/claude' && [ -x '$root/libexec/claude' ] &&
   [ -f '$kit/Resources/skills/c11/SKILL.md' ] && [ ! -e '$root/libexec/c11' ] &&
   [ \"\$(/usr/bin/plutil -extract C11Version raw -o - '$kit/Info.plist')\" = 9.9.9-h1 ] &&
   python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))[\"kit_version\"]==\"9.9.9-h1\"' '$root/manifest.json'"
check "claude: bin/c11h is the relay c11 too" "cmp -s '$root/bin/c11' '$root/bin/c11h' && '$root/bin/c11h' x | grep -q 'session=c11-t args=x'"
check "claude: with no bin/claude there, c11 writes its own entry" \
  "grep -q 'c11 relay claude entry' '$root/bin/claude'"
if [ -n "${C11_CLI_BIN:-}" ] && [ -x "${C11_CLI_BIN:-}" ]; then
  make_app "$tmp/real.app" "$C11_CLI_BIN"
  run install --session c11-g --cli "$tmp/real.app/Contents/Resources/bin/c11" >/dev/null
  guide="$(env -i HOME="$home" PATH=/usr/bin:/bin "$home/.local/share/c11/relay/c11-g/bin/c11h" guide 2>&1 | head -1)"
  check "claude: the note's first command works here: bin/c11h guide names this build" "echo \"\$guide\" | grep -q '^c11 9.9.9-h1'"
  run uninstall --session c11-g >/dev/null
else
  echo "SKIP claude: bin/c11h guide (set C11_CLI_BIN to a built c11 CLI)"
fi
claude_args="$tmp/claude-args"
# A c11 terminal here: C11_RELAY_BIN from c11, never the relay env pair.
claude_env=(env -i HOME="$home" PATH="$root/bin:$home/brew/bin:/usr/bin:/bin" TMPDIR="$tmp/tmpdir"
            C11_TEST_ARGS="$claude_args" C11_PANEL_ID=0D3E2A5C-1111-4222-8333-944455556666
            C11_WORKSPACE_ID=7A1B2C3D-AAAA-4BBB-8CCC-DDDDEEEEFFFF HC_TERMINAL_ID=t3
            C11_SOCKET_PATH="$root/no-socket" CMUX_SOCKET_PATH="$root/no-socket" C11_RELAY_BIN="$root/bin")
tty_claude() { rm -f "$claude_args"; script -q /dev/null "${claude_env[@]}" "$@" claude "${claude_args_in[@]}" >/dev/null 2>&1 </dev/null || true; }
home_before="$(cd "$home" && find . -type f -not -path './.local/share/c11/relay/*' | sort | xargs shasum)"
claude_args_in=(--model x); tty_claude
check "claude: a relay launch reaches the real claude once with c11's session, hooks and note, then its own args" \
  "python3 -I - '$claude_args' '$root/bin' <<'PY'
import json, re, sys
lines = open(sys.argv[1]).read().splitlines()
assert lines.count('CALL') == 1, lines
args = lines[1:-1]
assert args[0] == '--session-id' and re.fullmatch(r'[0-9a-f-]{36}', args[1]), args
assert args[2] == '--settings', args
assert args[4] == '--append-system-prompt' and args[5].startswith('c11 9.9.9-h1. You are running inside c11'), args
assert args[6:] == ['--model', 'x'], args
assert lines[-1] == 'ENV pid=unset tok=unset', lines[-1]
hooks = json.load(open(args[3]))['hooks']
assert set(hooks) == {'SessionStart', 'UserPromptSubmit', 'Stop', 'StopFailure', 'Notification',
                      'PreToolUse', 'PostToolUse', 'SessionEnd'}, sorted(hooks)
for event, groups in hooks.items():
    for group in groups:
        for hook in group['hooks']:
            assert hook['command'].startswith(\"'%s/c11' claude-hook \" % sys.argv[2]), hook
            assert hook.get('async', False) == (event not in ('Stop', 'PostToolUse')), (event, hook)
for event in ('PreToolUse', 'PostToolUse'):
    assert hooks[event][0]['matcher'] == 'AskUserQuestion|ExitPlanMode', hooks[event]
PY"
check "claude: launching writes nothing in HOME outside the relay folder" \
  "[ \"\$(cd '$home' && find . -type f -not -path './.local/share/c11/relay/*' | sort | xargs shasum)\" = \"\$home_before\" ]"
claude_args_in=(mcp list); tty_claude
check "claude: a subcommand passes through unchanged" "[ \"\$(sed -n '2,3p' '$claude_args')\" = \"\$(printf '%s\n' mcp list)\" ]"
claude_args_in=(--model x); tty_claude C11_CLAUDE_WRAPPER_REENTRY=1
check "claude: a claude started by Claude passes through unchanged" \
  "[ \"\$(sed -n '2,3p' '$claude_args')\" = \"\$(printf '%s\n' --model x)\" ] && [ \"\$(grep -c . '$claude_args')\" = 4 ]"
rm -f "$claude_args"; script -q /dev/null "${claude_env[@]}" C11_RELAY_BIN= "$kit_bin/claude" --model x >/dev/null 2>&1 </dev/null || true
check "claude: outside a relay terminal (no C11_RELAY_BIN) the wrapper passes through unchanged" \
  "[ \"\$(sed -n '2,3p' '$claude_args')\" = \"\$(printf '%s\n' --model x)\" ] && [ \"\$(grep -c . '$claude_args')\" = 4 ]"

# Each relay-mode condition on its own: anything off leaves the launch untouched.
mkdir -p "$tmp/elsewhere/bin"; cp "$root/bin/c11" "$tmp/elsewhere/bin/c11"
mkdir -p "$home/.local/share/c11/relay/c11-x/bin"
for bad in HC_TERMINAL_ID=x3 HC_TERMINAL_ID= C11_PANEL_ID=not-a-panel C11_PANEL_ID= \
           C11_RELAY_BIN="$tmp/elsewhere/bin" C11_RELAY_BIN="$home/.local/share/c11/relay/c11-x/bin"; do
  rm -f "$claude_args"; script -q /dev/null "${claude_env[@]}" "$bad" "$kit_bin/claude" --model x >/dev/null 2>&1 </dev/null || true
  check "claude: with $bad (${bad%%=*} not a relay terminal's) the wrapper passes through unchanged" \
    "[ \"\$(sed -n '2,3p' '$claude_args')\" = \"\$(printf '%s\n' --model x)\" ] && [ \"\$(grep -c . '$claude_args')\" = 4 ]"
done
/bin/rm -rf "$tmp/elsewhere" "$home/.local/share/c11/relay/c11-x"

# A hand-written bin/claude (the 2026-11-01 Glass Test's, exporting an account
# token that later ran out) never stays in front of c11's: install moves it to
# set-aside/, byte-identical, says so, and writes c11's own entry. Claude then
# gets the hooks and no stale token. /bin/sh, not zsh: this test HOME's .zshenv
# puts the fake real claude first, which would hide a shim-to-wrapper loop. It
# counts its runs and stops a loop at the fourth, so a loop fails a check.
shim_count="$tmp/shim-count"
write_shim() {
  cat > "$root/bin/claude" <<SHIM
#!/bin/sh
n=\$(( \$(cat '$shim_count' 2>/dev/null || echo 0) + 1 )); echo "\$n" > '$shim_count'
[ "\$n" -gt 3 ] && exit 99
export CLAUDE_CODE_OAUTH_TOKEN=fake-token
exec '$root/libexec/claude' "\$@"
SHIM
  chmod 755 "$root/bin/claude"
}
write_shim; shim_sum="$(shasum < "$root/bin/claude")"
notice="$(run install --session c11-t --cli "$app/Resources/bin/c11")"
aside="$(ls "$root"/set-aside/claude.* 2>/dev/null | head -1)"
check "claude: reinstall moves a hand-written bin/claude to set-aside, byte-identical, and says so" \
  "[ -n \"\$aside\" ] && [ \"\$(shasum < \"\$aside\")\" = \"\$shim_sum\" ] && echo \"\$notice\" | grep -q 'moved $root/bin/claude (not written by this installer) to '"
check "claude: and writes c11's own bin/claude, listed in the manifest" \
  "grep -q 'c11 relay claude entry' '$root/bin/claude' &&
   python3 -I -c 'import json,sys; assert \"bin/claude\" in json.load(open(sys.argv[1]))[\"files\"]' '$root/manifest.json'"
claude_args_in=(--model x); /bin/rm -f "$shim_count"; tty_claude
check "claude: c11's entry reaches the real claude once, hooked, with no stale token" \
  "[ ! -e '$shim_count' ] && [ \"\$(grep -c '^CALL\$' '$claude_args')\" = 1 ] && grep -qx -- --settings '$claude_args' &&
   grep -qx 'ENV pid=unset tok=unset' '$claude_args'"
# The old advice put an operator shim ending in `exec <relay>/libexec/claude`; on
# PATH after the relay bin it would be taken as the real claude and loop. It is skipped.
mkdir -p "$home/opshim"; cp "$aside" "$home/opshim/claude"; chmod 755 "$home/opshim/claude"
claude_args_in=(--model x); /bin/rm -f "$shim_count"
tty_claude PATH="$root/bin:$home/opshim:$home/brew/bin:/usr/bin:/bin"
check "claude: an operator shim that still execs the relay entry is skipped, no loop" \
  "[ ! -e '$shim_count' ] && [ \"\$(grep -c '^CALL\$' '$claude_args')\" = 1 ] && grep -qx -- --settings '$claude_args'"
/bin/rm -rf "$home/opshim"
# An account shim that only names a relay path (a comment) and execs the real
# claude is a real shim: it is taken, so its token reaches claude.
mkdir -p "$home/opshim"
cat > "$home/opshim/claude" <<SHIM
#!/bin/sh
# runs after $root/bin in c11 terminals; picks the account
export CLAUDE_CODE_OAUTH_TOKEN=pool-token
exec '$home/brew/bin/claude' "\$@"
SHIM
chmod 755 "$home/opshim/claude"
claude_args_in=(--model x); /bin/rm -f "$shim_count"
tty_claude PATH="$root/bin:$home/opshim:$home/brew/bin:/usr/bin:/bin"
check "claude: an account shim that only names a relay path is taken, with its token" \
  "[ \"\$(grep -c '^CALL\$' '$claude_args')\" = 1 ] && grep -qx -- --settings '$claude_args' && grep -q 'tok=pool-token' '$claude_args'"
/bin/rm -rf "$home/opshim"
check "claude: the set-aside note says to drop that exec line" "echo \"\$notice\" | grep -q 'must not exec $root/libexec/claude'"
# A reinstall from a standalone CLI (no app around it) keeps the kit's Claude
# wrapper, note and skill, so c11's entry stays whole.
mkdir -p "$tmp/standalone"; cp "$tmp/fake-cli" "$tmp/standalone/c11"
check "claude: a standalone-CLI reinstall keeps the chain whole and hooked" \
  "run install --session c11-t --cli '$tmp/standalone/c11' >/dev/null 2>&1 && grep -q 'c11 relay claude entry' '$root/bin/claude' &&
   [ -x '$root/libexec/claude' ] && [ -x '$kit_bin/claude' ] && [ -f '$kit/Resources/skills/c11/SKILL.md' ] &&
   claude_args_in=(--model x) && tty_claude && grep -qx -- --settings '$claude_args' &&
   [ \"\$(grep -c '^CALL\$' '$claude_args')\" = 1 ]"
uninstalled="$(run uninstall --session c11-t 2>&1)"
check "claude: uninstall removes c11's files and leaves the set-aside copy, saying so" \
  "[ \"\$(shasum < \"\$aside\")\" = \"\$shim_sum\" ] && [ ! -e '$root/bin/claude' ] && echo \"\$uninstalled\" | grep -q 'leaving $root/set-aside/claude'"
/bin/rm -rf "$root/set-aside"
run install --session c11-t --cli "$app/Resources/bin/c11" >/dev/null
check "claude: a standalone-CLI reinstall keeps c11's own bin/claude, its entry and their ownership" \
  "run install --session c11-t --cli '$tmp/standalone/c11' >/dev/null 2>&1 && grep -q 'c11 relay claude entry' '$root/bin/claude' &&
   [ -x '$root/libexec/claude' ] && [ -x '$kit_bin/claude' ] &&
   python3 -I -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"files\"]; assert {\"bin/claude\",\"libexec/claude\",\"c11-relay.app/Contents/Resources/bin/claude\",\"c11-relay.app/Contents/Info.plist\",\"c11-relay.app/Contents/Resources/skills/c11/SKILL.md\"} <= set(f), f' '$root/manifest.json' &&
   claude_args_in=(--model x) && tty_claude && grep -qx -- --settings '$claude_args'"
printf '# edited\n' >> "$kit_bin/claude"
check "claude: with the kit wrapper no longer its own, a standalone reinstall removes c11's entry and bin/claude, never leaving them pointing at nothing" \
  "run install --session c11-t --cli '$tmp/standalone/c11' >/dev/null 2>&1 && [ ! -e '$root/libexec/claude' ] && [ ! -e '$root/bin/claude' ] &&
   grep -q '# edited' '$kit_bin/claude'"
/bin/rm -f "$kit_bin/claude"
run install --session c11-t --cli "$app/Resources/bin/c11" >/dev/null
# The operator's counterpart: its own shim stays, and install says it now runs nothing.
write_shim; shim_sum="$(shasum "$root/bin/claude")"
printf '# edited\n' >> "$kit_bin/claude"
check "claude: with an operator shim, that reinstall keeps the shim and says its entry is removed" \
  "run install --session c11-t --cli '$tmp/standalone/c11' >/dev/null 2>'$tmp/chain.err' && [ ! -e '$root/libexec/claude' ] &&
   [ \"\$(shasum '$root/bin/claude')\" = \"\$shim_sum\" ] && grep -q 'still runs $root/libexec/claude, which is removed' '$tmp/chain.err'"
/bin/rm -f "$kit_bin/claude" "$root/bin/claude"
run install --session c11-t --cli "$app/Resources/bin/c11" >/dev/null

stamp="$(stat -f %m "$kit_bin/c11")"; sleep 1
check "reinstall with the same CLI keeps the binary" "run install --session c11-t --cli '$app/Resources/bin/c11' >/dev/null && [ \"\$(stat -f %m '$kit_bin/c11')\" = '$stamp' ]"
check "uninstall removes only the relay folder" "run uninstall --session c11-t >/dev/null && [ ! -e '$root' ] && [ -f '$home/.zprofile' ]"

# C11H-78: --shards N installs S-s1 .. S-sN, each with its own manifest and socket, and nothing else.
before2="$(cd "$home" && find . -type f -not -path './.local/share/c11/relay/*' | sort | xargs shasum)"
check "refuses --shards 0 and 9" "! run install --session c11-t --shards 0 --cli '$tmp/fake-cli' 2>/dev/null && ! run install --session c11-t --shards 9 --cli '$tmp/fake-cli' 2>/dev/null"
check "a refused --shards wrote nothing" "[ ! -e '$home/.local/share/c11/relay' ] || [ -z \"\$(ls -A '$home/.local/share/c11/relay')\" ]"
check "installs three shard sessions" "run install --session c11-t --shards 3 --cli '$tmp/fake-cli' >/dev/null"
check "exactly the three shard folders" "[ \"\$(ls '$home/.local/share/c11/relay' | tr '\n' ' ')\" = 'c11-t-s1 c11-t-s2 c11-t-s3 ' ]"
check "each manifest names its own shard session" \
  "for n in 1 2 3; do python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m[\"session\"]==sys.argv[2], m' '$home/.local/share/c11/relay/c11-t-s'\$n/manifest.json c11-t-s\$n || exit 1; done"
check "each shim reaches its own shard socket" "'$home/.local/share/c11/relay/c11-t-s2/bin/c11' x | grep -q 'socket=$home/.local/share/c11/run/c11-t-s2.sock session=c11-t-s2 '"
check "uninstalling one shard leaves the others" "run uninstall --session c11-t-s2 >/dev/null && [ ! -e '$home/.local/share/c11/relay/c11-t-s2' ] && [ -f '$home/.local/share/c11/relay/c11-t-s1/manifest.json' ] && [ -f '$home/.local/share/c11/relay/c11-t-s3/manifest.json' ]"
check "uninstall --shards removes the rest" "run uninstall --session c11-t --shards 3 >/dev/null && [ -z \"\$(ls -A '$home/.local/share/c11/relay')\" ]"
after2="$(cd "$home" && find . -type f -not -path './.local/share/c11/relay/*' | sort | xargs shasum)"
check "shards wrote nothing outside the relay folder" "[ \"\$before2\" = \"\$after2\" ]"

# Glass finding 2: the installer changes only files it wrote. A hand-made bin/claude survives
# reinstall and uninstall, with a note each time; a foreign file at one of its own paths stops it.
groot="$home/.local/share/c11/relay/c11-g"
check "install for the planted-file case" "run install --session c11-g --cli '$tmp/fake-cli' >/dev/null"
printf '#!/bin/sh\necho hand-made\n' > "$groot/bin/claude"; chmod 755 "$groot/bin/claude"
printf 'operator notes\n' > "$groot/notes.txt"
planted="$(shasum "$groot/bin/claude")"
check "reinstall keeps the planted bin/claude" "run install --session c11-g --cli '$tmp/fake-cli' >/dev/null 2>'$tmp/re.err' && [ \"\$(shasum '$groot/bin/claude')\" = \"\$planted\" ]"
check "reinstall says it left bin/claude" "grep -q 'leaving $groot/bin/claude: not written by this installer' '$tmp/re.err'"
check "the manifest lists exactly the installer's eleven files, each with the hash it wrote" \
  "python3 -I - '$groot' <<'PY'
import hashlib, json, sys
root = sys.argv[1]
m = json.load(open(root + '/manifest.json'))
want = ['bin/c11', 'bin/c11h', 'bin/codex', 'zdotdir/.zshenv', 'zdotdir/.zprofile', 'zdotdir/.zshrc', 'zdotdir/.zlogin', 'bash/rc', 'no-socket',
        'manifest.json', 'c11-relay.app/Contents/Resources/bin/c11']
assert m['files'] == want and len(set(m['files'])) == 11, m['files']
assert m['bashrc'] == root + '/bash/rc', m.get('bashrc')
assert sorted(m['file_sha256']) == sorted(f for f in want if f != 'manifest.json'), m['file_sha256']
assert len(m['self_sha256']) == 64, m.get('self_sha256')
for f, h in m['file_sha256'].items():
    assert hashlib.sha256(open(root + '/' + f, 'rb').read()).hexdigest() == h, f
PY"
check "uninstall keeps the planted bin/claude and says so" "run uninstall --session c11-g >/dev/null 2>'$tmp/un.err' && [ \"\$(shasum '$groot/bin/claude')\" = \"\$planted\" ] && grep -q 'leaving $groot/bin/claude' '$tmp/un.err'"
check "uninstall removed every file of its own" "[ \"\$(cd '$groot' && find . -type f | sort | tr '\n' ' ')\" = './bin/claude ./notes.txt ' ]"
check "a reinstall after that keeps it too" "run install --session c11-g --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(shasum '$groot/bin/claude')\" = \"\$planted\" ] && run uninstall --session c11-g >/dev/null 2>&1"
froot="$home/.local/share/c11/relay/c11-f"; mkdir -p "$froot/bin"; printf 'mine\n' > "$froot/bin/c11"
check "a foreign file at an installer path stops install" "! run install --session c11-f --cli '$tmp/fake-cli' >/dev/null 2>&1"
check "and nothing was written or replaced" "[ \"\$(cat '$froot/bin/c11')\" = mine ] && [ \"\$(cd '$froot' && find . -type f | tr '\n' ' ')\" = './bin/c11 ' ]"
check "uninstall with no manifest of ours removes nothing" "run uninstall --session c11-f >/dev/null 2>&1 && [ \"\$(cat '$froot/bin/c11')\" = mine ]"
lroot="$home/.local/share/c11/relay/c11-l"
check "install for the legacy-manifest case" "run install --session c11-l --cli '$tmp/fake-cli' >/dev/null"
# A genuinely old install, made from a fresh one: none of the manifest fields
# that came with "files", and its layout: the CLI in libexec/c11 with bin/c11
# running it, and no kit, bin/c11h, Claude entry (C11H-134) or bash/rc (C11H-392).
to_legacy() { # <root>
  python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); [m.pop(k, None) for k in ("files","file_sha256","self_sha256","kit_version","bashrc")]; json.dump(m, open(p,"w"))' "$1/manifest.json"
  /bin/rm -rf "$1/c11-relay.app" "$1/bin/c11h" "$1/libexec/claude" "$1/bash"; mkdir -p "$1/libexec"; cp "$tmp/fake-cli" "$1/libexec/c11"
  sed -i '' "s|$1/c11-relay.app/Contents/Resources/bin/c11|$1/libexec/c11|" "$1/bin/c11"
}
to_legacy "$lroot"
printf 'hand\n' > "$lroot/bin/claude"
check "a manifest from before files owns the installer's paths: reinstall works and keeps bin/claude" "run install --session c11-l --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(cat '$lroot/bin/claude')\" = hand ]"
check "and retires its libexec/c11 once bin/c11 runs the kit" "[ ! -e '$lroot/libexec/c11' ] && grep -q '$lroot/c11-relay.app/Contents/Resources/bin/c11' '$lroot/bin/c11'"
check "and uninstall then keeps bin/claude" "run uninstall --session c11-l >/dev/null 2>&1 && [ \"\$(cat '$lroot/bin/claude')\" = hand ] && [ ! -e '$lroot/manifest.json' ]"

# terra (#108) 1: a file replaced at one of the installer's own paths after install is not its own.
snap() {
  python3 -I - "$1" <<'PYHASH'
import hashlib, os, sys
base = sys.argv[1]
rows = []
for root, dirs, files in os.walk(base):
    for name in dirs + files:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, base)
        if os.path.islink(path):
            value = "link " + os.readlink(path)
        elif os.path.isfile(path):
            with open(path, "rb") as source:
                value = hashlib.sha256(source.read()).hexdigest()
        else:
            value = "directory"
        rows.append((rel, value))
for rel, value in sorted(rows):
    print(rel, value)
PYHASH
}
rroot="$home/.local/share/c11/relay/c11-r"
check "install for the replaced-file case" "run install --session c11-r --cli '$tmp/fake-cli' >/dev/null"
printf 'mine\n' > "$rroot/bin/c11"
rsnap="$(snap "$rroot")"
check "reinstall refuses over a replaced bin/c11, writing nothing" "! run install --session c11-r --cli '$tmp/fake-cli' >/dev/null 2>'$tmp/rr.err' && [ \"\$(snap '$rroot')\" = \"\$rsnap\" ] && grep -q 'bin/c11 exists' '$tmp/rr.err'"
check "uninstall keeps the replaced bin/c11, says so, and removes the rest" "run uninstall --session c11-r >/dev/null 2>'$tmp/ru.err' && [ \"\$(cat '$rroot/bin/c11')\" = mine ] && grep -q 'leaving $rroot/bin/c11: changed since install' '$tmp/ru.err' && [ \"\$(cd '$rroot' && find . -type f | tr '\n' ' ')\" = './bin/c11 ' ]"
rm -rf "$rroot"
check "install for the edited-file case" "run install --session c11-r --cli '$tmp/fake-cli' >/dev/null"
printf '# my edit\n' >> "$rroot/zdotdir/.zshrc"; ln -sf /etc/hosts "$rroot/no-socket"
rsnap="$(snap "$rroot")"
check "an edited startup file or a symlink at an installer path stops reinstall" "! run install --session c11-r --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(snap '$rroot')\" = \"\$rsnap\" ]"
check "uninstall leaves both and removes the untouched files" "run uninstall --session c11-r >/dev/null 2>&1 && [ -L '$rroot/no-socket' ] && grep -q 'my edit' '$rroot/zdotdir/.zshrc' && [ \"\$(cd '$rroot' && find . \\( -type f -o -type l \\) | sort | tr '\n' ' ')\" = './no-socket ./zdotdir/.zshrc ' ]"
rm -rf "$rroot"

# terra (#108) verification 1: an edited manifest owns nothing, so nothing is rewritten or removed.
eroot="$home/.local/share/c11/relay/c11-e"
check "install for the edited-manifest case" "run install --session c11-e --cli '$tmp/fake-cli' >/dev/null"
# A byte-level edit that keeps the installer's compact format, so only the self-hash can tell.
python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); assert s.startswith("{\"relay_protocol\""); open(p,"w").write("{\"operator_note\":\"mine\"," + s[1:])' "$eroot/manifest.json"
esnap="$(snap "$eroot")"
check "reinstall refuses over an edited manifest, writing nothing" "! run install --session c11-e --cli '$tmp/fake-cli' >/dev/null 2>'$tmp/e.err' && [ \"\$(snap '$eroot')\" = \"\$esnap\" ] && grep -q 'manifest.json exists' '$tmp/e.err'"
check "uninstall with an edited manifest removes nothing and keeps the edit" "run uninstall --session c11-e >/dev/null 2>&1 && [ \"\$(snap '$eroot')\" = \"\$esnap\" ] && grep -q operator_note '$eroot/manifest.json'"
rm -rf "$eroot"

# terra (#108) verification 3: deleting "files" from a current manifest does not make it legacy.
froot2="$home/.local/share/c11/relay/c11-n"
check "install for the files-removed case" "run install --session c11-n --cli '$tmp/fake-cli' >/dev/null"
python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m.pop("files"); json.dump(m, open(p,"w"))' "$froot2/manifest.json"
nsnap="$(snap "$froot2")"
check "reinstall refuses a current manifest with files removed, writing nothing" "! run install --session c11-n --cli '$tmp/fake-cli' >/dev/null 2>'$tmp/n.err' && [ \"\$(snap '$froot2')\" = \"\$nsnap\" ] && grep -q 'manifest.json exists' '$tmp/n.err'"
check "uninstall with files removed removes nothing" "run uninstall --session c11-n >/dev/null 2>&1 && [ \"\$(snap '$froot2')\" = \"\$nsnap\" ]"
rm -rf "$froot2"

# terra (#108) verification 2: a symlink to a same-content copy is still not the installer's file.
same_link() { cp "$1/no-socket" "$tmp/sentinel-copy-$2"; rm "$1/no-socket"; ln -s "$tmp/sentinel-copy-$2" "$1/no-socket"; }
yroot="$home/.local/share/c11/relay/c11-y"
check "install for the same-content symlink reinstall case" "run install --session c11-y --cli '$tmp/fake-cli' >/dev/null"
same_link "$yroot" y
ysnap="$(snap "$yroot")"
check "reinstall refuses over a same-content symlink, writing nothing" "! run install --session c11-y --cli '$tmp/fake-cli' >/dev/null 2>'$tmp/y.err' && [ -L '$yroot/no-socket' ] && [ \"\$(snap '$yroot')\" = \"\$ysnap\" ] && grep -q 'no-socket exists' '$tmp/y.err'"
rm -rf "$yroot"
zroot="$home/.local/share/c11/relay/c11-z"
check "install for the same-content symlink uninstall case" "run install --session c11-z --cli '$tmp/fake-cli' >/dev/null"
same_link "$zroot" z
check "uninstall keeps a same-content symlink and removes the rest" "run uninstall --session c11-z >/dev/null 2>&1 && [ -L '$zroot/no-socket' ] && [ \"\$(cd '$zroot' && find . \\( -type f -o -type l \\) | tr '\n' ' ')\" = './no-socket ' ]"
rm -rf "$zroot"

# terra (#108) 2: a conflict in a later shard leaves every requested shard as it was.
printf '#!/bin/sh\necho v2\n' > "$tmp/fake-cli-2"; chmod 755 "$tmp/fake-cli-2"
check "install shard 1 alone first" "run install --session c11-m-s1 --cli '$tmp/fake-cli' >/dev/null"
mkdir -p "$home/.local/share/c11/relay/c11-m-s2/bin"; printf 'theirs\n' > "$home/.local/share/c11/relay/c11-m-s2/bin/c11"
msnap="$(snap "$home/.local/share/c11/relay")"
check "a foreign file in shard 2 refuses the whole --shards 3 install" "! run install --session c11-m --shards 3 --cli '$tmp/fake-cli-2' >/dev/null 2>'$tmp/m.err' && grep -q 'c11-m-s2/bin/c11 exists' '$tmp/m.err'"
check "and no requested shard was written: shard 1 keeps its old CLI, shard 3 was not made" "[ \"\$(snap '$home/.local/share/c11/relay')\" = \"\$msnap\" ] && [ ! -e '$home/.local/share/c11/relay/c11-m-s3' ]"
run uninstall --session c11-m-s1 >/dev/null 2>&1; rm -rf "$home/.local/share/c11/relay/c11-m-s2"

# A manifest from before "files" still checks its libexec/c11 against cli_sha256.
check "install for the legacy-binary case" "run install --session c11-l2 --cli '$tmp/fake-cli' >/dev/null"
l2="$home/.local/share/c11/relay/c11-l2"
to_legacy "$l2"
printf 'swapped\n' > "$l2/libexec/c11"
check "a legacy install whose libexec/c11 no longer matches cli_sha256 refuses reinstall" "! run install --session c11-l2 --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(cat '$l2/libexec/c11')\" = swapped ]"
rm -rf "$l2"

# The Codex shim added on main participates in the same ownership contract.
croot="$home/.local/share/c11/relay/c11-codex"
mkdir -p "$croot/bin"; printf 'operator codex\n' > "$croot/bin/codex"
csnap="$(snap "$croot")"
check "an operator codex blocks a fresh install without writes" "! run install --session c11-codex --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(snap '$croot')\" = \"\$csnap\" ]"
check "uninstall without a manifest preserves operator codex" "run uninstall --session c11-codex >/dev/null 2>&1 && [ \"\$(snap '$croot')\" = \"\$csnap\" ]"
rm -rf "$croot"
run install --session c11-codex --cli "$tmp/fake-cli" >/dev/null
printf 'operator codex\n' > "$croot/bin/codex"
csnap="$(snap "$croot")"
check "a replaced codex blocks reinstall without writes" "! run install --session c11-codex --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(snap '$croot')\" = \"\$csnap\" ]"
check "uninstall keeps replaced codex and removes the owned payload" "run uninstall --session c11-codex >/dev/null 2>&1 && [ \"\$(cat '$croot/bin/codex')\" = 'operator codex' ] && [ ! -e '$croot/manifest.json' ]"
rm -rf "$croot"
run install --session c11-codex --cli "$tmp/fake-cli" >/dev/null
to_legacy "$croot"
printf 'operator codex\n' > "$croot/bin/codex"
csnap="$(snap "$croot")"
check "legacy migration never claims a foreign codex by path" "! run install --session c11-codex --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(snap '$croot')\" = \"\$csnap\" ]"
check "legacy uninstall preserves foreign codex" "run uninstall --session c11-codex >/dev/null 2>&1 && [ \"\$(cat '$croot/bin/codex')\" = 'operator codex' ]"

# A symlinked parent must not turn an owned relative path into an outside write.
droot="$home/.local/share/c11/relay/c11-dir"
mkdir -p "$droot" "$tmp/operator-bin"
printf 'operator file\n' > "$tmp/operator-bin/keep"
ln -s "$tmp/operator-bin" "$droot/bin"
dsnap="$(snap "$tmp/operator-bin")"
check "a symlinked payload directory refuses install without outside writes" "! run install --session c11-dir --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(snap '$tmp/operator-bin')\" = \"\$dsnap\" ] && [ ! -e '$droot/manifest.json' ]"
rm -rf "$droot"
run install --session c11-dir --cli "$tmp/fake-cli" >/dev/null
mv "$droot" "$tmp/operator-relay"
ln -s "$tmp/operator-relay" "$droot"
dsnap="$(snap "$tmp/operator-relay")"
check "a symlinked relay root refuses reinstall without writes" "! run install --session c11-dir --cli '$tmp/fake-cli' >/dev/null 2>&1 && [ \"\$(snap '$tmp/operator-relay')\" = \"\$dsnap\" ]"
check "uninstall never follows a symlinked relay root" "run uninstall --session c11-dir >/dev/null 2>&1 && [ \"\$(snap '$tmp/operator-relay')\" = \"\$dsnap\" ]"

# C11H-392: a c11 terminal whose shell is bash starts `bash --rcfile bash/rc -i`.
# The rc reads what a login bash reads (here ~/.bash_profile, which wins over
# ~/.profile), then puts the relay's bin first, ahead of the user's own PATH
# edits, and keeps it first after a prompt hook moves it.
bhome="$tmp/bash-home"; mkdir -p "$bhome/own"
printf 'PATH="$HOME/own:$PATH"; export PATH; C11_TEST_PROFILE=bash_profile\n' > "$bhome/.bash_profile"
printf 'C11_TEST_PROFILE=profile\n' > "$bhome/.profile"
HOME="$bhome" /bin/sh "$script" install --session c11-bash --cli "$tmp/fake-cli" >/dev/null 2>&1
brc="$bhome/.local/share/c11/relay/c11-bash/bash/rc"
bbin="$bhome/.local/share/c11/relay/c11-bash/bin"
cat > "$tmp/bash-probe" <<'PROBE'
printf 'profile=%s\n' "$C11_TEST_PROFILE"
printf 'first=%s\n' "${PATH%%:*}"
printf 'path=:%s:\n' "$PATH"
printf 'rcvar=%s\n' "${C11_RELAY_BASHRC-unset}"
PATH=/usr/bin:$PATH
eval "$PROMPT_COMMAND"
printf 'after=%s\n' "${PATH%%:*}"
PROBE
env -i HOME="$bhome" PATH=/usr/bin:/bin TERM=dumb C11_RELAY_BASHRC="$brc" \
  /bin/bash --rcfile "$brc" -i -c ". '$tmp/bash-probe'" </dev/null >"$tmp/bash-probe.out" 2>/dev/null || true
check "bash/rc reads the first login file and puts the relay bin first" \
  "grep -qx 'profile=bash_profile' '$tmp/bash-probe.out' && grep -qx 'first=$bbin' '$tmp/bash-probe.out' && grep -q '^path=.*:$bhome/own:' '$tmp/bash-probe.out'"
check "bash/rc names the relay bin once and unsets C11_RELAY_BASHRC" \
  "[ \"\$(grep '^path=' '$tmp/bash-probe.out' | grep -o ':$bbin:' | wc -l | tr -d ' ')\" = 1 ] && grep -qx 'rcvar=unset' '$tmp/bash-probe.out'"
check "bash/rc keeps the relay bin first after PATH moves it" "grep -qx 'after=$bbin' '$tmp/bash-probe.out'"

# An installer from before bash/rc, run over this kit, writes a manifest that
# leaves bash/rc out. This installer adopts it again only by its exact bytes.
downgrade() { # <kit root>: the manifest such an installer would leave
  /usr/bin/python3 -I - "$1/manifest.json" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
m = json.load(open(path))
m["files"] = [f for f in m["files"] if f != "bash/rc"]
m["file_sha256"].pop("bash/rc", None)
m.pop("bashrc", None)
m["self_sha256"] = ""
m["self_sha256"] = hashlib.sha256(json.dumps(m, separators=(",", ":")).encode()).hexdigest()
open(path, "w").write(json.dumps(m, separators=(",", ":")))
PY
}
broot="$bhome/.local/share/c11/relay/c11-bash"
downgrade "$broot"
check "after an older installer, this one adopts its own bash/rc and names it again" \
  "HOME='$bhome' /bin/sh '$script' install --session c11-bash --cli '$tmp/fake-cli' >/dev/null 2>&1 && grep -q '\"bash/rc\"' '$broot/manifest.json'"
downgrade "$broot"; printf '# changed\n' >> "$broot/bash/rc"
check "a bash/rc an older manifest left out is not adopted once changed" \
  "! HOME='$bhome' /bin/sh '$script' install --session c11-bash --cli '$tmp/fake-cli' >/dev/null 2>&1"

# A prompt hook the user's login files register (mise, direnv) moves PATH at
# every prompt; the relay's fixer must run after it. Commands go on stdin, as a
# terminal types them, so every prompt runs PROMPT_COMMAND (`-c` shows none).
# The hook's value ends in ';', which a ';' join would turn into a syntax error.
hhome="$tmp/bash-hook-home"; mkdir -p "$hhome/hook"
printf '#!/bin/sh\necho hook\n' > "$hhome/hook/c11"; chmod 755 "$hhome/hook/c11"
printf '_hook() { _hook_n=$((${_hook_n:-0} + 1)); PATH="$HOME/hook:$PATH"; }\nPROMPT_COMMAND="_hook;"\n' > "$hhome/.bash_profile"
HOME="$hhome" /bin/sh "$script" install --session c11-bash --cli "$tmp/fake-cli" >/dev/null 2>&1
hrc="$hhome/.local/share/c11/relay/c11-bash/bash/rc"
hbin="$hhome/.local/share/c11/relay/c11-bash/bin"
hook_term() { # <bash> <out>: three prompts, a cd between, then the hook count
  printf 'command -v c11\ncd /\ncommand -v c11\nprintf "hooks=%%s\\n" "$_hook_n"\nexit\n' |
    env -i HOME="$hhome" PATH=/usr/bin:/bin TERM=dumb "$1" --rcfile "$hrc" -i >"$2" 2>/dev/null || true
}
hook_ok() { # <out>: the relay c11 both times, after the hook ran at each prompt
  [ "$(sed -n 1p "$1")" = "$hbin/c11" ] && [ "$(sed -n 2p "$1")" = "$hbin/c11" ] && grep -qx 'hooks=4' "$1"
}
hook_term /bin/bash "$tmp/bash-hook.out"
check "bash/rc runs its PATH fixer after the user's prompt hooks, at every prompt" "hook_ok '$tmp/bash-hook.out'"
# bash 5.1 and later run every element of an array PROMPT_COMMAND, so the fixer
# must be the last element, after a hook in a later one. macOS's /bin/bash is
# 3.2; this runs with a newer bash when one is installed (the Linux box test
# always runs it).
bash5=
for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -x "$b" ] && "$b" -c '(( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501 ))' 2>/dev/null && { bash5=$b; break; }
done
if [ -n "$bash5" ]; then
  printf '_hook() { _hook_n=$((${_hook_n:-0} + 1)); PATH="$HOME/hook:$PATH"; }\nPROMPT_COMMAND=(: _hook)\n' > "$hhome/.bash_profile"
  hook_term "$bash5" "$tmp/bash-hook-array.out"
  check "bash/rc appends its fixer to an array PROMPT_COMMAND ($bash5)" "hook_ok '$tmp/bash-hook-array.out'"
else
  echo "skip bash/rc with an array PROMPT_COMMAND (no bash 5.1 or later here)"
fi

[ "$fails" -eq 0 ] && echo "PASS c11_atlas_relay_test" || { echo "FAIL c11_atlas_relay_test ($fails)"; exit 1; }
