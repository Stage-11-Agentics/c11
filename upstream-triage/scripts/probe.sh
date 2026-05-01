#!/usr/bin/env bash
# probe.sh — try cherry-picking an upstream cmux PR onto a probe branch.
# Reports status (clean | conflict | empty | error) without pushing.
#
# Usage:
#   probe.sh <pr-number>
#
# On `clean`: leaves probe branch checked out, ready for push.
# On `conflict`: leaves probe branch in conflicted state for inspection.
# On `empty`: aborts the cherry-pick and switches back to main.
# On `error`: prints diagnosis and switches back to main.
#
# The script never pushes. It never modifies main. It never force-deletes anything.
#
# Output format (last line, stable for parsing):
#   STATUS=<clean|conflict|empty|error>
#   BRANCH=<probe-branch-or-empty>
#   FILES=<conflict-file-1,conflict-file-2,...>  (only when STATUS=conflict)
#   DETAIL=<one-line-detail>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <pr-number>" >&2
  exit 2
fi

PR="$1"
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "error: PR number must be numeric, got: $PR" >&2
  exit 2
fi

UPSTREAM_REPO="manaflow-ai/cmux"
BRANCH="upstream-probe/pr-${PR}"

# --- preconditions ---

if ! command -v gh >/dev/null 2>&1; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=gh CLI not found"
  exit 1
fi

# Must be inside the c11 repo.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=not in a git repo"
  exit 1
fi

# Working tree must be clean.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=working tree dirty; refusing to probe"
  exit 1
fi

# Must be on main (or detached from it).
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || echo '')"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=must run from main branch (current: ${CURRENT_BRANCH:-detached})"
  exit 1
fi

# Must have an upstream remote pointing at manaflow-ai/cmux.
UPSTREAM_URL="$(git remote get-url upstream 2>/dev/null || echo '')"
if [[ ! "$UPSTREAM_URL" =~ manaflow-ai/cmux ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=upstream remote missing or not pointing at manaflow-ai/cmux"
  exit 1
fi

# --- gather PR metadata ---

# Fetch PR info. Tolerate transient gh failures with a clear error.
PR_JSON="$(gh pr view "$PR" --repo "$UPSTREAM_REPO" --json mergeCommit,state,mergedAt,title 2>/dev/null || echo '')"
if [[ -z "$PR_JSON" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=could not fetch PR ${PR} from ${UPSTREAM_REPO}"
  exit 1
fi

MERGE_SHA="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);mc=d.get("mergeCommit");print(mc["oid"] if mc else "")')"
PR_STATE="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))')"
PR_TITLE="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("title",""))')"

if [[ -z "$MERGE_SHA" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=PR ${PR} has no merge commit (state=${PR_STATE})"
  exit 1
fi

# --- ensure we have the merge commit locally ---

if ! git cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null; then
  # Fetch upstream main first; if still missing, fetch the specific commit.
  git fetch upstream main >/dev/null 2>&1 || true
  if ! git cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null; then
    git fetch upstream "$MERGE_SHA" >/dev/null 2>&1 || {
      echo "STATUS=error"
      echo "BRANCH="
      echo "DETAIL=could not fetch merge commit ${MERGE_SHA} from upstream"
      exit 1
    }
  fi
fi

# --- already-applied check ---

# If the merge commit is already reachable from main, nothing to do.
if git merge-base --is-ancestor "$MERGE_SHA" HEAD 2>/dev/null; then
  echo "STATUS=empty"
  echo "BRANCH="
  echo "DETAIL=merge commit ${MERGE_SHA} already in main"
  exit 0
fi

# Check via cherry-pick equivalence too — a squash-merge or rebase might have
# brought the patch in under a different SHA.
# git cherry returns lines starting with '-' for upstream commits already in HEAD.
CHERRY="$(git cherry HEAD "$MERGE_SHA" "${MERGE_SHA}^" 2>/dev/null | head -1 || echo '')"
if [[ "$CHERRY" == -* ]]; then
  echo "STATUS=empty"
  echo "BRANCH="
  echo "DETAIL=patch ${MERGE_SHA} equivalent already in main (cherry detected)"
  exit 0
fi

# --- create probe branch ---

# If a stale probe branch exists, refuse — caller must clean up.
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "STATUS=error"
  echo "BRANCH=$BRANCH"
  echo "DETAIL=probe branch ${BRANCH} already exists; delete or push before retrying"
  exit 1
fi

git checkout -b "$BRANCH" main >/dev/null 2>&1

# --- attempt cherry-pick ---

# Determine if the merge commit is a merge (multiple parents).
PARENT_COUNT="$(git cat-file -p "$MERGE_SHA" | grep -c '^parent ')"
CHERRY_ARGS=()
if [[ "$PARENT_COUNT" -gt 1 ]]; then
  CHERRY_ARGS+=("-m" "1")
fi

if git cherry-pick "${CHERRY_ARGS[@]}" "$MERGE_SHA" >/tmp/probe-${PR}.log 2>&1; then
  # Cherry-pick succeeded with no conflicts.
  # But: if the result is empty (no diff vs main), treat as empty.
  if git diff --quiet HEAD~1 HEAD 2>/dev/null; then
    git reset --hard HEAD~1 >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git branch -D "$BRANCH" >/dev/null 2>&1
    echo "STATUS=empty"
    echo "BRANCH="
    echo "DETAIL=cherry-pick produced no changes"
    exit 0
  fi
  echo "STATUS=clean"
  echo "BRANCH=$BRANCH"
  echo "DETAIL=cherry-pick clean: ${PR_TITLE}"
  exit 0
fi

# Cherry-pick failed. Determine why.
CONFLICT_FILES="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ',' | sed 's/,$//')"

if [[ -n "$CONFLICT_FILES" ]]; then
  echo "STATUS=conflict"
  echo "BRANCH=$BRANCH"
  echo "FILES=$CONFLICT_FILES"
  echo "DETAIL=conflicts in $(echo "$CONFLICT_FILES" | tr ',' '\n' | wc -l | tr -d ' ') file(s)"
  exit 0
fi

# No conflict markers but cherry-pick failed — usually a missing-path case.
# Abort the cherry-pick to leave the branch clean for inspection.
git cherry-pick --abort >/dev/null 2>&1 || true
ERROR_LINE="$(tail -3 /tmp/probe-${PR}.log | tr '\n' ' ' | sed 's/  */ /g' | head -c 240)"
git checkout main >/dev/null 2>&1
git branch -D "$BRANCH" >/dev/null 2>&1
echo "STATUS=error"
echo "BRANCH="
echo "DETAIL=cherry-pick failed: ${ERROR_LINE}"
exit 0
