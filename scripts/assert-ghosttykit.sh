#!/usr/bin/env bash
# Verify that the local GhosttyKit artifact belongs to the checked-out
# ghostty submodule before an xcodebuild can consume it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/ghostty"
KIT_PATH="${GHOSTTYKIT_PATH:-$REPO_ROOT/GhosttyKit.xcframework}"
CACHE_ROOT="${CMUX_GHOSTTYKIT_CACHE_DIR:-$HOME/.cache/cmux/ghosttykit}"
CHECKSUMS_FILE="${GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
DOWNLOAD_SCRIPT="${GHOSTTYKIT_DOWNLOAD_SCRIPT:-$SCRIPT_DIR/download-prebuilt-ghosttykit.sh}"

refuse() {
  echo "error: GhosttyKit.xcframework is missing or does not match ghostty SHA $GHOSTTY_SHA; run ./scripts/setup.sh to provision a pinned kit." >&2
  exit 1
}

if ! GHOSTTY_SHA="$(git -C "$REPO_ROOT" ls-tree HEAD ghostty | awk '$1 == "160000" && $4 == "ghostty" { print $3; found = 1 } END { if (!found) exit 1 }')"; then
  echo "error: ghostty submodule gitlink is missing from HEAD; check out a pinned c11 revision." >&2
  exit 1
fi

if [[ ! -d "$GHOSTTY_DIR" ]] || ! CHECKED_OUT_GHOSTTY_SHA="$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null)"; then
  echo "error: ghostty submodule is missing; run git submodule update --init --recursive ghostty vendor/bonsplit." >&2
  exit 1
fi

if [[ "$CHECKED_OUT_GHOSTTY_SHA" != "$GHOSTTY_SHA" ]]; then
  echo "error: ghostty submodule is at $CHECKED_OUT_GHOSTTY_SHA, but HEAD pins $GHOSTTY_SHA; run git submodule update --init --recursive ghostty." >&2
  exit 1
fi

if [[ ! "$GHOSTTY_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "error: ghostty submodule HEAD is not a full commit SHA; run git submodule update --init --recursive ghostty." >&2
  exit 1
fi

CACHE_DIR="$CACHE_ROOT/$GHOSTTY_SHA"
CACHE_KIT="$CACHE_DIR/GhosttyKit.xcframework"

resolved_directory() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  (cd "$path" && pwd -P)
}

kit_matches() {
  local kit_real cache_real
  [[ -L "$KIT_PATH" ]] || return 1
  kit_real="$(resolved_directory "$KIT_PATH")" || return 1
  cache_real="$(resolved_directory "$CACHE_KIT")" || return 1
  [[ "$kit_real" == "$cache_real" ]]
}

if kit_matches; then
  echo "GhosttyKit.xcframework matches ghostty $GHOSTTY_SHA"
  exit 0
fi

checksum_count=0
if [[ -f "$CHECKSUMS_FILE" ]]; then
  checksum_count="$(awk -v sha="$GHOSTTY_SHA" '$1 == sha { count += 1 } END { print count + 0 }' "$CHECKSUMS_FILE")"
fi
if [[ "$checksum_count" -ne 1 ]]; then
  refuse
fi

mkdir -p "$CACHE_ROOT"

if [[ ! -d "$CACHE_KIT" ]]; then
  if [[ ! -x "$DOWNLOAD_SCRIPT" ]]; then
    echo "error: GhosttyKit.xcframework is missing or stale and its download helper is unavailable; run ./scripts/setup.sh to provision a pinned kit." >&2
    exit 1
  fi

  DOWNLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-ghosttykit.XXXXXX")"
  if ! (
    cd "$DOWNLOAD_DIR"
    GHOSTTY_SHA="$GHOSTTY_SHA" \
      GHOSTTYKIT_OUTPUT_DIR="$DOWNLOAD_DIR/GhosttyKit.xcframework" \
      GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
      "$DOWNLOAD_SCRIPT"
  ); then
    rm -rf "$DOWNLOAD_DIR"
    echo "error: could not download GhosttyKit.xcframework for ghostty $GHOSTTY_SHA; run ./scripts/setup.sh and retry." >&2
    exit 1
  fi

  if [[ ! -d "$DOWNLOAD_DIR/GhosttyKit.xcframework" ]]; then
    rm -rf "$DOWNLOAD_DIR"
    echo "error: GhosttyKit download did not produce a framework for ghostty $GHOSTTY_SHA; run ./scripts/setup.sh and retry." >&2
    exit 1
  fi

  CACHE_STAGE="$(mktemp -d "$CACHE_ROOT/.c11-ghosttykit.XXXXXX")"
  mv "$DOWNLOAD_DIR/GhosttyKit.xcframework" "$CACHE_STAGE/GhosttyKit.xcframework"
  rm -rf "$DOWNLOAD_DIR"
  if [[ -e "$CACHE_DIR" || -L "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"
  fi
  mv "$CACHE_STAGE" "$CACHE_DIR"
  echo "Downloaded and cached GhosttyKit.xcframework for ghostty $GHOSTTY_SHA"
fi

BACKUP_PATH=""
if [[ -e "$KIT_PATH" || -L "$KIT_PATH" ]]; then
  BACKUP_PATH="$KIT_PATH.bak-$$"
  while [[ -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ]]; do
    BACKUP_PATH="$KIT_PATH.bak-$$-$RANDOM"
  done
  if ! mv "$KIT_PATH" "$BACKUP_PATH"; then
    echo "error: cannot replace stale GhosttyKit.xcframework at $KIT_PATH; run ./scripts/setup.sh after removing it." >&2
    exit 1
  fi
fi

if ! ln -s "$CACHE_KIT" "$KIT_PATH" || ! kit_matches; then
  rm -f "$KIT_PATH"
  if [[ -n "$BACKUP_PATH" ]]; then
    mv "$BACKUP_PATH" "$KIT_PATH" || true
  fi
  echo "error: could not link GhosttyKit.xcframework for ghostty $GHOSTTY_SHA; run ./scripts/setup.sh and retry." >&2
  exit 1
fi

if [[ -n "$BACKUP_PATH" ]]; then
  rm -rf "$BACKUP_PATH"
fi

echo "GhosttyKit.xcframework ready for ghostty $GHOSTTY_SHA"
