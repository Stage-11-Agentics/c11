#!/usr/bin/env bash
# Build c11's agent guest images: copies of c11's sandbox goldens with node and the agent CLIs.
# Usage: scripts/c11-guest-image.sh build <a|b> [--max-load N]
#        scripts/c11-guest-image.sh status
# Runs on the Tart host (the build host). docs/c11-guest-agents.md says what is in the image and why.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sandbox-common.sh
source "$SCRIPT_DIR/sandbox-common.sh"

# Pins. Bump deliberately, then rebuild both images (docs/c11-guest-agents.md).
NODE_VERSION=v24.22.2
NODE_TARBALL="node-${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_SHA256=aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a
CLAUDE_CODE_VERSION=2.1.316
OPENCODE_VERSION=1.15.13
IMAGE_A="${C11_IMAGE_A:-c11h-sandbox-golden}"
IMAGE_B="${C11_IMAGE_B:-c11h-sandbox-golden-b}"
MIN_FREE_GB=60

usage() {
  cat <<'EOF'
Usage: scripts/c11-guest-image.sh build <a|b> [--max-load N] [--min-free-gb N]
       scripts/c11-guest-image.sh status

build a   c11-sandbox-golden   -> c11h-sandbox-golden
build b   c11-sandbox-golden-b -> c11h-sandbox-golden-b

Clones c11's golden for that serial slot as c11-sb-c11-img-<slot> (recorded
under that slot, so every sandbox-up keeps its serial free while it boots),
boots the clone headless, installs node (official darwin-arm64 tarball,
SHA-256 pinned here) and the pinned agent CLIs, seeds first-run state that
needs no credential, shuts it down, and renames it to the c11 image,
replacing an older one. c11's goldens are only read by tart clone. No
credential is ever placed in the image.

Refuses below --min-free-gb free (default 60; lower it only on an explicit
exception), at one-minute load >= --max-load (default 30),
when the slot's serial is in use, or when two guests are already running.
A build boots a guest: it takes one of the build host's two guest slots.

status prints each image's state and /opt/c11h/VERSIONS record.
EOF
}

cmd="${1:-}"
case "$cmd" in
  -h|--help|"") usage; [[ -n "$cmd" ]]; exit $? ;;
  build|status) shift ;;
  *) sandbox_die "unknown command: $cmd" ;;
esac
[[ "$(sandbox_host_name)" == local ]] || sandbox_die "run this on the Tart host with C11_SANDBOX_HOST=local"
cache="${C11_IMAGE_CACHE:-$HOME/.c11-sandbox/c11-image-cache}"

if [[ "$cmd" == status ]]; then
  for img in "$IMAGE_A" "$IMAGE_B"; do
    rec="$HOME/.c11-sandbox/c11-images/$img.versions"
    state="$(tart list 2>/dev/null | awk -v n="$img" '$2==n {print $NF}')"
    echo "== $img: ${state:-missing}"
    [[ -f "$rec" ]] && cat "$rec" || echo "(no VERSIONS record at $rec)"
  done
  exit 0
fi

slot="${1:-}"; shift || true
max_load=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-load) max_load="${2:?--max-load needs a number}"; shift 2 ;;
    --min-free-gb) MIN_FREE_GB="${2:?--min-free-gb needs a number}"; shift 2 ;;
    *) sandbox_die "unexpected argument: $1" ;;
  esac
done
[[ "$max_load" =~ ^[0-9]+$ ]] || sandbox_die "--max-load takes a whole number"
[[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || sandbox_die "--min-free-gb takes a whole number"
case "$slot" in
  a) slot_golden="${C11_SANDBOX_GOLDEN:-c11-sandbox-golden}"; target="$IMAGE_A" ;;
  b) slot_golden="${C11_SANDBOX_GOLDEN_B:-${C11_SANDBOX_GOLDEN:-c11-sandbox-golden}-b}"; target="$IMAGE_B" ;;
  *) sandbox_die "build takes a slot: a or b" ;;
esac
sandbox_validate_token "image" "$target" '^c11-[A-Za-z0-9._-]{1,58}$'
run_id="c11-img-$slot"

free_gb="$(df -g "$HOME/.tart" | awk 'NR==2 {print $4}')"
(( free_gb >= MIN_FREE_GB )) || sandbox_die "only ${free_gb} GB free under ~/.tart; a new image needs ${MIN_FREE_GB}"
load1="$(sysctl -n vm.loadavg | awk '{print int($2)}')"
(( load1 < max_load )) || sandbox_die "one-minute load is $load1 (limit $max_load); build later"

