#!/usr/bin/env bash
# C11H-364 shell tests: c11's per-user folder helpers, the codex wrapper's
# launch-boundary block, the build lock and the shell integration's socket
# gate. Everything runs in its own temporary root; nothing launches an app,
# signals a process it did not start, or touches the real per-user folder or
# a running c11's /tmp files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/c11-user-paths-test.XXXXXX")"
# Sockets need a short path (sun_path is 104 bytes): the user's own temp folder.
SOCKDIR="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)u364s.XXXXXX")"
trap '/bin/rm -rf "$TMP" "$SOCKDIR"' EXIT
export C11_DEV_RUNTIME_DIR="$TMP/runtime/c11"
# shellcheck source=../scripts/lib/c11-user-paths.sh
source "$ROOT/scripts/lib/c11-user-paths.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok - $*"; }
mode_of() { /usr/bin/stat -f '%Lp' "$1"; }

# An `id` that reports another uid: our own entries then look like another
# account's, which is how a test without a second account sees the refusal.
SHIM="$TMP/other-uid-bin"
mkdir -p "$SHIM"
cat > "$SHIM/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then echo 4242; exit 0; fi
exec /usr/bin/id "$@"
EOF
chmod +x "$SHIM/id"

# --- socket names: the same vectors as C11UserRuntimeTests ---------------------
dir="/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/c11"
[[ "$(c11_socket_path_for_stem c11-debug-c11-orch9 "$dir")" == "$dir/c11-debug-c11-orch9.sock" ]] || fail "short stem changed"
kept="c11-debug-$(printf 'x%.0s' $(seq 1 29))"
[[ "$(c11_socket_path_for_stem "$kept" "$dir")" == "$dir/$kept.sock" ]] || fail "29-byte slug was cut"
over="c11-debug-$(printf 'x%.0s' $(seq 1 30))"
[[ "$(c11_socket_path_for_stem "$over" "$dir")" == "$dir/c11-debug-xxxxxxxxxxxxxxxxxxxx-7b75b09f.sock" ]] || fail "30-byte slug: $(c11_socket_path_for_stem "$over" "$dir")"
long="c11-debug-a-very-long-tag-name-that-goes-on-and-on-far-past-every-sensible-length-and-then-some-more-text-xyz"
got="$(c11_socket_path_for_stem "$long" "$dir")"
[[ "$got" == "$dir/c11-debug-a-very-long-tag-name-a0aa9565.sock" ]] || fail "long tag: $got"
(( ${#got} + 6 <= 103 )) || fail "long tag does not fit sun_path with a pid sibling"
ok "socket names match the Swift vectors and fit sun_path"

real="$(env -u C11_DEV_RUNTIME_DIR bash -c "source '$ROOT/scripts/lib/c11-user-paths.sh'; c11_user_runtime_dir")"
[[ "$real" == "$(getconf DARWIN_USER_TEMP_DIR)c11" ]] || fail "folder is not the user temp folder: $real"
[[ "$(env -u C11_DEV_RUNTIME_DIR TMPDIR=/tmp bash -c "source '$ROOT/scripts/lib/c11-user-paths.sh'; c11_user_runtime_dir")" == "$real" ]] || fail "TMPDIR changed the folder"
ok "the folder is \$(getconf DARWIN_USER_TEMP_DIR)c11 and ignores TMPDIR"

# --- the folder ------------------------------------------------------------------
made="$(umask 022; c11_ensure_user_runtime_dir)"
[[ "$made" == "$C11_DEV_RUNTIME_DIR" && "$(mode_of "$made")" == 700 ]] || fail "folder not created 0700"
chmod 755 "$made"
c11_ensure_user_runtime_dir >/dev/null
[[ "$(mode_of "$made")" == 700 ]] || fail "loose folder not tightened"
mkdir "$TMP/elsewhere"
C11_DEV_RUNTIME_DIR="$TMP/linked" ; ln -s "$TMP/elsewhere" "$TMP/linked"
if c11_ensure_user_runtime_dir >/dev/null 2>&1; then fail "symlinked folder accepted"; fi
export C11_DEV_RUNTIME_DIR="$TMP/runtime/c11"
ok "folder is created 0700, tightened, and a symlink is refused"

# --- c11_private_write -------------------------------------------------------------
crumb="$C11_DEV_RUNTIME_DIR/c11-last-socket-path"
(umask 022; c11_private_write "$crumb" "/x/c11-debug.sock")
[[ "$(cat "$crumb")" == "/x/c11-debug.sock" && "$(mode_of "$crumb")" == 600 ]] || fail "breadcrumb not 0600"
printf 'victim\n' > "$TMP/victim"
ln -sf "$TMP/victim" "$TMP/crumb-link"
c11_private_write "$TMP/crumb-link" "/y.sock"
[[ "$(cat "$TMP/victim")" == victim && ! -L "$TMP/crumb-link" ]] || fail "wrote through a planted symlink"
ln "$TMP/victim" "$TMP/crumb-hard"
c11_private_write "$TMP/crumb-hard" "/z.sock"
[[ "$(cat "$TMP/victim")" == victim ]] || fail "wrote through a planted hard link"
printf 'theirs\n' > "$TMP/theirs"
if PATH="$SHIM:$PATH" c11_private_write "$TMP/theirs" "/w.sock" 2>/dev/null; then fail "wrote an entry another user owns"; fi
[[ "$(cat "$TMP/theirs")" == theirs ]] || fail "another user's entry changed"
ok "breadcrumbs are 0600 and never written through a link or into another user's entry"

# --- c11_private_symlink ------------------------------------------------------------
c11_private_symlink /bin/echo "$TMP/c11-cli"
[[ "$(readlink "$TMP/c11-cli")" == /bin/echo ]] || fail "link not created"
c11_private_symlink /bin/cat "$TMP/c11-cli"
[[ "$(readlink "$TMP/c11-cli")" == /bin/cat ]] || fail "own link not replaced"
if PATH="$SHIM:$PATH" c11_private_symlink /bin/echo "$TMP/c11-cli" 2>/dev/null; then fail "replaced a link another user owns"; fi
[[ "$(readlink "$TMP/c11-cli")" == /bin/cat ]] || fail "another user's link changed"
printf 'file\n' > "$TMP/plain"
if c11_private_symlink /bin/echo "$TMP/plain" 2>/dev/null; then fail "replaced a regular file"; fi
ok "the dev CLI link replaces only this user's own link"

# --- codex launch-boundary block (N15) -------------------------------------------------
block="$TMP/boundary-block.sh"
awk '/boundary_dir="\$\{CMUX_SOCKET_PATH\}\.codex-launch-boundaries"/ {on=1} on {print} on && /^        fi$/ {exit}' \
  "$ROOT/Resources/bin/codex" > "$block"
[[ -s "$block" ]] || fail "could not extract the boundary block"
surface="BE697B27-4DB6-45D4-9875-0AD724009C18"
run_block() { # <socket path>
  CMUX_SOCKET_PATH="$1" boundary_surface="$surface" EXPECTED_RESUME_ID="resume-1" bash -c "set -u; source '$block'"
}
mkdir -p "$TMP/sock-good"
run_block "$TMP/sock-good/c11.sock"
bdir="$TMP/sock-good/c11.sock.codex-launch-boundaries"
[[ "$(mode_of "$bdir")" == 700 && "$(sed -n 2p "$bdir/$surface")" == resume-1 ]] || fail "boundary marker not written in a 0700 folder"
[[ "$(mode_of "$bdir/$surface")" == 600 ]] || fail "boundary marker not 0600"

mkdir -p "$TMP/sock-open/c11.sock.codex-launch-boundaries"
chmod 777 "$TMP/sock-open/c11.sock.codex-launch-boundaries"
ln -s "$TMP/victim" "$TMP/sock-open/c11.sock.codex-launch-boundaries/$surface"
run_block "$TMP/sock-open/c11.sock"
[[ "$(cat "$TMP/victim")" == victim ]] || fail "wrote through a link in a planted 0777 folder"
[[ -L "$TMP/sock-open/c11.sock.codex-launch-boundaries/$surface" && "$(ls -A "$TMP/sock-open/c11.sock.codex-launch-boundaries")" == "$surface" ]] \
  || fail "marker written into a planted 0777 folder"

mkdir -p "$TMP/sock-link" "$TMP/link-target"
chmod 700 "$TMP/link-target"
ln -s "$TMP/link-target" "$TMP/sock-link/c11.sock.codex-launch-boundaries"
run_block "$TMP/sock-link/c11.sock"
[[ -z "$(ls -A "$TMP/link-target")" ]] || fail "marker written through a linked folder"
ok "the codex boundary block refuses a planted 0777 folder and a planted link"

# --- a GNU stat first on PATH (Homebrew's gnubin) ------------------------------------
# GNU stat reads -f as file-system status: a BSD format prints a report and fails.
GNU="$TMP/gnu-bin"
mkdir -p "$GNU"
cat > "$GNU/stat" <<'GNUSTAT'
#!/bin/sh
case "${1:-}" in
  -f) printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: apfs\n' "${3:-}"; exit 1 ;;
  -c) format="$2"; shift 2; [ "${1:-}" = "--" ] && shift
      case "$format" in
        %a) exec /usr/bin/stat -f '%Lp' "$1" ;;
        %u) exec /usr/bin/stat -f '%u' "$1" ;;
      esac ;;
