#!/bin/bash
# c11 guest kit: run guest commands with Claude's token in their environment, HOST SIDE.
#   C11_GUEST=<run-id> tools/c11-guest/claude-env.sh sh '<zsh>'        plain ssh session
#   C11_GUEST=<run-id> tools/c11-guest/claude-env.sh aqua-sh '<zsh>'   guest Aqua session (to launch an app)
#   C11_GUEST=<run-id> tools/c11-guest/claude-env.sh smoke             claude -p 'reply OK', with argv checks
#   C11_GUEST=<run-id> tools/c11-guest/claude-env.sh verify-clean [host paths...]
# The kit's g.sh exposes sh/aqua-sh as `claude-sh` / `claude-aqua-sh`. docs/c11-guest-agents.md.
#
# The token (C11_CLAUDE_TOKEN_FILE, default ~/.config/stage11/claude/bravo.token: its first
# line that is not blank or a # comment) is read into a shell variable here and written to the
# ssh session's stdin. In the guest, zsh `read`s it into CLAUDE_CODE_OAUTH_TOKEN, the variable
# Claude Code reads for a setup token, and runs the snippet with stdin at /dev/null. It is never
# in an argument list on either machine, never in a file in the guest, and never printed: the
# snippet's own output passes through unchanged, so a snippet must not print its environment.
set -euo pipefail

die() { echo "claude-env: $1" >&2; exit "${2:-1}"; }
run="${C11_RUN:-${C11_GUEST:-}}"
[[ -n "$run" ]] || die "set C11_GUEST (or C11_RUN) to the sandbox run id" 3
[[ "$run" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,48}$ ]] || die "run id is not a safe token: $run" 3
verb="${1:-}"; shift || true
TART="${TART:-/opt/homebrew/bin/tart}"
token_file="${C11_CLAUDE_TOKEN_FILE:-$HOME/.config/stage11/claude/bravo.token}"

ip="$("$TART" ip "c11-sb-$run" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
[[ -n "$ip" ]] || die "no running guest c11-sb-$run (lease one with the guest-up helper)" 3
SSH=(ssh -i "$HOME/.ssh/c11-sandbox" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15 "admin@$ip")

# Sets tok. Prints nothing about the value.
read_token() {
  local line
  tok=""
  [[ -r "$token_file" ]] || die "cannot read the token file $token_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    tok="$line"
    break
  done < "$token_file"
  # The guest-side argv check slices the same 12 characters, so the scheme length is fixed here.
  [[ "$tok" == sk-ant-oat01-* ]] || die "the token file's first value is not a Claude setup token (sk-ant-oat01-…)"
  [[ "$tok" =~ ^[A-Za-z0-9_-]+$ ]] || die "the token has characters a setup token does not"
}

