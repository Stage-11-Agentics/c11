#!/usr/bin/env bash
# Resolve the pinned Zig toolchain without changing system directories.
# Prints the directory containing the selected zig executable.
set -euo pipefail

ZIG_REQUIRED="${C11_ZIG_VERSION:-0.15.2}"

version_matches() {
  local executable="$1"
  [[ -x "$executable" ]] && "$executable" version 2>/dev/null | grep -qx "$ZIG_REQUIRED"
}

if command -v zig >/dev/null 2>&1 && version_matches "$(command -v zig)"; then
  dirname "$(command -v zig)"
  exit 0
fi

CANDIDATE="${C11_ZIG_DIR:-$HOME/zig-$ZIG_REQUIRED}"
if version_matches "$CANDIDATE/zig"; then
  printf '%s\n' "$CANDIDATE"
  exit 0
fi

CACHE_ROOT="${C11_ZIG_CACHE_DIR:-$HOME/.cache/c11/zig}"
INSTALL_DIR="$CACHE_ROOT/$ZIG_REQUIRED"
if version_matches "$INSTALL_DIR/zig"; then
  printf '%s\n' "$INSTALL_DIR"
  exit 0
fi

mkdir -p "$CACHE_ROOT"
LOCK_DIR="$INSTALL_DIR.lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if version_matches "$INSTALL_DIR/zig"; then
    printf '%s\n' "$INSTALL_DIR"
    exit 0
  fi
  sleep 1
done
cleanup_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT

if version_matches "$INSTALL_DIR/zig"; then
  printf '%s\n' "$INSTALL_DIR"
  exit 0
fi

case "$(uname -m)" in
  arm64|aarch64) ARCH="aarch64" ;;
  x86_64) ARCH="x86_64" ;;
  *) echo "Unsupported CPU arch: $(uname -m)" >&2; exit 1 ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-zig.XXXXXX")"
cleanup_tmp() {
  rm -rf "$TMP_DIR"
}
trap 'cleanup_tmp; cleanup_lock' EXIT

ARCHIVE="$TMP_DIR/zig.tar.xz"
URL="https://ziglang.org/download/$ZIG_REQUIRED/zig-$ARCH-macos-$ZIG_REQUIRED.tar.xz"
curl --fail --show-error --location --retry 3 --retry-all-errors -o "$ARCHIVE" "$URL"
tar -xf "$ARCHIVE" -C "$TMP_DIR"
EXTRACTED="$TMP_DIR/zig-$ARCH-macos-$ZIG_REQUIRED"
version_matches "$EXTRACTED/zig" || {
  echo "downloaded Zig does not report version $ZIG_REQUIRED" >&2
  exit 1
}
mv "$EXTRACTED" "$INSTALL_DIR"
printf '%s\n' "$INSTALL_DIR"
