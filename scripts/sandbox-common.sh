#!/usr/bin/env bash
# Library for scripts/sandbox-*.sh. The Tart host defaults to Atlas.
# Entry points are the sandbox-* scripts; sourcing this file is the other use.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "sandbox-common.sh is a library. Use scripts/sandbox-up.sh and the other sandbox-* scripts." >&2
  exit 1
fi

sandbox_die() {
  echo "sandbox: $*" >&2
  exit 1
}

sandbox_host_name() {
  local host="${C11_SANDBOX_HOST:-atlas}"
  case "$host" in
    local|localhost) printf '%s\n' local ;;
    *) printf '%s\n' "$host" ;;
  esac
}

sandbox_golden_name() {
  printf '%s\n' "${C11_SANDBOX_GOLDEN:-c11-sandbox-golden}"
}

sandbox_validate_token() {
  local label="$1" value="$2" pattern="$3"
  [[ "$value" =~ $pattern ]] || sandbox_die "$label is not a safe token: $value"
}

sandbox_validate_run_id() {
  local id="$1"
  sandbox_validate_token "run id" "$id" '^[A-Za-z0-9][A-Za-z0-9._-]{0,48}$'
  local vm="c11-sb-${id}"
  [[ "$vm" != "$(sandbox_golden_name)" ]] || sandbox_die "run id resolves to the golden image"
  case "$vm" in
    scanner-*) sandbox_die "run id resolves to a scanner VM" ;;
  esac
}

sandbox_vm_name() {
  printf 'c11-sb-%s\n' "$1"
}

# zsh that runs on the Tart host. Callers prepend it to a remote script.
sandbox_host_prelude() {
  local golden="${C11_SANDBOX_GOLDEN:-c11-sandbox-golden}"
  local guest="${C11_SANDBOX_GUEST_USER:-admin}"
  sandbox_validate_token "golden image" "$golden" '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
  sandbox_validate_token "guest user" "$guest" '^[A-Za-z_][A-Za-z0-9._-]{0,31}$'
  printf 'golden=%q\n' "$golden"
  printf 'guest_user=%q\n' "$guest"
  cat <<'ZSH'
zmodload zsh/datetime
root="$HOME/.c11-sandbox"
key="$HOME/.ssh/c11-sandbox"
known="$root/known_hosts"
mkdir -p "$root/runs" "$root/apps" "$root/out" "${known:h}"
touch "$known"

die() {
  print -u2 -- "sandbox: $*"
  exit 1
}

tart_bin() {
  if [[ -x /opt/homebrew/bin/tart ]]; then
    print -r -- /opt/homebrew/bin/tart
    return 0
  fi
  command -v tart
}

refuse_protected() {
  local name="$1"
  [[ "$name" != "$golden" ]] || die "refusing to operate on the golden image ($golden)"
  case "$name" in
    scanner-*) die "refusing to operate on scanner VM $name" ;;
  esac
  [[ "$name" == c11-sb-* ]] || die "refusing to operate on VM $name"
}

vm_field() {
  local want="$1" line tart
  tart="$(tart_bin)" || die "tart is not on PATH on this host"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == Source* ]] && continue
    local -a f
    f=("${(z)line}")
    [[ "${f[2]:-}" == "$want" ]] || continue
    print -r -- "${f[-1]}"
    return 0
  done < <("$tart" list)
  return 1
}

running_count() {
  local n=0 line tart state
  tart="$(tart_bin)" || die "tart is not on PATH on this host"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == Source* ]] && continue
    state="${line##* }"
    # A suspended guest can still hold one of the two macOS VM slots.
    [[ "$state" == stopped ]] || n=$((n + 1))
  done < <("$tart" list)
  print -r -- "$n"
}

meta_path() {
  print -r -- "$root/runs/$1/meta.env"
}

load_meta() {
  local run_id="$1" meta
  meta="$(meta_path "$run_id")"
  [[ -f "$meta" ]] || die "no metadata for run $run_id. Run sandbox-up.sh first."
  source "$meta"
  [[ -n "${VM:-}" ]] || die "metadata for $run_id has no VM"
  refuse_protected "$VM"
}

