#!/bin/bash
# Build the Linux c11 (the c11 CLI) from the files the Xcode c11-cli target compiles (sources.txt).
#   tools/linux-cli/build.sh [--static] [--debug]     run on Linux with a swift.org toolchain (and the Static Linux SDK for --static)
# Output: tools/linux-cli/.stage/out/c11 and one line with the time, size and sha256.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
stage="$here/.stage"; cfg=release; sdk=()
for a in "$@"; do case "$a" in --static) sdk=(--swift-sdk x86_64-swift-linux-musl);; --debug) cfg=debug;; *) echo "build.sh: unknown $a" >&2; exit 2;; esac; done
t0=$(date +%s)
rm -rf "$stage/Sources" "$stage/Shims"; mkdir -p "$stage/Sources/c11" "$stage/out"
cp "$here/Package.swift" "$here/Package.resolved" "$stage/"; cp -R "$here/Shims" "$stage/"
# The staged copy only: the two Apple imports become their Linux equivalents, and a module-qualified `Darwin.x` names
# the C library this build links (Glibc, or Musl for --static); nothing else changes.
libc=Glibc; [ ${#sdk[@]} -eq 0 ] || libc=Musl
while read -r f; do
  [ -n "$f" ] || continue; mkdir -p "$stage/Sources/c11/$(dirname "$f")"
  sed -e "s/^import Darwin\$/import $libc/" -e 's/^import CryptoKit$/import Crypto/' -e "s/\bDarwin\./$libc./g" \
      "$root/$f" > "$stage/Sources/c11/$f"
done < "$here/sources.txt"
cp "$here/LinuxSupport/"*.swift "$stage/Sources/c11/"
if [ ${#sdk[@]} -gt 0 ]; then   # static musl: SQLite from its amalgamation, pinned by SQLite's own SHA3-256
  SQLITE_ZIP=2026/sqlite-amalgamation-3540100.zip SQLITE_SHA3=92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
  cache="$HOME/.cache/c11-linux-cli"; mkdir -p "$cache"; zip="$cache/$(basename "$SQLITE_ZIP")"
  [ -s "$zip" ] || curl -fsSL -o "$zip" "https://sqlite.org/$SQLITE_ZIP"
  python3 -c 'import hashlib,sys; d=hashlib.sha3_256(open(sys.argv[1],"rb").read()).hexdigest(); sys.exit(0 if d==sys.argv[2] else "sqlite amalgamation: SHA3-256 "+d)' "$zip" "$SQLITE_SHA3"
  a="$stage/Shims/SQLite3Amalgamation"; mkdir -p "$a/include"; tmp="$(mktemp -d)"; unzip -q -o "$zip" -d "$tmp"
  cp "$tmp"/sqlite-amalgamation-*/sqlite3.c "$a/"; cp "$tmp"/sqlite-amalgamation-*/sqlite3.h "$a/include/"; rm -rf "$tmp"
  export C11_LINUX_SQLITE=amalgamation
fi
cd "$stage"
swift build -c "$cfg" ${sdk[@]+"${sdk[@]}"} --product c11 2>&1 | tee "$stage/build.log" | grep -E "error:|warning: unre|Compiling|Build complete" | grep -v "^\[" | tail -400 || true
bin="$(swift build -c "$cfg" ${sdk[@]+"${sdk[@]}"} --show-bin-path)/c11"
[ -x "$bin" ] || { echo "build.sh: no binary; $(grep -c 'error:' "$stage/build.log") errors, log $stage/build.log" >&2; exit 1; }
# A release build ships without its symbols (about a tenth of the size); a debug build keeps them.
if [ "$cfg" = release ]; then strip --strip-all -o "$stage/out/c11" "$bin"; else cp "$bin" "$stage/out/c11"; fi
echo "build.sh: $cfg ${sdk[*]:-glibc} in $(( $(date +%s) - t0 ))s, $(( $(stat -c %s "$stage/out/c11") / 1048576 )) MiB, sha256 $(sha256sum "$stage/out/c11" | cut -c1-16)"
