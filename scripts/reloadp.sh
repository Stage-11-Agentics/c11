#!/usr/bin/env bash
set -euo pipefail

"$(cd "$(dirname "$0")" && pwd)/assert-ghosttykit.sh"
"$(cd "$(dirname "$0")" && pwd)/with-build-lock.sh" xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 -configuration Release -destination 'platform=macOS' build
# Path-scoped so a name kill cannot hit c11. Pattern contains c11 and .app/Contents/MacOS/.
pkill -f "c11.app/Contents/MacOS/c11" || true
sleep 0.2
APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/c11.app/Contents/MacOS/c11" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -n "${APP_PATH}" ]]; then
  APP_PATH="$(dirname "$(dirname "$(dirname "$APP_PATH")")")"
fi
if [[ -z "${APP_PATH}" ]]; then
  echo "c11.app not found in DerivedData" >&2
  exit 1
fi
# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into c11, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"
