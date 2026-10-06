#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <dmg-path> <tag> [output-path]" >&2
  exit 1
fi

DMG_PATH="$1"
TAG="$2"
OUT_PATH="${3:-appcast.xml}"

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is required (exported from Sparkle generate_keys)." >&2
  exit 1
fi

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.3}"
# Defaults reflect the c11 fork's release path. release.yml + nightly.yml
# both override these explicitly with the same URLs; the defaults guard
# against a human regenerating an appcast locally and silently writing
# upstream URLs that would never resolve under the fork.
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/Stage-11-Agentics/c11/releases/download/$TAG/}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/Stage-11-Agentics/c11/releases/tag/$TAG}"

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

# SPARKLE_BIN_DIR points at prebuilt Sparkle tools (the bin/ of a Sparkle
# release tarball). scripts/release-local.sh sets it so a local release
# never runs xcodebuild on the operator's machine; CI leaves it unset and
# builds the tools from source.
if [[ -n "${SPARKLE_BIN_DIR:-}" ]]; then
  generate_appcast="$SPARKLE_BIN_DIR/generate_appcast"
  sign_update="$SPARKLE_BIN_DIR/sign_update"
else
  echo "Cloning Sparkle ${SPARKLE_VERSION}..."
  git clone --depth 1 --branch "$SPARKLE_VERSION" https://github.com/sparkle-project/Sparkle "$work_dir/Sparkle"

  echo "Building Sparkle generate_appcast tool..."
  xcodebuild \
    -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
    -scheme generate_appcast \
    -configuration Release \
    -derivedDataPath "$work_dir/build" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

  echo "Building Sparkle sign_update tool..."
  xcodebuild \
    -project "$work_dir/Sparkle/Sparkle.xcodeproj" \
    -scheme sign_update \
    -configuration Release \
    -derivedDataPath "$work_dir/build" \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

  generate_appcast="$work_dir/build/Build/Products/Release/generate_appcast"
  sign_update="$work_dir/build/Build/Products/Release/sign_update"
fi

if [[ ! -x "$generate_appcast" ]]; then
  echo "generate_appcast binary not found at $generate_appcast" >&2
  exit 1
fi
if [[ ! -x "$sign_update" ]]; then
  echo "sign_update binary not found at $sign_update" >&2
  exit 1
fi

archives_dir="$work_dir/archives"
mkdir -p "$archives_dir"
cp "$DMG_PATH" "$archives_dir/$(basename "$DMG_PATH")"

key_file="$work_dir/sparkle_ed_key"
# Ensure base64 padding (keys may be stored without trailing '=')
padded_key="$SPARKLE_PRIVATE_KEY"
while (( ${#padded_key} % 4 != 0 )); do
  padded_key="${padded_key}="
done
printf "%s" "$padded_key" > "$key_file"

generated_appcast_path="$archives_dir/$(basename "$OUT_PATH")"

"$generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  "$archives_dir"

if [[ ! -f "$generated_appcast_path" ]]; then
  fallback_generated_appcast="$(find "$archives_dir" -maxdepth 1 -name '*.xml' | head -n 1)"
  if [[ -n "$fallback_generated_appcast" ]]; then
    generated_appcast_path="$fallback_generated_appcast"
  fi
fi

if [[ ! -f "$generated_appcast_path" ]]; then
  echo "Expected appcast was not generated." >&2
  exit 1
fi

# Check if generate_appcast added the edSignature. If not, use sign_update
# to sign the DMG and inject the signature. generate_appcast silently skips
# signing when the public key derived from the private key doesn't match the
# SUPublicEDKey in the app's Info.plist.
if ! grep -q 'sparkle:edSignature' "$generated_appcast_path"; then
  echo "Warning: generate_appcast did not add edSignature. Using sign_update fallback..."
  SIGNATURE=$("$sign_update" -p --ed-key-file "$key_file" "$DMG_PATH")
  DMG_LENGTH=$(stat -f%z "$DMG_PATH")
  echo "  EdDSA signature: ${SIGNATURE:0:20}..."
  echo "  DMG length: $DMG_LENGTH"

  # Rewrite the enclosure's length and signature in place. generate_appcast
  # already writes a length attribute, so appending another would produce a
  # duplicate attribute and an appcast Sparkle cannot parse.
  python3 - "$generated_appcast_path" "$SIGNATURE" "$DMG_LENGTH" <<'PY_INJECT'
import re
import sys

path, sig, length = sys.argv[1:]
xml = open(path, encoding="utf-8").read()
enclosures = re.findall(r"<enclosure\b[^>]*>", xml)
if len(enclosures) != 1:
    sys.exit(f"expected one enclosure in {path}, found {len(enclosures)}")
old = enclosures[0]
new = re.sub(r'\s(?:length|sparkle:edSignature)="[^"]*"', "", old)
new = new.replace("<enclosure", f'<enclosure sparkle:edSignature="{sig}" length="{length}"', 1)
open(path, "w", encoding="utf-8").write(xml.replace(old, new, 1))
print("  Injected edSignature into appcast.xml")
PY_INJECT
fi

cp "$generated_appcast_path" "$OUT_PATH"
echo "Generated appcast at $OUT_PATH"

# A malformed appcast breaks every client's update check; refuse to emit one.
python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$OUT_PATH" \
  || { echo "ERROR: appcast is not well-formed XML!" >&2; exit 1; }

# Verify the appcast has a signature
if grep -q 'sparkle:edSignature' "$OUT_PATH"; then
  echo "Verified: appcast contains sparkle:edSignature"
else
  echo "ERROR: appcast is missing sparkle:edSignature!" >&2
  exit 1
fi
