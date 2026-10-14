#!/usr/bin/env bash
# Lint .github/workflows with pinned actionlint v1.7.12.
# Release commit 914e7df21a07ef503a81201c76d2b11c789d3fca.
# https://github.com/rhysd/actionlint/releases/tag/v1.7.12
#
# The tarball SHA-256 is the pin. The -shellcheck= flag is set on purpose:
# actionlint's own checks are the gate (workflow syntax, contexts, expressions).
# Checking run-script style on today's workflows reports 15 pre-existing hits
# (SC2012, SC2086, SC2129, SC2016, SC2209), including false positives on
# GitHub expressions. That noise is not the failure that left a scheduled
# workflow invalid for days.
set -euo pipefail

VERSION="1.7.12"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    ASSET="linux_amd64"
    SHA="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
    ;;
  Linux-aarch64 | Linux-arm64)
    ASSET="linux_arm64"
    SHA="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"
    ;;
  Darwin-arm64)
    ASSET="darwin_arm64"
    SHA="aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
    ;;
  Darwin-x86_64)
    ASSET="darwin_amd64"
    SHA="5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644"
    ;;
  *)
    echo "error: unsupported host $(uname -s)-$(uname -m)" >&2
    exit 2
    ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/c11-actionlint.XXXXXX")"
trap '/bin/rm -rf "$TMP"' EXIT

TARBALL="$TMP/actionlint.tar.gz"
URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/actionlint_${VERSION}_${ASSET}.tar.gz"
curl -fsSL --retry 3 --retry-delay 2 -o "$TARBALL" "$URL"

if command -v sha256sum >/dev/null 2>&1; then
  got="$(sha256sum "$TARBALL" | awk '{print $1}')"
else
  got="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
fi
if [[ "$got" != "$SHA" ]]; then
  echo "error: actionlint ${VERSION} ${ASSET} checksum mismatch" >&2
  echo "  want ${SHA}" >&2
  echo "  got  ${got}" >&2
  exit 1
fi

tar -xzf "$TARBALL" -C "$TMP" actionlint
chmod +x "$TMP/actionlint"

cd "$ROOT"
exec "$TMP/actionlint" -shellcheck= "$@"
