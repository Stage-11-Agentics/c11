#!/usr/bin/env bash
# Logged-in agent tabs (Claude Code, Codex, Grok) inside a sandbox guest's c11.
# Usage: scripts/sandbox-agent.sh <run-id> <stage|launch|screen|c11|wipe|verify-clean> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/sandbox-agent.sh <run-id> <command> [args...]

Agents run inside the guest that sandbox-up.sh started. Every command below
reaches the guest over SSH through the Tart host. Nothing runs on, or takes
focus on, the machine where this script is invoked.

  stage [claude,codex,grok]
      Copy the Tart host's installed agent CLIs into the guest and stage one
      access credential per kind, exported on the Tart host by the Overwatch
      seat launcher (seat.sh export-cred). Default: all three. Run it again to
      refresh credentials (Grok tokens last about 6 hours).
      sandbox-up.sh --agents runs this for you.

  launch <claude|codex|grok> <brief-file> [--title T] [--model M] [--effort E]
         [--workspace REF] [--address A] [--no-push] [--no-wait] [--timeout S]
      Copy the brief into the guest and launch a typed agent tab in the guest
      c11 with `c11 launch-agent --prompt-file`, so the agent is told to read
      the file. Sets mailbox.address (default: the title) and, unless
      --no-push, mailbox.delivery=stdin. Steps known first-run screens and
      waits until the agent's composer is up (default 180 s).
      Prints tab=, workspace=, tab_id=, workspace_id=, ready=.

  screen <tab> [--workspace REF] [--lines N]
      The guest tab's screen text (c11 read-screen).

  c11 <c11 arguments...>
      Any guest c11 command against the guest socket, for example
        c11 tree --no-layout
        c11 new-tab --workspace workspace:2 --no-focus
        c11 send --workspace workspace:2 --tab tab:12 --raw --no-submit "hello wor"
      Mailbox commands need a sender tab, so run them in a guest shell tab:
        c11 send --workspace workspace:2 --tab tab:12 "c11 mailbox send --to lc-claude --body 'reply PONG'"

  wipe
      Delete the staged credentials inside the guest. sandbox-down.sh calls
      this before it deletes the clone; deleting the clone is what removes
      them for good.

  verify-clean [--control]
      With --control, while the clone is up: the same search must find the
      staged values on the clone's own disk, which proves it can see guest
      files. Without it, after sandbox-down.sh: the clone is gone, and neither the golden image's
      disk nor the host's .c11-sandbox tree contains the credentials this run
      staged. Re-exports them on the Tart host and searches with the values
      fed through a pipe; prints only found/absent.

Credentials never touch this machine. They are exported on the Tart host,
sent to the guest on SSH stdin, and written there as mode 600 files. The
golden image is never booted or written. Overwatch's seat.sh is read from
C11_SANDBOX_SEAT_SH on the Tart host (default
~/Projects/Stage11/code/overwatch/launcher/seat.sh). C11_SANDBOX_CLAUDE_ACCOUNT
names the Claude call-sign (default: seat.sh's).
EOF
}

sandbox_validate_kinds() {
  local list="$1" k
  [[ -n "$list" ]] || sandbox_die "no agent kinds given"
  local IFS=,
  for k in $list; do
    case "$k" in
      claude|codex|grok) ;;
      *) sandbox_die "unknown agent kind '$k'. Kinds: claude, codex, grok." ;;
    esac
  done
}

