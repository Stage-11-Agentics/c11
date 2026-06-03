#!/usr/bin/env bash
# C11-99 Area B: safe local invocation of the c11-unit XCTest scheme.
#
# Without isolation, `xcodebuild test -scheme c11-unit` binds /tmp/c11-debug.sock
# (the path the operator's running c11 DEV.app owns) and unlinks it on test-host
# teardown — killing the operator's c11 socket mid-session. See the audit doc:
# notes/build-test-pipeline-audit-2026-05-18.md §2.
#
# This wrapper forces the test host onto a per-PID socket path the operator's
# c11 never touches. The XCTest host still beachballs its own window for ~22s
# (intrinsic to the launch chain) but the operator's primary c11 is unaffected.
#
# Three layers of defense:
#   1. CMUX_TAG  → triggers taggedDebugSocketPath → /tmp/c11-debug-<tag>.sock
#   2. CMUX_SOCKET_PATH + CMUX_ALLOW_SOCKET_OVERRIDE → explicit override
#   3. SocketControlSettings runtime guard (per-PID fallback when
#      XCTestConfigurationFilePath is in env) — defense-in-depth in case the
#      scheme env block is bypassed or wiped by a future cleanup pass.
#
# Usage:
#   scripts/test-unit-local.sh                                                     # full c11-unit
#   scripts/test-unit-local.sh -only-testing:c11Tests/<Class>/<test>                # narrow slice
#   scripts/test-unit-local.sh -resultBundlePath /tmp/c11-unit.xcresult test        # save xcresult
set -euo pipefail

cd "$(dirname "$0")/.."

SOCKET_TAG="xctest-${USER:-anon}-$$"
export CMUX_TAG="$SOCKET_TAG"
export CMUX_SOCKET_PATH="/tmp/c11-test-${USER:-anon}-$$.sock"
export CMUX_ALLOW_SOCKET_OVERRIDE=1

PROJECT="GhosttyTabs.xcodeproj"
SCHEME="c11-unit"
CONFIGURATION="${C11_TEST_CONFIGURATION:-${CMUX_TEST_CONFIGURATION:-Debug}}"
DESTINATION="${C11_TEST_DESTINATION:-${CMUX_TEST_DESTINATION:-platform=macOS}}"
DERIVED_DATA="${C11_TEST_DERIVED_DATA:-build-test-local}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

echo "[test-unit-local] CMUX_TAG=$CMUX_TAG"
echo "[test-unit-local] CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH"
echo "[test-unit-local] derivedDataPath=$DERIVED_DATA"

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "$@"
