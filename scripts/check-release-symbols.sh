#!/usr/bin/env bash
# Prove a release-built c11.app was stripped of its debug map only (C11H-133).
#
#   scripts/check-release-symbols.sh <app> [<dSYM>]
#
# - The app and CLI executables carry no N_SO/N_OSO stabs (they name every
#   source and object under the build root).
# - The app executable keeps its Swift symbols, so backtraces read: at least
#   C11_MIN_SWIFT_SYMBOLS (default 50000) `_$s` names in its arm64 slice. A
#   full build has about 155,000; `strip -T` leaves under 10,000.
# - The dSYM (default: c11.app.dSYM beside the app) still has the Swift
#   packages' DWARF: at least one Bonsplit source file.
# Exit 0 when all hold, 1 when any fails, 2 on usage.
set -euo pipefail

if [[ $# -lt 1 || ! -d "$1" ]]; then
  printf 'usage: %s <app> [<dSYM>]\n' "$(basename "$0")" >&2
  exit 2
fi
app="$1"
dsym="${2:-$(dirname "$app")/c11.app.dSYM}"
min_swift="${C11_MIN_SWIFT_SYMBOLS:-50000}"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
main="$app/Contents/MacOS/$executable"
cli="$app/Contents/Resources/bin/c11"
failed=0

for file in "$main" "$cli"; do
  if [[ ! -r "$file" ]]; then
    printf 'missing or unreadable: %s\n' "$file"
    failed=1
    continue
  fi
  stabs="$({ nm -ap "$file" 2>/dev/null || true; } | { grep -c -E ' (SO|OSO) ' || true; })"
  printf '%s: %s N_SO/N_OSO stabs\n' "${file#"$app"/}" "$stabs"
  [[ "$stabs" -eq 0 ]] || failed=1
done

swift="$({ nm -j -arch arm64 "$main" 2>/dev/null || true; } | { grep -c '^_\$s' || true; })"
printf '%s: %s Swift symbols (arm64; at least %s)\n' "${main#"$app"/}" "$swift" "$min_swift"
[[ "$swift" -ge "$min_swift" ]] || failed=1

if [[ -d "$dsym" ]]; then
  bonsplit="$({ xcrun dwarfdump --show-sources "$dsym" 2>/dev/null || true; } | { grep -c '/Bonsplit/' || true; })"
  printf '%s: %s Bonsplit source files\n' "$(basename "$dsym")" "$bonsplit"
  [[ "$bonsplit" -gt 0 ]] || failed=1
else
  printf 'no dSYM at %s\n' "$dsym"
  failed=1
fi

exit "$failed"
