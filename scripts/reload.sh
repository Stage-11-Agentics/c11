#!/usr/bin/env bash
set -euo pipefail

APP_NAME="c11 DEV"
BUNDLE_ID="com.stage11.c11.debug"
BASE_APP_NAME="c11 DEV"
BASE_EXECUTABLE_NAME="c11"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
CMUX_DEBUG_LOG=""
CLI_PATH=""
LAST_SOCKET_PATH_DIR="$HOME/Library/Application Support/c11"
LAST_SOCKET_PATH_FILE="${LAST_SOCKET_PATH_DIR}/last-socket-path"

write_dev_cli_shim() {
  local target="$1"
  local fallback_bin="$2"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
# c11 dev shim (managed by scripts/reload.sh)
set -euo pipefail

CLI_PATH_FILE="/tmp/c11-last-cli-path"
CLI_PATH_OWNER="\$(stat -f '%u' "\$CLI_PATH_FILE" 2>/dev/null || stat -c '%u' "\$CLI_PATH_FILE" 2>/dev/null || echo -1)"
if [[ -r "\$CLI_PATH_FILE" ]] && [[ ! -L "\$CLI_PATH_FILE" ]] && [[ "\$CLI_PATH_OWNER" == "\$(id -u)" ]]; then
  CLI_PATH="\$(cat "\$CLI_PATH_FILE")"
  if [[ -x "\$CLI_PATH" ]]; then
    exec "\$CLI_PATH" "\$@"
  fi
fi

if [[ -x "$fallback_bin" ]]; then
  exec "$fallback_bin" "\$@"
fi

echo "error: no reload-selected dev c11 CLI found. Run ./scripts/reload.sh --tag <name> first." >&2
exit 1
EOF
  chmod +x "$target"
}