# The node tarball, checked against the pin and against nodejs.org's SHASUMS256.txt.
mkdir -p "$cache"
if [[ ! -f "$cache/$NODE_TARBALL" ]]; then
  curl -fsSL -o "$cache/$NODE_TARBALL.part" "https://nodejs.org/dist/$NODE_VERSION/$NODE_TARBALL"
  mv "$cache/$NODE_TARBALL.part" "$cache/$NODE_TARBALL"
fi
curl -fsSL -o "$cache/SHASUMS256-$NODE_VERSION.txt" "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt"
published="$(awk -v f="$NODE_TARBALL" '$2==f {print $1}' "$cache/SHASUMS256-$NODE_VERSION.txt")"
actual="$(shasum -a 256 "$cache/$NODE_TARBALL" | awk '{print $1}')"
[[ "$actual" == "$NODE_SHA256" ]] || sandbox_die "node tarball sha256 $actual does not match the pin $NODE_SHA256"
[[ "$published" == "$NODE_SHA256" ]] || sandbox_die "nodejs.org publishes $published for $NODE_TARBALL, not the pin $NODE_SHA256"
echo "node=$NODE_VERSION sha256=$actual (pin and SHASUMS256.txt agree)"

# Guest-side install. Runs as admin over ssh; no credential is read or written.
install_script() {
  printf 'NODE_VERSION=%q\nNODE_TARBALL=%q\nNODE_SHA256=%q\nCLAUDE_CODE_VERSION=%q\nOPENCODE_VERSION=%q\n' \
    "$NODE_VERSION" "$NODE_TARBALL" "$NODE_SHA256" "$CLAUDE_CODE_VERSION" "$OPENCODE_VERSION"
  cat <<'GUEST'
set -eu
setopt pipefail
node_dir=/opt/c11h/node-${NODE_VERSION}-darwin-arm64
[[ -x "$node_dir/bin/node" ]] || { print -u2 -- "node did not unpack at $node_dir"; exit 1 }
/usr/bin/sudo -n /bin/ln -sfn "$node_dir" /opt/c11h/node
/usr/bin/sudo -n /usr/sbin/chown -R "$(id -un):staff" /opt/c11h
export PATH=/opt/c11h/node/bin:/usr/bin:/bin:/usr/sbin:/sbin
export npm_config_cache="$HOME/.c11-npm-cache" npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false
# npm 11 holds back install scripts unless named: allow exactly these two (each places its native binary).
npm install -g --prefix /opt/c11h/npm --allow-scripts=@anthropic-ai/claude-code,opencode-ai \
  @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} opencode-ai@${OPENCODE_VERSION} </dev/null >/dev/null
/usr/bin/sudo -n /bin/mkdir -p /usr/local/bin
for b in node npm npx; do /usr/bin/sudo -n /bin/ln -sf "/opt/c11h/node/bin/$b" "/usr/local/bin/$b"; done
for b in claude opencode; do /usr/bin/sudo -n /bin/ln -sf "/opt/c11h/npm/bin/$b" "/usr/local/bin/$b"; done
# First-run answers that need no credential: onboarding and theme done, no auto-update,
# folders trusted for the guest's work paths. No account, token or key.
/usr/bin/python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path.home() / ".claude.json"
d = json.loads(p.read_text()) if p.exists() else {}
d.update(hasCompletedOnboarding=True, theme="dark", autoUpdates=False, bypassPermissionsModeAccepted=True)
projects = d.setdefault("projects", {})
home = str(pathlib.Path.home())
for path in (home, home + "/c11-sandbox", home + "/c11-sandbox/work", "/tmp", "/private/tmp"):
    projects.setdefault(path, {}).update(hasTrustDialogAccepted=True, hasCompletedProjectOnboarding=True)
