#!/usr/bin/env bash
# Run one CI command through Atlas's two-slot admission and c11 build lock.
#
# This wrapper is intentionally process-scoped. It does not install tools,
# change xcode-select, or modify a tenant's configuration.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: ci-atlas-run.sh <command> [args...]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_SLUG="${C11_ATLAS_BUILD_SLUG:-ci-${GITHUB_WORKFLOW:-local}-${GITHUB_JOB:-job}}"
SLUG="$(printf '%s' "$RAW_SLUG" | tr '[:upper:]_/' '[:lower:]--' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
if [[ -z "$SLUG" ]]; then
  echo "invalid empty Atlas build slug from '$RAW_SLUG'" >&2
  exit 2
fi

export C11_ATLAS_SLOTS_DIR="${C11_ATLAS_SLOTS_DIR:-/tmp/c11-atlas-build-slots}"
export C11_BUILD_LOCK_TIMEOUT="${C11_BUILD_LOCK_TIMEOUT:-5400}"

exec python3 "$SCRIPT_DIR/atlas_build_slots.py" "$SLUG" \
  "$SCRIPT_DIR/with-build-lock.sh" "$@"
