# C11-1 rebrand — parallel execution briefs

Umbrella ticket: **C11-1 (c11mux → c11 rebrand pass, fork-level, upstream-compatible)**

## How to run

### Phase 0 — serialized prereq (human at keyboard, ~5 min)

1. Verify the Lattice digit-in-project-code regex fix (commit `84a225e` on the stale `claude/c11-rebrand-initial` branch) landed upstream. If not, cherry-pick.
2. Switch `.lattice/config.json` `project_code` CMUX → C11.
3. File tickets:
   - C11-1: c11mux → c11 rebrand pass (this work)
   - C11-2: landing page + 60s demo video (deferred)
   - C11-3: installer / skill-copy UX (deferred)
4. Cut umbrella branch `c11/rebrand` off current `main`.

### Phase 1 — parallel agent dispatch

**First wave (3 concurrent clear agents):**

```bash
env -u CLAUDECODE claude -p "$(cat notes/c11-rebrand/00-shared-rules.md notes/c11-rebrand/b1-top-level-copy.md)" --dangerously-skip-permissions
env -u CLAUDECODE claude -p "$(cat notes/c11-rebrand/00-shared-rules.md notes/c11-rebrand/b2-docs-tree.md)" --dangerously-skip-permissions
env -u CLAUDECODE claude -p "$(cat notes/c11-rebrand/00-shared-rules.md notes/c11-rebrand/b4-localization.md)" --dangerously-skip-permissions
```

Each runs in background, pushes its bucket branch when done.

**Second wave (after first wave reports):**

```bash
env -u CLAUDECODE claude -p "$(cat notes/c11-rebrand/00-shared-rules.md notes/c11-rebrand/b3-skill-rename.md)" --dangerously-skip-permissions
```

B3 runs last because renaming `skills/cmux/` → `skills/c11/` mid-session would break skill auto-detection for any other agent still loading the skill.

### Phase 2 — serialized merge + ship (human at keyboard)

1. Merge B1, B2, B4 into `c11/rebrand` (order doesn't matter; no overlap).
2. Merge B3 into `c11/rebrand`.
3. `rg -i c11mux` full-tree audit — should return only whitelisted historical artifacts.
4. Dry-run upstream merge: `git merge --no-commit origin/main` from `manaflow-ai/cmux` (if remote configured) to confirm zero conflicts in `Sources/`, `cmuxd/`, Xcode project files.
5. `./scripts/reload.sh --tag c11-rebrand` — smoke test app launches, skill still loads.
6. Open single PR `c11/rebrand` → `main`. Merge.
7. Delete bucket branches `c11/rebrand-b{1,2,3,4}` after merge.
8. Delete stale branch `claude/c11-rebrand-initial` only after operator confirms nothing else was cherry-picked from it.

## Bucket summary

| Bucket | Scope | Size | Runs in wave |
|---|---|---|---|
| B1 | Root-level prose (README, CLAUDE.md, PHILOSOPHY, CHANGELOG, TODO, welcome) | S | 1 |
| B2 | docs/ tree — active docs rename + rebrand, historical frozen | L | 1 |
| B3 | skills/ directory renames + content (4 skills) | M | 2 |
| B4 | Resources/Localizable.xcstrings English + Japanese | S | 1 |

## What's deliberately out of scope

- **CLI `c11` symlink:** requires runtime install logic, not a source-tree rename. File as follow-up ticket.
- **Source code identifiers:** `cmux` stays as the binary, target, scheme, bundle ID, env var prefix, socket path, and Swift/Zig identifier name. Upstream-merge continuity.
- **Website copy (`code/stage11.ai/`):** separate repo; covered by C11-2.
- **Installer / skill-copy UX:** covered by C11-3.