# zsh for the Tart host: credential export and the secret-free summaries of it.
# These scripts run as `zsh -s` with the script on stdin, so any child that might
# read stdin gets </dev/null, or it would swallow the rest of the script.
sandbox_agent_host_prelude() {
  printf 'seat_sh=%q\n' "${C11_SANDBOX_SEAT_SH:-}"
  printf 'claude_account=%q\n' "${C11_SANDBOX_CLAUDE_ACCOUNT:-}"
  cat <<'ZSH'
[[ -n "$seat_sh" ]] || seat_sh="$HOME/Projects/Stage11/code/overwatch/launcher/seat.sh"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
lib_dir=/usr/local/libexec/c11-sandbox

# One kind's credential as a JSON line on stdout. stdout carries the secret;
# callers keep it in a variable or a pipe, never a file or argv.
export_cred() {
  local kind="$1"
  [[ -x "$seat_sh" || -f "$seat_sh" ]] || die "Overwatch seat launcher not found at $seat_sh (set C11_SANDBOX_SEAT_SH)"
  local -a extra
  extra=()
  [[ "$kind" == claude && -n "$claude_account" ]] && extra=(--account "$claude_account")
  /bin/bash "$seat_sh" export-cred --agent "$kind" "${extra[@]}" </dev/null
}

# stdin: patterns, one per line. Searches each path (files, or directories walked
# without following links) for any of them; reads only allocated extents of sparse
# files, at nice 15. Prints "<path> found|absent|error bytes=<n> [reason]".
# Exit 1 when anything is found, 2 when any part could not be read (an unread
# byte is never reported as absent), 0 only when every byte was searched.
secret_scan() {
  /usr/bin/python3 -c '
import errno, os, stat, sys
os.nice(15)
pats = [l.rstrip("\n").encode() for l in sys.stdin if l.strip()]
if not pats:
    sys.exit("secret_scan: no patterns")
keep = max(len(p) for p in pats) - 1
CHUNK = 64 << 20
NO_SEEK_DATA = (errno.EINVAL, errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", errno.ENOTSUP))
def extents(fd, size):
    if not hasattr(os, "SEEK_DATA"):
        yield 0, size
        return
    pos = 0
    while pos < size:
        try:
            start = os.lseek(fd, pos, os.SEEK_DATA)
        except OSError as e:
            if e.errno == errno.ENXIO:
                return  # no data after pos
            if pos == 0 and e.errno in NO_SEEK_DATA:
                yield 0, size  # filesystem without hole reporting: read it all
                return
            raise
        end = os.lseek(fd, start, os.SEEK_HOLE)  # an error here propagates
        yield start, end
        pos = end
def scan(path):
    n = 0
    with open(path, "rb") as f:
        fd = f.fileno()
        size = os.fstat(fd).st_size
        for start, end in extents(fd, size):
            tail, off = b"", start
            while off < end:
                data = os.pread(fd, min(CHUNK, end - off), off)
                if not data:
                    raise OSError(errno.EIO, "short read at offset %d of %d" % (off, size))
                buf = tail + data
                if any(p in buf for p in pats):
                    return True, n + len(data)
                n += len(data)
                off += len(data)
                tail = buf[-keep:] if keep else b""
    return False, n
def files_under(root, errors):
    st = os.lstat(root)  # a missing root raises
    if stat.S_ISREG(st.st_mode):
        return [root]
    if not stat.S_ISDIR(st.st_mode):
        raise OSError(errno.EINVAL, "not a file or directory")
    out = []
    for d, _, xs in os.walk(root, onerror=errors.append):
        out.extend(os.path.join(d, x) for x in xs)
    return out
found = failed = False
for root in sys.argv[1:]:
    hit, total, errors = False, 0, []
    try:
        files = files_under(root, errors)
    except OSError as e:
        files, errors = [], [e]
    for path in files:
        try:
            st = os.lstat(path)
            if not stat.S_ISREG(st.st_mode):
                continue  # links are not followed; sockets and fifos hold no file content
            h, n = scan(path)
        except OSError as e:
            errors.append(e)
            continue
        total += n
        if h:
            hit = True
            break
    if hit:
        found = True
        print("%s found bytes=%d" % (root, total))
    elif errors:
        failed = True
        e = errors[0]
        print("%s error bytes=%d %d unreadable: %s (%s)" % (root, total, len(errors), getattr(e, "filename", "") or root, e.strerror or e))
    else:
        print("%s absent bytes=%d" % (root, total))
sys.exit(1 if found else 2 if failed else 0)
' "$@"
}

# The version string of a host agent binary. Running it can hang: a quarantined
# Homebrew codex blocks in Gatekeeper's first-launch check when started over SSH.
# The Codex cask records its version in codex-package.json; anything else gets
# --version under a 20 s alarm.
agent_version() {
  local kind="$1" bin="$2" manifest
  manifest="${bin:h:h}/codex-package.json"
  if [[ "$kind" == codex && -f "$manifest" ]]; then
    /usr/bin/python3 -c 'import json, sys; print("codex-cli " + json.load(open(sys.argv[1]))["version"])' "$manifest" </dev/null
    return
  fi
  /usr/bin/perl -e 'alarm 20; exec @ARGV' "$bin" --version </dev/null 2>/dev/null | head -n 1
}

# stdin: credential JSON lines. Modes: patterns (the values a guest file holds,
# one per line, for a pipe only), fingerprints (kind:sha256 prefix), summary.
secret_tool() {
  /usr/bin/python3 -c '
import base64, hashlib, json, sys
mode = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    kind, env = d["agent"], d["env"]
    if kind == "claude":
        vals = [env["CLAUDE_CODE_OAUTH_TOKEN"]]
    elif kind == "codex":
        t = json.loads(base64.b64decode(env["CODEX_AUTH_JSON_B64"]))["tokens"]
        vals = [t["access_token"]] + ([t["id_token"]] if t.get("id_token") else [])
    elif kind == "grok":
        vals = [json.loads(env["GROK_ACCESS_TOKEN_JSON"])["access_token"]]
    else:
        sys.exit("unknown kind " + kind)
    if mode == "summary":
        print("%s account=%s expires_at=%s" % (kind, d.get("account") or "-", d.get("expires_at") or "-"))
        continue
    for v in vals:
        if mode == "patterns":
            print(v)
        else:
            print(kind + ":" + hashlib.sha256(v.encode()).hexdigest()[:16])
' "$1"
}
ZSH
}

# The guest side of stage: the claude shim, grok-auth, and the credential stager.
sandbox_agent_guest_installer() {
  cat <<'GUEST'
set -eu
setopt pipefail
lib=/usr/local/libexec/c11-sandbox
inc="$HOME/c11-sandbox/agents/incoming"
/usr/bin/sudo -n /bin/mkdir -p "$lib" /usr/local/bin
for k in ${=copied}; do
  [[ -d "$inc/$k" ]] || { print -u2 -- "missing $inc/$k"; exit 1 }
  /usr/bin/sudo -n /bin/rm -rf "$lib/$k"
  /usr/bin/sudo -n /bin/mv "$inc/$k" "$lib/$k"
  print -r -- "${versions[$k]}" | /usr/bin/sudo -n /usr/bin/tee "$lib/$k/VERSION" >/dev/null
done
tmp="$(mktemp -d)"
cat > "$tmp/claude" <<'SH'
#!/bin/sh
# c11 sandbox. Claude Code on macOS has no file login, so a setup-token reaches it only through
# CLAUDE_CODE_OAUTH_TOKEN. Export the staged token for this process tree and run the real CLI.
f="$HOME/.c11-sandbox-secrets/claude-oauth"
# Keep the version stage installed and recorded; Claude Code updates itself otherwise.
DISABLE_AUTOUPDATER=1
export DISABLE_AUTOUPDATER
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r "$f" ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat "$f")"
  export CLAUDE_CODE_OAUTH_TOKEN
fi
exec /usr/local/libexec/c11-sandbox/claude/claude "$@"
SH
cat > "$tmp/grok-auth" <<'SH'
#!/bin/sh
# c11 sandbox: Grok Build's external auth provider. Prints the staged access token in Grok's JSON
# contract. The guest holds no refresh token; sandbox-agent.sh stage replaces the file.
f="$HOME/.c11-sandbox-secrets/grok-token"
[ -r "$f" ] || { echo "grok-auth: $f missing; run scripts/sandbox-agent.sh <run-id> stage grok" >&2; exit 1; }
exec /usr/bin/python3 - "$f" <<'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    tok, exp = d["access_token"], int(d["expires_at"])
except Exception as e:
    print("grok-auth: unreadable token file: %s" % e, file=sys.stderr); sys.exit(1)
left = exp - int(time.time())
if not tok or left < 60:
    print("grok-auth: token expired; run scripts/sandbox-agent.sh <run-id> stage grok", file=sys.stderr); sys.exit(1)
print(json.dumps({"access_token": tok, "expires_in": left}))
PY
SH
cat > "$tmp/stage.py" <<'PY'
# c11 sandbox credential stager. stdin: one JSON line per kind from seat.sh export-cred.
# Writes each secret as a mode 600 file and seeds first-run state. Prints paths, never values.
import base64, json, os, sys, time
home = os.path.expanduser("~")
secrets = os.path.join(home, ".c11-sandbox-secrets")
work = os.path.join(home, "c11-sandbox", "work")
os.makedirs(work, exist_ok=True)
os.makedirs(secrets, mode=0o700, exist_ok=True)
os.chmod(secrets, 0o700)

def write_secret(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    print("staged %s mode=600" % path)

def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}

def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    kind, env = d["agent"], d["env"]
    if kind == "claude":
        write_secret(os.path.join(secrets, "claude-oauth"), env["CLAUDE_CODE_OAUTH_TOKEN"].encode())
        p = os.path.join(home, ".claude.json")
        c = load(p)
        c.setdefault("hasCompletedOnboarding", True)
        c.setdefault("theme", "dark")
        c.setdefault("projects", {}).setdefault(work, {})["hasTrustDialogAccepted"] = True
        json.dump(c, open(p, "w"), indent=1)
        sp = os.path.join(home, ".claude", "settings.json")
        s = load(sp)
        s["skipDangerousModePermissionPrompt"] = True
        os.makedirs(os.path.dirname(sp), exist_ok=True)
        json.dump(s, open(sp, "w"), indent=1)
    elif kind == "codex":
        write_secret(os.path.join(home, ".codex", "auth.json"), base64.b64decode(env["CODEX_AUTH_JSON_B64"]))
        write_text(os.path.join(home, ".codex", "config.toml"), "\n".join([
            "check_for_update_on_startup = false",
            'cli_auth_credentials_store = "file"',
            "",
            '[projects."%s"]' % work,
            'trust_level = "trusted"',
            "",
            "[notice]",
            "hide_full_access_warning = true",
            "hide_rate_limit_model_nudge = true",
            "",
            "[analytics]",
            "enabled = false",
            ""]))
    elif kind == "grok":
        write_secret(os.path.join(secrets, "grok-token"), env["GROK_ACCESS_TOKEN_JSON"].encode())
        write_text(os.path.join(home, ".grok", "config.toml"), "\n".join([
            "[cli]",
            "auto_update = false",
            "",
            "[auth]",
            'auth_provider_command = "/usr/local/libexec/c11-sandbox/grok-auth"',
            'auth_provider_label = "c11 sandbox"',
            "",
            "[features]",
            "telemetry = false",
            "feedback = false",
            "",
            "[telemetry]",
            "trace_upload = false",
            "mixpanel_enabled = false",
            "",
            "[ui]",
            'permission_mode = "always-approve"',
            "",
            "[privacy]",
            'privacy_banner_acked = "%s"' % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            ""]))
    else:
        sys.exit("unknown kind %s" % kind)
    print("seeded %s first-run state" % kind)
PY
/usr/bin/sudo -n /usr/bin/install -m 755 "$tmp/claude" "$lib/claude-shim"
/usr/bin/sudo -n /usr/bin/install -m 755 "$tmp/grok-auth" "$lib/grok-auth"
mkdir -p "$HOME/c11-sandbox/agents"
/usr/bin/install -m 644 "$tmp/stage.py" "$HOME/c11-sandbox/agents/stage.py"
rm -rf "$tmp"
for k in ${=kinds}; do
  case "$k" in
    claude) /usr/bin/sudo -n /bin/ln -sfn "$lib/claude-shim" /usr/local/bin/claude ;;
    codex) /usr/bin/sudo -n /bin/ln -sfn "$lib/codex/bin/codex" /usr/local/bin/codex ;;
    grok) /usr/bin/sudo -n /bin/ln -sfn "$lib/grok/grok" /usr/local/bin/grok ;;
  esac
  v="$(/usr/local/bin/$k --version </dev/null 2>/dev/null | head -n 1 || true)"
  [[ -n "$v" ]] || { print -u2 -- "$k does not run in the guest"; exit 1 }
  print -r -- "guest_${k}=$v"
