#!/bin/sh
# C11H-16: install c11's relay `c11` on the machine c11 links to (the build host),
# beside ticket 11's pinned hc. Run it there.
#
#   c11-atlas-relay.sh install --session S [--shards N] --cli <c11 CLI binary>
#   c11-atlas-relay.sh uninstall --session S [--shards N]
#
# --shards N (1-8, C11H-78) acts on the shard sessions S-s1 .. S-sN instead
# of S: each shard pair has its own relay folder and manifest, and removing
# one never touches another.
#
# Writes only $HOME/.local/share/c11/relay/<S>/:
#   c11-relay.app/  the kit (C11H-134): Contents/Resources/bin/c11, the c11
#                    CLI binary (same build as the app), and, when they sit
#                    beside --cli in the app, its Info.plist, its c11 skill, its
#                    Claude wrapper and note files; laid out as an app so
#                    `c11 guide` here names this build
#   bin/c11, bin/c11h  shims that run the kit's CLI in relay mode for session S
#   bin/codex        C11H-123: runs the next codex on PATH; an interactive one
#                    gets a per-launch notify flag that reports its turn end
#   libexec/claude   C11H-134: runs the kit's Claude wrapper, which in a c11
#                    terminal here adds c11's per-launch hooks and note
#   bin/claude       runs libexec/claude, whenever the kit carries the Claude
#                    wrapper. The kit owns this path: a bin/claude it did not
#                    write is moved to set-aside/ with a one-line note, never
#                    kept in front of c11's (a hand-written one that exported
#                    an account token outlived that account on 2026-11-03).
#                    The wrapper runs the next claude on PATH, so an account
#                    choice or pool shim belongs there, outside this folder.
#   zdotdir/.zsh*    zsh startup files: each sources the user's own file, then
#                    puts bin/ first on PATH (after path_helper and the user's
#                    own PATH edits, which on this machine put c11's CLI first)
#   bash/rc          C11H-392: bash has no ZDOTDIR, so a c11 terminal whose
#                    shell is bash (a Linux machine's) starts `bash --rcfile
#                    bash/rc -i`: it reads what a login bash reads
#                    (/etc/profile, then the first of ~/.bash_profile,
#                    ~/.bash_login, ~/.profile), then puts bin/ first on PATH
#   no-socket        a regular file; c11 terminals point C11_SOCKET_PATH and
#                    CMUX_SOCKET_PATH at it so any other c11 fails closed
#   manifest.json    what c11 reads when the link comes up; its "files" lists
#                    the paths above, the only files this script ever writes or
#                    removes
#
# The manifest's "file_sha256" records what each of those files was when
# written, and "self_sha256" what the manifest itself was. A file counts as the installer's only while it still matches: one
# replaced or edited since, a symlink, or anything else in the folder is left
# in place, and install and uninstall say so; bin/claude is the one exception
# (above). Install refuses, writing nothing in any requested session, when one of
# its own paths in any of them holds a file that is not its own. A manifest
# from before "files" owns exactly the paths it wrote, its libexec/c11 checked
# against cli_sha256. libexec/c11 (the CLI before the kit) is retired: an
# install removes it once the new shims are written, while it is still ours.
#
# Only c11's terminals on this machine get ZDOTDIR and the socket variables
# (c11 passes them when it starts the terminal). Nothing is written to the
# user's shell files, ~/.ssh, herdr-app's install or c11's. c11 serves only
# calls signed with a c11 terminal's own credential (relay protocol 2,
# C11H-176); see docs/c11-relay.md for what that does and does not stop.
set -eu

die() { printf 'c11-atlas-relay: %s\n' "$1" >&2; exit 2; }

session_ok() {
  printf '%s' "$1" | grep -Eq '^c11(-[A-Za-z0-9][A-Za-z0-9._-]*)?$'
}

