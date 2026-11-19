#!/usr/bin/env bash
# Host-side proof for the c11 identity script guards. c11 2.0 owns the c11 names;
# the retired line's and cmux's are foreign and stay byte for byte, except
# that prune-tags also clears the retired line's stopped tagged builds. Uses temp directories
# only. Does not run reload.sh, prune against live DerivedData, or the
# run-tests launchers.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- reload shim bytes -------------------------------------------------------
# shellcheck source=lib/c11-dev-shims.sh
source "$root/scripts/lib/c11-dev-shims.sh"

link_dir="$tmp/links"
shim_dir="$tmp/shims"
mkdir -p "$link_dir" "$shim_dir"
# c11-2.0:begin-keep (the retired line's shims are the foreign ones)
old_dev="$shim_dir/c11h-dev"
cmux_dev="$shim_dir/cmux-dev"
old_cli="$link_dir/c11h-cli"
printf 'c11h-dev-sentinel\n' > "$old_dev"
printf 'cmux-dev-sentinel\n' > "$cmux_dev"
printf 'c11h-cli-sentinel\n' > "$old_cli"
before_foreign="$(cksum "$old_dev" "$cmux_dev" "$old_cli")"
# c11-2.0:end-keep
fake_cli="$tmp/fake-c11"
printf '#!/bin/sh\nexit 0\n' > "$fake_cli"
chmod +x "$fake_cli"

C11_DEV_LINK_DIR="$link_dir" \
C11_DEV_SHIM_DIR="$shim_dir" \
C11_DEV_CLI_PATH_FILE="$tmp/c11-last-cli-path" \
  install_c11_dev_cli_links "$fake_cli"

after_foreign="$(cksum "$old_dev" "$cmux_dev" "$old_cli")" # c11-2.0:keep
[[ "$before_foreign" == "$after_foreign" ]] || fail "foreign shims changed: $after_foreign"
[[ -L "$link_dir/c11-cli" ]] || fail "missing c11-cli link"
[[ -x "$shim_dir/c11-dev" ]] || fail "missing c11-dev shim"
grep -q 'c11 dev shim' "$shim_dir/c11-dev" || fail "c11 shim marker missing"
grep -q '/c11.app/Contents/Resources/bin/c11' "$shim_dir/c11-dev" || fail "bundle CLI name c11 was dropped"

# --- owned socket cleanup ----------------------------------------------------
sock_root="$tmp/socks"
mkdir -p "$sock_root"
foreign="$sock_root/c11h.sock" # c11-2.0:keep (the retired line's live socket)
python3 -c '
import os, socket, sys, time
path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
time.sleep(30)
' "$foreign" &
py_pid=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [[ -S "$foreign" ]]; then ready=1; break; fi
  sleep 0.05
done
[[ "$ready" == 1 ]] || fail "foreign listener did not bind"
printf 'other\n' > "$sock_root/c11mux.sock"
printf 'other-h\n' > "$sock_root/c11-debug.sock"
printf 'owned\n' > "$sock_root/c11-debug-tests-v1.sock"
# shellcheck source=c11-owned-socket.sh
source "$root/scripts/c11-owned-socket.sh"
if c11_cleanup_owned_socket "$foreign"; then
  fail "cleanup accepted a foreign listener"
fi
C11_TEST_SOCKET_ROOT="$sock_root" bash "$root/scripts/c11-owned-socket.sh" cleanup tests-v1
[[ -S "$foreign" ]] || fail "foreign listener was removed"
[[ -f "$sock_root/c11mux.sock" ]] || fail "c11mux socket was removed"
[[ -f "$sock_root/c11-debug.sock" ]] || fail "untagged c11 socket was removed by a tagged cleanup"
[[ ! -e "$sock_root/c11-debug-tests-v1.sock" ]] || fail "owned socket still present"
kill "$py_pid" 2>/dev/null || true
wait "$py_pid" 2>/dev/null || true

# --- running-tag parser ------------------------------------------------------
(
  C11_PRUNE_LIB_ONLY=1
  # shellcheck source=prune-tags.sh
  source "$root/scripts/prune-tags.sh"
  sample="/Users/x/Library/Developer/Xcode/DerivedData/c11-live/Build/Products/Debug/c11 DEV live.app/Contents/MacOS/c11"
  [[ "$(tag_from_process_line "$sample")" == "live" ]] || exit 1
  old_sample="/Users/x/Library/Developer/Xcode/DerivedData/c11h-livetag/Build/Products/Debug/c11h DEV livetag.app/Contents/MacOS/c11h" # c11-2.0:keep
  [[ "$(tag_from_process_line "$old_sample")" == "livetag" ]] || exit 1
  other="/tmp/not-derived/c11 DEV.app/Contents/MacOS/c11"
  [[ "$(tag_from_process_line "$other")" == "$other" ]] || exit 1
) || fail "running tag parser"

