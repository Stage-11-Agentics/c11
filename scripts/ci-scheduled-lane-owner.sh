#!/usr/bin/env bash
# Watch scheduled lanes from outside their workflows.
# Usage: ci-scheduled-lane-owner.sh [--dry-run]
#
# Reads completed runs on main. success closes that lane's issue.
# failure, startup_failure, and timed_out open or comment once per run.
# The comment ends with <!-- lane-run: reason url -->. A later watch that
# sees the same marker leaves the issue alone. skipped runs, and a
# cancelled run that a newer decisive run superseded, are ignored. Three
# consecutive cancelled runs are a failure, so a lane that hangs and is
# cancelled every hour is reported. A lane with a stale window and no
# completed run inside it is a failure. ci-hourly has no stale window:
# it runs on push to main, not on a clock.
#
# --dry-run reads runs and issues and prints what it would do. It does not
# create, comment, close, or edit. CI_LANE_OWNER is the assignee, default
# BenevolentFutures. A live run refuses any GITHUB_EVENT_NAME other than
# schedule or workflow_dispatch.
set -euo pipefail

ASSIGNEE="${CI_LANE_OWNER:-BenevolentFutures}"
REPO="${GITHUB_REPOSITORY:-Stage-11-Agentics/c11}"
NOW="${C11_LANE_NOW:-$(date +%s)}"
DRY=0

# One line per lane: workflow file, then stale hours. "-" skips staleness.
lane_table() {
  cat <<'EOF'
ci-hourly.yml -
ci-macos-compat.yml 3
nightly.yml 36
EOF
}

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 2
fi

if [[ "$DRY" -eq 0 && -n "${GITHUB_EVENT_NAME:-}" ]]; then
  case "$GITHUB_EVENT_NAME" in
    schedule | workflow_dispatch) ;;
    *)
      echo "error: lane owner does not run for event ${GITHUB_EVENT_NAME}" >&2
      exit 2
      ;;
  esac
fi

if [[ ! "$NOW" =~ ^[0-9]+$ ]]; then
  echo "error: C11_LANE_NOW must be an epoch second, got ${NOW}" >&2
  exit 2
fi

# decision, reason, url. Runs are newest first after the sort.
classify_runs() {
  local json="$1" stale_hours="$2" count newest_epoch newest_url window
  count="$(jq 'length' <<<"$json")"
  if [[ "$count" -eq 0 ]]; then
    if [[ "$stale_hours" == "-" ]]; then
      printf 'ignore none -\n'
    else
      printf 'fail stale -\n'
    fi
    return
  fi

  # Staleness uses the newest updatedAt, so a run that finished inside the
  # window counts even when a newer attempt exists. Classification below
  # walks createdAt, so re-running an older green run cannot hide a newer
  # failure. A failing date parse inside this function does not abort it:
  # the epoch stays empty, arithmetic treats that as 0, and the lane is stale.
  local updated_json
  updated_json="$(jq 'sort_by(.updatedAt) | reverse' <<<"$json")"
  newest_url="$(jq -r '.[0].url // "-"' <<<"$updated_json")"
  newest_epoch="$(jq -r '.[0].updatedAt | sub("\\.[0-9]+"; "") | fromdateiso8601' <<<"$updated_json")"
  if [[ "$stale_hours" != "-" ]]; then
    window=$((stale_hours * 3600))
    if (( NOW - newest_epoch > window )); then
      printf 'fail stale %s\n' "$newest_url"
      return
    fi
  fi

  json="$(jq 'sort_by(.createdAt // .updatedAt) | reverse' <<<"$json")"
  local i conclusion url cancelled=0 first_cancel_url=""
  for ((i = 0; i < count; i++)); do
    conclusion="$(jq -r --argjson i "$i" '.[$i].conclusion // ""' <<<"$json")"
    url="$(jq -r --argjson i "$i" '.[$i].url // "-"' <<<"$json")"
    case "$conclusion" in
      success)
        printf 'pass success %s\n' "$url"
        return
        ;;
      failure | startup_failure | timed_out)
        printf 'fail %s %s\n' "$conclusion" "$url"
        return
        ;;
      skipped) ;;
      cancelled)
        cancelled=$((cancelled + 1))
        if [[ -z "$first_cancel_url" ]]; then
          first_cancel_url="$url"
        fi
        if (( cancelled >= 3 )); then
          printf 'fail cancelled %s\n' "$first_cancel_url"
          return
        fi
        ;;
      *)
        # Unknown conclusions fail closed. A job timeout on these lanes has
        # shown up as run conclusion "failure", not "timed_out"; timed_out
        # is still handled above for when GitHub emits it.
        printf 'fail %s %s\n' "${conclusion:-unknown}" "$url"
        return
        ;;
    esac
  done
  printf 'ignore none -\n'
}

