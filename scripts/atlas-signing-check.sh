#!/usr/bin/env bash
# Prove the release signing path works on Atlas from a non-GUI ssh session,
# without touching a real key or publishing anything (C11-542). Agent-safe.
#
#   scripts/atlas-signing-check.sh            # from any Mac on the tailnet
#
# On Atlas, under one launchd unlock lease of the dedicated signing keychain:
#   1. codesign a scratch binary with the Developer ID identity (hardened
#      runtime, secure timestamp) and verify the signature;
#   2. notarytool history with the notary profile stored in that keychain;
#   3. store a throwaway Sparkle key under a throwaway account, read it back,
#      sign a scratch file with Sparkle's sign_update and verify the signature
#      against the throwaway public key, then delete the item;
#   4. lock the keychain and confirm no scratch file or throwaway item remains.
# Prints one line per check; prints no key, password or certificate hash.
set -euo pipefail

HOST="${C11_SIGNING_HOST:-atlas}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC2016
REMOTE='
set -euo pipefail
kc="${C11_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/acetate-release.keychain-db}"
helper="${C11_SIGNING_KEYCHAIN_HELPER:-$HOME/.acetate-release/bin/release_keychain.sh}"
identity="${C11_SIGNING_IDENTITY:-Developer ID Application: Authentic Technologies Inc. (UKQ4QALWD4)}"
profile="${C11_NOTARY_PROFILE:-acetate-notary}"
bin_dir="$1"
bounded() { local s="$1"; shift; perl -e "alarm $s; exec @ARGV or exit 127" -- "$@"; }
work="$(mktemp -d "${TMPDIR:-/tmp}/c11-signcheck.XXXXXX")"
chmod 700 "$work"
account="c11-signcheck-$$"
cleanup() {
  bounded 30 security delete-generic-password -s https://sparkle-project.org -a "$account" "$kc" >/dev/null 2>&1 || true
  bounded 30 "$helper" lock $$ >/dev/null 2>&1 || true
  /bin/rm -rf "$work"
}
trap cleanup EXIT
[[ -n "${SSH_CONNECTION:-}" ]] && echo "session: ssh, no GUI ($(id -un)@$(hostname -s))"
bounded 90 "$helper" request-unlock 300 $$ >/dev/null
echo "keychain: $(bounded 30 "$helper" status) under lease $$"

printf "int main(void){return 0;}\n" >"$work/hello.c"
clang -arch arm64 -o "$work/hello" "$work/hello.c"
bounded 120 /usr/bin/codesign --force --options runtime --timestamp --keychain "$kc" --sign "$identity" "$work/hello" 2>"$work/cs.err" \
  || { echo "codesign: FAILED $(head -c 300 "$work/cs.err")"; exit 1; }
/usr/bin/codesign --verify --strict "$work/hello"
authority="$(/usr/bin/codesign -dvv "$work/hello" 2>&1 | sed -n "s/^Authority=//p" | head -1)"
echo "codesign: ok, signed by \"$authority\" with hardened runtime and timestamp"

bounded 90 xcrun notarytool history --keychain-profile "$profile" --keychain "$kc" >/dev/null 2>"$work/nt.err" \
  || { echo "notarytool: FAILED $(head -c 300 "$work/nt.err")"; exit 1; }
echo "notarytool: ok, profile $profile authenticates from the signing keychain"

seed="$(openssl rand -base64 32)"
printf "add-generic-password -U -s https://sparkle-project.org -a %s -T /usr/bin/security -w %s %s\n" \
  "$account" "$seed" "$kc" | bounded 30 security -i >/dev/null
unset seed
( umask 077; bounded 30 security find-generic-password -s https://sparkle-project.org -a "$account" -w "$kc" >"$work/key" )
head -c 4096 /dev/urandom >"$work/archive.bin"
sig="$(bounded 60 "$bin_dir/sign_update" -f "$work/key" "$work/archive.bin" -p)"
pub="$(cat >"$work/derive.swift" <<SWIFT
import CryptoKit
import Foundation
var b = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
while b.count % 4 != 0 { b += "=" }
let k = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: b)!)
print(k.publicKey.rawRepresentation.base64EncodedString())
SWIFT
bounded 120 swift "$work/derive.swift" <"$work/key")"
cat >"$work/verify.swift" <<SWIFT
import CryptoKit
import Foundation
let a = CommandLine.arguments
let key = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: a[1])!)
let ok = key.isValidSignature(Data(base64Encoded: a[2])!, for: try! Data(contentsOf: URL(fileURLWithPath: a[3])))
print(ok ? "valid" : "invalid"); exit(ok ? 0 : 1)
SWIFT
verdict="$(bounded 120 swift "$work/verify.swift" "$pub" "$sig" "$work/archive.bin")"
echo "sparkle: key read back from the signing keychain, sign_update signature $verdict"
[[ "$verdict" == "valid" ]]

cleanup
trap - EXIT
left="$( (ls -d "${TMPDIR:-/tmp}"/c11-signcheck.* 2>/dev/null || true) | wc -l | tr -d " ")"
bounded 30 security find-generic-password -s https://sparkle-project.org -a "$account" "$kc" >/dev/null 2>&1 && item=present || item=gone
echo "after: keychain $(bounded 30 "$helper" status), scratch dirs left $left, throwaway item $item"
[[ "$left" == "0" && "$item" == "gone" ]]
'

# Sparkle tools on Atlas, from the same checksum-pinned tarball as releases.
ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'mkdir -p ~/.cache/c11/scripts'
scp -q -o BatchMode=yes "$ROOT/scripts/fetch-sparkle-tools.sh" "$HOST:.cache/c11/scripts/fetch-sparkle-tools.sh"
BIN_DIR="$(ssh -o BatchMode=yes "$HOST" 'bash ~/.cache/c11/scripts/fetch-sparkle-tools.sh')"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$(printf '%q ' bash -c "$REMOTE" atlas-signing-check "$BIN_DIR")"
