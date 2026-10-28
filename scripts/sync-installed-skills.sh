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
# through c11 Settings → Agent Skills.
#
# Each synced copy gets its own `.c11-skill.json` stamp: `installed_by: "sync"`,
# the checkout commit, and the content hash it wrote. The app treats a copy that
# still matches that hash as checkout-managed and never offers to replace it with
# its (possibly older) bundled copy; Settings → Agent Skills replaces it only on
# an explicit Replace Local Copies.
#
# Usage:
#   scripts/sync-installed-skills.sh           # sync all installed installable skills
#   scripts/sync-installed-skills.sh c11       # sync just one
#
# C11_SKILL_ROOTS overrides the harness folder list (colon-separated), for tests.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SKILLS="${REPO_ROOT}/skills"
MANIFEST="${REPO_SKILLS}/MANIFEST.json"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ] && [ -n "$(git -C "$REPO_ROOT" status --porcelain -- skills 2>/dev/null)" ]; then
  COMMIT="${COMMIT}-dirty"
fi

# Writes the sync stamp into an installed copy. The hash matches
# SkillInstaller.contentHash(of:skipInstallerManifest: true) in
# Sources/SkillInstaller.swift; keep the two in step.
write_stamp() {
  python3 - "$1" "$2" "$COMMIT" <<'PY'
import datetime, hashlib, json, os, struct, sys

dest, name, commit = sys.argv[1:4]
entries = []
for root, _, files in os.walk(dest):
    for filename in files:
        path = os.path.join(root, filename)
        rel = os.path.relpath(path, dest)
        if rel == ".c11-skill.json" or filename == ".DS_Store":
            continue
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        entries.append((rel, path))
digest = hashlib.sha256()
for rel, path in sorted(entries):
    rel_bytes = rel.encode()
    with open(path, "rb") as handle:
        data = handle.read()
    digest.update(struct.pack(">Q", len(rel_bytes)) + rel_bytes)
    digest.update(struct.pack(">Q", len(data)) + data)

version = None
with open(os.path.join(dest, "SKILL.md"), encoding="utf-8") as handle:
    lines = handle.read().splitlines()
if lines and lines[0].strip() == "---":
    for line in lines[1:]:
        line = line.strip()
        if line == "---":
            break
        if line.startswith("version:"):
            version = line[len("version:"):].strip().strip("\"'") or None
            break

stamp = {
    "c11_skill_schema": 1,
    "package": name,
    "skill_version": version,
    "installed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "installed_by": "sync",
    "app_version": "",
    "app_build": "",
    "commit": commit,
    "source_sha256": "sha256:" + digest.hexdigest(),
}
if version is None:
    del stamp["skill_version"]
path = os.path.join(dest, ".c11-skill.json")
with open(path + ".tmp", "w", encoding="utf-8") as handle:
    json.dump(stamp, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(path + ".tmp", path)
PY
}

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
    # The stamp is excluded from the mirror and rewritten as a sync stamp.
    rsync -a --delete --exclude='.c11-skill.json' "${src}/" "${dest}/"
    write_stamp "$dest" "$name"
    echo "sync  ${name} → ${dest}"
    synced=$((synced+1))
  done
  if [ "$found" -eq 0 ]; then
    echo "skip  ${name}: not installed in any harness; install via c11 Settings first" >&2
    skipped=$((skipped+1))
  fi
done

echo "done: ${synced} synced, ${skipped} skipped"