write_meta() {
  # Not named path: zsh ties path to PATH, and a local path clears PATH.
  local meta="$1"
  shift
  mkdir -p "${meta:h}"
  : > "$meta"
  local item k v
  for item in "$@"; do
    k="${item%%=*}"
    v="${item#*=}"
    printf '%s=%q\n' "$k" "$v" >> "$meta"
  done
}

emit_meta() {
  load_meta "$1"
  printf 'SOCKET=%q\n' "${SOCKET:-}"
  printf 'GUEST_APP=%q\n' "${GUEST_APP:-}"
  printf 'CLI=%q\n' "${CLI:-}"
  printf 'LOG=%q\n' "${LOG:-}"
  printf 'STDOUT=%q\n' "${STDOUT:-}"
  printf 'DSOCK=%q\n' "${DSOCK:-}"
  printf 'VM=%q\n' "${VM:-}"
  printf 'IP=%q\n' "${IP:-}"
}

guest_ip() {
  local vm="$1" tart ip
  tart="$(tart_bin)"
  ip="$("$tart" ip "$vm" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  [[ -n "$ip" ]] || die "no IP for $vm (is it running?)"
  print -r -- "$ip"
}

guest_ssh_opts() {
  [[ -f "$key" ]] || die "missing $key. Golden-image setup installs this key; scripts do not use a password."
  ssh-keygen -f "$known" -R "$1" >/dev/null 2>&1 || true
}

guest_ssh() {
  local ip="$1"
  guest_ssh_opts "$ip"
  ssh -i "$key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$known" \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=10 \
    -o LogLevel=ERROR \
    "${guest_user}@${ip}" 'exec /bin/zsh -s'
}

# stdin is a tar stream. Virtiofs turns framework symlinks (Sparkle, Sentry) into loops,
# so the .app is copied this way instead of being read from the share.
guest_receive_tar() {
  local ip="$1" dest="$2"
  guest_ssh_opts "$ip"
  ssh -i "$key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$known" \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=10 \
    -o LogLevel=ERROR \
    "${guest_user}@${ip}" \
    "mkdir -p $(printf '%q' "$dest") && /usr/bin/tar -xf - -C $(printf '%q' "$dest")"
}
ZSH
}

sandbox_on_host() {
  local host
  host="$(sandbox_host_name)"
  if [[ "$host" == "local" ]]; then
    PATH="/opt/homebrew/bin:${PATH:-/usr/bin:/bin}" /bin/zsh -s
    return
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=25 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o LogLevel=ERROR \
    "$host" 'PATH=/opt/homebrew/bin:$PATH exec /bin/zsh -s'
}

# Copy a tar stream into $HOME/<rel> on the Tart host. rel stays under .c11-sandbox.
sandbox_extract_tar() {
  local rel="$1"
  [[ "$rel" =~ ^\.c11-sandbox/[A-Za-z0-9._/-]+$ ]] || sandbox_die "refusing to extract outside .c11-sandbox ($rel)"
  local host
  host="$(sandbox_host_name)"
  if [[ "$host" == "local" ]]; then
    mkdir -p "${HOME}/${rel}"
    tar -xf - -C "${HOME}/${rel}"
    return
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=25 -o LogLevel=ERROR "$host" \
    "mkdir -p \"\$HOME/${rel}\" && tar -xf - -C \"\$HOME/${rel}\""
}

sandbox_fetch() {
  local rel="$1" dest="$2"
  [[ "$rel" =~ ^\.c11-sandbox/[A-Za-z0-9._/-]+$ ]] || sandbox_die "refusing to fetch outside .c11-sandbox ($rel)"
  local host
  host="$(sandbox_host_name)"
  mkdir -p "$(dirname "$dest")"
  if [[ "$host" == "local" ]]; then
    cp "${HOME}/${rel}" "$dest"
    return
  fi
  scp -o BatchMode=yes -o ConnectTimeout=25 -o LogLevel=ERROR "${host}:${rel}" "$dest"
}

sandbox_load_meta() {
  local run_id="$1" quoted
  sandbox_validate_run_id "$run_id"
  quoted="$(sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
emit_meta $(printf '%q' "$run_id")
EOF
)"
  # shellcheck disable=SC2086
  eval "$quoted"
}

