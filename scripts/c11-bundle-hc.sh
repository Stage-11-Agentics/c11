#!/usr/bin/env bash
# C11H-66: put the stock hc core into c11.app at Contents/Helpers/herdr-core.
#
# Run by the app target's "Bundle hc core" build phase (SRCROOT, CONFIGURATION,
# TARGET_BUILD_DIR, WRAPPER_NAME), or by hand with C11_BUNDLE_APP=<c11.app>.
#
# Source: the one build named by SHA-256 in Resources/hc/hc-source.json (the hc
# Lead's reproducible stock build). Any other file is refused. It is taken from
# the SHA-keyed cache ~/.cache/c11/hc/<sha>/herdr-core (C11_HC_CACHE_DIR), which
# is seeded from the hc repo's build output (C11_HC_BUILD_OUT, default
# <hc repo>/out/<ref>, the repo being C11_HC_REPO from the environment or
# ~/.config/c11/dev-hosts, else ~/src/hc) only when its build.json names the same
# commit and hash and says unsigned.
#
# Steps, inside out: copy, sign the helper alone (hardened runtime, no
# entitlements; ad hoc unless C11_HC_SIGN_IDENTITY), then record the signed
# file's hash in Contents/Resources/hc-pin.json. Xcode's own app signature then
# seals that file. scripts/c11-release.sh re-signs the helper with the
# Developer ID and rewrites the hash before it signs the app.
#
# No source build: Release fails; Debug warns and leaves no helper (the app
# then uses the external pin, for the C11H-66 transition).
# Helpers stays writable here. The installer makes it 0555 (S1).
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_JSON="${C11_HC_SOURCE_JSON:-$ROOT/Resources/hc/hc-source.json}"
CONFIG="${CONFIGURATION:-Debug}"
CODESIGN="${C11_CODESIGN:-/usr/bin/codesign}"
IDENTITY="${C11_HC_SIGN_IDENTITY:--}"
HELPER_ID="com.stage11.c11.herdr-core"

die() { printf 'error: c11-bundle-hc: %s\n' "$1" >&2; exit 1; }
warn() { printf 'warning: c11-bundle-hc: %s\n' "$1" >&2; }

if [[ -n "${C11_BUNDLE_APP:-}" ]]; then
  APP="$C11_BUNDLE_APP"
else
  [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]] || die "set C11_BUNDLE_APP or run from Xcode"
  APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
fi
[[ -d "$APP/Contents" ]] || die "no app at $APP"
[[ -f "$SOURCE_JSON" ]] || die "no $SOURCE_JSON"

field() { /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
sha_of() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

VERSION="$(field version "$SOURCE_JSON")" || die "hc-source.json has no version"
REF="$(field ref "$SOURCE_JSON")" || die "hc-source.json has no ref"
COMMIT="$(field commit "$SOURCE_JSON")" || die "hc-source.json has no commit"
SHA="$(field sha256 "$SOURCE_JSON")" || die "hc-source.json has no sha256"
GENERATION="$(field protocolGeneration "$SOURCE_JSON")" || die "hc-source.json has no protocolGeneration"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "hc-source.json sha256 is not a lowercase SHA-256"
[[ "$VERSION" =~ ^[0-9.]+$ ]] || die "hc-source.json version is not numeric"
[[ "$GENERATION" =~ ^[0-9]+$ ]] || die "hc-source.json protocolGeneration is not a number"

CACHE_ROOT="${C11_HC_CACHE_DIR:-$HOME/.cache/c11/hc}"
CACHED="$CACHE_ROOT/$SHA/herdr-core"
# shellcheck source=dev-hosts.sh
source "$ROOT/scripts/dev-hosts.sh"
HC_REPO="$(c11_dev_host C11_HC_REPO 2>/dev/null)" || HC_REPO="$HOME/src/hc"
[[ "$HC_REPO" != "~/"* ]] || HC_REPO="$HOME/${HC_REPO#\~/}"
BUILD_OUT="${C11_HC_BUILD_OUT:-$HC_REPO/out/$REF}"

seed_cache() {
  local candidate="$BUILD_OUT/herdr-core" record="$BUILD_OUT/build.json" got tmp
  [[ -f "$candidate" && -f "$record" ]] || return 1
  [[ "$(field commit "$record")" == "$COMMIT" ]] || { warn "$record names another commit"; return 1; }
  [[ "$(field sha256 "$record")" == "$SHA" ]] || { warn "$record names another hash"; return 1; }
  [[ "$(field signed "$record")" == "false" ]] || { warn "$record is not an unsigned build"; return 1; }
  got="$(sha_of "$candidate")"
  [[ "$got" == "$SHA" ]] || { warn "$candidate hashes to $got, not $SHA"; return 1; }
  mkdir -p "$CACHE_ROOT/$SHA"
  tmp="$CACHE_ROOT/$SHA/.herdr-core.$$"
  cp "$candidate" "$tmp"
  [[ "$(sha_of "$tmp")" == "$SHA" ]] || { rm -f "$tmp"; return 1; }
  chmod 0555 "$tmp"
  mv -f "$tmp" "$CACHED"
}

if [[ -f "$CACHED" ]]; then
  got="$(sha_of "$CACHED")"
  [[ "$got" == "$SHA" ]] || die "cached $CACHED hashes to $got, not $SHA; refusing it"
elif ! seed_cache; then
  if [[ "$CONFIG" == "Release" ]]; then
    die "hc core $SHA ($REF $COMMIT) is not in $CACHE_ROOT and $BUILD_OUT has no matching build"
  fi
  warn "hc core $SHA not available; this $CONFIG build has no bundled core and uses the external pin"
  exit 0
fi

HELPERS="$APP/Contents/Helpers"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$HELPERS" "$RESOURCES"
chmod u+w "$HELPERS"
tmp="$HELPERS/.herdr-core.$$"
trap 'rm -f "$tmp"' EXIT
cp "$CACHED" "$tmp"
chmod 0755 "$tmp"
[[ "$(sha_of "$tmp")" == "$SHA" ]] || die "copy of $CACHED does not hash to $SHA"
# Hardened runtime, no entitlements: what passed the hc contract suite (W3).
"$CODESIGN" --force --options runtime --identifier "$HELPER_ID" --sign "$IDENTITY" "$tmp" \
  || die "codesign of the helper failed"
mv -f "$tmp" "$HELPERS/herdr-core"
trap - EXIT
SIGNED="$(sha_of "$HELPERS/herdr-core")"
manifest_tmp="$RESOURCES/.hc-pin.json.$$"
printf '{"version":"%s","protocolGeneration":%s,"sourceSHA256":"%s","executableSHA256":"%s"}\n' \
  "$VERSION" "$GENERATION" "$SHA" "$SIGNED" > "$manifest_tmp"
mv -f "$manifest_tmp" "$RESOURCES/hc-pin.json"
printf 'c11-bundle-hc: %s source %s signed %s\n' "$HELPERS/herdr-core" "$SHA" "$SIGNED"