done
GUEST
}

cmd_stage() {
  local kinds="${1:-claude,codex,grok}"
  [[ $# -le 1 ]] || sandbox_die "stage takes one comma-separated kind list"
  sandbox_validate_kinds "$kinds"
  local installer_b64
  installer_b64="$(sandbox_agent_guest_installer | base64 | tr -d '\n')"
  sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
$(sandbox_agent_host_prelude)
run_id=$(printf '%q' "$run_id")
kinds_csv=$(printf '%q' "$kinds")
kinds=(\${(s:,:)kinds_csv})
load_meta "\$run_id"
ip="\$(guest_ip "\$VM")"
# 1. Credentials, exported here and held only in this shell's memory.
typeset -A cred
for k in \$kinds; do
  one="\$(export_cred "\$k")" || die "could not export the \$k credential on \$(hostname -s). The error above names the missing login; fix it there and rerun stage."
  [[ -n "\$one" ]] || die "the \$k export returned nothing"
  cred[\$k]="\$one"
done
# 2. Agent CLIs: the versions installed on this host, copied when the guest lacks them.
typeset -A versions payload
for k in \$kinds; do
  case "\$k" in
    claude) b="\$HOME/.local/bin/claude"; [[ -e "\$b" ]] || b="\$(command -v claude)" ;;
    codex) b="\$(command -v codex)" ;;
    grok) b="\$HOME/.local/bin/grok"; [[ -e "\$b" ]] || b="\$(command -v grok)" ;;
  esac
  b="\${b:A}"
  /usr/bin/file -b "\$b" | grep -q 'Mach-O' || die "\$k on this host is not a native binary (\$b)"
  versions[\$k]="\$(agent_version "\$k" "\$b")"
  [[ -n "\${versions[\$k]}" ]] || die "\$k --version did not answer on this host (\$b)"
  payload[\$k]="\$b"