# Run a guest zsh script for a run. The script is read from stdin.
sandbox_guest_script() {
  local run_id="$1" b64
  sandbox_validate_run_id "$run_id"
  b64="$(base64 | tr -d '\n')"
  [[ -n "$b64" ]] || sandbox_die "empty guest script"
  sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
load_meta $(printf '%q' "$run_id")
ip="\$(guest_ip "\$VM")"
{
  printf 'SANDBOX_RUN_ID=%q\n' $(printf '%q' "$run_id")
  printf 'SANDBOX_SOCKET=%q\n' "\${SOCKET:-}"
  printf 'SANDBOX_GUEST_APP=%q\n' "\${GUEST_APP:-}"
  printf 'SANDBOX_CLI=%q\n' "\${CLI:-}"
  printf 'SANDBOX_LOG=%q\n' "\${LOG:-}"
  printf 'SANDBOX_STDOUT=%q\n' "\${STDOUT:-}"
  printf 'SANDBOX_DSOCK=%q\n' "\${DSOCK:-}"
  printf 'SANDBOX_VM=%q\n' "\${VM:-}"
  printf 'SANDBOX_IP=%q\n' "\${IP:-}"
  print -r -- '${b64}' | /usr/bin/base64 -D
} | guest_ssh "\$ip"
EOF
}

# zsh functions pasted into the guest: launch and quit the sandboxed c11.
sandbox_guest_runtime_zsh() {
  cat <<'ZSH'
sandbox_quit_app() {
  # sudo: a launch that failed to drop uid leaves a root-owned c11, which
  # the SSH user cannot signal. Passwordless sudo is part of the golden image.
  /usr/bin/sudo -n /usr/bin/killall c11 2>/dev/null || true
  /usr/bin/sudo -n /usr/bin/killall cmux 2>/dev/null || true
  local i
  for i in {1..25}; do
    if ! pgrep -x c11 >/dev/null 2>&1 && ! pgrep -x cmux >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  /usr/bin/sudo -n /usr/bin/killall -9 c11 2>/dev/null || true
  /usr/bin/sudo -n /usr/bin/killall -9 cmux 2>/dev/null || true
}

sandbox_launch_app() {
  local app="$1" socket="$2" dbglog="$3" stdout="$4" dsock="$5"
  local bin="$app/Contents/MacOS/c11"
  [[ -x "$bin" ]] || bin="$app/Contents/MacOS/cmux"
  [[ -x "$bin" ]] || { print -u2 -- "no c11 binary in $app"; return 1 }
  mkdir -p "${dsock:h}" "$(dirname "$stdout")"
  # A root-owned socket from an earlier launch cannot be unlinked by the SSH user.
  /usr/bin/sudo -n /bin/rm -f "$socket" "$dsock"
  local uid user
  uid="$(id -u)"
  user="$(id -un)"
  # launchctl asuser enters the Aqua audit session only when run as root, and it
  # does not change uid. The second sudo drops to the console user so the socket
  # is theirs (the CLI refuses a socket it does not own) and TCC applies to them.
  # Passwordless sudo is part of the golden image. A password prompt would hang a run.
  /usr/bin/sudo -n /bin/launchctl asuser "$uid" \
    /usr/bin/sudo -n -u "$user" /usr/bin/env -i \
    HOME="$HOME" \
    USER="$user" \
    LOGNAME="$user" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    C11_SOCKET_MODE=automation \
    C11_ALLOW_SOCKET_OVERRIDE=1 \
    C11_SOCKET="$socket" \
    C11_SOCKET_PATH="$socket" \
    CMUXD_UNIX_PATH="$dsock" \
    C11_DEBUG_LOG="$dbglog" \
    C11_QA_LAUNCH=fresh \
    /bin/zsh -c 'nohup "$1" > "$2" 2>&1 & echo $!' _ "$bin" "$stdout" >/dev/null
  local i
  for i in {1..90}; do
    [[ -S "$socket" ]] && return 0
    sleep 1
  done
  print -u2 -- "socket $socket did not appear"
  [[ -f "$stdout" ]] && tail -n 50 "$stdout" >&2
  [[ -f "$dbglog" ]] && tail -n 50 "$dbglog" >&2
  return 1
}
ZSH
}