esac
exit 1
GNUSTAT
chmod +x "$GNU/stat"
mkdir -p "$TMP/sock-gnu"
PATH="$GNU:$PATH" CMUX_SOCKET_PATH="$TMP/sock-gnu/c11.sock" boundary_surface="$surface" EXPECTED_RESUME_ID="resume-1" \
  bash -c "set -u; source '$block'"
gdir="$TMP/sock-gnu/c11.sock.codex-launch-boundaries"
[[ -f "$gdir/$surface" && "$(mode_of "$gdir/$surface")" == 600 && "$(mode_of "$gdir")" == 700 ]] \
  || fail "with GNU stat on PATH the boundary marker was skipped"

# shellcheck source=../scripts/lib/c11-dev-shims.sh
source "$ROOT/scripts/lib/c11-dev-shims.sh"
printf '#!/bin/sh\necho POINTED\n' > "$TMP/pointed-c11"
chmod +x "$TMP/pointed-c11"
c11_private_write "$TMP/gnu-pointer" "$TMP/pointed-c11"
C11_DEV_CLI_PATH_FILE="$TMP/gnu-pointer" write_c11_dev_cli_shim "$TMP/gnu-shim/c11-dev" "$TMP/no-fallback"
out="$(PATH="$GNU:$PATH" "$TMP/gnu-shim/c11-dev" 2>/dev/null || true)"
[[ "$out" == POINTED ]] || fail "with GNU stat on PATH the dev shim ignored its own pointer (got: $out)"
ok "a GNU stat first on PATH changes neither the codex block nor the dev shim"

