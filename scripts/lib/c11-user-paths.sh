#!/usr/bin/env bash
# c11's per-user runtime folder for dev sockets, logs, build logs and
# breadcrumbs: $(getconf DARWIN_USER_TEMP_DIR)c11, 0700 and owned by the user.
# Mirrors Sources/C11UserRuntime.swift (C11H-364). Shared /tmp is never used
# for a fixed name another local account could create first.
#
# Never $TMPDIR: agent harnesses override it and `env -i` drops it.
# C11_DEV_RUNTIME_DIR overrides the folder, for tests' temporary roots only.

# Prints the folder (no trailing slash).
c11_user_runtime_dir() {
  if [[ -n "${C11_DEV_RUNTIME_DIR:-}" ]]; then
    printf '%s\n' "${C11_DEV_RUNTIME_DIR%/}"
    return 0
  fi
  local temp=""
  temp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  if [[ "$temp" != /* ]]; then
    temp="$HOME/Library/Caches/"
  fi
  printf '%s\n' "${temp%/}/c11"
}

# Creates or verifies the folder (a real directory this user owns, 0700) and
# prints it. Refuses a symlink or another account's folder.
c11_ensure_user_runtime_dir() {
  local dir
  dir="$(c11_user_runtime_dir)"
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    (umask 077 && mkdir -p -- "$dir") || return 1
  fi
  if [[ -L "$dir" || ! -d "$dir" || ! -O "$dir" ]]; then
    echo "c11: refusing $dir: it must be a folder this user owns, not a symlink" >&2
    return 1
  fi
  chmod 700 "$dir" || return 1
  printf '%s\n' "$dir"
}

# c11_socket_path_for_stem <stem> [folder]: <folder>/<stem>.sock, with the
# stem cut to its first bytes plus "-" and 8 hex digits of its SHA-256 when
# the path and a "-<pid>" sibling would not fit sun_path (103 bytes). The
# same rule as C11UserRuntime.fittedSocketStem.
c11_socket_path_for_stem() {
  local stem="$1"
  local dir="${2:-}"
  [[ -n "$dir" ]] || dir="$(c11_user_runtime_dir)"
  local budget=$(( 103 - ${#dir} - 1 - 5 - 6 ))
  if (( ${#stem} > budget )); then
    local keep=$(( budget - 9 ))
    (( keep < 0 )) && keep=0
    local digest
    digest="$(printf '%s' "$stem" | /usr/bin/shasum -a 256 | cut -c1-8)"
    stem="${stem:0:keep}-${digest}"
  fi
  printf '%s/%s.sock\n' "$dir" "$stem"
}

# The /tmp name builds before C11H-364 used for the same stem.
c11_legacy_tmp_socket_path() {
  printf '/tmp/%s.sock\n' "$1"
}

# Prints the uid that owns the entry itself (a link is not followed).
_c11_entry_owner() {
  /usr/bin/stat -f '%u' -- "$1" 2>/dev/null || stat -c '%u' -- "$1" 2>/dev/null
}

# c11_private_write <path> <value>: writes one line 0600 through a mktemp file
# in the same folder and a rename. A symlink or hard link at <path> is
# replaced, never written through; an entry another account owns is refused
# (in sticky /tmp the rename could not replace it anyway).
c11_private_write() {
  local path="$1" value="$2" dir tmp owner
  dir="$(dirname -- "$path")"
  if [[ -e "$path" || -L "$path" ]]; then
    owner="$(_c11_entry_owner "$path")"
    if [[ "$owner" != "$(id -u)" ]]; then
      echo "c11: not writing $path: another user owns it" >&2
      return 1
    fi
    if [[ -d "$path" && ! -L "$path" ]]; then
      echo "c11: not writing $path: it is a folder" >&2
      return 1
    fi
  fi
  tmp="$(umask 077 && mktemp "$dir/.c11-write.XXXXXXXX")" || return 1
  if ! printf '%s\n' "$value" > "$tmp"; then
    /bin/rm -f -- "$tmp"
    return 1
  fi
  if ! /bin/mv -fh -- "$tmp" "$path"; then
    /bin/rm -f -- "$tmp"
    return 1
  fi
}

# c11_private_symlink <target> <path>: points <path> at <target> through a
# link made under a random name and renamed into place. A symlink this user
# owns is replaced; anything else, or an entry another account owns, is left
# alone and refused.
c11_private_symlink() {
  local target="$1" path="$2" dir tmp owner
  dir="$(dirname -- "$path")"
  if [[ -e "$path" || -L "$path" ]]; then
    owner="$(_c11_entry_owner "$path")"
    if [[ "$owner" != "$(id -u)" ]]; then
      echo "c11: not linking $path: another user owns it; do not run it" >&2
      return 1
    fi
    if [[ ! -L "$path" ]]; then
      echo "c11: not linking $path: something other than a link is there" >&2
      return 1
    fi
  fi
  tmp="$dir/.c11-link.$$.$RANDOM$RANDOM"
  ln -s -- "$target" "$tmp" || return 1
  if ! /bin/mv -fh -- "$tmp" "$path"; then
    /bin/rm -f -- "$tmp"
    return 1
  fi
}