# --- prune mixed fixtures ----------------------------------------------------
# c11-2.0:begin-keep (owned: c11's tagged builds and the retired line's; foreign: cmux)
derived="$tmp/DerivedData"  # the liveness parser reads tags from .../DerivedData/<prefix>-<tag>/
support="$tmp/support-c11"
mkdir -p \
  "$derived/c11-stopped/Build/Products/Debug/c11 DEV stopped.app/Contents" \
  "$derived/c11h-oldtag/Build/Products/Debug/c11h DEV oldtag.app/Contents" \
  "$derived/c11h-livetag/Build/Products/Debug/c11h DEV livetag.app/Contents/MacOS" \
  "$derived/c11-mixed/Build/Products/Debug/c11 DEV.app/Contents" \
  "$derived/c11-mixed/Build/Products/Debug/cmux DEV.app/Contents" \
  "$derived/c11-empty" \
  "$support" "$tmp/tmproot"
write_plist() {
  local path="$1" ident="$2"
  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${ident}</string></dict></plist>
EOF
}
write_plist "$derived/c11-stopped/Build/Products/Debug/c11 DEV stopped.app/Contents/Info.plist" "com.stage11.c11.debug.stopped"
write_plist "$derived/c11h-oldtag/Build/Products/Debug/c11h DEV oldtag.app/Contents/Info.plist" "com.stage11.c11h.debug.oldtag"
write_plist "$derived/c11h-livetag/Build/Products/Debug/c11h DEV livetag.app/Contents/Info.plist" "com.stage11.c11h.debug.livetag"
# A running build of the retired line: a fake executable at its path, stopped below by its PID.
live_bin="$derived/c11h-livetag/Build/Products/Debug/c11h DEV livetag.app/Contents/MacOS/c11h"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$live_bin"
chmod +x "$live_bin"
"$live_bin" >/dev/null 2>&1 &
live_pid=$!
trap 'kill "$live_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
sleep 1
write_plist "$derived/c11-mixed/Build/Products/Debug/c11 DEV.app/Contents/Info.plist" "com.stage11.c11.debug.mixed"
write_plist "$derived/c11-mixed/Build/Products/Debug/cmux DEV.app/Contents/Info.plist" "com.stage11.cmux"
printf 'drop-stopped\n' > "$derived/c11-stopped/DROP"
printf 'drop-old\n' > "$derived/c11h-oldtag/DROP"
printf 'keep-empty\n' > "$derived/c11-empty/KEEP"
printf 'keep-mixed-c11\n' > "$derived/c11-mixed/Build/Products/Debug/c11 DEV.app/KEEP"
printf 'keep-mixed-cmux\n' > "$derived/c11-mixed/Build/Products/Debug/cmux DEV.app/KEEP"
printf 'c11-sock\n' > "$tmp/tmproot/c11-debug-stopped.sock"
printf 'cmux-sock\n' > "$tmp/tmproot/cmux-debug-stopped.sock"
printf 'old-live-sock\n' > "$tmp/tmproot/c11h.sock"
printf 'c11-cache\n' > "$tmp/tmproot/c11-build-cache"
printf 'cmux-cache\n' > "$tmp/tmproot/cmux-module-cache"
printf 'own-daemon\n' > "$support/c11d-dev-stopped.sock"

C11_PRUNE_DERIVED_ROOT="$derived" \
C11_PRUNE_TMP_ROOT="$tmp/tmproot" \
C11_PRUNE_SUPPORT_DIR="$support" \
  bash "$root/scripts/prune-tags.sh" --yes >"$tmp/prune.out"

[[ ! -e "$derived/c11-stopped" ]] || fail "a stopped c11 tag survived prune"
[[ ! -e "$derived/c11h-oldtag" ]] || fail "a stopped tag of the retired line survived prune"
[[ -x "$live_bin" ]] || fail "prune deleted a running build of the retired line"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
[[ -f "$derived/c11-empty/KEEP" ]] || fail "unverified DerivedData was deleted"
[[ -f "$derived/c11-mixed/Build/Products/Debug/c11 DEV.app/KEEP" ]] || fail "mixed root deleted the c11 product beside a foreign app"
[[ -f "$derived/c11-mixed/Build/Products/Debug/cmux DEV.app/KEEP" ]] || fail "mixed root deleted the cmux product"
[[ ! -e "$tmp/tmproot/c11-debug-stopped.sock" ]] || fail "the stopped tag's debug socket survived"
[[ -f "$tmp/tmproot/cmux-debug-stopped.sock" ]] || fail "cmux debug socket was deleted"
[[ -f "$tmp/tmproot/c11h.sock" ]] || fail "the retired line's live socket was deleted"
[[ ! -e "$tmp/tmproot/c11-build-cache" ]] || fail "c11 build cache survived"
[[ -f "$tmp/tmproot/cmux-module-cache" ]] || fail "cmux module cache was deleted"
[[ ! -e "$support/c11d-dev-stopped.sock" ]] || fail "the stopped tag's daemon socket survived"
# c11-2.0:end-keep

echo "c11 identity script checks passed"
