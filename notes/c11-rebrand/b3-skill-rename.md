# B3 — Skill directory rename + content rebrand

You are one of four parallel agents executing a fork-level rebrand from `c11mux` → `c11` on the Stage 11 fork of cmux. **Read `notes/c11-rebrand/00-shared-rules.md` before starting — it carries the scope heuristic, hard rules, brand casing, and branch hygiene that apply to every bucket.**

Your bucket handles `skills/`. This is the **last bucket to run** — do not start until B1, B2, and B4 have reported their final diffs. Agents (including the operator's concurrent sessions) load skills by filename; renaming mid-session breaks skill auto-detection for other running agents.

## Mission

1. Rename the four skill directories from `cmux*` → `c11*`.
2. Rebrand prose inside each skill's `SKILL.md` and reference files.
3. Update `skills/MANIFEST.json` to reflect new directory names.
4. Update any in-file references that point to the old skill directory names.

## Files in scope (exclusive ownership)

Directory moves (use `git mv`):

- `skills/cmux/` → `skills/c11/`
- `skills/cmux-browser/` → `skills/c11-browser/`
- `skills/cmux-debug-windows/` → `skills/c11-debug-windows/`
- `skills/cmux-markdown/` → `skills/c11-markdown/`

Files inside each skill (rebrand prose; filenames inside stay unless the name carries the product brand):

- Each skill's `SKILL.md`
- Each skill's `references/*.md`
- Each skill's `agents/*.yaml` — **prose in `description:` and `prompt:` fields only**; do not rebrand any command examples, env var names, socket paths, or binary references.

Single JSON file:

- `skills/MANIFEST.json` — update the `"installable"` array to the new names.

## Files out of scope (do NOT touch)

- `skills/release/` — not a c11mux-branded skill; leave alone.
- Everything outside `skills/`.

## Hard rules (bucket-specific on top of shared)

1. **Skill auto-detection relies on directory names.** Agents running concurrently in other panes may be loading `skills/cmux/SKILL.md`. You are the last bucket for exactly this reason — operator confirmed other agents are done before dispatching you.
2. **`git mv` the directory, don't copy-and-delete.** History must follow.
3. **Command examples inside SKILL.md stay `cmux`.** The skill describes how to use the `cmux` CLI binary. Every `cmux pane-split`, `cmux send`, `cmux set-metadata` example is binary-level, not brand-level. Untouchable.
4. **Env vars stay.** `CMUX_SHELL_INTEGRATION`, `CMUX_SURFACE_ID`, `CMUX_TAB_ID`, `CMUX_WORKSPACE_ID`, `CMUX_SOCKET`, etc. all remain exactly as written.
5. **Socket paths stay.** `/tmp/cmux-debug.sock`, `/tmp/cmux-<tag>.sock`, etc.
6. **Trigger descriptions in SKILL.md frontmatter can rebrand.** The `description:` field tells agents when to load the skill; rebranding `c11mux` → `c11` in trigger phrases is correct. But keep the trigger that says "when `CMUX_SHELL_INTEGRATION=1` is set" exactly — that's a compiler-level detection rule.
7. **MANIFEST.json schema key:** the top-level key is `c11mux_skill_manifest_schema`. This is a schema identifier, not prose. **Leave it as `c11mux_skill_manifest_schema`** for forward/backward compatibility with any installer that reads it. A follow-up ticket can migrate the schema key with a compatibility shim.
8. **Inbound cross-references.** Other skills or docs may reference `skills/cmux/...` paths. Those are B1/B2's responsibility; flag them in your report.

## Branch + commit

```bash
git checkout c11/rebrand
git pull  # ensures B1, B2, B4 merges are in if operator has fast-forwarded
git checkout -b c11/rebrand-b3

# commit sequence:
#  1. git mv of all 4 skill directories (one commit, "c11 rebrand: skills/ directory moves (C11-1)")
#  2. update skills/MANIFEST.json "installable" array (one commit)
#  3. rebrand prose inside each skill's SKILL.md + references (one commit per skill, or one combined)

git push -u origin c11/rebrand-b3
```

## Definition of done

1. `ls skills/` shows `c11`, `c11-browser`, `c11-debug-windows`, `c11-markdown`, `release`, `MANIFEST.json`. No `cmux*` directories remain.
2. `skills/MANIFEST.json` `"installable"` array contains the new names.
3. Top-level `"c11mux_skill_manifest_schema"` key is **unchanged** (see hard rule 7).
4. `rg -n '\bc11mux\b' skills/` returns only: (a) the schema key in MANIFEST.json, (b) any explicitly-historical phrasing ("previously called c11mux").
5. `git diff --stat c11/rebrand..HEAD` shows only files under `skills/`.
6. Smoke test: `lattice` and `cmux` CLI help still mention nothing broken — skill directory renames don't break anything at build time (skills are runtime-discovered).
7. Final report includes: (a) git mv log, (b) broken inbound path references spotted in other buckets, (c) any `description:`/`prompt:` frontmatter phrases you rebranded that a reviewer should double-check.
