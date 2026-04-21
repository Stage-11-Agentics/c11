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

exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  "$@"
