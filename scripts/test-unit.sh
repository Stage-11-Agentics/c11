#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="GhosttyTabs.xcodeproj"
SCHEME="c11-unit"
CONFIGURATION="${C11_TEST_CONFIGURATION:-${CMUX_TEST_CONFIGURATION:-Debug}}"
DESTINATION="${C11_TEST_DESTINATION:-${CMUX_TEST_DESTINATION:-platform=macOS}}"

# Default to `test` when no explicit xcodebuild action is provided.
if [ "$#" -eq 0 ]; then
  set -- test
fi

# C11-371: same 60s hard case bound as test-unit-local.sh. XCTest rounds up
# to a minute, so 60 is the effective bound.
for arg in "$@"; do
  case "$arg" in
    test|test-without-building|-only-testing:*)
      # Prepend. An empty array under `set -u` is an unbound variable on bash 3.2.
      set -- \
        -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 60 \
        -maximum-test-execution-time-allowance 60 \
        "$@"
      break
      ;;
  esac
done

scripts/assert-ghosttykit.sh
exec scripts/with-build-lock.sh xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  "$@"
