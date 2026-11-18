#!/bin/sh
# C11H-392: scripts/c11-remote-artifacts.sh stamp. No network, no signing identity.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
STAMP=$ROOT/scripts/c11-remote-artifacts.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

app=$TMP/c11.app
mkdir -p "$app/Contents/Resources" "$TMP/in"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>2.0.1</string></dict></plist>
PLIST
printf '\177ELFlinux hc' > "$TMP/in/herdr-core"
printf '\177ELFlinux c11' > "$TMP/in/c11"
hc_sha=$(shasum -a 256 "$TMP/in/herdr-core" | awk '{print $1}')
cli_sha=$(shasum -a 256 "$TMP/in/c11" | awk '{print $1}')
printf '{"version":"0.1.16","remote":{"linux-x86_64":{"sha256":"%s"}}}\n' "$hc_sha" > "$TMP/hc-source.json"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/codesign.calls"\n' "$TMP" > "$TMP/codesign"
chmod 755 "$TMP/codesign"
stamp() { C11_HC_SOURCE_JSON=$TMP/hc-source.json C11_CODESIGN=$TMP/codesign "$STAMP" stamp "$@"; }

check "stamp writes the manifest" "stamp --app '$app' --dir '$TMP/in' >/dev/null"
check "the manifest names each file by hash, asset and release URL" "python3 -I - '$app/Contents/Resources/remote-artifacts.json' '$hc_sha' '$cli_sha' <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m['version'] == 1, m
by = {a['name']: a for a in m['artifacts']}
assert sorted(by) == ['c11', 'herdr-core'], by
assert by['herdr-core'] == {'platform': 'linux-x86_64', 'name': 'herdr-core', 'version': '0.1.16', 'sha256': sys.argv[2],
    'asset': 'herdr-core-linux-x86_64',
    'url': 'https://github.com/Stage-11-Agentics/c11/releases/download/v2.0.1/herdr-core-linux-x86_64'}, by['herdr-core']
assert by['c11']['sha256'] == sys.argv[3] and by['c11']['asset'] == 'c11-linux-x86_64' and by['c11']['version'] == '2.0.1', by['c11']
PY"
check "the assets are laid out under the names the release guard lists, with checksums" \
  "(cd '$TMP/in/assets' && shasum -a 256 -c c11-linux-checksums.txt >/dev/null) && [ \"\$(LC_ALL=C ls '$TMP/in/assets' | tr '\n' ' ')\" = 'c11-linux-checksums.txt c11-linux-x86_64 herdr-core-linux-x86_64 ' ]"
check "a release stamp signs nothing" "[ ! -e '$TMP/codesign.calls' ]"
check "--ad-hoc re-signs keeping the app's entitlements" \
  "stamp --app '$app' --dir '$TMP/in' --ad-hoc >/dev/null && grep -qx -- '--force --sign - --preserve-metadata=entitlements,requirements,flags,runtime $app' '$TMP/codesign.calls'"
check "--base names another https folder" \
  "stamp --app '$app' --dir '$TMP/in' --base https://example.invalid/r/ >/dev/null && grep -q '\"url\":\"https://example.invalid/r/c11-linux-x86_64\"' '$app/Contents/Resources/remote-artifacts.json'"
check "an http base is refused" "! stamp --app '$app' --dir '$TMP/in' --base http://example.invalid/r >/dev/null 2>&1"

rm -f "$app/Contents/Resources/remote-artifacts.json"
printf '\177ELFanother hc' > "$TMP/in/herdr-core"
check "a herdr-core that is not the pinned build is refused" "! stamp --app '$app' --dir '$TMP/in' 2>'$TMP/err' && grep -q 'not the pinned' '$TMP/err'"
check "and no manifest is written" "[ ! -e '$app/Contents/Resources/remote-artifacts.json' ]"
printf '\177ELFlinux hc' > "$TMP/in/herdr-core"
printf '#!/bin/sh\n' > "$TMP/in/c11"
check "a c11 that is not an ELF executable is refused" "! stamp --app '$app' --dir '$TMP/in' >/dev/null 2>&1 && [ ! -e '$app/Contents/Resources/remote-artifacts.json' ]"
printf '\177ELFlinux c11' > "$TMP/real-c11"; rm -f "$TMP/in/c11"; ln -s "$TMP/real-c11" "$TMP/in/c11"
check "a symlinked input is refused" "! stamp --app '$app' --dir '$TMP/in' >/dev/null 2>&1"
printf '{"version":"0.1.16"}\n' > "$TMP/hc-source.json"; rm -f "$TMP/in/c11"; cp "$TMP/real-c11" "$TMP/in/c11"
check "a source pin without the Linux hc is refused" "! stamp --app '$app' --dir '$TMP/in' 2>'$TMP/err' && grep -q 'pins no hc' '$TMP/err'"

[ "$fails" -eq 0 ] && echo "PASS c11_remote_artifacts_test" || { echo "FAIL c11_remote_artifacts_test ($fails)"; exit 1; }
