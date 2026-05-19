#!/usr/bin/env bash
set -euo pipefail

APP_NAME="c11 STAGING"
BUNDLE_ID="com.stage11.c11.staging"
BASE_APP_NAME="c11"
BASE_EXECUTABLE_NAME="c11"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
WMO=0
UNIVERSAL=0
CLEAN=0
LAST_SOCKET_PATH_DIR="$HOME/Library/Application Support/c11"
LAST_SOCKET_PATH_FILE="${LAST_SOCKET_PATH_DIR}/last-socket-path"

write_last_socket_path() {
  local socket_path="$1"
  mkdir -p "$LAST_SOCKET_PATH_DIR"
  echo "$socket_path" > "$LAST_SOCKET_PATH_FILE" || true
  echo "$socket_path" > /tmp/c11-last-socket-path || true
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reloads.sh [options]

Release build with isolated "c11 STAGING" identity. Runs side-by-side with
the production c11 app.

Options:
  --tag <name>           Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  --clean                Wipe the derived-data dir before building.
  --universal            Build a universal (arm64 + x86_64) binary.
                         Default is arm64-only for faster local iteration.
                         Use this for x86_64-specific checks; combine with
                         --wmo for full prod parity before a tag push.
  --wmo                  Use wholemodule Swift compilation (prod parity).
                         Default is incremental for faster local iteration.
                         Recommended before tag push to catch WMO-only bugs.
  -h, --help             Show this help.

The default derived-data path keys on the tag *family* (the prefix up to
the first hyphen of the sanitized tag), so related tags share an
incremental build cache:

  --tag release/v0.49.0   -> /tmp/c11-staging-release/
  --tag c11-110-build     -> /tmp/c11-staging-c11/
  --tag feat-foo-bar      -> /tmp/c11-staging-feat/

The script prints the last tag/SHA built into the shared dir on reuse;
pass --clean (or --derived-data <path>) to override.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

# Family extraction: prefix-up-to-first-hyphen of the sanitized tag slug.
# release-v0-49-0 -> release; c11-110-build-perf -> c11; feat-foo -> feat.
# Lets related tags (release/v0.49.0, release/v0.50.0; c11-108, c11-109)
# share a derived-data dir for incremental rebuilds across branches.
family_for_slug() {
  local slug="$1"
  local family="${slug%%-*}"
  if [[ -z "$family" ]]; then
    family="default"
  fi
  echo "$family"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    --wmo)
      WMO=1
      shift
      ;;
    --universal)
      UNIVERSAL=1
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  TAG_FAMILY="$(family_for_slug "$TAG_SLUG")"
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="c11 STAGING ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.stage11.c11.staging.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="/tmp/c11-staging-${TAG_FAMILY}"
  fi
fi

# Optional cold-build: wipe the derived-data dir before building.
# Mirrors the old per-tag "always clean" behavior for callers that need it.
if [[ "$CLEAN" -eq 1 && -n "$DERIVED_DATA" && -d "$DERIVED_DATA" ]]; then
  echo "[reloads.sh] --clean: removing $DERIVED_DATA"
  rm -rf "$DERIVED_DATA"
fi

# Breadcrumb for shared derived-data reuse. Reports what was last built
# in this dir alongside the current HEAD/tag so the operator can decide
# whether to pass --clean next time.
LAST_SHA_FILE=""
LAST_TAG_FILE=""
if [[ -n "$DERIVED_DATA" ]]; then
  LAST_SHA_FILE="${DERIVED_DATA}/.last-sha"
  LAST_TAG_FILE="${DERIVED_DATA}/.last-tag"
  CUR_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [[ -f "$LAST_SHA_FILE" || -f "$LAST_TAG_FILE" ]]; then
    PREV_SHA="$(cat "$LAST_SHA_FILE" 2>/dev/null || echo unknown)"
    PREV_TAG="$(cat "$LAST_TAG_FILE" 2>/dev/null || echo unknown)"
    echo "[reloads.sh] reusing $DERIVED_DATA (last: tag=$PREV_TAG sha=$PREV_SHA; now: tag=${TAG:-none} sha=$CUR_SHA)"
    echo "             pass --clean to force a cold build"
  fi
fi

XCODEBUILD_ARGS=(
  -project GhosttyTabs.xcodeproj
  -scheme c11
  -configuration Release
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  )
fi
# On Apple Silicon the x86_64 slice of a universal build is dead weight at
# iteration time and roughly doubles the Swift compile cost. CI's release.yml
# still produces universal because it invokes xcodebuild without these
# overrides; pass --universal here to catch x86_64-only issues locally.
if [[ "$UNIVERSAL" -eq 0 ]]; then
  XCODEBUILD_ARGS+=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
fi
# Staging is built for running, not for IDE navigation; the indexer output
# would only be useful if we ever edited against this build in Xcode.
XCODEBUILD_ARGS+=(COMPILER_INDEX_STORE_ENABLE=NO)
# Default to incremental Swift compilation. Wholemodule is faster for a
# single binary's runtime perf but slower to compile on each iteration.
# Pass --wmo for the rare staging build that needs prod parity (e.g. the
# build right before a tag push, to catch WMO-only regressions like the
# 0.47.0 New Workspace dialog issue).
if [[ "$WMO" -eq 0 ]]; then
  XCODEBUILD_ARGS+=(SWIFT_COMPILATION_MODE=incremental)