done
guest_has="\$(print -r -- 'for k in claude codex grok; do print -r -- "\$k=\$(cat /usr/local/libexec/c11-sandbox/\$k/VERSION 2>/dev/null)"; done' | guest_ssh "\$ip")"
copied=()
for k in \$kinds; do
  have="\$(print -r -- "\$guest_has" | sed -n "s/^\$k=//p")"
  [[ "\$have" == "\${versions[\$k]}" ]] && continue
  b="\${payload[\$k]}"
  inc="c11-sandbox/agents/incoming"
  print -r -- "rm -rf \\"\\\$HOME/\$inc/\$k\\"" | guest_ssh "\$ip" >/dev/null
  if [[ "\$k" == codex && -d "\${b:h:h}/codex-resources" ]]; then
    # The Homebrew cask keeps resources beside bin/; ship the whole version directory.
    COPYFILE_DISABLE=1 /usr/bin/tar -C "\${b:h:h:h}" -s ",^\${b:h:h:t},codex," -cf - "\${b:h:h:t}" | guest_receive_tar "\$ip" "/Users/\$guest_user/\$inc"
  else
    # One binary. Its place in the guest matches the link the installer makes.
    case "\$k" in
      codex) dest="codex/bin/codex" ;;
      *) dest="\$k/\$k" ;;
    esac
    COPYFILE_DISABLE=1 /usr/bin/tar -C "\${b:h}" -s ",^\${b:t}\\$,\$dest," -cf - "\${b:t}" | guest_receive_tar "\$ip" "/Users/\$guest_user/\$inc"
  fi
  copied+=("\$k")
