#!/usr/bin/env bash
# PR scope and the required-check verdict for ci.yml.
#
#   ci-pr-scope.sh scope    Prints code=true|false (and appends it to
#                           $GITHUB_OUTPUT when set). code=false only when
#                           every file the PR touches is documentation.
#                           Anything uncertain is code.
#   ci-pr-scope.sh verdict  Reads $NEEDS_JSON (toJSON(needs) of the required
#                           aggregate) and exits 0 only when scope succeeded
#                           and either code=false with every other job
#                           skipped, or code=true with every other job
#                           successful.
#
# scope env: GITHUB_EVENT_NAME, GITHUB_REPOSITORY, PR_NUMBER, GH_TOKEN.
set -euo pipefail

# The PR files GitHub's files endpoint lists at most. A PR at the cap may have
# more files than we can see, so it counts as code.
FILES_API_CAP=3000

is_docs_path() {
  case "$1" in
    *.md | docs/* | notes/* | Resources/Localizable.xcstrings) return 0 ;;
  esac
  return 1
}

emit_scope() {
  local code="$1" reason="$2"
  echo "code=$code"
  echo "reason: $reason" >&2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "code=$code" >> "$GITHUB_OUTPUT"
  fi
}

cmd_scope() {
  if [[ "${GITHUB_EVENT_NAME:-}" != pull_request ]]; then
    emit_scope true "event ${GITHUB_EVENT_NAME:-unset} is not a pull_request"
    return
  fi
  if [[ ! "${PR_NUMBER:-}" =~ ^[0-9]+$ || -z "${GITHUB_REPOSITORY:-}" ]]; then
    emit_scope true "PR number or repository missing"
    return
  fi

  local listing
  if ! listing="$(gh api --paginate \
      "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files?per_page=100" \
      --jq '.[] | [.filename, (.previous_filename // "")] | @tsv')"; then
    emit_scope true "could not list the PR's files"
    return
  fi

  local count=0 filename previous
  while IFS=$'\t' read -r filename previous; do
    [[ -n "$filename" ]] || continue
    count=$((count + 1))
    if ! is_docs_path "$filename"; then
      emit_scope true "$filename is not documentation"
      return
    fi
    if [[ -n "$previous" ]] && ! is_docs_path "$previous"; then
      emit_scope true "$filename was renamed from $previous"
      return
    fi
  done <<< "$listing"

  if (( count == 0 )); then
    emit_scope true "the PR lists no files"
  elif (( count >= FILES_API_CAP )); then
    emit_scope true "$count files reaches the files API cap"
  else
    emit_scope false "all $count files are documentation"
  fi
}

cmd_verdict() {
  local needs="${NEEDS_JSON:-}"
  if ! jq -e 'type == "object"' <<< "$needs" >/dev/null 2>&1; then
    echo "FAIL: NEEDS_JSON is not a JSON object" >&2
    return 1
  fi

  local scope_result code
  scope_result="$(jq -r '.scope.result // "missing"' <<< "$needs")"
  code="$(jq -r '.scope.outputs.code // "missing"' <<< "$needs")"
  if [[ "$scope_result" != success ]]; then
    echo "FAIL: scope job result is $scope_result" >&2
    return 1
  fi

  local expected
  case "$code" in
    true) expected=success ;;
    false) expected=skipped ;;
    *)
      echo "FAIL: scope output code is $code" >&2
      return 1
      ;;
  esac

  local jobs bad=0 name result
  jobs="$(jq -r 'to_entries[] | select(.key != "scope") | [.key, .value.result] | @tsv' <<< "$needs")"
  if [[ -z "$jobs" ]]; then
    echo "FAIL: no checks besides scope" >&2
    return 1
  fi
  while IFS=$'\t' read -r name result; do
    if [[ "$result" == "$expected" ]]; then
      echo "ok: $name $result"
    else
      echo "FAIL: $name is $result, expected $expected (code=$code)" >&2
      bad=1
    fi
  done <<< "$jobs"
  return "$bad"
}

case "${1:-}" in
  scope) cmd_scope ;;
  verdict) cmd_verdict ;;
  *)
    echo "usage: $0 scope|verdict" >&2
    exit 2
    ;;
esac

# C11-564 ruleset proof (code PR); closed unmerged.
