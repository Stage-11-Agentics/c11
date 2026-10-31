#!/usr/bin/env bash
# Copy c11's Sparkle EdDSA private key (keychain account c11mux) from this Mac's
# login keychain into the dedicated release keychain on Atlas, so a release can
# sign its appcast on Atlas while this Mac sleeps (C11-542).
#
# OPERATOR-RUN, ONCE, on the Mac that holds the key:
#   scripts/move-sparkle-key-to-atlas.sh
# macOS shows one dialog asking to let Sparkle's generate_keys use the c11mux
# key: click Allow. Nothing else asks for input.
#
# AGENTS run only:
#   scripts/move-sparkle-key-to-atlas.sh --check       # match | missing | mismatch on Atlas
#   scripts/move-sparkle-key-to-atlas.sh --self-test
# which pushes a throwaway key through the same Atlas path (store, read back in
# a non-GUI ssh session, derive and compare the public key, delete) and never
# touches the real key.
#
# The key is never in an argv, printed, logged, committed or left on disk. It
# leaves this Mac as ssh stdin and reaches the keychain through `security -i`'s
# stdin on Atlas. The temporary export lives in a 0700 directory removed on
# every exit path. Atlas's keychain is unlocked through its launchd lease for
# the store and locked again by the same trap.
set -euo pipefail

HOST="${C11_SIGNING_HOST:-atlas}"
ACCOUNT="${C11_SPARKLE_ACCOUNT:-c11mux}"
SERVICE="https://sparkle-project.org"
EXPECTED_PUB="naW2p9Qixxto6tuJUi+NgmJU8EOx2vdRazhi0jwBALk="
# Atlas paths, as Atlas's shell expands them.
REMOTE_KEYCHAIN="${C11_SIGNING_KEYCHAIN:-\$HOME/Library/Keychains/acetate-release.keychain-db}"
REMOTE_HELPER="${C11_SIGNING_KEYCHAIN_HELPER:-\$HOME/.acetate-release/bin/release_keychain.sh}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'move-sparkle-key: %s\n' "$*" >&2; exit 1; }

SELF_TEST=0
CHECK_ONLY=0
case "${1:-}" in
  "") ;;
  --self-test) SELF_TEST=1 ;;
  --check) CHECK_ONLY=1 ;;
  *) die "usage: $0 [--self-test | --check]" ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/c11-sparkle-move.XXXXXX")"
chmod 700 "$TMP"
trap '/bin/rm -rf "$TMP"' EXIT

# Runs on Atlas. Reads the key from stdin, stores it, reads it back in this
# non-GUI session, derives the public key and prints only "match" or
# "mismatch". With a fourth argument "delete", removes the item afterwards.
# shellcheck disable=SC2016
REMOTE_SCRIPT='
set -euo pipefail
kc="$1"; helper="$2"; account="$3"; expected="$4"; mode="${5:-keep}"
service="https://sparkle-project.org"
bounded() { local s="$1"; shift; perl -e "alarm $s; exec @ARGV or exit 127" -- "$@"; }
if [[ "$mode" != "check" ]]; then
  key="$(cat)"
  [[ "$key" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "key is not base64" >&2; exit 1; }
fi
bounded 60 "$helper" request-unlock 120 $$ >/dev/null
trap "bounded 30 \"$helper\" lock $$ >/dev/null 2>&1 || true" EXIT
if [[ "$mode" == "check" ]]; then
  bounded 30 security find-generic-password -s "$service" -a "$account" "$kc" >/dev/null 2>&1 || { echo missing; exit 0; }
else
  printf "add-generic-password -U -s %s -a %s -T /usr/bin/security -w %s %s\n" \
    "$service" "$account" "$key" "$kc" | bounded 30 security -i >/dev/null
  unset key
fi
derive="$(mktemp "${TMPDIR:-/tmp}/c11-derive.XXXXXX").swift"
cat >"$derive" <<SWIFT
import CryptoKit
import Foundation
var b64 = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!
  .trimmingCharacters(in: .whitespacesAndNewlines)
while b64.count % 4 != 0 { b64 += "=" }
guard let d = Data(base64Encoded: b64) else { exit(1) }
if d.count == 32, let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) {
  print(k.publicKey.rawRepresentation.base64EncodedString())
} else if d.count == 96 {
  print(d[64...].base64EncodedString())
} else { exit(1) }
SWIFT
pub="$(bounded 30 security find-generic-password -s "$service" -a "$account" -w "$kc" | bounded 120 swift "$derive")"
/bin/rm -f "$derive"
if [[ "$mode" == "delete" ]]; then
  bounded 30 security delete-generic-password -s "$service" -a "$account" "$kc" >/dev/null
fi
if [[ "$pub" == "$expected" ]]; then echo match; else echo mismatch; [[ "$mode" == "check" ]] || exit 1; fi
'

remote() {
  # remote <key-file|/dev/null> <account> <expected-public-key> [keep|delete|check]
  local quoted
  quoted="$(printf '%q ' bash -c "$REMOTE_SCRIPT" move-sparkle-key)"
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
    "$quoted \"$REMOTE_KEYCHAIN\" \"$REMOTE_HELPER\" $(printf '%q' "$2") $(printf '%q' "$3") ${4:-keep}" <"$1"
}

LOG="${XDG_CACHE_HOME:-$HOME/.cache}/c11/move-sparkle-key.log"
mkdir -p "$(dirname "$LOG")"
record() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >>"$LOG"; echo "$*"; }

if [[ "$SELF_TEST" -eq 1 ]]; then
  # A throwaway Ed25519 seed under a throwaway account; the real key is untouched.
  openssl rand -base64 32 >"$TMP/key"
  pub="$(swift "$ROOT/scripts/derive_sparkle_public_key.swift" "$(cat "$TMP/key")")"
  result="$(remote "$TMP/key" "c11mux-selftest" "$pub" delete)" || die "self-test failed on $HOST: ${result:-no output}"
  echo "self-test on $HOST: store, read back in a non-GUI session, $result, deleted"
  exit 0
fi

# Safe to run twice: when Atlas already holds the right key, stop before the dialog.
state="$(remote /dev/null "$ACCOUNT" "$EXPECTED_PUB" check)" || die "could not reach Atlas's signing keychain on $HOST"
if [[ "$CHECK_ONLY" -eq 1 ]]; then echo "$state"; exit 0; fi
if [[ "$state" == "match" ]]; then
  record "Already done: Atlas holds the $ACCOUNT key that matches every installed c11. Nothing changed."
  exit 0
fi

BIN="$("$ROOT/scripts/fetch-sparkle-tools.sh")" || die "could not fetch Sparkle tools"
echo "Exporting the $ACCOUNT Sparkle key from this Mac's keychain (macOS may ask: click Allow)..."
"$BIN/generate_keys" --account "$ACCOUNT" -x "$TMP/key" >/dev/null || die "generate_keys could not export the $ACCOUNT key"
[[ -s "$TMP/key" ]] || die "export produced no key"
echo "Storing it in Atlas's release keychain and checking it there..."
result="$(remote "$TMP/key" "$ACCOUNT" "$EXPECTED_PUB")" || die "Atlas did not confirm the key: ${result:-no output}"
record "Done: Atlas holds the $ACCOUNT key ($result with the public key every installed c11 trusts). The local export is deleted."
