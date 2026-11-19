#!/usr/bin/env bash
# Prune stale per-tag build artifacts left behind by ./scripts/reload.sh --tag <tag>.
#
# Each tagged reload leaves ~3.5 GB in DerivedData plus /tmp build dirs, sockets, and
# logs. Nothing cleans them automatically, so they accumulate (we've seen 200 GB+).
# This script finds every c11-* tag directory, skips ones whose app is currently
# running, and removes the rest.
#
# Dry-run by default. Pass --yes to actually delete. Pass --keep <tag> (repeatable)
# to preserve additional tags beyond the auto-detected running ones.

set -euo pipefail

DRY_RUN=1
KEEP_TAGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--keep <tag>]...

  --yes         Actually delete (default is dry-run).
  --keep TAG    Additional tag to preserve. Repeatable. Running tags are always kept.
  -h, --help    Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) DRY_RUN=0; shift ;;
    --keep)
      if [[ -z "${2:-}" ]]; then
        echo "error: --keep requires a tag" >&2
        exit 2
      fi
      KEEP_TAGS+=("$2")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

DERIVED_ROOT="${C11_PRUNE_DERIVED_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
TMP_ROOT="${C11_PRUNE_TMP_ROOT:-/tmp}"
# Tagged builds since C11H-364 keep their sockets, logs and DerivedData link in
# c11's per-user folder ($(getconf DARWIN_USER_TEMP_DIR)c11); older ones in /tmp.
# shellcheck source=lib/c11-user-paths.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/c11-user-paths.sh"
RUNTIME_ROOT="${C11_PRUNE_RUNTIME_ROOT:-$(c11_user_runtime_dir)}"
C11D_SOCK_DIR="${C11_PRUNE_SUPPORT_DIR:-$HOME/Library/Application Support/c11}"

# BSD sed uses `|` as the `s|||` delimiter, so the `(c11|cmux)` alternation
# needs a different separator or the substitution never extracts a tag.
tag_from_process_line() {
  printf '%s\n' "$1" | sed -E 's#.*DerivedData/(c11h|c11|cmux)-([^/]+)/Build/Products/Debug/.*#\2#' # c11-2.0:legacy
}

running_tags() {
  # Each c11 app lives at .../c11-<tag>/Build/Products/Debug/c11 DEV <tag>.app/.../c11.
  # Path-scoped. Also keep a live c11 DEV bundle (executable ends in /c11, not /c11)
  # so this prune cannot drop DerivedData out from under the operator's c11.
  {
    pgrep -afl 'c11 DEV [^/]*\.app/Contents/MacOS/c11' 2>/dev/null || true
    pgrep -afl 'c11 DEV [^/]*\.app/Contents/MacOS/c11([^h]|$)' 2>/dev/null || true
    # The retired line's tagged builds, which prune also clears: a running one is kept.
    pgrep -afl 'c11h DEV [^/]*\.app/Contents/MacOS/c11h' 2>/dev/null || true # c11-2.0:legacy
  } | while IFS= read -r line; do
    tag_from_process_line "$line"
  done | grep -vE '^$' | sort -u
}

human_bytes() {
  local b=$1
  if (( b > 1073741824 )); then printf '%.1fG' "$(echo "$b / 1073741824" | bc -l)"
  elif (( b > 1048576 )); then printf '%.1fM' "$(echo "$b / 1048576" | bc -l)"
  elif (( b > 1024 )); then printf '%.1fK' "$(echo "$b / 1024" | bc -l)"
  else printf '%dB' "$b"
  fi
}

# A DerivedData directory is deleted only when every built app is in the c11
# family and at least one such app exists. One coexisting c11, cmux, or
# unreadable product keeps the whole root, including the c11 app beside it.
is_c11_product_root() {
  local root="$1"
  [[ -d "$root" ]] || return 1
  local app plist id owned=0
  shopt -s nullglob
  local apps=(
    "$root"/Build/Products/*/*.app
    "$root"/Build/Products/*/*/*.app
  )
  shopt -u nullglob
  [[ ${#apps[@]} -gt 0 ]] || return 1
  for app in "${apps[@]}"; do
    [[ -d "$app" ]] || continue
    plist="$app/Contents/Info.plist"
    id=""
    if [[ -f "$plist" ]]; then
      id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    fi
    # c11 2.0's own builds, and the retired line's tagged builds it still cleans up.
    if [[ "$id" == "com.stage11.c11" || "$id" == com.stage11.c11.* ||
          "$id" == "com.stage11.c11h" || "$id" == com.stage11.c11h.* ]]; then # c11-2.0:legacy
      owned=1
      continue
    fi
    return 1
  done
  [[ "$owned" -eq 1 ]]
}

collect_tags() {
  {
    if [[ -d "$DERIVED_ROOT" ]]; then
      local d leaf
      shopt -s nullglob
      for d in "$DERIVED_ROOT"/c11-* "$DERIVED_ROOT"/c11h-*; do # c11-2.0:legacy
        [[ -d "$d" ]] || continue
        is_c11_product_root "$d" || continue
        leaf="${d##*/}"
        if [[ "$leaf" == c11h-* ]]; then # c11-2.0:legacy
          echo "${leaf#c11h-}" # c11-2.0:legacy
        elif [[ "$leaf" == c11-* ]]; then
          echo "${leaf#c11-}"
        fi
      done
      shopt -u nullglob
    fi
    local p base
    shopt -s nullglob
    for p in "$RUNTIME_ROOT"/c11-* "$TMP_ROOT"/c11-* "$TMP_ROOT"/c11h-*; do # c11-2.0:legacy
      base="${p##*/}"
      [[ "$base" != *.sock && "$base" != *.log ]] || continue
      [[ -d "$p/Build" ]] || continue
      is_c11_product_root "$p" || continue
      base="${base#c11h-}" # c11-2.0:legacy
      echo "${base#c11-}"
    done
    shopt -u nullglob
  } | sort -u
}

