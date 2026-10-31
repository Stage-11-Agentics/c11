#!/usr/bin/env bash
# Install the pinned zig toolchain into /usr/local for the release and nightly
# workflows. The extracted toolchain is kept in <cache-dir>, which the workflow
# restores with actions/cache, so a hit skips the slow ziglang.org download
# (about 36 s at 1.3 MB/s in v1.5.1) and the xz extract. A miss downloads the
# official tarball and verifies its published SHA-256 before extracting.
#
# Usage: scripts/install-zig.sh <cache-dir>
set -euo pipefail

ZIG_REQUIRED="0.15.2"
cache_root="${1:?usage: install-zig.sh <cache-dir>}"

if command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -q "^${ZIG_REQUIRED}$"; then
  echo "zig ${ZIG_REQUIRED} already installed"
  exit 0
fi

case "$(uname -m)" in
  arm64|aarch64)
    ZIG_HOST_ARCH="aarch64"
    ZIG_SHA256="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b" ;;
  x86_64)
    ZIG_HOST_ARCH="x86_64"
    ZIG_SHA256="375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f" ;;
  *) echo "Unsupported CPU arch: $(uname -m)" >&2; exit 1 ;;
esac

name="zig-${ZIG_HOST_ARCH}-macos-${ZIG_REQUIRED}"
toolchain="$cache_root/$name"

if [[ -x "$toolchain/zig" && -d "$toolchain/lib" ]] \
    && [[ "$("$toolchain/zig" version 2>/dev/null)" == "$ZIG_REQUIRED" ]]; then
  echo "zig ${ZIG_REQUIRED} (${ZIG_HOST_ARCH}) from cache"
else
  echo "Installing zig ${ZIG_REQUIRED} (${ZIG_HOST_ARCH}) from tarball"
  /bin/rm -rf "$toolchain"
  mkdir -p "$cache_root"
  tarball="$cache_root/$name.tar.xz"
  curl -fSL --retry 3 "https://ziglang.org/download/${ZIG_REQUIRED}/${name}.tar.xz" -o "$tarball"
  actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  if [[ "$actual" != "$ZIG_SHA256" ]]; then
    /bin/rm -f "$tarball"
    echo "zig ${ZIG_REQUIRED} tarball checksum mismatch: got $actual" >&2
    exit 1
  fi
  tar xf "$tarball" -C "$cache_root"
  /bin/rm -f "$tarball"
fi

# zig looks for its standard library at ../lib/zig beside the binary, so the
# lib tree is linked from the toolchain instead of copied (thousands of files).
sudo mkdir -p /usr/local/bin /usr/local/lib
sudo cp -f "$toolchain/zig" /usr/local/bin/zig
sudo /bin/rm -rf /usr/local/lib/zig
sudo ln -s "$toolchain/lib" /usr/local/lib/zig
/usr/local/bin/zig version
