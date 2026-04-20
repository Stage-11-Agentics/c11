# C11-1 rebrand — shared rules (all briefs)

Stage 11 is running a **fork-level rebrand** from `c11mux` → `c11`. You are one of four parallel agents working disjoint file sets. Do not touch files outside your bucket.

## Scope heuristic

**User sees it → rename. Compiler/daemon sees it → do NOT touch.**

| Rename | Don't rename |
|---|---|
| Product brand in prose ("c11mux" as a word) | CLI binary name `cmux` |
| User-facing docs (README, CLAUDE.md, PHILOSOPHY.md, docs/*-plan.md) | Env vars (`CMUX_*`, `CMUX_SHELL_INTEGRATION`, etc.) |
| Skill directory name + content | Socket paths (`/tmp/cmux-*.sock`), bundle IDs, Xcode targets/schemes |
| Localized English/Japanese product-name strings | `cmuxd` daemon name |
| Changelog prose | Source identifiers, type names, Swift/Zig code |
| Welcome page prose | Comments inside source files |

## Brand rendering

- **Product name:** `c11` (lowercase c, digits 11). Previous was `c11mux` (also lowercase) → new is `c11` (drop `mux`).
- **Never** write `C11`, `C-11`, `C11Mux`, `c-11` in prose.
- **Exception:** Lattice ticket IDs use uppercase prefix: `C11-1`, `C11-2`. That's a Lattice regex constraint, not a brand style.

## Hard rules — every agent

1. **Do not rename anything inside code fences.** Every `cmux <command>`, `./scripts/reload.sh --tag`, `cmux-debug.log`, `CMUX_*`, `/tmp/cmux-*` example stays exact. Only rebrand **prose around** the fence.
2. **Do not rename file paths in Markdown links.** `[reload script](./scripts/reload.sh)` stays. `[c11mux theming plan](docs/c11mux-theming-plan.md)` — the visible text rebrands to "c11 theming plan" but the path stays unless B2 explicitly renames the file.
3. **Do not edit files outside your bucket.** If you spot a rebrand opportunity in another agent's files, note it in your final report — do not fix it yourself. Overlap causes merge conflicts.
4. **Do not touch Swift, Zig, Python, TypeScript, or other source code.** Source identifiers stay `cmux`.
5. **Do not touch `.lattice/config.json`, `.lattice/tasks/`, `.lattice/events/`.** Lattice switch was done in Phase 0.
6. **Historical docs freeze:** `docs/*-spec.md`, `docs/*-impl-notes.md`, `docs/*-amendment.md`, `docs/*-review.md`, `docs/*-review-pack-*/`, `docs/binary-rename-considered.md`. Do not rename filenames; do not edit prose inside.
7. **Do not delete the stale branch `claude/c11-rebrand-initial`.** The operator decides when it goes.

## Branch + commit hygiene

- Start from branch `c11/rebrand` (the umbrella branch cut in Phase 0).
- Cut your bucket branch: `c11/rebrand-b{1,2,3,4}` off `c11/rebrand`.
- Commit title format: `c11 rebrand: <bucket scope> (C11-1)`. Example: `c11 rebrand: top-level copy (C11-1)`.
- Keep commits small and topical. Multiple commits per bucket is fine.
- Push your bucket branch when done. Do NOT merge it yourself — the operator merges all four buckets in a serial final pass.

## Definition of done (per bucket)

1. All files in your scope rebranded per rules.
2. `git diff c11/rebrand..HEAD` shows zero changes outside your bucket's file list.
3. `rg -n '\bc11mux\b' <your bucket paths>` returns only whitelisted historical artifacts.
4. Final report lists: (a) files changed, (b) any out-of-scope rebrands you spotted, (c) any ambiguous judgment calls you made.
