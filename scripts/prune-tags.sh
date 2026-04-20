#!/usr/bin/env bash
# Prune stale per-tag build artifacts left behind by ./scripts/reload.sh --tag <tag>.
#
# Each tagged reload leaves ~3.5 GB in DerivedData plus /tmp build dirs, sockets, and
# logs. Nothing cleans them automatically, so they accumulate (we've seen 200 GB+).
# This script finds every cmux-* tag directory, skips ones whose app is currently
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

DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
CMUXD_SOCK_DIR="$HOME/Library/Application Support/c11mux"

running_tags() {
  # Each app lives at .../cmux-<tag>/Build/Products/Debug/c11 DEV <tag>.app/.../cmux
  pgrep -afl "c11 DEV " 2>/dev/null \
    | sed -E 's|.*DerivedData/cmux-([^/]+)/Build/Products/Debug/.*|\1|' \
    | grep -vE '^$' \
    | sort -u
}

human_bytes() {
  local b=$1
  if (( b > 1073741824 )); then printf '%.1fG' "$(echo "$b / 1073741824" | bc -l)"
  elif (( b > 1048576 )); then printf '%.1fM' "$(echo "$b / 1048576" | bc -l)"
  elif (( b > 1024 )); then printf '%.1fK' "$(echo "$b / 1024" | bc -l)"
  else printf '%dB' "$b"
  fi
}

is_tag_artifact() {
  # Returns 0 if the given path is a per-tag build artifact we can safely prune.
  # Criteria: (a) symlink whose target is exactly a DerivedData/cmux-<SAME_TAG> root
  # (reload.sh compat link — NOT a bin symlink like /tmp/c11mux-cli), or
  # (b) a dir containing Build/ (used as -derivedDataPath).
  local p="$1"
  local path_tag="${p##*/cmux-}"
  path_tag="${path_tag##*/c11mux-}"
  if [[ -L "$p" ]]; then
    local target
    target="$(readlink "$p" 2>/dev/null || true)"
    # Reject if symlink target has anything after the DerivedData/cmux-<tag>/ component
    # (e.g. points at Build/Products/Debug/cmux). Those are bin symlinks, not tag roots.
    if [[ "$target" == */DerivedData/cmux-${path_tag} ]]; then
      return 0
    fi
    return 1
  fi
  [[ -d "$p/Build" ]] && return 0
  return 1
}

collect_tags() {
  # /tmp is a symlink on macOS, so use shell globs (which expand via the link) instead of find.
  {
    if [[ -d "$DERIVED_ROOT" ]]; then
      local d
      for d in "$DERIVED_ROOT"/cmux-*; do
        [[ -d "$d" ]] || continue
        echo "${d##*/cmux-}"
      done
    fi
    local p tag
    shopt -s nullglob
    for p in /tmp/cmux-* /tmp/c11mux-*; do
      is_tag_artifact "$p" || continue
      tag="${p##*/cmux-}"
      tag="${tag##*/c11mux-}"
      echo "$tag"
    done
    shopt -u nullglob
  } | sort -u
}

GENERIC_CACHES=(
  /tmp/cmux-build-cache
  /tmp/cmux-build-module-cache
  /tmp/cmux-build-home
  /tmp/cmux-module-cache
  /tmp/cmux-swift-module-cache
)

tag_paths() {
  local tag="$1"
  printf '%s\n' \
    "$DERIVED_ROOT/cmux-$tag" \
    "/tmp/cmux-$tag" \
    "/tmp/c11mux-$tag" \
    "/tmp/c11mux-debug-$tag.sock" \
    "/tmp/c11mux-debug-$tag.log" \
    "/tmp/c11mux-debug-$tag-bg.log" \
    "/tmp/c11mux-xcodebuild-$tag.log" \
    "$CMUXD_SOCK_DIR/cmuxd-dev-$tag.sock"
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
