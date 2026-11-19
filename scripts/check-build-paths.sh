#!/usr/bin/env bash
# Prove a built c11.app ships no builder home path (C11H-133).
#
#   scripts/check-build-paths.sh <app> [<home> ...]
#
# Scans the bytes of every Mach-O file in the app and prints one line per file
# that carries:
# - "<home>/" for each home given (default: $HOME), and
# - any other "/Users/<name>/", so an app built on another host is caught too.
#   Two names are not anyone's home on a build host: "runner" (GitHub's CI
#   account, in Sentry's prebuilt framework) and "me" (the CLI's usage examples).
# A file that cannot be read fails the check rather than passing unseen.
# Exit 0 when clean, 1 when any file carries a home path or cannot be read, 2 on usage.
set -euo pipefail

if [[ $# -lt 1 || ! -d "$1" ]]; then
  printf 'usage: %s <app> [<home> ...]\n' "$(basename "$0")" >&2
  exit 2
fi
app="$1"
shift
homes=("$@")
[[ ${#homes[@]} -gt 0 ]] || homes=("$HOME")
not_homes='^/Users/(runner|me)/$'

# Every match of a pattern in a file's bytes, one per line. grep exits 1 when it
# finds nothing (the clean answer) and 2 when it cannot read, which fails here.
matches() {
  local mode="$1" pattern="$2" file="$3" status=0 out
  out="$(LC_ALL=C grep -a -o "$mode" -- "$pattern" "$file" 2>/dev/null)" || status=$?
  [[ "$status" -le 1 ]] || return 2
  printf '%s' "$out"
}

found=0
scanned=0
while IFS= read -r -d '' file; do
  rel="${file#"$app"/}"
  if [[ ! -r "$file" ]]; then
    printf '%s: unreadable, so not checked\n' "$rel"
    found=1
    continue
  fi
  magic="$(head -c 4 "$file" | xxd -p)" || { printf '%s: unreadable, so not checked\n' "$rel"; found=1; continue; }
  case "$magic" in
    feedfacf|cffaedfe|feedface|cefaedfe|cafebabe|bebafeca) ;;
    *) continue ;;
  esac
  scanned=$((scanned + 1))
  if ! users="$(matches -E '/Users/[A-Za-z0-9._-]+/' "$file")"; then
    printf '%s: unreadable, so not checked\n' "$rel"
    found=1
    continue
  fi
  for home in "${homes[@]}"; do
    if ! hits="$(matches -F "$home/" "$file")"; then
      printf '%s: unreadable, so not checked\n' "$rel"
      found=1
      continue 2
    fi
    count="$(printf '%s' "$hits" | { grep -c . || true; })"
    if [[ "$count" -gt 0 ]]; then
      found=1
      printf '%s: %s strings with %s/\n' "$rel" "$count" "$home"
      { LC_ALL=C strings -a "$file" 2>/dev/null | grep -F -- "$home/" || true; } | sort -u | head -3 | sed 's/^/  /'
    fi
  done
  others="$(printf '%s' "$users" | sort | uniq -c | while read -r n prefix; do
    [[ -n "$prefix" ]] || continue
    [[ "$prefix" =~ $not_homes ]] && continue
    for home in "${homes[@]}"; do [[ "$prefix" == "$home/" ]] && continue 2; done
    printf '%s %s\n' "$n" "$prefix"
  done)"
  if [[ -n "$others" ]]; then
    found=1
    printf '%s\n' "$others" | while read -r n prefix; do
      printf '%s: %s strings with %s (another home)\n' "$rel" "$n" "$prefix"
    done
  fi
done < <(find "$app" -type f -print0)

if [[ "$found" -eq 0 ]]; then
  printf 'clean: %d Mach-O files in %s carry no %s and no other /Users/<name>/\n' "$scanned" "$app" "${homes[*]}"
fi
exit "$found"
