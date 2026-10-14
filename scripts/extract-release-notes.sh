#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: scripts/extract-release-notes.sh <version> [CHANGELOG.md]" >&2
  exit 2
fi

VERSION="$1"
CHANGELOG="${2:-$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like X.Y.Z (got '$VERSION')" >&2
  exit 2
fi

awk -v version="$VERSION" '
  BEGIN { target = "## [" version "] - " }
  !found && index($0, target) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
  END { if (!found) exit 1 }
' "$CHANGELOG"