fi
XCODEBUILD_ARGS+=(build)

echo "[reloads.sh] xcodebuild ${XCODEBUILD_ARGS[*]}"
xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2

# Successful build: record the breadcrumb for the next reuse.
if [[ -n "$DERIVED_DATA" && -d "$DERIVED_DATA" ]]; then
  CUR_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '%s\n' "$CUR_SHA" > "$LAST_SHA_FILE" 2>/dev/null || true
  printf '%s\n' "${TAG:-none}" > "$LAST_TAG_FILE" 2>/dev/null || true
fi

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Release/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Release/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${SEARCH_APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH:-}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/${FALLBACK_APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
    fi
  fi
fi
if [[ -z "${APP_PATH:-}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

# Staging always copies the built app and patches the plist to set an isolated
# socket path, bundle id, and display name. This prevents conflicts with the
# production cmux app.
STAGING_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
rm -rf "$STAGING_APP_PATH"
cp -R "$APP_PATH" "$STAGING_APP_PATH"
INFO_PLIST="$STAGING_APP_PATH/Contents/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"

  # Inject staging socket paths via LSEnvironment so the Release binary
  # (which defaults to the per-user stable socket) uses isolated sockets instead.
  STAGING_SLUG="${TAG_SLUG:-staging}"
  APP_SUPPORT_DIR="$HOME/Library/Application Support/c11"
  CMUXD_SOCKET="${APP_SUPPORT_DIR}/c11d-${STAGING_SLUG}.sock"
  CMUX_SOCKET="/tmp/c11-${STAGING_SLUG}.sock"
  write_last_socket_path "$CMUX_SOCKET"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUXD_UNIX_PATH \"${CMUXD_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUXD_UNIX_PATH string \"${CMUXD_SOCKET}\"" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SOCKET_PATH \"${CMUX_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_SOCKET_PATH string \"${CMUX_SOCKET}\"" "$INFO_PLIST"
  if [[ -S "$CMUXD_SOCKET" ]]; then
    for PID in $(lsof -t "$CMUXD_SOCKET" 2>/dev/null); do
      kill "$PID" 2>/dev/null || true
    done
    rm -f "$CMUXD_SOCKET"
  fi
  if [[ -S "$CMUX_SOCKET" ]]; then
    rm -f "$CMUX_SOCKET"
  fi
  /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$STAGING_APP_PATH" >/dev/null 2>&1 || true
fi
APP_PATH="$STAGING_APP_PATH"

# Ensure any running instance is fully terminated, regardless of DerivedData path.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
# Kill any running staging instance; allow side-by-side with the main and dev apps.
pkill -f "${APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" || true
sleep 0.3
C11D_SRC="$PWD/c11d/zig-out/bin/c11d"
if [[ -d "$PWD/c11d" ]]; then
  (cd "$PWD/c11d" && zig build -Doptimize=ReleaseFast)
fi
if [[ -x "$C11D_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$C11D_SRC" "$BIN_DIR/c11d"
  chmod +x "$BIN_DIR/c11d"
  ln -sfh c11d "$BIN_DIR/cmuxd"
fi
# Avoid inheriting cmux/ghostty environment variables from the terminal that
# runs this script (often inside another cmux instance), which can cause
# socket and resource-path conflicts.
OPEN_CLEAN_ENV=(
  env
  -u CMUX_SOCKET_PATH
  -u CMUX_TAB_ID
  -u CMUX_PANEL_ID
  -u CMUXD_UNIX_PATH
  -u CMUX_TAG
  -u CMUX_BUNDLE_ID
  -u CMUX_SHELL_INTEGRATION
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  # Dev shells (including CI/Codex) often force-disable paging by exporting these.
  # Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
  -u GIT_PAGER
  -u GH_PAGER
  -u TERMINFO
  -u XDG_DATA_DIRS
)

# Always inject staging socket paths via env to ensure they take effect
# (LSEnvironment requires app restart to pick up plist changes).
"${OPEN_CLEAN_ENV[@]}" CMUX_SOCKET_PATH="$CMUX_SOCKET" CMUXD_UNIX_PATH="$CMUXD_SOCKET" open -g "$APP_PATH"

# Safety: ensure only one instance is running.
sleep 0.2
PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
if [[ "${#PIDS[@]}" -gt 1 ]]; then
  NEWEST_PID=""
  NEWEST_AGE=999999
  for PID in "${PIDS[@]}"; do
    AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
    if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
      NEWEST_AGE="$AGE"
      NEWEST_PID="$PID"
    fi
  done
  for PID in "${PIDS[@]}"; do
    if [[ "$PID" != "$NEWEST_PID" ]]; then
      kill "$PID" 2>/dev/null || true
    fi
  done
fi
