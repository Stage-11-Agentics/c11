#!/usr/bin/env bash
# Behavioral coverage for the local GhosttyKit/submodule guard.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/c11-ghosttykit-guard.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

REPO_DIR="$TMP_DIR/repo"
CACHE_ROOT="$TMP_DIR/cache"
BIN_DIR="$TMP_DIR/bin"
CHECKSUMS_FILE="$REPO_DIR/scripts/ghosttykit-checksums.txt"
NO_PIN_FILE="$TMP_DIR/no-pinned-checksum"
XCODEBUILD_LOG="$TMP_DIR/xcodebuild.log"
CURL_LOG="$TMP_DIR/curl.log"

mkdir -p "$REPO_DIR/scripts" "$REPO_DIR/ghostty" "$BIN_DIR"
cp "$ROOT_DIR/scripts/assert-ghosttykit.sh" "$REPO_DIR/scripts/assert-ghosttykit.sh"
cp "$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh" "$REPO_DIR/scripts/download-prebuilt-ghosttykit.sh"
cp "$ROOT_DIR/scripts/with-build-lock.sh" "$REPO_DIR/scripts/with-build-lock.sh"
cp "$ROOT_DIR/scripts/reload.sh" "$REPO_DIR/scripts/reload.sh"
cp "$ROOT_DIR/scripts/reloads.sh" "$REPO_DIR/scripts/reloads.sh"
cp "$ROOT_DIR/scripts/reloadp.sh" "$REPO_DIR/scripts/reloadp.sh"
cp "$ROOT_DIR/scripts/test-unit-local.sh" "$REPO_DIR/scripts/test-unit-local.sh"
cp "$ROOT_DIR/scripts/test-unit.sh" "$REPO_DIR/scripts/test-unit.sh"
chmod +x "$REPO_DIR/scripts/"*.sh

git -C "$REPO_DIR/ghostty" init -q
git -C "$REPO_DIR/ghostty" config user.email c11-218-test@example.invalid
git -C "$REPO_DIR/ghostty" config user.name c11-218-test
printf '%s\n' fixture > "$REPO_DIR/ghostty/fixture.txt"
git -C "$REPO_DIR/ghostty" add fixture.txt
git -C "$REPO_DIR/ghostty" commit -qm fixture
GHOSTTY_SHA="$(git -C "$REPO_DIR/ghostty" rev-parse HEAD)"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email c11-218-test@example.invalid
git -C "$REPO_DIR" config user.name c11-218-test
git -c advice.addEmbeddedRepo=false -C "$REPO_DIR" add ghostty 2>/dev/null
git -C "$REPO_DIR" commit -qm fixture

WRONG_SHA="0000000000000000000000000000000000000000"
mkdir -p "$CACHE_ROOT/$WRONG_SHA/GhosttyKit.xcframework"
printf '%s\n' wrong > "$CACHE_ROOT/$WRONG_SHA/GhosttyKit.xcframework/marker"
ln -s "$CACHE_ROOT/$WRONG_SHA/GhosttyKit.xcframework" "$REPO_DIR/GhosttyKit.xcframework"
: > "$NO_PIN_FILE"

cat > "$BIN_DIR/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_XCODEBUILD_LOG:?}"
EOF
chmod +x "$BIN_DIR/xcodebuild"

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$output" ]] || exit 1
cp "${TEST_FIXTURE_ARCHIVE:?}" "$output"
printf '%s\n' fetched >> "${TEST_CURL_LOG:?}"
EOF
chmod +x "$BIN_DIR/curl"

run_refusal() {
  local script="$1"
  shift
  local name="$1"
  shift
  local output="$TMP_DIR/$name.out"
  local rc

  rm -f "$XCODEBUILD_LOG"
  if env \
    PATH="$BIN_DIR:$PATH" \
    TEST_XCODEBUILD_LOG="$XCODEBUILD_LOG" \
    C11_BUILD_LOCK_DIR="$TMP_DIR/$name-lock" \
    CMUX_GHOSTTYKIT_CACHE_DIR="$CACHE_ROOT" \
    GHOSTTYKIT_CHECKSUMS_FILE="$NO_PIN_FILE" \
    "$REPO_DIR/scripts/$script" "$@" >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  [[ "$rc" -ne 0 ]] || fail "$script unexpectedly accepted an unpinned stale kit"
  grep -Fq "error: GhosttyKit.xcframework is missing or does not match ghostty SHA $GHOSTTY_SHA" "$output" \
    || fail "$script did not report the stale kit: $(tr '\n' ' ' < "$output")"
  [[ ! -e "$XCODEBUILD_LOG" ]] || fail "$script started xcodebuild before refusing"
  echo "refusal $script exit=$rc: $(tr '\n' ' ' < "$output")"
}

# A stale symlink must stop every documented local xcodebuild entry point
# before the fake xcodebuild can run.
run_refusal reload.sh reload-dev --tag guard-refusal
run_refusal reloads.sh reload-staging --tag guard-refusal
run_refusal reloadp.sh reload-prod
run_refusal test-unit-local.sh unit-local
run_refusal test-unit.sh unit

