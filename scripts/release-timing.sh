#!/usr/bin/env bash
# Print step durations (seconds) for recent release.yml runs, one TSV row per
# run, so a release slowdown shows against docs/release-speed.md.
#
# Usage: scripts/release-timing.sh [count]   (default 5)
set -euo pipefail

count="${1:-5}"
repo="Stage-11-Agentics/c11"

printf 'tag\tconclusion\tjob_s\tto_published_s\tbuild_s\tdeps_s\tnotarize_s\tappcast_s\tsentry_s\tupload_s\n'
gh run list -R "$repo" --workflow release.yml --limit "$count" \
  --json databaseId,headBranch,conclusion --jq '.[] | "\(.databaseId) \(.headBranch) \(.conclusion)"' |
while read -r id tag conclusion; do
  gh api "repos/$repo/actions/runs/$id/jobs" </dev/null |
    jq -r --arg tag "$tag" --arg c "${conclusion:-running}" '
      .jobs[] | select(.name == "build-sign-notarize") as $j
      | def dur($n): ([$j.steps[] | select(.name == $n and .completed_at != null)
          | ((.completed_at | fromdate) - (.started_at | fromdate))] | first // "");
        [ $tag, $c,
          (if $j.completed_at then (($j.completed_at | fromdate) - ($j.started_at | fromdate)) else "" end),
          # Job start to the end of the release upload: what users wait for.
          ([$j.steps[] | select(.name == "Upload release asset" and .completed_at != null)
            | ((.completed_at | fromdate) - ($j.started_at | fromdate))] | first // ""),
          dur("Build app (Release)"), dur("Install build deps"), dur("Notarize app"),
          dur("Generate Sparkle appcast"), dur("Upload dSYMs to Sentry"), dur("Upload release asset")
        ] | @tsv'
done