done
# 3. Install the CLIs and helpers in the guest (no secrets in this script).
{
  printf 'kinds=%q\n' "\${(j: :)kinds}"
  printf 'copied=%q\n' "\${(j: :)copied}"
  print -r -- 'typeset -A versions'
  for k in \$kinds; do printf 'versions[%s]=%q\n' "\$k" "\${versions[\$k]}"; done
  print -r -- '${installer_b64}' | /usr/bin/base64 -D
} | guest_ssh "\$ip"
# 4. Secrets: on SSH stdin, written in the guest as mode 600 files.
for k in \$kinds; do print -r -- "\${cred[\$k]}"; done \
  | guest_ssh_run "\$ip" '/usr/bin/python3 "\$HOME/c11-sandbox/agents/stage.py"'
# 5. A secret-free record for verify-clean.
# Repeated stages merge: every kind, Claude account and credential ever staged
# in this clone stays listed, so verify-clean searches for all of them.
golden_disk="\$HOME/.tart/vms/\$golden/disk.img"
record="\$root/runs/\$run_id/agents.env"
KINDS="" CLAUDE_ACCOUNTS="" FINGERPRINTS="" GOLDEN_DISK_MTIME=""
[[ -f "\$record" ]] && source "\$record"
all_kinds=(\${(s:,:)KINDS} \$kinds)
accounts=(\${(s:,:)CLAUDE_ACCOUNTS})
if (( \${+cred[claude]} )); then
  acct="\$(print -r -- "\${cred[claude]}" | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["account"])')"
  [[ -n "\$acct" && "\$acct" != None ]] || die "the claude export names no account"
  accounts+=("\$acct")
fi
new_fps="\$(for k in \$kinds; do print -r -- "\${cred[\$k]}"; done | secret_tool fingerprints | tr '\n' ' ')"
[[ -n "\${new_fps// /}" ]] || die "could not fingerprint the staged credentials"
fps="\$FINGERPRINTS \$new_fps"
{
  printf 'KINDS=%q\n' "\${(j:,:)\${(@u)all_kinds}}"
  printf 'CLAUDE_ACCOUNTS=%q\n' "\${(j:,:)\${(@u)accounts}}"
  printf 'GOLDEN_DISK_MTIME=%q\n' "\${GOLDEN_DISK_MTIME:-\$(stat -f %m "\$golden_disk" 2>/dev/null || true)}"
  printf 'STAGED_AT=%q\n' "\$EPOCHSECONDS"
  printf 'FINGERPRINTS=%q\n' "\${(j: :)\${(@u)\${=fps}}}"
} > "\$record.tmp"
mv "\$record.tmp" "\$record"
for k in \$kinds; do print -r -- "\${cred[\$k]}"; done | secret_tool summary | sed 's/^/credential /'
for k in \$kinds; do printf 'version_%s=%s\n' "\$k" "\${versions[\$k]}"; done
printf 'copied=%s\n' "\${(j:,:)copied}"
printf 'staged=%s\n' "\${(j:,:)kinds}"
EOF
}

# Run the guest c11 CLI against the guest socket. Arguments travel base64-encoded.
guest_c11() {
  local argv_b64
  argv_b64="$(printf '%s\0' "$@" | base64 | tr -d '\n')"
  sandbox_guest_script "$run_id" <<EOF
set -eu
export SANDBOX_CLI SANDBOX_SOCKET
export SANDBOX_ARGV_B64='${argv_b64}'
exec /usr/bin/python3 - <<'PY'
import base64, os, sys
raw = base64.b64decode(os.environ["SANDBOX_ARGV_B64"])
args = [p.decode() for p in raw.split(b"\0")[:-1]]
if args[:2] == ["mailbox", "send"]:
    # mailbox send resolves its sender from the calling tab, and this call has none.
    sys.exit("sandbox-agent: mailbox send needs a sender tab. Run it in a guest shell tab: "
             "sandbox-agent.sh <run-id> c11 send --workspace <ws> --tab <shell-tab> \"c11 mailbox send --to <tab> --body <text>\"")
env = {k: v for k, v in os.environ.items() if not k.startswith(("C11_", "CMUX_"))}
env["LC_ALL"] = env["LANG"] = "en_US.UTF-8"
cli, sock = os.environ["SANDBOX_CLI"], os.environ["SANDBOX_SOCKET"]
os.execve(cli, [cli, "--socket", sock] + args, env)
PY
EOF
}

