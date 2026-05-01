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

# HEAD must point at the tip of local `main`. Branch name is incidental —
# worktrees may use a different branch name (e.g. `probe-main`) that tracks
# main. The invariant is the commit, not the branch label.
HEAD_SHA="$(git rev-parse HEAD)"
MAIN_SHA="$(git rev-parse main 2>/dev/null || echo '')"
if [[ -z "$MAIN_SHA" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=local main branch not found"
  exit 1
fi
if [[ "$HEAD_SHA" != "$MAIN_SHA" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=HEAD ($HEAD_SHA) is not at local main tip ($MAIN_SHA); run on main or a worktree at main's tip"
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
PR_JSON="$(gh pr view "$PR" --repo "$UPSTREAM_REPO" --json mergeCommit,state,mergedAt,title,headRefOid,baseRefName 2>/dev/null || echo '')"
if [[ -z "$PR_JSON" ]]; then
  echo "STATUS=error"
  echo "BRANCH="
  echo "DETAIL=could not fetch PR ${PR} from ${UPSTREAM_REPO}"
  exit 1
fi

MERGE_SHA="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);mc=d.get("mergeCommit");print(mc["oid"] if mc else "")')"
HEAD_OID="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headRefOid","") or "")')"
BASE_REF="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("baseRefName","") or "main")')"
PR_STATE="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))')"
PR_TITLE="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("title",""))')"

# Pick the SHA we'll apply.
# - If the PR was merged, use the merge commit.
# - Otherwise (open or closed-not-merged), use the head commit and we'll
#   cherry-pick the range from its merge-base with the PR's base branch.
APPLY_MODE=""
APPLY_SHA=""
if [[ -n "$MERGE_SHA" ]]; then
  APPLY_MODE="merge-commit"
  APPLY_SHA="$MERGE_SHA"
else
  if [[ -z "$HEAD_OID" ]]; then
    echo "STATUS=error"
    echo "BRANCH="
    echo "DETAIL=PR ${PR} has neither mergeCommit nor headRefOid (state=${PR_STATE})"
    exit 1
  fi
  APPLY_MODE="range"
  APPLY_SHA="$HEAD_OID"
fi

# --- ensure we have the necessary commits locally ---

# Fetch the PR's head ref via the GitHub PR refspec — works for both open and merged PRs.
if ! git cat-file -e "${APPLY_SHA}^{commit}" 2>/dev/null; then
  git fetch upstream "pull/${PR}/head:refs/upstream-prs/pr-${PR}" >/dev/null 2>&1 || true
  git fetch upstream main >/dev/null 2>&1 || true
  if ! git cat-file -e "${APPLY_SHA}^{commit}" 2>/dev/null; then
    git fetch upstream "$APPLY_SHA" >/dev/null 2>&1 || {
      echo "STATUS=error"
      echo "BRANCH="
      echo "DETAIL=could not fetch ${APPLY_MODE} sha ${APPLY_SHA} from upstream"
      exit 1
    }
  fi
fi

# For range mode, we also need the merge-base with the PR's base branch.
RANGE_BASE=""
if [[ "$APPLY_MODE" == "range" ]]; then
  if ! git rev-parse --verify "upstream/${BASE_REF}" >/dev/null 2>&1; then
    git fetch upstream "$BASE_REF" >/dev/null 2>&1 || true
  fi
  RANGE_BASE="$(git merge-base "$APPLY_SHA" "upstream/${BASE_REF}" 2>/dev/null || echo '')"
  if [[ -z "$RANGE_BASE" ]]; then
    echo "STATUS=error"
    echo "BRANCH="
    echo "DETAIL=could not find merge-base of ${APPLY_SHA} with upstream/${BASE_REF}"
    exit 1
  fi
fi

# --- already-applied check ---

if [[ "$APPLY_MODE" == "merge-commit" ]]; then
  if git merge-base --is-ancestor "$APPLY_SHA" HEAD 2>/dev/null; then
    echo "STATUS=empty"
    echo "BRANCH="
    echo "DETAIL=merge commit ${APPLY_SHA} already in main"
    exit 0
  fi
  CHERRY="$(git cherry HEAD "$APPLY_SHA" "${APPLY_SHA}^" 2>/dev/null | head -1 || echo '')"
  if [[ "$CHERRY" == -* ]]; then
    echo "STATUS=empty"
    echo "BRANCH="
    echo "DETAIL=patch ${APPLY_SHA} equivalent already in main (cherry detected)"
    exit 0
  fi
else
  # Range mode: if every commit in (RANGE_BASE..APPLY_SHA] is already in HEAD,
  # treat as empty. Use git cherry to detect.
  REMAINING="$(git cherry HEAD "$APPLY_SHA" "$RANGE_BASE" 2>/dev/null | grep -c '^+' || echo 0)"
  if [[ "$REMAINING" == "0" ]]; then
    echo "STATUS=empty"
    echo "BRANCH="
    echo "DETAIL=all commits in ${RANGE_BASE}..${APPLY_SHA} equivalent already in main"
    exit 0
  fi
fi

# Capture original ref so we can restore it on cleanup paths.
# Use the symbolic name if we're on a branch, else the SHA.
ORIGINAL_REF="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse HEAD)"

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

# Build the cherry-pick spec.
# - merge-commit mode: a single commit, with -m 1 if it has multiple parents.
# - range mode: every commit in (RANGE_BASE..APPLY_SHA].
CHERRY_ARGS=()
CHERRY_TARGET=""
if [[ "$APPLY_MODE" == "merge-commit" ]]; then
  PARENT_COUNT="$(git cat-file -p "$APPLY_SHA" | grep -c '^parent ')"
  if [[ "$PARENT_COUNT" -gt 1 ]]; then
    CHERRY_ARGS+=("-m" "1")
  fi
  CHERRY_TARGET="$APPLY_SHA"
else
  CHERRY_TARGET="${RANGE_BASE}..${APPLY_SHA}"
fi

if git cherry-pick ${CHERRY_ARGS[@]+"${CHERRY_ARGS[@]}"} "$CHERRY_TARGET" >/tmp/probe-${PR}.log 2>&1; then
  # Cherry-pick succeeded.
  # Empty-result check: count new commits and verify there's a real diff vs main.
  NEW_COMMITS="$(git rev-list --count main..HEAD 2>/dev/null || echo 0)"
  if [[ "$NEW_COMMITS" == "0" ]] || git diff --quiet "main..HEAD" 2>/dev/null; then
    git reset --hard main >/dev/null 2>&1
    git checkout "$ORIGINAL_REF" >/dev/null 2>&1
    git branch -D "$BRANCH" >/dev/null 2>&1
    echo "STATUS=empty"
    echo "BRANCH="
    echo "DETAIL=cherry-pick produced no changes"
    exit 0
  fi
  echo "STATUS=clean"
  echo "BRANCH=$BRANCH"
  if [[ "$APPLY_MODE" == "merge-commit" ]]; then
    echo "DETAIL=cherry-pick clean: ${PR_TITLE}"
  else
    echo "DETAIL=cherry-pick clean (range, ${NEW_COMMITS} commits): ${PR_TITLE}"
  fi
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
