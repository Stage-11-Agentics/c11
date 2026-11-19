#!/usr/bin/env bash
# Exact socket owned by a c11 test launch. Never globs c11 or c11mux sockets.
set -euo pipefail

c11_owned_test_socket() {
  local root="${1:-${C11_TEST_SOCKET_ROOT:-/tmp}}"
  local tag="${2:-}"
  local slug=""
  if [[ -n "$tag" ]]; then
    slug="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  fi
  if [[ -n "$slug" ]]; then
    printf '%s/c11-debug-%s.sock\n' "$root" "$slug"
  else
    printf '%s/c11-debug.sock\n' "$root"
  fi
}

c11_cleanup_owned_socket() {
  local sock="$1"
  case "$sock" in
    *"/c11-debug.sock"|*"/c11-debug-"*".sock") ;;
    *)
      echo "refusing to remove a socket c11 does not own: $sock" >&2
      return 1
      ;;
  esac
  rm -f -- "$sock"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command="${1:-}"
  tag="${2:-}"
  case "$command" in
    path)
      c11_owned_test_socket "${C11_TEST_SOCKET_ROOT:-/tmp}" "$tag"
      ;;
    cleanup)
      c11_cleanup_owned_socket "$(c11_owned_test_socket "${C11_TEST_SOCKET_ROOT:-/tmp}" "$tag")"
      ;;
    *)
      echo "usage: c11-owned-socket.sh path|cleanup [tag]" >&2
      exit 2
      ;;
  esac
fi