safe_path() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/@ -]+$' || return 1
  case "$1" in *..*) return 1 ;; /*) return 0 ;; *) return 1 ;; esac
}

LEGACY_OWNED='libexec/c11 bin/c11 zdotdir/.zshenv zdotdir/.zprofile zdotdir/.zshrc zdotdir/.zlogin no-socket manifest.json'
# Always written. The kit's files, libexec/claude and a bin/claude this
# installer wrote are owned too, each listed in the manifest with its hash.
OWNED='bin/c11 bin/c11h bin/codex zdotdir/.zshenv zdotdir/.zprofile zdotdir/.zshrc zdotdir/.zlogin bash/rc no-socket manifest.json'
KIT=c11-relay.app
KIT_BIN=$KIT/Contents/Resources/bin
RETIRED='libexec/c11'
claude_marker='# c11 relay claude entry'

# Linux may have sha256sum and no shasum (Debian ships shasum in the full perl package).
sha256() { if [ -x /usr/bin/shasum ]; then /usr/bin/shasum -a 256 "$@"; else sha256sum "$@"; fi; }
sha_of() { sha256 "$1" | /usr/bin/awk '{print $1}'; }

# What an earlier install recorded as its own, one "<path> <sha256|->" per
# line; nothing when there is no manifest or it is not one of ours. A manifest
# is ours only when its "self_sha256" is the hash of its own bytes with that
# field emptied, so an edited manifest owns nothing. "-" marks the manifest
# (verified that way) and the paths of a manifest from before "files", which
# owns them by path (its libexec/c11 is checked against cli_sha256). Only a
# manifest with none of files, file_sha256 or self_sha256 is that old one.
owned_before() { # <root> <session>
  [ -f "$1/manifest.json" ] && [ ! -L "$1/manifest.json" ] || return 0
  legacy_codex_sha=$(bin="$1/bin"; codex_file | sha256 | /usr/bin/awk '{print $1}')
  bashrc_sha=$(bin="$1/bin"; bash_rc | sha256 | /usr/bin/awk '{print $1}')
  /usr/bin/python3 -I - "$1/manifest.json" "$2" "$OWNED" "$LEGACY_OWNED" "$legacy_codex_sha" "$bashrc_sha" <<'PY'
import json, sys
import hashlib, re
path, session, owned = sys.argv[1], sys.argv[2], sys.argv[3].split()
try:
    raw = open(path, "rb").read()
    m = json.loads(raw)
except Exception:
    sys.exit(0)
if not isinstance(m, dict) or m.get("relay_protocol") not in (1, 2) or m.get("session") != session:
    sys.exit(0)
# Only a manifest with none of the current fields is from before "files";
# one that carries any of them is current and must pass every check below.
if not any(k in m for k in ("files", "file_sha256", "self_sha256")):
    for f in sys.argv[4].split():
        sha = m.get("cli_sha256") if f == "libexec/c11" else None
        print(f, sha if isinstance(sha, str) else "-")
    # The newer Codex shim was not in the legacy ownership list. Adopt it
    # only if it matches the exact generated bytes, never by path alone.
    print("bin/codex", sys.argv[5])
    sys.exit(0)
files, hashes, own = m.get("files"), m.get("file_sha256"), m.get("self_sha256")
if not isinstance(files, list) or not isinstance(hashes, dict) or not isinstance(own, str):
    sys.exit(0)
field = b'"self_sha256":"' + own.encode() + b'"'
if not re.fullmatch(r"[0-9a-f]{64}", own) or raw.count(field) != 1:
    sys.exit(0)
if hashlib.sha256(raw.replace(field, b'"self_sha256":""')).hexdigest() != own:
    sys.exit(0)
# Every path a verified manifest lists was written by this installer.
for f in files:
    if not isinstance(f, str) or f.startswith("/") or ".." in f or not re.fullmatch(r"[A-Za-z0-9._/@ -]+", f):
        continue
    sha = hashes.get(f)
    if f == "manifest.json":
        print(f, "-")
    elif isinstance(sha, str) and len(sha) == 64:
        print(f, sha)
# C11H-392: an installer from before bash/rc, run over a newer kit, leaves
# bash/rc out of its manifest. Adopt it only if it holds exactly the bytes
# this installer writes, never by path alone.
if "bash/rc" not in files:
    print("bash/rc", sys.argv[6])
PY
}

# Never follow a symlink in the relay path, including directory components.
# HOME itself is supplied by the operator; all descendants must be real paths.
real_path() { # <absolute path beneath HOME>
  checked=$1
  while [ "$checked" != "$HOME" ]; do
    [ ! -L "$checked" ] || return 1
    parent=${checked%/*}
    [ -n "$parent" ] && [ "$parent" != "$checked" ] || return 1
    checked=$parent
  done
}

# Is <root>/<rel> still the file the installer wrote? A symlink never is.
is_ours() { # <root> <rel> <owned>
  real_path "$1/$2" || return 1
  [ -f "$1/$2" ] && [ ! -L "$1/$2" ] || return 1
  rec=$(printf '%s\n' "$3" | /usr/bin/awk -v r="$2" '$1 == r { print $2; exit }')
  [ -n "$rec" ] || return 1
  [ "$rec" = - ] && return 0
  [ "$(sha_of "$1/$2")" = "$rec" ]
}

# Every file left under <root>, relative, one per line.
files_under() { # <root>
  [ -d "$1" ] || return 0
  (cd "$1" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
}

note_left() { # <root> <owned records>: name each file that stays because it is not the installer's
  known=" $OWNED $(printf '%s\n' "$2" | /usr/bin/awk '{printf "%s ", $1}')"
  files_under "$1" | while read -r rel; do
    case "$known" in
      *" $rel "*) printf 'c11-atlas-relay: leaving %s/%s: changed since install, not the file this installer wrote\n' "$1" "$rel" >&2 ;;
      *) printf 'c11-atlas-relay: leaving %s/%s: not written by this installer\n' "$1" "$rel" >&2 ;;
    esac
  done
}

root_for() {
  printf '%s/.local/share/c11/relay/%s' "$HOME" "$1"
}

write_file() { # <path> <mode>  (content on stdin), swapped in whole
  tmp="$1.tmp.$$"
  cat > "$tmp"
  chmod "$2" "$tmp"
  mv -f "$tmp" "$1"
}

zsh_file() { # <name>: one zdotdir startup file
  name=$1
  cat <<EOF
# c11 relay (prototype, Settled 9), written by scripts/c11-atlas-relay.sh.
# Only c11 terminals on this machine set ZDOTDIR to this folder. This file
# sources your own $name, then puts c11's relay c11 first on PATH.
_c11_relay_user=\${_c11_relay_user:-\$HOME}
ZDOTDIR=\$_c11_relay_user
[[ -f \$_c11_relay_user/$name ]] && source \$_c11_relay_user/$name
EOF
  if [ "$name" = .zshenv ]; then
    cat <<'EOF'
# Your .zshenv may move ZDOTDIR; later files are then read from there.
[[ -n ${ZDOTDIR:-} && $ZDOTDIR != "$HOME" ]] && _c11_relay_user=$ZDOTDIR
EOF
  fi
  cat <<EOF
ZDOTDIR='$zdotdir'
export ZDOTDIR
path=('$bin' \${path:#'$bin'})
export PATH
EOF
  if [ "$name" = .zshrc ]; then
    cat <<EOF
# Prompt hooks (mise, direnv) may edit PATH later; keep the relay first.
_c11_relay_first() { [[ \${path[1]} == '$bin' ]] || path=('$bin' \${path:#'$bin'}); }
autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _c11_relay_first
EOF
  fi
}

# C11H-392: bash's startup file for c11 terminals here. c11's launch line
# starts `bash --rcfile <this> -i` only when the terminal's SHELL is bash and
# the manifest names this file (C11_RELAY_BASHRC). It reads what a login bash
# reads, then puts the relay's bin first, and keeps it first after prompt
# hooks (mise, direnv) edit PATH: its fixer runs after theirs, at every
# prompt. The shell is interactive, not a login shell: `logout` asks for
# `exit`, and ~/.bash_logout is not read.
bash_rc() {
  cat <<EOF
# c11 relay, written by scripts/c11-atlas-relay.sh (C11H-392).
# Only c11 terminals on this machine start bash with this file. It reads what a
# login bash reads, then puts c11's relay c11 first on PATH.
unset C11_RELAY_BASHRC
[ -r /etc/profile ] && . /etc/profile
for _c11_relay_f in "\$HOME/.bash_profile" "\$HOME/.bash_login" "\$HOME/.profile"; do
  if [ -r "\$_c11_relay_f" ]; then . "\$_c11_relay_f"; break; fi
done
unset _c11_relay_f
_c11_relay_first() {
  case ":\$PATH:" in ":$bin:"*) return 0 ;; esac
  local IFS=: p= d
  for d in \$PATH; do [ "\$d" = '$bin' ] || p=\$p\${p:+:}\$d; done
  PATH='$bin'\${p:+:\$p}
  export PATH
}
_c11_relay_first
# The fixer runs after the prompt hooks your files registered (mise, direnv),
# so their PATH edits never put another c11 or claude ahead of the relay's.
# bash 5.1 and later run every element of an array PROMPT_COMMAND: it is
# appended as the last one. A string gets it on a new line, which also keeps
# a value that ends in ';' (history -a;) valid.
_c11_relay_pc=\$(declare -p PROMPT_COMMAND 2>/dev/null)
if [ "\${_c11_relay_pc#declare -a}" != "\$_c11_relay_pc" ] && (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 501 )); then
  PROMPT_COMMAND+=(_c11_relay_first)
else
  PROMPT_COMMAND="\${PROMPT_COMMAND:+\$PROMPT_COMMAND
}_c11_relay_first"
fi
unset _c11_relay_pc
EOF
}

shard_sessions() { # <session> <shards or empty>: the sessions to act on
  if [ -z "$2" ]; then printf '%s\n' "$1"; return; fi
  n=1
  while [ "$n" -le "$2" ]; do printf '%s-s%s\n' "$1" "$n"; n=$((n + 1)); done
}

codex_file() { # C11H-123: bin/codex, so Codex's own turn end reaches c11
  cat <<EOF
#!/bin/sh
# c11 relay codex (prototype, Settled 9), written by scripts/c11-atlas-relay.sh.
# C11H-123: an interactive Codex in a c11 terminal on this machine reports its
# own turn end to c11, so a Codex idle at its prompt with a background
# terminal still running reads idle there. It adds Codex's per-launch notify
# flag (-c notify=...) and nothing else: no file, nothing in ~/.codex. A
# notify you pass on the command line comes later in argv and wins.
relay_bin='$bin'
EOF
  cat <<'CODEX'
if [ "${1:-}" = __c11-relay-notify ]; then
  # Codex runs this after each completed turn, with its JSON payload as $2.
  # Codex serializes the payload with its type first; match only that, so
  # text inside a message can never pass for a turn end.
  case "${2:-}" in
    '{"type":"agent-turn-complete"'*|'{"type": "agent-turn-complete"'*) ;;
    *) exit 0 ;;
  esac
  panel=${C11_PANEL_ID:-${CMUX_PANEL_ID:-}}
  workspace=${C11_WORKSPACE_ID:-${CMUX_WORKSPACE_ID:-}}
  uuid='^[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}$'
  printf '%s' "$panel" | grep -q "$uuid" || exit 0
  printf '%s' "$workspace" | grep -q "$uuid" || exit 0
  [ -x "$relay_bin/c11" ] || exit 0
  event=$(/usr/bin/uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
  printf '%s' "$event" | grep -q "$uuid" || exit 0
  # Milliseconds: hc dates a status to the millisecond on this machine.
  now=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time() * 1000' 2>/dev/null)
  case "$now" in ''|*[!0-9]*) now=$(( $(date +%s) * 1000 )) ;; esac
  printf '{"schema_version":1,"event_id":"%s","kind":"agent.turn.completed","emitted_at_ms":%s,"panel_id":"%s","workspace_id":"%s","agent_kind":"codex","source":"hook","adapter":"codex_notify","native_event":"agent-turn-complete"}' \
    "$event" "$now" "$panel" "$workspace" | "$relay_bin/c11" agent-event append --stdin >/dev/null 2>&1
  exit 0
fi

real=
old_ifs=$IFS; IFS=:
for dir in $PATH; do
  [ "$dir" = "$relay_bin" ] && continue
  if [ -x "$dir/codex" ] && [ ! -d "$dir/codex" ]; then real=$dir/codex; break; fi
done
IFS=$old_ifs
[ -n "$real" ] || { echo "Error: codex not found in PATH" >&2; exit 127; }

# Only the interactive Codex that owns this terminal reports: never a Codex
# it starts itself, a subcommand, or a run that does not read the terminal.
interactive=1
[ -n "${C11_RELAY_CODEX_WRAPPER_REENTRY:-}" ] && interactive=0
case "${1:-}" in
  exec|e|review|login|logout|mcp|mcp-server|app-server|app|completion|sandbox|debug|apply|cloud|exec-server|features|plugin|help|--help|-h|--version|-V|-VV) interactive=0 ;;
esac
{ [ -t 0 ] && [ -t 1 ]; } || interactive=0
[ -x "$relay_bin/c11" ] || interactive=0
C11_RELAY_CODEX_WRAPPER_REENTRY=1
export C11_RELAY_CODEX_WRAPPER_REENTRY
if [ "$interactive" = 1 ]; then
  exec "$real" -c "notify=[\"$relay_bin/codex\",\"__c11-relay-notify\"]" "$@"
fi
exec "$real" "$@"
CODEX
}

cmd_install() {
  session= cli= shards=
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session=$2; shift 2 ;;
      --shards) shards=$2; shift 2 ;;
      --cli) cli=$2; shift 2 ;;
      *) die "unknown install option: $1" ;;
    esac
  done
  session_ok "$session" || die "bad session: $session (c11 or c11-<tag>; never default)"
  # Checked here: a die inside $(shard_sessions) would end only its subshell.
  [ -z "$shards" ] || printf '%s' "$shards" | grep -Eq '^[1-8]$' || die "--shards must be 1 to 8"
  [ -f "$cli" ] && [ -x "$cli" ] || die "--cli must be the c11 CLI binary"
  safe_path "$HOME" || die "HOME is not a plain absolute path"
  for each in $(shard_sessions "$session" "$shards"); do
    session_ok "$each" || die "bad session: $each"
  done
  # Every requested session is checked before any is written: a conflict in
  # one leaves all of them as they were.
  for each in $(shard_sessions "$session" "$shards"); do
    preflight_one "$each"
  done
  for each in $(shard_sessions "$session" "$shards"); do
    install_one "$each" "$cli"
  done
}

kit_plan() { # one "<relative path> <source>" per line: the kit after this install
  # (uses $root and $owned). Each part comes from the app around --cli; a part a
  # standalone --cli does not bring is kept as the earlier install left it, while
  # it is still the installer's own ("=keep"), so the shims and Claude entry it
  # serves never name a removed file.
  src_dir=$(dirname "$cli")
  printf '%s %s\n' "$KIT_BIN/c11" "$cli"
  if [ -f "$src_dir/../../Info.plist" ]; then
    printf '%s %s\n' "$KIT/Contents/Info.plist" "$src_dir/../../Info.plist"
  elif is_ours "$root" "$KIT/Contents/Info.plist" "$owned"; then
    printf '%s =keep\n' "$KIT/Contents/Info.plist"
  fi
  if [ -f "$src_dir/../skills/c11/SKILL.md" ]; then
    (cd "$src_dir/../skills/c11" && find . -type f | sed 's|^\./||' | sort) | while read -r rel; do
      printf '%s %s\n' "$KIT/Contents/Resources/skills/c11/$rel" "$src_dir/../skills/c11/$rel"
    done
  else
    printf '%s\n' "$owned" | while read -r rel _; do
      case "$rel" in "$KIT/Contents/Resources/skills/"*) ;; *) continue ;; esac
      if is_ours "$root" "$rel" "$owned"; then printf '%s =keep\n' "$rel"; fi
    done
  fi
  if has_claude; then
    for name in claude c11-agent-note.sh c11-agent-note.txt; do printf '%s %s\n' "$KIT_BIN/$name" "$src_dir/$name"; done
  elif is_ours "$root" "$KIT_BIN/claude" "$owned" && is_ours "$root" "$KIT_BIN/c11-agent-note.sh" "$owned" &&
       is_ours "$root" "$KIT_BIN/c11-agent-note.txt" "$owned"; then
    for name in claude c11-agent-note.sh c11-agent-note.txt; do printf '%s =keep\n' "$KIT_BIN/$name"; done
  fi
}

has_claude() { # the app's Claude wrapper and its note files sit beside --cli
  for name in claude c11-agent-note.sh c11-agent-note.txt; do [ -f "$(dirname "$cli")/$name" ] || return 1; done
}

kit_has_claude() { # <plan>: the kit after this install carries the Claude wrapper
  printf '%s\n' "$1" | /usr/bin/awk -v r="$KIT_BIN/claude" '$1 == r { found = 1 } END { exit !found }'
}

relay_stub() { # bin/c11 and bin/c11h: the kit's CLI in relay mode for this session
  cat <<EOF
#!/bin/sh
# c11 relay (prototype, Settled 9): c11 in a c11 terminal on this machine
# reaches c11 through hc's link to it. Session $session.
C11_RELAY_HC_SOCKET='$hc_socket'
C11_RELAY_SESSION='$session'
export C11_RELAY_HC_SOCKET C11_RELAY_SESSION
exec '$root/$KIT_BIN/c11' "\$@"
EOF
}

claude_entry() { # C11H-134: libexec/claude, the stable way into the kit's Claude wrapper
  cat <<EOF
#!/bin/sh
# c11 claude wrapper: $claude_marker (prototype, Settled 9), written by
# scripts/c11-atlas-relay.sh. Session $session. Runs c11's Claude wrapper,
# which in a c11 terminal here adds c11's per-launch hooks file (in \$TMPDIR)
# and note; the hooks reach c11 through bin/c11. Nothing is written in
# ~/.claude. The wrapper then runs the next claude on PATH (your own shim or
# account pool, if you have one); whatever it exports passes through untouched.
C11_RELAY_BIN=\${C11_RELAY_BIN:-'$bin'}
export C11_RELAY_BIN
exec '$root/$KIT_BIN/claude' "\$@"
EOF
}

preflight_one() { # <session>: die, writing nothing, if an installer path holds a file not ours
  root=$(root_for "$1")
  owned=$(owned_before "$root" "$1")
  if [ -z "$owned" ] && { [ -e "$root/manifest.json" ] || [ -L "$root/manifest.json" ]; }; then
    die "$root/manifest.json exists and is not one this installer wrote (edited since, or foreign); nothing written"
  fi
  plan=$(kit_plan)
  will=$(printf '%s\n' $OWNED; printf '%s\n' "$plan" | /usr/bin/awk '{print $1}'; if kit_has_claude "$plan"; then echo libexec/claude; fi)
  for rel in $will; do
    real_path "$root/$rel" || die "$root/$rel exists through a symlink; nothing written"
    if [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; then
      is_ours "$root" "$rel" "$owned" || die "$root/$rel exists and this installer did not write it (or it changed since); nothing written"
    fi
  done
  real_path "$root/bin/claude" || die "$root/bin/claude exists through a symlink; nothing written"
  # A retired path still holding a file is checked as before: never ours, no install.
  for rel in $RETIRED; do
    if [ -e "$root/$rel" ] || [ -L "$root/$rel" ]; then
      is_ours "$root" "$rel" "$owned" || die "$root/$rel exists and this installer did not write it (or it changed since); nothing written"
    fi
  done
}

install_one() { # <session> <cli>
  session=$1 cli=$2
  root=$(root_for "$session")
  bin=$root/bin
  zdotdir=$root/zdotdir
  sentinel=$root/no-socket
  hc_socket=$HOME/.local/share/c11/run/$session.sock
  sha=$(sha_of "$cli")
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || die "could not hash $cli"
  owned=$(owned_before "$root" "$session")

  umask 077
  mkdir -p "$bin" "$zdotdir" "$root/bash" "$root/$KIT_BIN"
  # The kit first, so the shims below never name a file not yet there.
  plan=$(kit_plan)
  printf '%s\n' "$plan" | while read -r rel src; do
    [ "$src" = =keep ] && continue
    mkdir -p "$root/${rel%/*}"
    case "$rel" in
      "$KIT_BIN/c11")
        [ -f "$root/$rel" ] && [ "$(sha_of "$root/$rel")" = "$sha" ] || write_file "$root/$rel" 755 < "$src" ;;
      "$KIT_BIN/claude") write_file "$root/$rel" 755 < "$src" ;;
      *) write_file "$root/$rel" 644 < "$src" ;;
    esac
  done
  # Kit files an earlier build brought and this one does not.
  printf '%s\n' "$owned" | while read -r rel _; do
    case "$rel" in "$KIT"/*) ;; *) continue ;; esac
    printf '%s\n' "$plan" | /usr/bin/awk -v r="$rel" '$1 == r { found = 1 } END { exit !found }' && continue
    if is_ours "$root" "$rel" "$owned"; then rm -f "$root/$rel"; fi
  done
  find "$root/$KIT" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
  relay_stub | write_file "$bin/c11" 755
  relay_stub | write_file "$bin/c11h" 755
  codex_file | write_file "$bin/codex" 755
  for name in .zshenv .zprofile .zshrc .zlogin; do
    zsh_file "$name" | write_file "$zdotdir/$name" 644
  done
  bash_rc | write_file "$root/bash/rc" 644
  write_file "$sentinel" 600 <<'EOF'
Not a socket. c11 terminals point C11_SOCKET_PATH here so that a c11 CLI
other than c11's relay fails closed instead of reaching this machine's c11.
EOF
  extra=
  if kit_has_claude "$plan"; then
    mkdir -p "$root/libexec"
    claude_entry | write_file "$root/libexec/claude" 755
    extra=libexec/claude
    # The kit owns bin/claude: one it did not write would win over c11's
    # wrapper in every c11 terminal here, silently, for as long as it lives.
    if [ -e "$bin/claude" ] && ! is_ours "$root" bin/claude "$owned"; then
      aside=$root/set-aside/claude.$(date +%Y%m%d-%H%M%S)
      [ ! -e "$aside" ] || aside=$aside.$$
      mkdir -p "$root/set-aside"
      /bin/mv -f "$bin/claude" "$aside"
      printf 'c11-atlas-relay: moved %s (not written by this installer) to %s; c11 terminals here now run the next claude on PATH through c11'"'"'s wrapper (a shim of yours there must not exec %s: drop that line)\n' \
        "$bin/claude" "$aside" "$root/libexec/claude"
    fi
    write_file "$bin/claude" 755 <<EOF
#!/bin/sh
# c11 claude wrapper: $claude_marker (prototype, Settled 9), written by
# scripts/c11-atlas-relay.sh. c11 owns this file and replaces it on install;
# put your own claude shim on PATH outside this folder instead.
exec '$root/libexec/claude' "\$@"
EOF
    extra="$extra bin/claude"
  else
    # No Claude wrapper in the kit: its entry goes, and so does a bin/claude
    # this installer wrote, which would name the removed entry.
    if is_ours "$root" libexec/claude "$owned"; then rm -f "$root/libexec/claude"; fi
    if is_ours "$root" bin/claude "$owned"; then rm -f "$bin/claude"; fi
    [ -e "$root/libexec/claude" ] || note_broken_chain "$root"
  fi
  # Retired paths go only after the shims above no longer name them.
  for rel in $RETIRED; do if is_ours "$root" "$rel" "$owned"; then rm -f "$root/$rel"; fi; done
  rmdir "$root/libexec" 2>/dev/null || true
  files=$(printf '%s\n' $OWNED $extra; printf '%s\n' "$plan" | /usr/bin/awk '{print $1}')
  hashes=
  for rel in $files; do
    [ "$rel" = manifest.json ] && continue
    hashes="$hashes${hashes:+,}\"$rel\":\"$(sha_of "$root/$rel")\""
  done
  kit_version=$(/usr/bin/plutil -extract C11Version raw -o - "$root/$KIT/Contents/Info.plist" 2>/dev/null) || kit_version=
  # Linux has no plutil: read an XML Info.plist's C11Version directly (C11H-191).
  [ -n "$kit_version" ] || kit_version=$(sed -n '/<key>C11Version<\/key>/{n;s/.*<string>\([A-Za-z0-9._-]*\)<\/string>.*/\1/p;}' "$root/$KIT/Contents/Info.plist" 2>/dev/null | head -1)
  printf '%s' "$kit_version" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || kit_version=
  # The manifest carries the hash of its own bytes with self_sha256 empty.
  body="{\"relay_protocol\":2,\"session\":\"$session\",\"home\":\"$HOME\",\"bin\":\"$bin\",\"zdotdir\":\"$zdotdir\",\"bashrc\":\"$root/bash/rc\",\"sentinel\":\"$sentinel\",\"cli_sha256\":\"$sha\",\"kit_version\":\"$kit_version\",\"files\":[$(printf '"%s",' $files | sed 's/,$//')],\"file_sha256\":{$hashes},\"self_sha256\":\"\"}"
  self=$(printf '%s\n' "$body" | sha256 | /usr/bin/awk '{print $1}')
  printf '%s\n' "$body" | sed "s/\"self_sha256\":\"\"/\"self_sha256\":\"$self\"/" | write_file "$root/manifest.json" 600
  note_left_foreign "$root" "$files"
  printf 'c11-atlas-relay: installed session %s at %s (cli %s)\n' "$session" "$root" "$sha"
}