cmd_launch() {
  local kind="${1:-}" brief="${2:-}"
  [[ -n "$kind" && -n "$brief" ]] || sandbox_die "launch needs <claude|codex|grok> <brief-file>"
  shift 2
  sandbox_validate_kinds "$kind"
  [[ -f "$brief" ]] || sandbox_die "brief not found: $brief"
  local title="" model="" effort="" workspace="" address="" push=1 wait=1 timeout=180
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="${2:?--title needs text}"; shift 2 ;;
      --model) model="${2:?--model needs an id}"; shift 2 ;;
      --effort) effort="${2:?--effort needs a tier}"; shift 2 ;;
      --workspace) workspace="${2:?--workspace needs a ref}"; shift 2 ;;
      --address) address="${2:?--address needs a handle}"; shift 2 ;;
      --no-push) push=0; shift ;;
      --no-wait) wait=0; shift ;;
      --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
      *) sandbox_die "unknown launch flag: $1" ;;
    esac
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || sandbox_die "--timeout takes seconds"
  [[ -n "$title" ]] || title="sb-$kind"
  [[ -n "$address" ]] || address="$title"
  local type
  case "$kind" in
    claude) type=claude-code ;;
    *) type="$kind" ;;
  esac
  local -a la=(launch-agent --type "$type" --title "$title" --json)
  [[ -n "$model" ]] && la+=(--model "$model")
  [[ -n "$effort" ]] && la+=(--effort "$effort")
  [[ -n "$workspace" ]] && la+=(--workspace "$workspace")
  local la_b64 brief_b64
  la_b64="$(printf '%s\0' "${la[@]}" | base64 | tr -d '\n')"
  brief_b64="$(base64 < "$brief" | tr -d '\n')"
  sandbox_guest_script "$run_id" <<EOF
set -eu
setopt pipefail
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
kind=$(printf '%q' "$kind")
address=$(printf '%q' "$address")
push=$(printf '%q' "$push")
wait=$(printf '%q' "$wait")
timeout=$(printf '%q' "$timeout")
c() { "\$SANDBOX_CLI" --socket "\$SANDBOX_SOCKET" "\$@" </dev/null }
command -v "\$kind" >/dev/null 2>&1 || [[ -x "/usr/local/bin/\$kind" ]] || {
  print -u2 -- "\$kind is not installed in this guest. Run scripts/sandbox-agent.sh \$SANDBOX_RUN_ID stage \$kind first."
  exit 1
}
work="\$HOME/c11-sandbox/work"
briefs="\$HOME/c11-sandbox/briefs"
mkdir -p "\$work" "\$briefs"
brief="\$briefs/\${kind}-\${EPOCHSECONDS:-\$(date +%s)}-\$\$.md"
print -r -- '${brief_b64}' | /usr/bin/base64 -D > "\$brief"
la=("\${(@0)\$(print -r -- '${la_b64}' | /usr/bin/base64 -D)}")
la=("\${(@)la:#}")
out="\$(c --id-format both "\${la[@]}" --prompt-file "\$brief" --cwd "\$work")" || { print -u2 -- "launch-agent failed: \$out"; exit 1 }
eval "\$(print -r -- "\$out" | /usr/bin/python3 -c '
import json, shlex, sys
d = json.load(sys.stdin)
if not d.get("ok", True):
    sys.exit("launch-agent: %s" % d)
for k, keys in (("tab_ref", ("panel_ref", "tab_ref")), ("workspace_ref", ("workspace_ref",)),
                ("tab_id", ("panel_id", "tab_id")), ("workspace_id", ("workspace_id",)), ("startup", ("startup",))):
    print("%s=%s" % (k, shlex.quote(str(next((d[x] for x in keys if d.get(x)), "")))))
')"
[[ -n "\$tab_ref" && -n "\$workspace_ref" ]] || { print -u2 -- "launch-agent returned no tab: \$out"; exit 1 }
c set-metadata --workspace "\$workspace_ref" --tab "\$tab_ref" --key mailbox.address --value "\$address" --type string >/dev/null
if [[ "\$push" == 1 ]]; then
  c set-metadata --workspace "\$workspace_ref" --tab "\$tab_ref" --key mailbox.delivery --value stdin --type string >/dev/null