p.write_text(json.dumps(d, indent=2) + "\n")
os.chmod(p, 0o600)
PY
mkdir -p "$HOME/c11-sandbox/work"
claude_v="$(DISABLE_AUTOUPDATER=1 /usr/local/bin/claude --version </dev/null 2>/dev/null | head -n 1)"
opencode_v="$(OPENCODE_DISABLE_AUTOUPDATE=1 /usr/local/bin/opencode --version </dev/null 2>/dev/null | head -n 1)"
[[ "$claude_v" == ${CLAUDE_CODE_VERSION}* ]] || { print -u2 -- "claude reports '$claude_v', expected ${CLAUDE_CODE_VERSION}"; exit 1 }
[[ "$opencode_v" == *${OPENCODE_VERSION}* ]] || { print -u2 -- "opencode reports '$opencode_v', expected ${OPENCODE_VERSION}"; exit 1 }
claude_real="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' /opt/c11h/npm/bin/claude)"
opencode_real="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' /opt/c11h/npm/bin/opencode)"
{
  print -r -- "built_at=$(date -u +%FT%TZ)"
  print -r -- "macos=$(sw_vers -productVersion)"
  print -r -- "node=$(/opt/c11h/node/bin/node --version) tarball=${NODE_TARBALL} sha256=${NODE_SHA256}"
  print -r -- "claude_code=$claude_v"
  print -r -- "opencode=$opencode_v"
  # The registry integrity npm checked each tarball against (a global install keeps no lockfile).
  for pkg in @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} @anthropic-ai/claude-code-darwin-arm64@${CLAUDE_CODE_VERSION} \
             opencode-ai@${OPENCODE_VERSION} opencode-darwin-arm64@${OPENCODE_VERSION}; do
    print -r -- "npm $pkg $(npm view "$pkg" dist.integrity </dev/null 2>/dev/null)"
  done
  print -r -- "sha256 $(shasum -a 256 "$claude_real")"
  print -r -- "sha256 $(shasum -a 256 "$opencode_real")"
  print -r -- "credentials=none"
} > /tmp/c11-VERSIONS
/bin/mv /tmp/c11-VERSIONS /opt/c11h/VERSIONS
# Root-owned and read-only to admin: neither CLI can update itself in a clone.
/usr/bin/sudo -n /usr/sbin/chown -R root:wheel /opt/c11h
/usr/bin/sudo -n /bin/chmod -R go-w /opt/c11h
rm -rf "$HOME/.c11-npm-cache" "$HOME/.npm" "$HOME/.zsh_history" "$HOME/.zsh_sessions"
cat /opt/c11h/VERSIONS
GUEST
}
install_b64="$(install_script | base64 | tr -d '\n')"

record_dir="$HOME/.c11-sandbox/c11-images"
mkdir -p "$record_dir"
PATH="/opt/homebrew/bin:$PATH" /bin/zsh -s <<EOF
set -eu
setopt pipefail no_hup no_monitor
$(sandbox_host_prelude)
run_id=$(printf '%q' "$run_id")
slot_golden=$(printf '%q' "$slot_golden")
target=$(printf '%q' "$target")
tarball=$(printf '%q' "$cache/$NODE_TARBALL")
record=$(printf '%q' "$record_dir/$target.versions")
vm="c11-sb-\$run_id"
refuse_protected "\$vm"
[[ "\$target" != "\$golden" && "\$target" != "\$golden_b" ]] || die "refusing to overwrite a c11 golden (\$target)"
tart="\$(tart_bin)" || die "tart is not installed on this host"
[[ -f "\$key" ]] || die "missing \$key"
slot_state="\$(vm_field "\$slot_golden" || true)"
[[ "\$slot_state" == stopped ]] || die "c11's golden \$slot_golden is \${slot_state:-missing}; it must exist and be stopped"
target_state="\$(vm_field "\$target" || true)"
[[ -z "\$target_state" || "\$target_state" == stopped ]] || die "\$target is \$target_state; stop its runs first"
golden_mtime_before="\$(stat -f %m "\$HOME/.tart/vms/\$slot_golden/disk.img")"
lock="\$root/clone.lock"; lock_held=0; failed=1
pidfile="\$root/runs/\$run_id/tart.pid"; log="\$root/runs/\$run_id/tart.log"
release_lock() { (( lock_held )) || return 0; rm -rf "\$lock"; lock_held=0; }
cleanup() {
  release_lock
  [[ "\$failed" == 1 ]] || return 0
  print -u2 -- "c11-guest-image: build failed; removing \$vm"
  [[ -f "\$pidfile" ]] && kill "\$(cat "\$pidfile")" 2>/dev/null || true
  "\$tart" stop "\$vm" >/dev/null 2>&1 || true
  "\$tart" delete "\$vm" >/dev/null 2>&1 || true
  rm -rf "\$root/runs/\$run_id"
}
trap 'failed=1; exit 1' INT HUP TERM
trap cleanup EXIT
for i in {1..120}; do
  if mkdir "\$lock" 2>/dev/null; then print -r -- \$\$ > "\$lock/pid"; print -r -- "\$run_id" > "\$lock/run"; lock_held=1; break; fi
  oldpid="\$(cat "\$lock/pid" 2>/dev/null || true)"
  if [[ -n "\$oldpid" ]] && ! kill -0 "\$oldpid" 2>/dev/null; then rm -rf "\$lock"; continue; fi
  sleep 1