note_broken_chain() { # <root>: C11H-134: a kept shim of yours still runs the removed Claude entry
  if [ -f "$1/bin/claude" ] && [ ! -e "$1/libexec/claude" ] && grep -Fq "$1/libexec/claude" "$1/bin/claude" 2>/dev/null; then
    printf 'c11-atlas-relay: %s still runs %s, which is removed: point its last line back at your own claude\n' \
      "$1/bin/claude" "$1/libexec/claude" >&2
  fi
}

note_left_foreign() { # <root> <files>: after an install every installer path is ours; name the rest
  known=" $(printf '%s ' $2)"
  files_under "$1" | while read -r rel; do
    case "$known" in *" $rel "*) ;; *) printf 'c11-atlas-relay: leaving %s/%s: not written by this installer\n' "$1" "$rel" >&2 ;; esac
  done
}

cmd_uninstall() {
  session= shards=
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session=$2; shift 2 ;;
      --shards) shards=$2; shift 2 ;;
      *) die "unknown uninstall option: $1" ;;
    esac
  done
  session_ok "$session" || die "bad session: $session"
  # Checked here: a die inside $(shard_sessions) would end only its subshell.
  [ -z "$shards" ] || printf '%s' "$shards" | grep -Eq '^[1-8]$' || die "--shards must be 1 to 8"
  for each in $(shard_sessions "$session" "$shards"); do
    session_ok "$each" || die "bad session: $each"
  done
  for each in $(shard_sessions "$session" "$shards"); do
    uninstall_one "$each"
  done
}