fi
case "\$kind" in
  claude)
    ready='bypass permissions on'
    fail='Select login method|Not logged in|Invalid API key|cannot be used with root'
    ;;
  codex)
    ready='\\? for shortcuts|Context [0-9]+% used|% context left'
    fail='Sign in with ChatGPT|Provide your own API key'
    ;;
  grok)
    ready='· always-approve|Shift\\+Tab:mode'
    fail='Log in to Grok|device code'
    ;;
esac
keys() { local k; for k in "\$@"; do c send-key --workspace "\$workspace_ref" --tab "\$tab_ref" "\$k" >/dev/null; sleep 0.3; done }
state=launched
if [[ "\$wait" == 1 ]]; then
  state=timeout
  deadline=\$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    screen="\$(c read-screen --workspace "\$workspace_ref" --tab "\$tab_ref" --lines 60 2>/dev/null || true)"
    if print -r -- "\$screen" | grep -qE "\$fail"; then
      print -u2 -- "\$kind is not logged in:"
      print -r -- "\$screen" | grep -E "\$fail" | head -n 3 >&2
      state=login
      break
    fi
    case "\$kind" in
      claude)
        if print -r -- "\$screen" | grep -qE 'Yes, I accept|Bypass Permissions mode'; then keys down enter; sleep 3; continue; fi
        if print -r -- "\$screen" | grep -qiE 'text style|Dark mode'; then keys enter; sleep 3; continue; fi
        if print -r -- "\$screen" | grep -qiE 'trust the files|Yes, proceed'; then keys enter; sleep 3; continue; fi
        ;;
      codex)
        if print -r -- "\$screen" | grep -qE 'Update available'; then keys down enter; sleep 3; continue; fi
        if print -r -- "\$screen" | grep -qE 'Trust this folder|Do you trust'; then keys enter; sleep 3; continue; fi
        ;;
      grok)
        if print -r -- "\$screen" | grep -qE 'Do you trust the contents of this directory'; then keys y; sleep 3; continue; fi
        ;;
    esac
    if print -r -- "\$screen" | grep -qE "\$ready"; then state=ready; break; fi
    sleep 2
  done
fi
printf 'tab=%s\nworkspace=%s\ntab_id=%s\nworkspace_id=%s\naddress=%s\nbrief=%s\nstartup=%s\nready=%s\n' \
  "\$tab_ref" "\$workspace_ref" "\$tab_id" "\$workspace_id" "\$address" "\$brief" "\$startup" "\$state"
[[ "\$state" == ready || "\$state" == launched ]]
EOF
}

cmd_screen() {
  local tab="${1:-}"
  [[ -n "$tab" ]] || sandbox_die "screen needs a tab ref"
  shift
  local -a args=(read-screen --tab "$tab")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) args+=(--workspace "${2:?--workspace needs a ref}"); shift 2 ;;
      --lines) args+=(--lines "${2:?--lines needs a number}"); shift 2 ;;
      --scrollback) args+=(--scrollback); shift ;;
      *) sandbox_die "unknown screen flag: $1" ;;
    esac
  done
  guest_c11 "${args[@]}"
}

cmd_wipe() {
  sandbox_guest_script "$run_id" <<'EOF'
set -eu
removed=()
for f in "$HOME/.c11-sandbox-secrets" "$HOME/.codex/auth.json"; do
  if [[ -e "$f" ]]; then
    /bin/rm -rf "$f"
    removed+=("$f")
  fi
done
printf 'wiped=%s\n' "${(j:,:)removed}"
EOF
}

cmd_verify_clean() {
  local control=0
  case "${1:-}" in
    "") ;;
    --control) control=1 ;;
    *) sandbox_die "verify-clean takes only --control" ;;
  esac
  sandbox_on_host <<EOF
set -eu
setopt pipefail
$(sandbox_host_prelude)
$(sandbox_agent_host_prelude)
run_id=$(printf '%q' "$run_id")
control=$(printf '%q' "$control")
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
record="\$root/runs/\$run_id/agents.env"
[[ -f "\$record" ]] || die "no staging record for \$run_id (\$record). Nothing was staged by sandbox-agent.sh for this run."
source "\$record"
bad=0
state="\$(vm_field "\$vm" || true)"
if [[ "\$control" == 1 ]]; then
  [[ -n "\$state" ]] || die "--control needs the clone up with credentials staged"
else
  if [[ -n "\$state" ]]; then print -r -- "clone=present (\$state)"; bad=1; else print -r -- "clone=absent"; fi
  if [[ -e "\$HOME/.tart/vms/\$vm" ]]; then print -r -- "clone_dir=present"; bad=1; else print -r -- "clone_dir=absent"; fi