GENERIC_CACHES=(
  "$TMP_ROOT/c11-build-cache"
  "$TMP_ROOT/c11-build-module-cache"
  "$TMP_ROOT/c11-build-home"
  "$TMP_ROOT/c11-module-cache"
  "$TMP_ROOT/c11-swift-module-cache"
)

LEGACY_TAG_PREFIX=c11h # c11-2.0:legacy (the retired line's tagged builds)

tag_paths() {
  local tag="$1"
  local p
  for p in "$DERIVED_ROOT/c11-$tag" "$DERIVED_ROOT/c11h-$tag"; do # c11-2.0:legacy
    if is_c11_product_root "$p"; then
      printf '%s\n' "$p"
    fi
  done
  for p in \
    "$RUNTIME_ROOT/c11-$tag" \
    "$(c11_socket_path_for_stem "c11-debug-$tag" "$RUNTIME_ROOT")" \
    "$RUNTIME_ROOT/c11-debug-$tag.log" \
    "$RUNTIME_ROOT/c11-debug-$tag-bg.log" \
    "$RUNTIME_ROOT/c11-xcodebuild-$tag.log" \
    "$TMP_ROOT/c11-$tag" \
    "$TMP_ROOT/$LEGACY_TAG_PREFIX-$tag" \
    "$TMP_ROOT/c11-debug-$tag.sock" \
    "$TMP_ROOT/c11-debug-$tag.log" \
    "$TMP_ROOT/c11-debug-$tag-bg.log" \
    "$TMP_ROOT/c11-xcodebuild-$tag.log" \
    "$C11D_SOCK_DIR/c11d-dev-$tag.sock"
  do
    case "${p##*/}" in
      c11-*|c11h-*|c11d-dev-*.sock) printf '%s\n' "$p" ;; # c11-2.0:legacy
    esac
  done
}

path_size_bytes() {
  local p="$1"
  if [[ -L "$p" ]]; then
    # Symlink itself is negligible, but its target in DerivedData is already counted.
    echo 0
  elif [[ -e "$p" ]]; then
    /usr/bin/du -sk "$p" 2>/dev/null | awk '{print $1 * 1024}'
  else
    echo 0
  fi
}

if [[ "${C11_PRUNE_LIB_ONLY:-}" == 1 ]]; then
  return 0
fi

RUNNING=()
while IFS= read -r t; do
  [[ -n "$t" ]] && RUNNING+=("$t")
done < <(running_tags)

is_protected() {
  local tag="$1"
  local t
  for t in "${RUNNING[@]+"${RUNNING[@]}"}"; do
    [[ "$t" == "$tag" ]] && return 0
  done
  for t in "${KEEP_TAGS[@]+"${KEEP_TAGS[@]}"}"; do
    [[ "$t" == "$tag" ]] && return 0
  done
  return 1
}

ALL_TAGS=()
while IFS= read -r t; do
  [[ -n "$t" ]] && ALL_TAGS+=("$t")
done < <(collect_tags)

echo "Found ${#ALL_TAGS[@]} tag candidates."
if [[ "${#RUNNING[@]}" -gt 0 ]]; then
  echo "Running tags (auto-kept): ${RUNNING[*]+${RUNNING[*]}}"
fi
if [[ "${#KEEP_TAGS[@]}" -gt 0 ]]; then
  echo "Extra --keep tags: ${KEEP_TAGS[*]+${KEEP_TAGS[*]}}"
fi
echo

TOTAL_BYTES=0
PRUNE_TAGS=()
for tag in "${ALL_TAGS[@]}"; do
  if is_protected "$tag"; then
    echo "keep  $tag (protected)"
    continue
  fi
  tag_bytes=0
  while IFS= read -r p; do
    b=$(path_size_bytes "$p")
    (( tag_bytes += b ))
  done < <(tag_paths "$tag")
  TOTAL_BYTES=$((TOTAL_BYTES + tag_bytes))
  PRUNE_TAGS+=("$tag")
  printf 'prune %-40s %s\n' "$tag" "$(human_bytes "$tag_bytes")"
done

CACHE_BYTES=0
CACHE_PRUNE=()
for c in "${GENERIC_CACHES[@]}"; do
  if [[ -e "$c" || -L "$c" ]]; then
    b=$(path_size_bytes "$c")
    CACHE_BYTES=$((CACHE_BYTES + b))
    CACHE_PRUNE+=("$c")
    printf 'prune %-40s %s  (generic cache)\n' "${c##*/}" "$(human_bytes "$b")"
  fi
done

echo
echo "Would free: $(human_bytes $((TOTAL_BYTES + CACHE_BYTES))) ($(human_bytes "$TOTAL_BYTES") tags + $(human_bytes "$CACHE_BYTES") caches across ${#PRUNE_TAGS[@]} tags)."

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run only. Re-run with --yes to delete."
  exit 0
fi

echo
echo "Deleting..."
for tag in "${PRUNE_TAGS[@]+"${PRUNE_TAGS[@]}"}"; do
  while IFS= read -r p; do
    if [[ -e "$p" || -L "$p" ]]; then
      rm -rf -- "$p"
    fi
  done < <(tag_paths "$tag")
  echo "  removed tag $tag"
done
for c in "${CACHE_PRUNE[@]+"${CACHE_PRUNE[@]}"}"; do
  rm -rf -- "$c"
  echo "  removed cache ${c##*/}"
done
echo "Done. Freed approximately $(human_bytes $((TOTAL_BYTES + CACHE_BYTES)))."