# --- build lock -----------------------------------------------------------------------
lockdir="$TMP/locks"
mkdir -p "$lockdir"
C11_BUILD_LOCK_DIR="$lockdir/build.lock" "$ROOT/scripts/with-build-lock.sh" \
  bash -c "/usr/bin/stat -f '%Lp' '$lockdir/build.lock' > '$lockdir/mode'"
[[ "$(cat "$lockdir/mode")" == 700 ]] || fail "build lock not created 0700"
mkdir "$lockdir/planted-target"
ln -s "$lockdir/planted-target" "$lockdir/link.lock"
start=$SECONDS
set +e
C11_BUILD_LOCK_DIR="$lockdir/link.lock" C11_BUILD_LOCK_TIMEOUT=10 "$ROOT/scripts/with-build-lock.sh" true 2>/dev/null
rc=$?
mkdir "$lockdir/theirs.lock"
PATH="$SHIM:$PATH" C11_BUILD_LOCK_DIR="$lockdir/theirs.lock" C11_BUILD_LOCK_TIMEOUT=10 "$ROOT/scripts/with-build-lock.sh" true 2>/dev/null
rc2=$?
set -e
(( rc == 2 && rc2 == 2 && SECONDS - start < 8 )) || fail "planted lock not refused at once (rc=$rc rc2=$rc2 after $((SECONDS - start))s)"
[[ -d "$lockdir/theirs.lock" && -z "$(ls -A "$lockdir/planted-target")" ]] || fail "planted lock was written to"
ok "the build lock is 0700 and a planted lock is refused at once"

# --- shell integration socket gate -------------------------------------------------------
for shell_file in cmux-zsh-integration.zsh cmux-bash-integration.bash; do
  gate="$TMP/gate-$shell_file"
  awk '/^_cmux_socket_ok\(\) \{/ {on=1} on {print} on && /^\}/ {exit}' \
    "$ROOT/Resources/shell-integration/$shell_file" > "$gate"
  [[ -s "$gate" ]] || fail "could not extract the $shell_file socket gate"
  runner=bash; [[ "$shell_file" == *.zsh ]] && runner=zsh
  sock="$SOCKDIR/g.sock"
  /bin/rm -f "$sock"
  python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$sock"
  CMUX_SOCKET_PATH="$sock" "$runner" -c "source '$gate'; _cmux_socket_ok" || fail "$shell_file refused its own socket"
  if CMUX_SOCKET_PATH="$TMP/victim" "$runner" -c "source '$gate'; _cmux_socket_ok"; then fail "$shell_file accepted a regular file"; fi
  if [[ -S /var/run/mDNSResponder ]]; then
    # A socket another account (root) owns stands in for a planted listener.
    if CMUX_SOCKET_PATH=/var/run/mDNSResponder "$runner" -c "source '$gate'; _cmux_socket_ok"; then
      fail "$shell_file accepted a socket another user owns"
    fi
  fi
done
ok "the shell integration reports only to a socket this user owns"

echo "PASS ($pass checks)"
