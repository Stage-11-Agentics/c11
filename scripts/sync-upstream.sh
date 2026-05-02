#!/usr/bin/env bash
# sync-upstream.sh — help keep c11 in sync with manaflow-ai/cmux.
#
# Does the mechanical parts of an upstream sync:
#   1. Verifies we're on main.
#   2. Fetches upstream (including tags).
#   3. Shows diverged commits and per-file change summary, bucketed into
#      "hotspot" files (where c11 diverges on purpose) vs the rest.
#   4. Optionally attempts `git merge upstream/main --no-commit --no-ff`.
#   5. Reports conflicts (if any) and exits — no auto-resolution.
#
# See docs/upstream-sync.md for the full playbook.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
LOCAL_BRANCH="${LOCAL_BRANCH:-main}"

# Hotspot files — where c11 intentionally differs from cmux.
# Keep in sync with docs/upstream-sync.md.
HOTSPOTS=(
  "Resources/Info.plist"
  "README.md"
  "CHANGELOG.md"
  "Sources/SocketControlSettings.swift"
  "Sources/AppDelegate.swift"
  "Sources/cmuxApp.swift"
  "Package.swift"
  "GhosttyTabs.xcodeproj/project.pbxproj"
)
# Any path under this prefix is also a hotspot.
HOTSPOT_PREFIXES=(
  "Resources/shell-integration/"
)

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--dry-run | --merge] [--help]

Flags:
  --dry-run   Fetch upstream and print divergence summary. No merge attempted.
              This is the default when no flag is passed.
  --merge     Fetch upstream and attempt 'git merge upstream/$UPSTREAM_BRANCH'
              with --no-commit --no-ff. Stops on conflicts.
  --help      Show this message and exit.

Environment overrides:
  UPSTREAM_REMOTE  Remote name for upstream (default: upstream)
  UPSTREAM_BRANCH  Upstream branch to sync from (default: main)
  LOCAL_BRANCH     Our branch that must be checked out (default: main)

See docs/upstream-sync.md for the full playbook.
EOF
}

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
info() { printf '%s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

mode="dry-run"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) mode="dry-run"; shift ;;
    --merge)   mode="merge"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown arg: $1"; usage >&2; exit 2 ;;
  esac
done

# --- Preflight -------------------------------------------------------------

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  err "not inside a git repository"
  exit 1
fi

current_branch="$(git symbolic-ref --quiet --short HEAD || echo '')"
if [[ "$current_branch" != "$LOCAL_BRANCH" ]]; then
  err "must be on '$LOCAL_BRANCH' (currently on '${current_branch:-detached HEAD}')"
  exit 1
fi

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  err "remote '$UPSTREAM_REMOTE' is not configured"
  err "add it with: git remote add $UPSTREAM_REMOTE https://github.com/manaflow-ai/cmux.git"
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  err "working tree has uncommitted changes — commit or stash first"
  exit 1
fi

# --- Fetch -----------------------------------------------------------------

section "Fetching $UPSTREAM_REMOTE (with tags)"
git fetch "$UPSTREAM_REMOTE" --tags

upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
if ! git rev-parse --verify --quiet "$upstream_ref" >/dev/null; then
  err "ref '$upstream_ref' does not exist after fetch"
  exit 1
fi

# --- Divergence summary ----------------------------------------------------

section "Commits on $upstream_ref not yet in $LOCAL_BRANCH"
commit_count="$(git rev-list --count "$LOCAL_BRANCH..$upstream_ref")"
if [[ "$commit_count" -eq 0 ]]; then
  info "(no incoming commits — already up to date)"
  exit 0
fi
git log --oneline --no-decorate "$LOCAL_BRANCH..$upstream_ref"
info ""
info "Total incoming commits: $commit_count"

section "Changed files (vs $LOCAL_BRANCH)"
mapfile -t changed_files < <(git diff --name-only "$LOCAL_BRANCH...$upstream_ref")

is_hotspot() {
  local f="$1"
  for h in "${HOTSPOTS[@]}"; do
    [[ "$f" == "$h" ]] && return 0
  done
  for p in "${HOTSPOT_PREFIXES[@]}"; do
    [[ "$f" == "$p"* ]] && return 0
  done
  return 1
}

hotspot_files=()
other_files=()
for f in "${changed_files[@]}"; do
  if is_hotspot "$f"; then
    hotspot_files+=("$f")
  else
    other_files+=("$f")
  fi
done

info "Hotspot files (expect conflicts — see docs/upstream-sync.md): ${#hotspot_files[@]}"
for f in "${hotspot_files[@]}"; do
  printf '  ! %s\n' "$f"
done
info ""
info "Other files: ${#other_files[@]}"
for f in "${other_files[@]}"; do
  printf '    %s\n' "$f"
done

# --- Merge (optional) ------------------------------------------------------

if [[ "$mode" == "dry-run" ]]; then
  section "Dry run complete"
  info "Re-run with --merge to attempt the actual merge."
  exit 0
fi

section "Attempting merge: git merge $upstream_ref --no-commit --no-ff"
set +e
git merge "$upstream_ref" --no-commit --no-ff
merge_status=$?
set -e

mapfile -t conflicted < <(git diff --name-only --diff-filter=U)

if (( ${#conflicted[@]} > 0 )); then
  section "Conflicts detected — resolve manually"
  for f in "${conflicted[@]}"; do
    if is_hotspot "$f"; then
      printf '  ! %s   (hotspot — see docs/upstream-sync.md)\n' "$f"
    else
      printf '    %s\n' "$f"
    fi
  done
  info ""
  info "Next steps:"
  info "  1. Open each conflicted file and resolve."
  info "  2. 'git add <file>' as you finish each."
  info "  3. Run sanity checks from docs/upstream-sync.md."
  info "  4. 'git commit' to record the merge."
  info "  5. 'git push origin $LOCAL_BRANCH'."
  exit 1
fi

if [[ $merge_status -ne 0 ]]; then
  err "merge failed without conflict list — inspect 'git status'"
  exit "$merge_status"
fi

section "Merge applied cleanly (not yet committed)"
info "Review with 'git status' and 'git diff --staged'."
info "Then run sanity checks (docs/upstream-sync.md) and commit:"
info "  git commit   # default merge message is fine, or customize"
info "  git push origin $LOCAL_BRANCH"
