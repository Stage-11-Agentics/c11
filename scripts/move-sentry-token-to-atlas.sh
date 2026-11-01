#!/usr/bin/env bash
# Copy the Sentry org auth token (stage-11-kl) into the dedicated release
# keychain on Atlas, so a release run on Atlas uploads its dSYMs (C11-542).
# Rerun after rotating the token.
#
#   scripts/move-sentry-token-to-atlas.sh            # store, then verify on Atlas
#   scripts/move-sentry-token-to-atlas.sh --check    # verify only: ok | missing | failed
#
# The token is read from the keys file (C11_KEYS_FILE, default
# ~/Projects/Gregorovich/keys.txt, line SENTRY_AUTH_TOKEN=...). It is never in
# an argv, printed, logged, committed or left on disk: it goes from the keys
# file to a 0600 file in a 0700 temp dir removed on exit, then as ssh stdin into
# `security -i`'s stdin on Atlas. Verification runs a read-only sentry-cli call
# on Atlas: `sentry-cli releases list` for the c11 project, with the token in
# that process's environment only (an org token cannot list projects).
set -euo pipefail

HOST="${C11_SIGNING_HOST:-atlas}"
KEYS_FILE="${C11_KEYS_FILE:-$HOME/Projects/Gregorovich/keys.txt}"
ORG="stage-11-kl"
PROJECT="c11"
SERVICE="c11-sentry-auth-token"
REMOTE_KEYCHAIN="${C11_SIGNING_KEYCHAIN:-\$HOME/Library/Keychains/acetate-release.keychain-db}"
REMOTE_HELPER="${C11_SIGNING_KEYCHAIN_HELPER:-\$HOME/.acetate-release/bin/release_keychain.sh}"

die() { printf 'move-sentry-token: %s\n' "$*" >&2; exit 1; }
MODE=store
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  *) die "usage: $0 [--check]" ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/c11-sentry-move.XXXXXX")"
chmod 700 "$TMP"
trap '/bin/rm -rf "$TMP"' EXIT
: >"$TMP/token"
chmod 600 "$TMP/token"

# Runs on Atlas: stores the token from stdin (unless checking), then verifies
# it with a read-only sentry-cli call and prints ok, missing or failed.
# shellcheck disable=SC2016
REMOTE_SCRIPT='
set -euo pipefail
kc="$1"; helper="$2"; service="$3"; org="$4"; project="$5"; mode="$6"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
bounded() { local s="$1"; shift; perl -e "alarm $s; exec @ARGV or exit 127" -- "$@"; }
if [[ "$mode" != "check" ]]; then
  token="$(cat)"
  [[ "$token" =~ ^[A-Za-z0-9_=.+/-]+$ ]] || { echo "token has unexpected characters" >&2; exit 1; }
fi
command -v sentry-cli >/dev/null || { echo "sentry-cli is not installed on Atlas" >&2; exit 1; }
# Armed before the request: an unlock whose probe then fails still relocks.
trap "bounded 30 \"$helper\" lock $$ >/dev/null 2>&1 || true" EXIT
bounded 60 "$helper" request-unlock 120 $$ >/dev/null
if [[ "$mode" != "check" ]]; then
  # Replace, not update: changing an existing item access list needs a prompt
  # that a non-GUI session cannot answer.
  bounded 30 security delete-generic-password -s "$service" -a "$org" "$kc" >/dev/null 2>&1 || true
  printf "add-generic-password -s %s -a %s -T /usr/bin/security -w %s %s\n" \
    "$service" "$org" "$token" "$kc" | bounded 30 security -i >/dev/null
  unset token
fi
bounded 30 security find-generic-password -s "$service" -a "$org" "$kc" >/dev/null 2>&1 || { echo missing; exit 0; }
# An org auth token carries only the CI scope (uploads and releases), so the
# check lists the releases of the project: read-only, and it fails on a bad token.
if SENTRY_AUTH_TOKEN="$(bounded 30 security find-generic-password -s "$service" -a "$org" -w "$kc")" \
    bounded 60 sentry-cli releases list --org "$org" --project "$project" >/dev/null 2>&1; then
  echo ok
else
  echo failed
  [[ "$mode" == "check" ]] || exit 1
fi
'

remote() {
  local quoted
  quoted="$(printf '%q ' bash -c "$REMOTE_SCRIPT" move-sentry-token)"
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
    "$quoted \"$REMOTE_KEYCHAIN\" \"$REMOTE_HELPER\" $SERVICE $ORG $PROJECT $1" <"$2"
}

if [[ "$MODE" == "check" ]]; then
  remote check /dev/null
  exit 0
fi

[[ -r "$KEYS_FILE" ]] || die "cannot read $KEYS_FILE"
# The exact key only; the value is written straight to the 0600 file.
awk 'index($0, "SENTRY_AUTH_TOKEN=") == 1 { v = substr($0, 19); gsub(/^["'"'"' \t]+|["'"'"' \t\r]+$/, "", v); print v; exit }' \
  "$KEYS_FILE" >"$TMP/token"
[[ -s "$TMP/token" ]] || die "no SENTRY_AUTH_TOKEN line in $KEYS_FILE"
result="$(remote store "$TMP/token")" || die "Atlas did not confirm the token: ${result:-no output}"
echo "Atlas release keychain holds the Sentry token for $ORG: sentry-cli check $result (releases of $PROJECT readable). The local copy is deleted."
