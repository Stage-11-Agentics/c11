#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT"

{
  for input in \
    Package.resolved \
    GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    Package.swift \
    GhosttyTabs.xcodeproj/project.pbxproj; do
    [[ -f "$input" ]] || { echo "missing DerivedData cache input: $input" >&2; exit 1; }
    shasum -a 256 "$input"
  done
  for submodule in ghostty vendor/bonsplit; do
    revision="$(git rev-parse "HEAD:$submodule")"
    [[ "$revision" =~ ^[[:xdigit:]]{40}$ ]] || {
      echo "invalid gitlink revision for $submodule: $revision" >&2
      exit 1
    }
    printf '%s=%s\n' "$submodule" "$revision"
  done
} | shasum -a 256 | awk '{ print $1 }'
