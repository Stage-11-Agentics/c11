#!/usr/bin/env bash
# Fetch Sparkle's prebuilt release tools (generate_appcast, sign_update,
# generate_keys) from the official, checksum-verified tarball and print their
# bin/ directory on stdout. Version and checksum are the single pin shared by
# release.yml, nightly.yml and release-local.sh; keep the version equal to the
# Sparkle pin in Package.resolved.
#
# Usage: scripts/fetch-sparkle-tools.sh [cache-root]
#   cache-root defaults to ${XDG_CACHE_HOME:-$HOME/.cache}/c11/sparkle
set -euo pipefail

SPARKLE_TOOLS_VERSION="2.9.3"
SPARKLE_TOOLS_SHA256="74a07da821f92b79310009954c0e15f350173374a3abe39095b4fc5096916be6"

root="${1:-${XDG_CACHE_HOME:-$HOME/.cache}/c11/sparkle}"
dir="$root/$SPARKLE_TOOLS_VERSION"
bin="$dir/bin"

if [[ ! -x "$bin/generate_appcast" || ! -x "$bin/sign_update" || ! -x "$bin/generate_keys" ]]; then
  mkdir -p "$dir"
  tarball="$dir/Sparkle.tar.xz"
  curl -fsSL --retry 3 -o "$tarball" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_TOOLS_VERSION/Sparkle-$SPARKLE_TOOLS_VERSION.tar.xz"
  actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  if [[ "$actual" != "$SPARKLE_TOOLS_SHA256" ]]; then
    /bin/rm -f "$tarball"
    echo "Sparkle $SPARKLE_TOOLS_VERSION tarball checksum mismatch: got $actual" >&2
    exit 1
  fi
  tar -xf "$tarball" -C "$dir"
  /bin/rm -f "$tarball"
fi

for tool in generate_appcast sign_update generate_keys; do
  [[ -x "$bin/$tool" ]] || { echo "Sparkle tool missing after extract: $bin/$tool" >&2; exit 1; }
done
echo "$bin"
