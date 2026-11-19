#!/usr/bin/env bash
# Sourceable c11 process identity. Do not name-kill.
#
# A pattern of "c11" (pkill -f c11, pkill -x c11, killall c11) also matches
# c11 and the operator's c11. Quit an owned bundle by its id, then if a
# process is still there, path-scope it:
#   osascript -e 'tell application id "<bundle>" to quit'
#   pkill -f '<pattern containing both c11 and .app/Contents/MacOS/>'
# The pattern must include both tokens. Never pkill -f c11, pkill -x c11,
# or killall c11.

# c11_owns_process BUNDLE_ID EXECUTABLE_PATH
# Exit 0 only when both are true:
#   - bundle id is exactly com.stage11.c11, or starts with com.stage11.c11.
#   - executable contains /Contents/MacOS/ and sits inside c11.app,
#     c11 DEV*.app, or c11 STAGING*.app, with no slash between the
#     product name and .app.
# com.stage11.c11.debug matches the c11. prefix. com.stage11.c11.debug
# does not, and must not match a naive com.stage11.c11 prefix check.
c11_owns_process() {
  local bundle_id="${1-}"
  local executable="${2-}"
  local bundle_path app_name

  case "$bundle_id" in
    com.stage11.c11|com.stage11.c11.*) ;;
    *) return 1 ;;
  esac
  case "$executable" in
    */Contents/MacOS/*) ;;
    *) return 1 ;;
  esac

  bundle_path="${executable%/Contents/MacOS/*}"
  app_name="${bundle_path##*/}"
  case "$app_name" in
    */*) return 1 ;;
    c11.app|c11\ DEV*.app|c11\ STAGING*.app) return 0 ;;
    *) return 1 ;;
  esac
}

# Not a killer. Callers use the osascript + path-scoped pkill pair above.
# This stub exists so a sourced caller cannot fall through to killall c11.
c11_kill_owned() {
  printf '%s\n' "c11_kill_owned: refused. Quit with osascript by bundle id, then pkill -f a pattern that contains both c11 and .app/Contents/MacOS/." >&2
  return 1
}
