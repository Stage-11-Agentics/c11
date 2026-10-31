#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <dmg-path> <tag> [output-path]" >&2
  exit 1
fi

DMG_PATH="$1"
TAG="$2"
OUT_PATH="${3:-appcast.xml}"

# SPARKLE_PRIVATE_KEY_FILE passes the key by path (release-local.sh), so it
# stays out of the environment every child process inherits.
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  SPARKLE_PRIVATE_KEY="$(cat "$SPARKLE_PRIVATE_KEY_FILE")"
fi
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE is required (exported from Sparkle generate_keys)." >&2
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
  if [[ -d "$work_dir/mnt" ]]; then hdiutil detach -quiet "$work_dir/mnt" 2>/dev/null || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

# SPARKLE_BIN_DIR points at prebuilt Sparkle tools (the bin/ of a Sparkle
# release tarball, from scripts/fetch-sparkle-tools.sh). release.yml,
# nightly.yml and release-local.sh set it; without it the tools are built
# from source.
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

# Sparkle 2.9+ clients on Intel skip an item that carries
# <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>, and
# generate_appcast emits it only when the app's main executable has no x86_64
# slice. c11 ships arm64-only since 1.8 (C11-541), so check the tag is there
# rather than trusting it: without it, Intel Macs would be offered a build
# they cannot run.
mkdir -p "$work_dir/mnt"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$work_dir/mnt" "$DMG_PATH" >/dev/null
app_path="$(find "$work_dir/mnt" -maxdepth 1 -name '*.app' | head -n 1)"
[[ -n "$app_path" ]] || { echo "ERROR: no .app in $DMG_PATH" >&2; exit 1; }
exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
app_archs="$(lipo -archs "$app_path/Contents/MacOS/$exe_name")"
hdiutil detach -quiet "$work_dir/mnt"
rmdir "$work_dir/mnt" 2>/dev/null || true
# The first build whose Sparkle honors hardwareRequirements. Releases: 132,
# c11 1.0.0 (0.67.0, the last 0.x, is build 131). Nightly builds number by run
# id, so nightly.yml passes its own threshold.
legacy_below_build="${SPARKLE_LEGACY_BELOW_BUILD:-132}"
[[ "$legacy_below_build" =~ ^[0-9]+$ ]] || { echo "SPARKLE_LEGACY_BELOW_BUILD must be a build number" >&2; exit 1; }
if [[ " $app_archs " != *" x86_64 "* ]]; then
  if ! grep -q '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>' "$OUT_PATH"; then
    echo "ERROR: app is arm64-only ($app_archs) but the appcast lacks sparkle:hardwareRequirements arm64; Intel Macs would be offered it." >&2
    exit 1
  fi
  echo "Verified: arm64-only app ($app_archs); appcast carries sparkle:hardwareRequirements arm64"

  # Sparkle before 2.9 ignores hardwareRequirements, and c11 0.x (builds up to
  # 131) ships Sparkle 2.8.1, so an Intel Mac still on 0.x would install a
  # build it cannot run. Make the item information-only below build 132 (c11
  # 1.0.0, the first with Sparkle 2.9): those hosts are told about the update
  # but cannot install it, and Apple-silicon ones download it by hand from the
  # release page. Sparkle honors informationalUpdate only on an item with an
  # http(s) <link>, so the release page goes in as the link. The edSignature
  # covers the DMG, not this XML, so editing the item keeps it valid.
  python3 - "$OUT_PATH" "$legacy_below_build" "$RELEASE_NOTES_URL" <<'PY_INFORMATIONAL'
import re
import sys
from xml.sax.saxutils import escape

path, below, link = sys.argv[1:]
if not re.match(r"https?://", link):
    sys.exit(f"release page URL is not http(s): {link}")
xml = open(path, encoding="utf-8").read()
if xml.count("<item>") != 1:
    sys.exit(f"expected one item in {path}")
if "sparkle:informationalUpdate" in xml or "<link>" in xml:
    sys.exit(f"{path} already has sparkle:informationalUpdate or <link>")
anchor = re.search(r"^([ \t]*)<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n", xml, re.M)
if anchor is None:
    sys.exit(f"no sparkle:hardwareRequirements line in {path}")
indent = anchor.group(1)
block = (
    f"{indent}<link>{escape(link)}</link>\n"
    f"{indent}<sparkle:informationalUpdate>\n"
    f"{indent}    <sparkle:belowVersion>{below}</sparkle:belowVersion>\n"
    f"{indent}</sparkle:informationalUpdate>\n"
)
open(path, "w", encoding="utf-8").write(xml[:anchor.end()] + block + xml[anchor.end():])
PY_INFORMATIONAL
fi

# Fail closed: the appcast must still parse; an arm64-only app's item must
# carry hardwareRequirements arm64, an http(s) <link> and informationalUpdate
# belowVersion 132; a universal app's item must carry neither guard.
python3 - "$OUT_PATH" "$app_archs" "$legacy_below_build" <<'PY_VERIFY'
import sys
import xml.dom.minidom

path, archs, below = sys.argv[1:]
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
items = xml.dom.minidom.parse(path).getElementsByTagName("item")
if len(items) != 1:
    sys.exit(f"ERROR: expected one item in {path}, found {len(items)}")
item = items[0]
text = lambda e: "".join(n.data for n in e.childNodes if n.nodeType == n.TEXT_NODE).strip()
hardware = [text(e) for e in item.getElementsByTagNameNS(ns, "hardwareRequirements")]
informational = item.getElementsByTagNameNS(ns, "informationalUpdate")
below_versions = [text(e) for e in item.getElementsByTagNameNS(ns, "belowVersion")]
links = [text(e) for e in item.childNodes if e.nodeType == e.ELEMENT_NODE and e.tagName == "link"]
if "x86_64" in archs.split():
    if hardware or informational:
        sys.exit(f"ERROR: universal app ({archs}) but the appcast item carries hardwareRequirements or informationalUpdate")
    print(f"Verified: universal app ({archs}); appcast item carries neither hardware nor informational guard")
else:
    if (hardware != ["arm64"] or len(informational) != 1 or below_versions != [below]
            or len(links) != 1 or not links[0].startswith(("https://", "http://"))):
        sys.exit(f"ERROR: arm64-only app ({archs}) but the appcast item lacks an http(s) <link> with informationalUpdate belowVersion {below}; Intel Macs on c11 0.x would install it")
    print(f"Verified: arm64-only app; appcast item is information-only below build {below} (link {links[0]})")
PY_VERIFY