existing_issue() {
  local title="$1"
  # createdBy takes the bot's user login. The app slug app/github-actions
  # matches nothing, so a public issue with the same title is not ours.
  gh issue list \
    --repo "$REPO" \
    --state open \
    --author "github-actions[bot]" \
    --limit 100 \
    --json number,title \
    | jq -r --arg title "$title" 'first(.[] | select(.title == $title) | .number) // empty'
}

# True when this exact failure was already commented. gh failure exits.
marker_seen() {
  local number="$1" marker="$2" bodies
  bodies="$(gh issue view "$number" --repo "$REPO" --json comments -q '.comments[].body')" || exit 1
  if grep -F -x -q -e "$marker" <<<"$bodies"; then
    return 0
  fi
  return 1
}

apply_lane() {
  local lane="$1" decision="$2" reason="$3" url="$4" stale_hours="$5"
  local title number body marker
  title="CI scheduled lane failed: ${lane}"
  number="$(existing_issue "$title")"

  if [[ "$decision" == "ignore" ]]; then
    echo "lane-owner: ${lane} ignore -> nothing"
    return
  fi

  if [[ "$decision" == "pass" ]]; then
    if [[ -z "$number" ]]; then
      echo "lane-owner: ${lane} pass ${reason} ${url} -> nothing"
      return
    fi
    if [[ "$DRY" -eq 1 ]]; then
      echo "lane-owner: ${lane} pass ${reason} ${url} -> would close #${number}"
      return
    fi
    body="$(printf 'Scheduled lane %s passed (%s).\n\nRun: %s\n' "$lane" "$reason" "$url")"
    gh issue close "$number" \
      --repo "$REPO" \
      --reason completed \
      --comment "$body" >/dev/null
    echo "lane-owner: ${lane} pass ${reason} ${url} -> closed #${number}"
    return
  fi

  marker="$(printf '<!-- lane-run: %s %s -->' "$reason" "$url")"
  if [[ "$reason" == "stale" && "$url" == "-" ]]; then
    body="$(printf 'Scheduled lane %s failed (stale).\nNo completed run on main within %sh.\n%s\n' "$lane" "$stale_hours" "$marker")"
  else
    body="$(printf 'Scheduled lane %s failed (%s).\n\nRun: %s\n%s\n' "$lane" "$reason" "$url" "$marker")"
  fi

  if [[ -n "$number" ]] && marker_seen "$number" "$marker"; then
    echo "lane-owner: ${lane} fail ${reason} ${url} -> already reported #${number}"
    return
  fi

  if [[ "$DRY" -eq 1 ]]; then
    if [[ -z "$number" ]]; then
      echo "lane-owner: ${lane} fail ${reason} ${url} -> would open"
    else
      echo "lane-owner: ${lane} fail ${reason} ${url} -> would comment #${number}"
    fi
    return
  fi

  if [[ -z "$number" ]]; then
    local created
    created="$(gh issue create \
      --repo "$REPO" \
      --title "$title" \
      --assignee "$ASSIGNEE" \
      --body "$(printf 'This issue tracks failures of the %s lane.\nEach failure adds a comment with the run URL.\nThe issue is closed when the lane next passes.\n' "$lane")")"
    number="${created##*/}"
    if [[ ! "$number" =~ ^[0-9]+$ ]]; then
      echo "error: issue create did not return an issue URL: ${created}" >&2
      exit 1
    fi
    gh issue comment "$number" --repo "$REPO" --body "$body" >/dev/null
    echo "lane-owner: ${lane} fail ${reason} ${url} -> opened #${number}"
    return
  fi

  gh issue edit "$number" --repo "$REPO" --add-assignee "$ASSIGNEE" >/dev/null
  gh issue comment "$number" --repo "$REPO" --body "$body" >/dev/null
  echo "lane-owner: ${lane} fail ${reason} ${url} -> commented #${number}"
}

while read -r workflow stale_hours; do
  [[ -z "${workflow:-}" || "$workflow" == \#* ]] && continue
  if [[ ! "$workflow" =~ ^[a-z0-9][a-z0-9.-]+\.yml$ ]]; then
    echo "error: bad workflow name ${workflow}" >&2
    exit 2
  fi
  if [[ "$stale_hours" != "-" && ! "$stale_hours" =~ ^[0-9]+$ ]]; then
    echo "error: bad stale hours for ${workflow}: ${stale_hours}" >&2
    exit 2
  fi
  lane="${workflow%.yml}"
  runs="$(gh run list \
    --repo "$REPO" \
    --workflow "$workflow" \
    --branch main \
    --status completed \
    --limit 20 \
    --json conclusion,createdAt,updatedAt,url,databaseId,headSha)"
  classified="$(classify_runs "$runs" "$stale_hours")"
  read -r decision reason url <<<"$classified"
  apply_lane "$lane" "$decision" "$reason" "$url" "$stale_hours"
done < <(lane_table)