# A real directory has no SHA-bearing target path, so it is also refused until
# a pinned repair is available.
rm -f "$REPO_DIR/GhosttyKit.xcframework"
mkdir -p "$REPO_DIR/GhosttyKit.xcframework"
printf '%s\n' unknown > "$REPO_DIR/GhosttyKit.xcframework/marker"
run_refusal test-unit.sh unit-real-directory

mkdir -p "$TMP_DIR/archive/GhosttyKit.xcframework"
printf '%s\n' downloaded > "$TMP_DIR/archive/GhosttyKit.xcframework/marker"
(cd "$TMP_DIR/archive" && tar czf "$TMP_DIR/GhosttyKit.xcframework.tar.gz" GhosttyKit.xcframework)
ARCHIVE_SHA256="$(shasum -a 256 "$TMP_DIR/GhosttyKit.xcframework.tar.gz" | awk '{print $1}')"
printf '%s %s\n' "$GHOSTTY_SHA" "$ARCHIVE_SHA256" > "$CHECKSUMS_FILE"

# A pinned stale real directory is repaired through the existing download
# seam, cached under the current SHA, and replaced by a SHA-keyed symlink.
env \
  PATH="$BIN_DIR:$PATH" \
  CMUX_GHOSTTYKIT_CACHE_DIR="$CACHE_ROOT" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  TEST_FIXTURE_ARCHIVE="$TMP_DIR/GhosttyKit.xcframework.tar.gz" \
  TEST_CURL_LOG="$CURL_LOG" \
  "$REPO_DIR/scripts/assert-ghosttykit.sh" >"$TMP_DIR/repair.out"
[[ -L "$REPO_DIR/GhosttyKit.xcframework" ]] || fail "repair did not create a symlink"
[[ "$(readlink "$REPO_DIR/GhosttyKit.xcframework")" == "$CACHE_ROOT/$GHOSTTY_SHA/GhosttyKit.xcframework" ]] \
  || fail "repair linked the wrong cache path"
[[ -f "$CACHE_ROOT/$GHOSTTY_SHA/GhosttyKit.xcframework/marker" ]] || fail "repair did not populate the cache"
[[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" == "1" ]] || fail "repair did not invoke the downloader exactly once"

# Once the correct cache exists, a wrong symlink is repaired without invoking
# the downloader again.
cat > "$TMP_DIR/failing-download.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' unexpected > "${TMP_DIR:?}/unexpected-download"
exit 99
EOF
chmod +x "$TMP_DIR/failing-download.sh"
rm -f "$REPO_DIR/GhosttyKit.xcframework"
ln -s "$CACHE_ROOT/$WRONG_SHA/GhosttyKit.xcframework" "$REPO_DIR/GhosttyKit.xcframework"
env \
  CMUX_GHOSTTYKIT_CACHE_DIR="$CACHE_ROOT" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  GHOSTTYKIT_DOWNLOAD_SCRIPT="$TMP_DIR/failing-download.sh" \
  TMP_DIR="$TMP_DIR" \
  "$REPO_DIR/scripts/assert-ghosttykit.sh" >/dev/null
[[ "$(readlink "$REPO_DIR/GhosttyKit.xcframework")" == "$CACHE_ROOT/$GHOSTTY_SHA/GhosttyKit.xcframework" ]] \
  || fail "cached repair did not repoint the stale symlink"
[[ ! -e "$TMP_DIR/unexpected-download" ]] || fail "cached repair performed a network/download step"
[[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" == "1" ]] || fail "cached repair invoked the downloader again"

# The matching path is the fast/no-network path and permits the wrapped build
# command to run.
rm -f "$XCODEBUILD_LOG"
env \
  PATH="$BIN_DIR:$PATH" \
  TEST_XCODEBUILD_LOG="$XCODEBUILD_LOG" \
  C11_BUILD_LOCK_DIR="$TMP_DIR/matching-lock" \
  CMUX_GHOSTTYKIT_CACHE_DIR="$CACHE_ROOT" \
  GHOSTTYKIT_CHECKSUMS_FILE="$CHECKSUMS_FILE" \
  GHOSTTYKIT_DOWNLOAD_SCRIPT="$TMP_DIR/failing-download.sh" \
  TMP_DIR="$TMP_DIR" \
  "$REPO_DIR/scripts/test-unit.sh" >"$TMP_DIR/matching.out"
[[ -s "$XCODEBUILD_LOG" ]] || fail "matching kit did not reach xcodebuild"
[[ ! -e "$TMP_DIR/unexpected-download" ]] || fail "matching kit invoked the downloader"
[[ "$(wc -l < "$CURL_LOG" | tr -d ' ')" == "1" ]] || fail "matching path changed downloader count"

echo "PASS: GhosttyKit guard refuses stale/unproven kits, repairs pinned kits, and preserves the matching no-network path"
