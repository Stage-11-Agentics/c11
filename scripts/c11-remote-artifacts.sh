#!/usr/bin/env bash
# C11H-392: name the Linux machine's files (its hc and the relay CLI) in a c11
# app by hash, before the app is signed, and lay them out as release assets.
#
#   scripts/c11-remote-artifacts.sh stamp --app <c11.app> --dir <dir> [--ad-hoc] [--base <url>]
#
# <dir> holds `herdr-core` (hc for x86-64 Linux: the stock static musl build
# whose SHA-256 Resources/hc/hc-source.json pins under remote.linux-x86_64)
# and `c11` (the c11 CLI built for x86-64 Linux from this commit,
# tools/linux-cli/build.sh --static). A herdr-core that is not the pinned build
# is refused. stamp writes <app>/Contents/Resources/remote-artifacts.json,
# naming each file's SHA-256, its asset name and the URL it is published at
# (--base, default the release's own download folder on GitHub), and copies the
# two files under their asset names (herdr-core-linux-x86_64, c11-linux-x86_64;
# scripts/release_asset_guard.js lists them) into <dir>/assets/ with
# c11-linux-checksums.txt.
#
# It publishes nothing: uploading <dir>/assets/ is part of the release, on the
# operator's go. Run it before the app is signed, so the signature seals the
# manifest (scripts/c11-release.sh --sign-app <app> --remote-artifacts <dir>).
# --ad-hoc re-signs an already built development app ad hoc afterwards, keeping
# its entitlements, for a QA guest; never a release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_JSON="${C11_HC_SOURCE_JSON:-$ROOT/Resources/hc/hc-source.json}"
CODESIGN="${C11_CODESIGN:-/usr/bin/codesign}"
PLATFORM=linux-x86_64

die() { printf 'c11-remote-artifacts: %s\n' "$1" >&2; exit 2; }
sha_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

[[ "${1:-}" == stamp ]] || die "usage: stamp --app <c11.app> --dir <dir> [--ad-hoc] [--base <url>]"
shift
APP= DIR= AD_HOC=0 BASE=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --ad-hoc) AD_HOC=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[[ -d "$APP/Contents/Resources" ]] || die "no app at ${APP:-<none>}"
[[ -d "$DIR" ]] || die "no folder at ${DIR:-<none>}"
for name in herdr-core c11; do
  [[ -f "$DIR/$name" && ! -L "$DIR/$name" ]] || die "$DIR/$name is missing or not a plain file"
done

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" \
  || die "$APP has no CFBundleShortVersionString"
[[ "$VERSION" =~ ^[0-9A-Za-z._-]{1,64}$ ]] || die "bad app version $VERSION"
HC_VERSION="$(/usr/bin/plutil -extract version raw -o - "$SOURCE_JSON")" || die "$SOURCE_JSON has no version"
HC_PIN="$(/usr/bin/plutil -extract remote.$PLATFORM.sha256 raw -o - "$SOURCE_JSON" 2>/dev/null)" \
  || die "$SOURCE_JSON pins no hc for $PLATFORM (remote.$PLATFORM.sha256)"
[[ "$HC_PIN" =~ ^[0-9a-f]{64}$ ]] || die "the $PLATFORM hc pin is not a lower-case SHA-256"

HC_SHA="$(sha_of "$DIR/herdr-core")"
[[ "$HC_SHA" == "$HC_PIN" ]] || die "$DIR/herdr-core hashes to $HC_SHA, not the pinned $HC_PIN; refusing it"
CLI_SHA="$(sha_of "$DIR/c11")"
/usr/bin/head -c 4 "$DIR/c11" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n' | /usr/bin/grep -qx 7f454c46 \
  || die "$DIR/c11 is not an ELF executable"
/usr/bin/head -c 4 "$DIR/herdr-core" | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \n' | /usr/bin/grep -qx 7f454c46 \
  || die "$DIR/herdr-core is not an ELF executable"

HC_ASSET="herdr-core-$PLATFORM"
CLI_ASSET="c11-$PLATFORM"
[[ -n "$BASE" ]] || BASE="https://github.com/Stage-11-Agentics/c11/releases/download/v$VERSION"
[[ "$BASE" == https://* ]] || die "--base must be an https URL"
BASE="${BASE%/}"

MANIFEST="$APP/Contents/Resources/remote-artifacts.json"
/usr/bin/python3 -I - "$MANIFEST.tmp" "$PLATFORM" "$HC_VERSION" "$HC_SHA" "$HC_ASSET" "$VERSION" "$CLI_SHA" "$CLI_ASSET" "$BASE" <<'PY'
import json, sys
out, platform, hc_version, hc_sha, hc_asset, version, cli_sha, cli_asset, base = sys.argv[1:]
artifacts = [
    {"platform": platform, "name": "herdr-core", "version": hc_version, "sha256": hc_sha, "asset": hc_asset, "url": base + "/" + hc_asset},
    {"platform": platform, "name": "c11", "version": version, "sha256": cli_sha, "asset": cli_asset, "url": base + "/" + cli_asset},
]
with open(out, "w", encoding="utf-8") as handle:
    json.dump({"version": 1, "artifacts": artifacts}, handle, separators=(",", ":"))
    handle.write("\n")
PY
mv -f "$MANIFEST.tmp" "$MANIFEST"

ASSETS="$DIR/assets"
mkdir -p "$ASSETS"
cp -f "$DIR/herdr-core" "$ASSETS/$HC_ASSET"
cp -f "$DIR/c11" "$ASSETS/$CLI_ASSET"
chmod 0755 "$ASSETS/$HC_ASSET" "$ASSETS/$CLI_ASSET"
( cd "$ASSETS" && /usr/bin/shasum -a 256 "$HC_ASSET" "$CLI_ASSET" > c11-linux-checksums.txt )
[[ "$(sha_of "$ASSETS/$HC_ASSET")" == "$HC_SHA" && "$(sha_of "$ASSETS/$CLI_ASSET")" == "$CLI_SHA" ]] \
  || die "the asset copies do not hash to the manifest"

if [[ "$AD_HOC" -eq 1 ]]; then
  "$CODESIGN" --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$APP" \
    || die "ad hoc re-sign failed"
fi
printf 'c11-remote-artifacts: %s names %s %s and %s %s; assets in %s\n' \
  "$MANIFEST" "$HC_ASSET" "${HC_SHA:0:12}" "$CLI_ASSET" "${CLI_SHA:0:12}" "$ASSETS"
