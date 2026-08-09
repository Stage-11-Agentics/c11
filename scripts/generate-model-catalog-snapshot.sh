#!/usr/bin/env bash
# Regenerate Sources/ModelCatalogSnapshot.swift — the offline tier of the model
# catalog (C11-203 Part D).
#
#   scripts/generate-model-catalog-snapshot.sh
#       Ask the live harness CLIs (opencode, pi, omp, kimi, grok) and snapshot
#       what they answer. Also refreshes c11Tests/Fixtures/model-catalog/ unless
#       --keep-fixtures is passed, so the parser tests always assert against the
#       same capture the snapshot was built from.
#
#   scripts/generate-model-catalog-snapshot.sh --from <dir>
#       Replay captures from <dir> instead of shelling out. Pointing this at
#       c11Tests/Fixtures/model-catalog reproduces the committed snapshot
#       exactly, which is how a reviewer checks it was not hand-edited.
#
# The generator links the app's own parsers (Sources/ModelCatalog.swift and
# Sources/ModelCatalogSources.swift), so there is no second implementation that
# can drift from what ships.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="$repo_root/c11Tests/Fixtures/model-catalog"
output="$repo_root/Sources/ModelCatalogSnapshot.swift"

from_dir=""
keep_fixtures=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) from_dir="${2:?--from needs a directory}"; shift 2 ;;
    --keep-fixtures) keep_fixtures=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

work="$(mktemp -d "${TMPDIR:-/tmp}/c11-model-catalog.XXXXXX")"
trap 'rm -rf "$work"' EXIT

capture_dir="$work/captures"
mkdir -p "$capture_dir"

if [[ -n "$from_dir" ]]; then
  echo "==> replaying captures from $from_dir"
  cp "$from_dir"/* "$capture_dir/"
else
  echo "==> querying live harness CLIs"
  # A harness that is not installed, not authenticated, or slow is skipped;
  # the generator refuses to write an empty snapshot but tolerates gaps.
  run_capture() { # name, output-file, command...
    local name="$1" out="$2"; shift 2
    if ! command -v "$1" >/dev/null 2>&1; then
      echo "    $name: binary '$1' not on PATH — skipped" >&2
      return 0
    fi
    if "$@" >"$capture_dir/$out" 2>/dev/null; then
      echo "    $name: $(wc -l <"$capture_dir/$out" | tr -d ' ') lines"
    else
      echo "    $name: command failed — skipped" >&2
      rm -f "$capture_dir/$out"
    fi
  }
  run_capture opencode opencode-models.txt    opencode models
  run_capture pi       pi-list-models.txt     pi --list-models
  run_capture omp      omp-models.txt         omp models
  run_capture kimi     kimi-provider-list.json kimi provider list --json
  run_capture grok     grok-models.txt        grok models

  if [[ "$keep_fixtures" -eq 0 ]]; then
    echo "==> refreshing $fixtures"
    mkdir -p "$fixtures"
    cp "$capture_dir"/* "$fixtures/"
  fi
fi

echo "==> building generator"
swiftc -O \
  -o "$work/gen" \
  "$repo_root/Sources/ModelCatalog.swift" \
  "$repo_root/Sources/ModelCatalogSources.swift" \
  "$repo_root/scripts/model-catalog-snapshot-gen.swift"

echo "==> generating $output"
"$work/gen" "$capture_dir" >"$work/ModelCatalogSnapshot.swift"
mv "$work/ModelCatalogSnapshot.swift" "$output"
echo "==> wrote $(wc -l <"$output" | tr -d ' ') lines"
