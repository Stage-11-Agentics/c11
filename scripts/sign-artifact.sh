#!/usr/bin/env bash
# Runs only on the ephemeral GitHub signing runner. Never enable shell tracing.
set +x
set -euo pipefail
PRODUCER_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "${1:?source checkout is required}" && pwd)"
python3 "$PRODUCER_DIR/sign_artifact.py" preflight "$SOURCE_DIR"
for name in APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY \
  APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID SPARKLE_PRIVATE_KEY; do
  [ -n "${!name:-}" ] || { echo "Missing $name secret" >&2; exit 1; }
done
cd "$SOURCE_DIR"
KEYCHAIN_PATH="${RUNNER_TEMP:?}/c11-signing.keychain-db"
CERT_PATH="$RUNNER_TEMP/c11-signing.p12"
NOTARY_ZIP="$RUNNER_TEMP/c11-notary.zip"
cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -f "$CERT_PATH" "$NOTARY_ZIP"
}
trap cleanup EXIT
mkdir -p build
[ ! -e build/signed-artifact ] || { echo 'Artifact output already exists; use a fresh runner' >&2; exit 1; }
./scripts/download-prebuilt-ghosttykit.sh
SPARKLE_PUBLIC_KEY="$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")"
export SPARKLE_PUBLIC_KEY
xcodebuild -scheme c11 -configuration Release -derivedDataPath build \
  -clonedSourcePackagesDirPath .spm-cache CODE_SIGNING_ALLOWED=NO build
APP_PATH="$SOURCE_DIR/build/Build/Products/Release/c11.app"
APP_VERSION="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$APP_PATH/Contents/Info.plist")"
DAEMON_TAG="${SIGN_TARGET_TAG:-proof-${SIGN_PROOF_BUILD}}"
./scripts/build_remote_daemon_release_assets.sh --version "$APP_VERSION" \
  --release-tag "$DAEMON_TAG" --repo Stage-11-Agentics/c11 --output-dir build/remote-daemon-assets
python3 "$PRODUCER_DIR/sign_artifact.py" configure "$SOURCE_DIR"
CLI_PATH="$APP_PATH/Contents/Resources/bin/c11"
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
[ -x "$CLI_PATH" ] && [ -x "$HELPER_PATH" ] || { echo 'Missing bundled CLI/theme helper' >&2; exit 1; }
C11_CLI_BIN="$CLI_PATH" CMUX_CLI_BIN="$CLI_PATH" python3 tests/test_cli_version_memory_guard.py

KEYCHAIN_PASSWORD="$(uuidgen)"
umask 077
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$CERT_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
# Suppress security's import diagnostics: no certificate/identity disclosure in logs.
security import "$CERT_PATH" -k "$KEYCHAIN_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH"
rm -f "$CERT_PATH"
for binary in "$CLI_PATH" "$HELPER_PATH" "$APP_PATH"; do
  codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" \
    --entitlements c11.entitlements --deep "$binary"
done
codesign --verify --deep --strict "$APP_PATH"
notarize() {
  local result status
  result="$(xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --output-format json)"
  status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<< "$result")"
  [ "$status" = Accepted ] || { echo 'Notarization was not Accepted' >&2; return 1; }
}
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
notarize "$NOTARY_ZIP"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vv --type execute "$APP_PATH"
mkdir -p build/dmg-stage
create-dmg --identity="$APPLE_SIGNING_IDENTITY" "$APP_PATH" build/dmg-stage/
DMGS=(build/dmg-stage/*.dmg)
[ "${#DMGS[@]}" -eq 1 ] && [ -f "${DMGS[0]}" ] || { echo 'Expected exactly one DMG' >&2; exit 1; }
DMG_PATH="$SOURCE_DIR/build/c11-macos.dmg"
mv "${DMGS[0]}" "$DMG_PATH"
notarize "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
DOWNLOAD_URL_PREFIX="$(python3 -c 'import json; print(json.load(open("build/signing-request.json"))["downloadURLPrefix"])')"
RELEASE_NOTES_URL="$(python3 -c 'import json; print(json.load(open("build/signing-request.json"))["releaseNotesURL"])')"
export DOWNLOAD_URL_PREFIX RELEASE_NOTES_URL
./scripts/sparkle_generate_appcast.sh "$DMG_PATH" "$DAEMON_TAG" build/appcast.xml
mkdir build/signed-artifact
cp "$DMG_PATH" build/appcast.xml build/remote-daemon-assets/c11d-remote-* build/signed-artifact/
python3 "$PRODUCER_DIR/sign_artifact.py" package "$SOURCE_DIR"
python3 "$PRODUCER_DIR/sign_artifact.py" verify build/signed-artifact