fi
creds=()
for k in \${(s:,:)KINDS}; do
  if [[ "\$k" == claude && -n "\${CLAUDE_ACCOUNTS:-}" ]]; then
    for a in \${(s:,:)CLAUDE_ACCOUNTS}; do
      claude_account="\${a:l}"
      one="\$(export_cred claude 2>/dev/null)" || die "could not re-export claude (\$a) to search for it"
      creds+=("\$one")
    done
  else
    one="\$(export_cred "\$k" 2>/dev/null)" || die "could not re-export \$k to search for it"
    creds+=("\$one")
  fi
done
now_fp_text="\$(for c in \$creds; do print -r -- "\$c"; done | secret_tool fingerprints)" || die "could not fingerprint the re-exported credentials"
now_fp=(\${(f)now_fp_text})
staged_fp=(\${=FINGERPRINTS})
missing=(\${staged_fp:|now_fp})
if (( \${#missing} == 0 )); then
  print -r -- "credentials=unchanged since stage (searching for every staged value: \${#staged_fp})"
else
  # A rotated value cannot be re-exported, so nothing below searches for it. Fail
  # closed: a scan of current values cannot certify that a staged one is gone.
  print -r -- "credentials=ROTATED: \${#missing} of \${#staged_fp} staged values can no longer be exported and are not searched for (\${missing}). This run cannot be certified clean."
  bad=1
fi
patterns() { for c in \$creds; do print -r -- "\$c"; done | secret_tool patterns }
# The search is only as good as its patterns: each must find itself in a copy of the list.
n_patterns="\$(patterns | wc -l | tr -d ' ')"
n_self="\$(patterns | /usr/bin/grep -c -F -f <(patterns) || true)"
(( n_patterns > 0 )) && [[ "\$n_self" == "\$n_patterns" ]] || die "pattern self-test failed (\$n_self of \$n_patterns)"
print -r -- "patterns=\$n_patterns (self-test passed)"
search() { # label path
  local label="\$1" rc=0 out
  out="\$(patterns | secret_scan "\$2")" || rc=\$?
  case "\$rc" in
    0) print -r -- "\$label=absent (\${out##* })" ;;
    1) print -r -- "\$label=FOUND"; bad=1 ;;
    *) print -r -- "\$label=ERROR (scan exit \$rc: \${out#* error })"; bad=1 ;;
  esac
}
if [[ "\$control" == 1 ]]; then
  # Positive control: the live clone's disk holds the staged files, so the same
  # scan must find them there. An absent here means the search cannot see guest
  # files (an encrypted guest disk, wrong patterns) and the golden result is void.
  ip="\$(guest_ip "\$vm")"
  print -r -- '/bin/sync' | guest_ssh "\$ip"
  rc=0
  out="\$(patterns | secret_scan "\$HOME/.tart/vms/\$vm/disk.img")" || rc=\$?
  case "\$rc" in
    1) print -r -- "control_clone_disk=found (the scan sees guest files)"; exit 0 ;;
    0) print -r -- "control_clone_disk=ABSENT (\${out##* }): the scan cannot see guest files"; exit 1 ;;
    *) print -r -- "control_clone_disk=error (scan exit \$rc)"; exit 1 ;;
  esac
fi
golden_disk="\$HOME/.tart/vms/\$golden/disk.img"
[[ -f "\$golden_disk" ]] || die "golden disk not found at \$golden_disk"
mtime="\$(stat -f %m "\$golden_disk")"
if [[ "\$mtime" == "\$GOLDEN_DISK_MTIME" ]]; then
  print -r -- "golden_disk_mtime=unchanged since stage"
else
  print -r -- "golden_disk_mtime=CHANGED since stage (\$GOLDEN_DISK_MTIME -> \$mtime)"
  bad=1
fi
search golden_disk "\$golden_disk"
search host_sandbox_tree "\$root"
(( bad == 0 )) && print -r -- "verify_clean=pass" || { print -r -- "verify_clean=FAIL"; exit 1 }
EOF
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -ge 2 ]] || { usage >&2; exit 1; }
run_id="$1"
cmd="$2"
shift 2
sandbox_validate_run_id "$run_id"
case "$cmd" in
  stage) cmd_stage "$@" ;;
  launch) cmd_launch "$@" ;;
  screen) cmd_screen "$@" ;;
  c11) [[ $# -ge 1 ]] || sandbox_die "c11 needs arguments"; guest_c11 "$@" ;;
  wipe) [[ $# -eq 0 ]] || sandbox_die "wipe takes no arguments"; cmd_wipe ;;
  verify-clean) [[ $# -le 1 ]] || sandbox_die "verify-clean takes only --control"; cmd_verify_clean "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; sandbox_die "unknown command: $cmd" ;;
esac
