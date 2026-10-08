#!/usr/bin/env bash
# sync-installed-skills.sh — push c11 skill source into the user-scope installs.
#
# WHY THIS EXISTS
# ---------------
# c11 installs its skills (Settings → Agent Skills) as ONE-TIME COPIES into
# every agent harness's skills folder (~/.claude/skills/<name>/,
# ~/.codex/skills/<name>/, ~/.pi/agent/skills/<name>/, …), each stamped with a
# `.c11-skill.json` marker. The app does NOT track the repo source after
# install — so editing a skill in this repo does nothing to the copies agents
# actually load until they are refreshed. Committing the source is necessary
# but NOT sufficient: the live skill on any machine where it's already
# installed stays stale, in every harness.
#
# Run this after editing any installable skill so every installed copy matches
# source. Idempotent. Only touches skills that are (a) marked installable in
# skills/MANIFEST.json AND (b) already installed in that harness's folder. It
# never installs a skill a harness doesn't already have; first installs go
# through c11 Settings → Agent Skills. The `.c11-skill.json` install marker is
# preserved (the app owns it).
#
# Usage:
#   scripts/sync-installed-skills.sh           # sync all installed installable skills
#   scripts/sync-installed-skills.sh c11       # sync just one
#
# C11_SKILL_ROOTS overrides the harness folder list (colon-separated), for tests.
set -euo pipefail

REPO_SKILLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills"
MANIFEST="${REPO_SKILLS}/MANIFEST.json"

[ -f "$MANIFEST" ] || { echo "error: no MANIFEST.json at $MANIFEST" >&2; exit 1; }

# Harness skills folders. Keep in step with SkillTarget.skillsDir in
# Sources/SkillInstaller.swift.
ROOTS=()
if [ -n "${C11_SKILL_ROOTS:-}" ]; then
  IFS=':' read -r -a ROOTS <<< "$C11_SKILL_ROOTS"
else
  ROOTS=(
    "${HOME}/.claude/skills"
    "${HOME}/.codex/skills"
    "${HOME}/.grok/skills"
    "${HOME}/.kimi/skills"
    "${HOME}/.config/opencode/skills"
    "${HOME}/.copilot/skills"
    "${HOME}/.pi/agent/skills"
    "${HOME}/.omp/agent/skills"
  )
fi

# Installable skill names: from positional args if given, else from the manifest.
# (Avoid `mapfile`/`readarray` — macOS ships bash 3.2, which lacks them.)
INSTALLABLE=()
if [ "$#" -gt 0 ]; then
  INSTALLABLE=("$@")
else
  while IFS= read -r line; do
    [ -n "$line" ] && INSTALLABLE+=("$line")
  done < <(python3 -c '
import json,sys
print("\n".join(json.load(open(sys.argv[1]))["installable"]))' "$MANIFEST")
fi

synced=0 skipped=0
for name in "${INSTALLABLE[@]}"; do
  src="${REPO_SKILLS}/${name}"
  if [ ! -d "$src" ]; then
    echo "skip  ${name}: no source dir (${src})" >&2; skipped=$((skipped+1)); continue
  fi
  found=0
  seen=":"   # physical paths already synced; harness folders are often symlinked together
  for root in "${ROOTS[@]}"; do
    dest="${root}/${name}"
    [ -d "$dest" ] || continue
    found=1
    real="$(cd "$dest" && pwd -P)"
    case "$seen" in *":${real}:"*) continue ;; esac
    seen="${seen}${real}:"
    # Mirror source → installed copy. --delete keeps removed files from lingering.
    # Preserve the app's install marker.
    rsync -a --delete --exclude='.c11-skill.json' "${src}/" "${dest}/"
    echo "sync  ${name} → ${dest}"
    synced=$((synced+1))
  done
  if [ "$found" -eq 0 ]; then
    echo "skip  ${name}: not installed in any harness; install via c11 Settings first" >&2
    skipped=$((skipped+1))
  fi
done

echo "done: ${synced} synced, ${skipped} skipped"