uninstall_one() { # <session>
  root=$(root_for "$1")
  case "$root" in */.local/share/c11/relay/c11*) ;; *) die "refusing $root" ;; esac
  if ! real_path "$root"; then
    printf 'c11-atlas-relay: leaving %s: symlinked relay path; nothing removed\n' "$root" >&2
    return 0
  fi
  owned=$(owned_before "$root" "$1")
  if [ -z "$owned" ]; then
    [ -e "$root" ] && note_left "$root" ""
    printf 'c11-atlas-relay: no install of session %s at %s; nothing removed\n' "$1" "$root"
    return 0
  fi
  # Only files still as the installer wrote them; the manifest goes last, so
  # an interrupted uninstall can run again.
  printf '%s\n' "$owned" | while read -r rel _; do
    [ -n "$rel" ] && [ "$rel" != manifest.json ] || continue
    if is_ours "$root" "$rel" "$owned"; then rm -f "$root/$rel"; fi
  done
  is_ours "$root" manifest.json "$owned" && rm -f "$root/manifest.json"
  find "$root" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
  note_left "$root" "$owned"
  note_broken_chain "$root"
  printf 'c11-atlas-relay: removed the installer'"'"'s files for session %s at %s\n' "$1" "$root"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  install) cmd_install "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  *) die "usage: c11-atlas-relay.sh install --session S [--shards N] --cli BIN | uninstall --session S [--shards N]" ;;
esac