select_cli_shim_target() {
  local bin_name="$1"
  local app_cli_dir="/Applications/c11.app/Contents/Resources/bin"
  local marker="c11 dev shim (managed by scripts/reload.sh)"
  local target=""
  local path_entry=""
  local candidate=""

  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ -z "$path_entry" ]] && continue
    if [[ "$path_entry" == "~/"* ]]; then
      path_entry="$HOME/${path_entry#~/}"
    fi
    if [[ "$path_entry" == "$app_cli_dir" ]]; then
      break
    fi
    [[ -d "$path_entry" && -w "$path_entry" ]] || continue
    candidate="$path_entry/$bin_name"
    if [[ ! -e "$candidate" ]]; then
      target="$candidate"
      break
    fi
    if [[ -f "$candidate" ]] && grep -q "$marker" "$candidate" 2>/dev/null; then
      target="$candidate"
      break
    fi
  done

  if [[ -n "$target" ]]; then
    echo "$target"
    return 0
  fi

  # Fallback for PATH layouts where app CLI isn't listed or no earlier entries were writable.
  for path_entry in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    [[ -d "$path_entry" && -w "$path_entry" ]] || continue
    candidate="$path_entry/$bin_name"
    if [[ ! -e "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    if [[ -f "$candidate" ]] && grep -q "$marker" "$candidate" 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

write_last_socket_path() {
  local socket_path="$1"
  mkdir -p "$LAST_SOCKET_PATH_DIR"
  echo "$socket_path" > "$LAST_SOCKET_PATH_FILE" || true
  echo "$socket_path" > /tmp/c11-last-socket-path || true
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reload.sh --tag <name> [options]

Options:
  --tag <name>           Required. Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  -h, --help             Show this help.
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

tagged_derived_data_path() {
  local slug="$1"
  echo "$HOME/Library/Developer/Xcode/DerivedData/c11-${slug}"
}

print_tag_cleanup_reminder() {
  local current_slug="$1"
  local path=""
  local tag=""
  local seen=" "
  local -a stale_tags=()

  while IFS= read -r -d '' path; do
    if [[ "$path" == /tmp/c11-* ]]; then
      tag="${path#/tmp/c11-}"
    elif [[ "$path" == "$HOME/Library/Developer/Xcode/DerivedData/c11-"* ]]; then
      tag="${path#$HOME/Library/Developer/Xcode/DerivedData/c11-}"
    else
      continue
    fi
    if [[ "$tag" == "$current_slug" ]]; then
      continue
    fi
    # Only surface stale debug tag builds.
    if [[ ! -d "$path/Build/Products/Debug" ]]; then
      continue
    fi
    if [[ "$seen" == *" $tag "* ]]; then
      continue
    fi
    seen="${seen}${tag} "
    stale_tags+=("$tag")
  done < <(
    find /tmp -maxdepth 1 -name 'c11-*' -print0 2>/dev/null
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'c11-*' -print0 2>/dev/null
  )

  echo
  echo "Tag cleanup status:"
  echo "  current tag: ${current_slug} (keep this running until you verify)"
  if [[ "${#stale_tags[@]}" -eq 0 ]]; then
    echo "  stale tags: none"
    echo "  stale cleanup: not needed"
  else
    echo "  stale tags:"
    for tag in "${stale_tags[@]}"; do
      echo "    - ${tag}"
    done
    echo "Prune all stale tags (protects running tags automatically):"
    echo "  ./scripts/prune-tags.sh          # dry run"
    echo "  ./scripts/prune-tags.sh --yes    # actually delete"
  fi
  echo "After you verify current tag, cleanup command:"
  echo "  pkill -f \"c11 DEV ${current_slug}.app/Contents/MacOS/c11\""
  echo "  rm -rf \"$(tagged_derived_data_path "$current_slug")\" \"/tmp/c11-${current_slug}\" \"/tmp/c11-debug-${current_slug}.sock\""
  echo "  rm -f \"/tmp/c11-debug-${current_slug}.log\""
  echo "  rm -f \"$HOME/Library/Application Support/c11/c11d-dev-${current_slug}.sock\""
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

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required (example: ./scripts/reload.sh --tag fix-sidebar-theme)" >&2
  usage
  exit 1
fi

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="c11 DEV ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.stage11.c11.debug.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="$(tagged_derived_data_path "$TAG_SLUG")"
  fi
fi

XCODEBUILD_ARGS=(
  -project GhosttyTabs.xcodeproj
  -scheme c11
  -configuration Debug
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
XCODEBUILD_ARGS+=(build)

XCODE_LOG="/tmp/c11-xcodebuild-${TAG_SLUG}.log"
xcodebuild "${XCODEBUILD_ARGS[@]}" 2>&1 | tee "$XCODE_LOG" | grep -E '(warning:|error:|fatal:|BUILD FAILED|BUILD SUCCEEDED|\*\* BUILD)' || true
XCODE_EXIT="${PIPESTATUS[0]}"
echo "Full build log: $XCODE_LOG"
if [[ "$XCODE_EXIT" -ne 0 ]]; then
  echo "error: xcodebuild failed with exit code $XCODE_EXIT" >&2
  exit "$XCODE_EXIT"
fi
sleep 0.2

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${SEARCH_APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${FALLBACK_APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" -print0 \
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
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

if [[ -n "${TAG_SLUG:-}" ]]; then
  TMP_COMPAT_DERIVED_LINK="/tmp/c11-${TAG_SLUG}"
  if [[ "$DERIVED_DATA" != "$TMP_COMPAT_DERIVED_LINK" ]]; then
    ABS_DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
    rm -rf "$TMP_COMPAT_DERIVED_LINK"
    ln -s "$ABS_DERIVED_DATA" "$TMP_COMPAT_DERIVED_LINK"
  fi
fi

if [[ -n "$TAG" && "$APP_NAME" != "$SEARCH_APP_NAME" ]]; then
  TAG_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
  rm -rf "$TAG_APP_PATH"
  cp -R "$APP_PATH" "$TAG_APP_PATH"
  INFO_PLIST="$TAG_APP_PATH/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      APP_SUPPORT_DIR="$HOME/Library/Application Support/c11"
      CMUXD_SOCKET="${APP_SUPPORT_DIR}/c11d-dev-${TAG_SLUG}.sock"
      CMUX_SOCKET="/tmp/c11-debug-${TAG_SLUG}.sock"
      CMUX_DEBUG_LOG="/tmp/c11-debug-${TAG_SLUG}.log"
      write_last_socket_path "$CMUX_SOCKET"
      echo "$CMUX_DEBUG_LOG" > /tmp/c11-last-debug-log-path || true
      /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUXD_UNIX_PATH \"${CMUXD_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUXD_UNIX_PATH string \"${CMUXD_SOCKET}\"" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SOCKET_PATH \"${CMUX_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_SOCKET_PATH string \"${CMUX_SOCKET}\"" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_DEBUG_LOG \"${CMUX_DEBUG_LOG}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_DEBUG_LOG string \"${CMUX_DEBUG_LOG}\"" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SOCKET_ENABLE 1" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_SOCKET_ENABLE string 1" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SOCKET_MODE automation" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_SOCKET_MODE string automation" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD 1" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD string 1" "$INFO_PLIST"
      /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUXTERM_REPO_ROOT \"${PWD}\"" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUXTERM_REPO_ROOT string \"${PWD}\"" "$INFO_PLIST"
      if [[ -S "$CMUXD_SOCKET" ]]; then
        for PID in $(lsof -t "$CMUXD_SOCKET" 2>/dev/null); do
          kill "$PID" 2>/dev/null || true
        done
        rm -f "$CMUXD_SOCKET"
      fi
      if [[ -S "$CMUX_SOCKET" ]]; then
        rm -f "$CMUX_SOCKET"
      fi
    fi
    /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$TAG_APP_PATH" >/dev/null 2>&1 || true
  fi
  APP_PATH="$TAG_APP_PATH"
fi

CLI_PATH="$(dirname "$APP_PATH")/c11"
if [[ -x "$CLI_PATH" ]]; then
  (umask 077; printf '%s\n' "$CLI_PATH" > /tmp/c11-last-cli-path) || true
  ln -sfn "$CLI_PATH" /tmp/c11-cli || true

  # Stable shims that always follow the last reload-selected dev CLI.
  # Write both c11-dev (primary) and cmux-dev (alias, kept for muscle memory).
  for dev_shim in "$HOME/.local/bin/c11-dev" "$HOME/.local/bin/cmux-dev"; do
    write_dev_cli_shim "$dev_shim" "/Applications/c11.app/Contents/Resources/bin/c11"
  done

  C11_SHIM_TARGET="$(select_cli_shim_target c11 || true)"
  if [[ -n "${C11_SHIM_TARGET:-}" ]]; then
    write_dev_cli_shim "$C11_SHIM_TARGET" "/Applications/c11.app/Contents/Resources/bin/c11"
  fi
  CMUX_SHIM_TARGET="$(select_cli_shim_target cmux || true)"
  if [[ -n "${CMUX_SHIM_TARGET:-}" ]]; then
    write_dev_cli_shim "$CMUX_SHIM_TARGET" "/Applications/c11.app/Contents/Resources/bin/c11"
  fi
fi

# Ensure any running instance is fully terminated, regardless of DerivedData path.
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 0.3
if [[ -z "$TAG" ]]; then
  # Non-tag mode: kill any running instance (across any DerivedData path) to avoid socket conflicts.
  pkill -f "/${BASE_APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" || true
else
  # Tag mode: only kill the tagged instance; allow side-by-side with the main app.
  pkill -f "${APP_NAME}.app/Contents/MacOS/${BASE_EXECUTABLE_NAME}" || true
fi
sleep 0.3
CMUXD_SRC="$PWD/c11d/zig-out/bin/c11d"
GHOSTTY_HELPER_SRC="$PWD/ghostty/zig-out/bin/ghostty"
if [[ -d "$PWD/c11d" ]]; then
  (cd "$PWD/c11d" && zig build -Doptimize=ReleaseFast)
fi
if [[ -d "$PWD/ghostty" ]]; then
  (cd "$PWD/ghostty" && zig build cli-helper -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast)
fi
if [[ -x "$CMUXD_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$CMUXD_SRC" "$BIN_DIR/c11d"
  chmod +x "$BIN_DIR/c11d"
fi
if [[ -x "$GHOSTTY_HELPER_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$GHOSTTY_HELPER_SRC" "$BIN_DIR/ghostty"
  chmod +x "$BIN_DIR/ghostty"
fi
CLI_PATH="$APP_PATH/Contents/Resources/bin/c11"
if [[ -x "$CLI_PATH" ]]; then
  echo "$CLI_PATH" > /tmp/c11-last-cli-path || true
fi
# Avoid inheriting c11/ghostty environment variables from the terminal that
# runs this script (often inside another c11 instance), which can cause
# socket and resource-path conflicts.
OPEN_CLEAN_ENV=(
  env
  -u CMUX_SOCKET_PATH
  -u CMUX_WORKSPACE_ID
  -u CMUX_SURFACE_ID
  -u CMUX_TAB_ID
  -u CMUX_PANEL_ID
  -u CMUXD_UNIX_PATH
  -u CMUX_TAG
  -u CMUX_DEBUG_LOG
  -u CMUX_BUNDLE_ID
  -u CMUX_SHELL_INTEGRATION
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  # Dev shells (including CI/Codex) often force-disable paging by exporting these.
  # Don't leak that into c11, otherwise `git diff` won't page even with PAGER=less.
  -u GIT_PAGER
  -u GH_PAGER
  -u TERMINFO
  -u XDG_DATA_DIRS
)

if [[ -n "${TAG_SLUG:-}" && -n "${CMUX_SOCKET:-}" ]]; then
  # Ensure tag-specific socket paths win even if the caller has CMUX_* overrides.
  "${OPEN_CLEAN_ENV[@]}" CMUX_TAG="$TAG_SLUG" CMUX_SOCKET_ENABLE=1 CMUX_SOCKET_MODE=automation CMUX_SOCKET_PATH="$CMUX_SOCKET" CMUXD_UNIX_PATH="$CMUXD_SOCKET" CMUX_DEBUG_LOG="$CMUX_DEBUG_LOG" CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 CMUXTERM_REPO_ROOT="$PWD" open -g "$APP_PATH"
elif [[ -n "${TAG_SLUG:-}" ]]; then
  "${OPEN_CLEAN_ENV[@]}" CMUX_TAG="$TAG_SLUG" CMUX_SOCKET_ENABLE=1 CMUX_SOCKET_MODE=automation CMUX_DEBUG_LOG="$CMUX_DEBUG_LOG" CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 CMUXTERM_REPO_ROOT="$PWD" open -g "$APP_PATH"
else
  echo "/tmp/c11-debug.sock" > /tmp/c11-last-socket-path || true
  echo "/tmp/c11-debug.log" > /tmp/c11-last-debug-log-path || true
  "${OPEN_CLEAN_ENV[@]}" open -g "$APP_PATH"
fi

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

if [[ -n "${TAG_SLUG:-}" ]]; then
  print_tag_cleanup_reminder "$TAG_SLUG"
fi

if [[ -x "${CLI_PATH:-}" ]]; then
  echo
  echo "CLI path:"
  echo "  $CLI_PATH"
  echo "CLI helpers:"
  echo "  /tmp/c11-cli ..."
  echo "  $HOME/.local/bin/c11-dev ..."
  echo "  $HOME/.local/bin/cmux-dev ..."
  if [[ -n "${C11_SHIM_TARGET:-}" ]]; then
    echo "  $C11_SHIM_TARGET ..."
  fi
  if [[ -n "${CMUX_SHIM_TARGET:-}" ]]; then
    echo "  $CMUX_SHIM_TARGET ..."
  fi
  echo "If your shell still resolves a stale c11/cmux, run: rehash"
fi