done
(( lock_held )) || die "timed out waiting for \$lock"
[[ -z "\$(vm_field "\$vm" || true)" ]] || { failed=0; die "\$vm already exists; delete it first (tart delete \$vm)"; }
n="\$(running_count)"
(( n < 2 )) || die "two guests are already running; macOS allows two"
# The slot's serial must be free: no running c11-sb-* guest may be recorded under it, and a
# host-test lane guest (c11-ht-*) always holds the first golden's serial.
while IFS= read -r line; do
  [[ -z "\$line" || "\$line" == Source* ]] && continue
  f=("\${(z)line}")
  if [[ "\${f[2]}" == c11-ht-* && "\${f[-1]}" != stopped ]]; then
    [[ "\$golden" != "\$slot_golden" ]] || die "serial slot \$slot_golden is in use by host-test lane guest \${f[2]}; wait or run c11-host-tests.py stop"
    continue
  fi
  [[ "\${f[2]}" == c11-sb-* && "\${f[-1]}" != stopped ]] || continue
  used="\$(cat "\$root/runs/\${f[2]#c11-sb-}/golden" 2>/dev/null || print -r -- "\$golden")"
  [[ "\$used" != "\$slot_golden" ]] || die "serial slot \$slot_golden is in use by \${f[2]}; build the other slot or wait"
done < <("\$tart" list)
mkdir -p "\$root/runs/\$run_id"
# Recorded before boot, under the lock: every sandbox-up now counts this VM against the slot.
print -r -- "\$slot_golden" > "\$root/runs/\$run_id/golden"
print -r -- "\$slot_golden" > "\$root/runs/\$run_id/image"
"\$tart" clone "\$slot_golden" "\$vm"
"\$tart" set "\$vm" --cpu 4 --memory 8192 --display 1440x900 --random-mac
/usr/bin/python3 -c 'import os,sys
tart, log, vm = sys.argv[1:4]
os.setsid()
fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.dup2(fd, 1); os.dup2(fd, 2); os.close(fd)
null = os.open(os.devnull, os.O_RDONLY); os.dup2(null, 0); os.close(null)
os.execv(tart, [tart, "run", "--no-graphics", "--no-audio", "--no-clipboard", vm])
' "\$tart" "\$log" "\$vm" &
print -r -- \$! > "\$pidfile"
disown 2>/dev/null || true
for i in {1..60}; do [[ "\$(vm_field "\$vm" || true)" == running ]] && break; sleep 0.5; done
[[ "\$(vm_field "\$vm" || true)" == running ]] || die "tart run did not start \$vm"
release_lock
ip=""
deadline=\$((SECONDS + 360))
while (( SECONDS < deadline )); do
  kill -0 "\$(cat "\$pidfile")" 2>/dev/null || die "tart run exited before \$vm got an IP"
  ip="\$("\$tart" ip "\$vm" --wait 3 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  [[ -n "\$ip" ]] && break
done
[[ -n "\$ip" ]] || die "no IP for \$vm"
ok=0
for i in {1..60}; do
  if print -r -- 'print -r -- ok' | guest_ssh "\$ip" | grep -q '^ok\$'; then ok=1; break; fi
  sleep 3
done
(( ok )) || die "ssh to \$vm did not come up"
guest_ssh_run "\$ip" '/usr/bin/sudo -n /bin/mkdir -p /opt/c11h && /usr/bin/sudo -n /usr/bin/tar -xzf - -C /opt/c11h' < "\$tarball"
versions="\$(print -r -- '${install_b64}' | /usr/bin/base64 -D | guest_ssh "\$ip")" || die "install in \$vm failed"
print -r -- "\$versions" > "\$record"
print -r -- "\$versions"
print -r -- '/usr/bin/sudo -n /sbin/shutdown -h now >/dev/null 2>&1 &' | guest_ssh "\$ip" || true
for i in {1..90}; do [[ "\$(vm_field "\$vm" || true)" == stopped ]] && break; sleep 2; done
[[ "\$(vm_field "\$vm" || true)" == stopped ]] || die "\$vm did not shut down cleanly"
kill "\$(cat "\$pidfile")" 2>/dev/null || true
# Same serial as the slot golden, or the image would bring Setup Assistant back.
ecid() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ecid"])' "\$HOME/.tart/vms/\$1/config.json"; }
[[ "\$(ecid "\$vm")" == "\$(ecid "\$slot_golden")" ]] || die "\$vm does not carry \$slot_golden's serial"
if [[ -n "\$(vm_field "\$target" || true)" ]]; then
  [[ "\$(vm_field "\$target")" == stopped ]] || die "\$target started during the build; left \$vm for inspection"
  "\$tart" delete "\$target"
fi
"\$tart" rename "\$vm" "\$target"
rm -rf "\$root/runs/\$run_id"
failed=0
golden_mtime_after="\$(stat -f %m "\$HOME/.tart/vms/\$slot_golden/disk.img")"
[[ "\$golden_mtime_before" == "\$golden_mtime_after" ]] && print -r -- "golden_disk_mtime=\$slot_golden unchanged" || print -r -- "golden_disk_mtime=\$slot_golden CHANGED (\$golden_mtime_before -> \$golden_mtime_after)"
print -r -- "image=\$target serial_slot=\$slot_golden state=\$(vm_field "\$target")"
EOF