# 12 characters of the secret body (characters 14-25), after the public sk-ant-oat01- scheme
# prefix every token shares and claude's own bundle contains. Sets slice.
token_slice() {
  slice="${tok:13:12}"
  (( ${#slice} == 12 )) || die "token too short to slice"
}

# Guest-side reader: the first stdin line becomes the token; the snippet ($1) gets /dev/null.
GUEST_READER='IFS= read -r CLAUDE_CODE_OAUTH_TOKEN || exit 97
[[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]] || exit 97
export CLAUDE_CODE_OAUTH_TOKEN DISABLE_AUTOUPDATER=1 OPENCODE_DISABLE_AUTOUPDATE=1
export PATH="/usr/local/bin:/opt/c11h/npm/bin:/opt/c11h/node/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
eval "$1" </dev/null'

guest_cmd() { # mode snippet -> the remote command line (code only)
  local mode="$1" snippet="$2" inner
  inner="/bin/zsh -c $(printf '%q' "$GUEST_READER") c11-claude $(printf '%q' "$snippet")"
  if [[ "$mode" == aqua ]]; then
    # Same recipe as scripts/sandbox-exec.sh; sudo and launchctl pass stdin through.
    printf '%s' '/usr/bin/sudo -n /bin/launchctl asuser "$(id -u)" /usr/bin/sudo -n -u "$(id -un)" /usr/bin/env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" TMPDIR="${TMPDIR:-/tmp}" '"$inner"
  else
    printf '%s' "$inner"
  fi
}

run_with_token() { # mode snippet
  local rc=0
  read_token
  printf '%s\n' "$tok" | "${SSH[@]}" "$(guest_cmd "$1" "$2")" || rc=$?
  tok=""
  (( rc != 97 )) || die "the guest did not receive the token on stdin"
  return "$rc"
}

# Host argv check: no process on this machine carries the slice in its arguments.
host_argv_clean() {
  local n
  n="$(/bin/ps -axww -o command= | grep -cF -f <(printf '%s\n' "$slice") || true)"
  [[ "$n" == 0 ]]
}

case "$verb" in
  sh) [[ $# -eq 1 ]] || die "usage: claude-env.sh sh '<zsh>'" 2; run_with_token plain "$1" ;;
  aqua-sh) [[ $# -eq 1 ]] || die "usage: claude-env.sh aqua-sh '<zsh>'" 2; run_with_token aqua "$1" ;;

  smoke)
    # claude -p runs in the background while both machines' process tables are sampled for
    # the slice. The guest samples with the slice taken from its own environment, fed to
    # grep by process substitution, so the check itself puts nothing in argv.
    read_token; token_slice
    snippet='mkdir -p "$HOME/c11-sandbox/work" && cd "$HOME/c11-sandbox/work"
out="$(mktemp -d)"
claude -p "reply OK" >"$out/reply" 2>"$out/err" &
pid=$!
hits=0 samples=0
while kill -0 $pid 2>/dev/null; do
  n="$(/bin/ps -axww -o command= | grep -cF -f <(print -r -- "${CLAUDE_CODE_OAUTH_TOKEN[14,25]}") || true)"
  (( hits += n, samples += 1 ))
  sleep 0.5
done
wait $pid; rc=$?
print -r -- "guest_argv_samples=$samples guest_argv_hits=$hits"
print -r -- "claude_version=$(claude --version 2>/dev/null | head -n 1)"
print -r -- "claude_exit=$rc"
print -r -- "claude_reply=$(tr -d "\r" <"$out/reply" | head -c 200)"
[[ -s "$out/err" ]] && print -r -- "claude_stderr=$(head -c 300 "$out/err" | tr "\n" " ")"
ok=0; grep -Eqi "^[[:space:]]*OK[.!]?[[:space:]]*$" "$out/reply" && ok=1
print -r -- "claude_reply_ok=$ok"
rm -rf "$out"
(( rc == 0 && hits == 0 && ok == 1 ))'
    hsamples=0 hhits=0
    out_file="$(mktemp)"
    printf '%s\n' "$tok" | "${SSH[@]}" "$(guest_cmd plain "$snippet")" >"$out_file" 2>&1 &
    spid=$!
    while kill -0 "$spid" 2>/dev/null; do
      host_argv_clean || hhits=$((hhits + 1))
      hsamples=$((hsamples + 1))
      sleep 0.5
    done
    rc=0; wait "$spid" || rc=$?
    tok=""
    cat "$out_file"; rm -f "$out_file"
    echo "host_argv_samples=$hsamples host_argv_hits=$hhits"
    (( rc != 97 )) || die "the guest did not receive the token on stdin"
    (( rc == 0 && hhits == 0 )) || { echo "smoke=FAIL"; exit 1; }
    echo "smoke=PASS" ;;

  verify-clean)
    # Searches the guest (~admin, /private/tmp, /opt/c11h, as root through passwordless sudo so
    # no guest file is unreadable) and then this host's run paths for the slice. The verdict is
    # pass only when every required root exists, grep exits 0 or 1 with no error on stderr, and
    # a planted canary is found. A file grep cannot read is an ERROR, never an absence.
    read_token; token_slice; tok=""
    nonce="c11-canary-$(/usr/bin/uuidgen)"
    evidence="${EVIDENCE_DIR:-$HOME/c11h-run/evidence}"
    bad=0
    read -r -a groots <<<"${C11_VERIFY_GUEST_ROOTS:-/Users/admin /private/tmp /opt/c11h}"
    gsudo="${C11_VERIFY_GUEST_SUDO:-1}"   # 0 only for the stand-in guest in tests
    groot_args=""; for r in "${groots[@]}"; do groot_args+=" $(printf '%q' "$r")"; done
    # Prints only RC/HIT/ERR/MISSING lines: paths and grep's own messages, never pattern text.
    guest_snippet='nonce=$1 use_sudo=$2; shift 2
canary="$HOME/.c11-verify-canary"; printf %s "$nonce" > "$canary"
for r in "$@"; do [[ -e "$r" ]] || print -r -- "MISSING $r"; done
if [[ "$use_sudo" == 1 ]]; then g=(/usr/bin/sudo -n /usr/bin/grep); else g=(/usr/bin/grep); fi
o="$(mktemp)" e="$(mktemp)"
"${g[@]}" -rlF -D skip -f /dev/stdin -- "$@" >"$o" 2>"$e"; rc=$?
print -r -- "RC $rc"
sed "s/^/HIT /" "$o"; sed "s/^/ERR /" "$e"
rm -f "$canary" "$o" "$e"'
    guest_out="$(printf '%s\n%s\n' "$slice" "$nonce" | "${SSH[@]}" "/bin/zsh -c $(printf '%q' "$guest_snippet") c11-verify $(printf '%q' "$nonce") $gsudo$groot_args")" \
      || die "guest search could not run"
    gcanary="${C11_VERIFY_GUEST_HOME:-/Users/admin}/.c11-verify-canary"
    # judge <label> <canary path> <output>: sets bad on any finding or error.
    judge() {
      local label="$1" can="$2" out="$3" rc hits errs missing
      rc="$(sed -n 's/^RC //p' <<<"$out")"
      hits="$(sed -n 's/^HIT //p' <<<"$out" | grep -vx -- "$can" || true)"
      errs="$(sed -n 's/^ERR //p' <<<"$out")"
      missing="$(sed -n 's/^MISSING //p' <<<"$out")"
      if [[ -n "$hits" ]]; then echo "$label=FOUND"; sed 's/^/  found: /' <<<"$hits"; bad=1; fi
      if [[ "$rc" != 0 && "$rc" != 1 ]] || [[ -n "$errs" || -n "$missing" ]] \
         || ! sed -n 's/^HIT //p' <<<"$out" | grep -qx -- "$can"; then
        echo "$label=ERROR (search incomplete: grep exit ${rc:-none}; the result is not a clean proof)"
        [[ -z "$missing" ]] || sed 's/^/  missing root: /' <<<"$missing"
        [[ -z "$errs" ]] || sed 's/^/  /' <<<"$errs"
        sed -n 's/^HIT //p' <<<"$out" | grep -qx -- "$can" || echo "  canary not found"
        bad=1
      elif [[ -z "$hits" ]]; then
        echo "$label=absent ($4)"
      fi
    }
    judge guest "$gcanary" "$guest_out" "${groots[*]}"
    # Host: the defaults are this run's paths and may not exist yet (each is reported);
    # paths named on the command line are required.
    canary_dir="$(mktemp -d)"; printf '%s' "$nonce" > "$canary_dir/canary"
    roots=("$canary_dir")
    for p in "$evidence" "$HOME/.c11-sandbox/runs/$run" "$HOME/.c11-sandbox/out/$run" "$HOME/c11h-run/logs" "$HOME/c11h-run/state"; do
      if [[ -e "$p" ]]; then roots+=("$p"); else echo "host_optional_root_absent=$p"; fi
    done
    host_out=""
    for p in "$@"; do
      if [[ -e "$p" ]]; then roots+=("$p"); else host_out+="MISSING $p"$'\n'; fi
    done
    o="$(mktemp)" e="$(mktemp)"; hrc=0
    /usr/bin/grep -rlF -D skip -f <(printf '%s\n%s\n' "$slice" "$nonce") -- "${roots[@]}" >"$o" 2>"$e" || hrc=$?
    host_out+="RC $hrc"$'\n'"$(sed 's/^/HIT /' "$o")"$'\n'"$(sed 's/^/ERR /' "$e")"
    rm -f "$o" "$e"
    judge host "$canary_dir/canary" "$host_out" "${roots[*]:1}"
    rm -rf "$canary_dir"
    slice=""
    (( bad == 0 )) && echo "verify_clean=pass" || { echo "verify_clean=FAIL"; exit 1; } ;;

  *) die "verbs: sh '<zsh>' | aqua-sh '<zsh>' | smoke | verify-clean [host paths...]" 2 ;;
esac
