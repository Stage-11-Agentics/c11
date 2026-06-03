# C11-28: Strip cmux/c11mux from Lattice repo + fix c11 dashboard project_name

Follow-on to C11-1 (c11mux → c11 rebrand pass). C11-1 covered the c11 repo; this ticket scopes the **Lattice repo + c11 dashboard config** slice that C11-1 explicitly left out of scope.

Planning was drafted in workspace `C11 improvements`, surface `Plan lattice update and rebrand CMUX to C11` (2026-05-17). Plan is parked pending operator branch switch and 4 open questions (see below).

## Scope

**Phase 1 — c11-side dashboard title (one-line):**
- `c11/.lattice/config.json`: `"project_name": "cmux"` → `"project_name": "c11"`. Removes the lingering `CMUX` badge in the dashboard top-left.
- Commit in the c11 repo on main: `chore(lattice): rename project name to c11`.

**Phase 2 — Lattice repo cleanup (lands in code/Lattice/, separate PR per upstream-fixes rule):**
1. `git mv` the cmux-named modules:
   - `src/lattice/integrations/cmux.py` → `c11.py`
   - `src/lattice/cli/cmux_bridge.py` → `c11_bridge.py`
   - `tests/test_integrations_cmux_parsing.py` → `test_integrations_c11_parsing.py`
2. Rename identifiers: `CmuxBackend` → `C11Backend`, `cmux_available()` → `c11_available()`, `_run_cmux` → `_run_c11`, registry name `\"cmux\"` → `\"c11\"`. Update importers (integrations/__init__.py, core/agent_spawn.py, agent_runner.py, claim_cmd.py, task/review cmds, terminal.py).
3. Switch env-var reads from `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` to `C11_WORKSPACE_ID`/`C11_SURFACE_ID` (c11 dual-writes; safe per Stage11/CLAUDE.md).
4. Switch subprocess calls from `[\"cmux\", ...]` to `[\"c11\", ...]`.
5. Rewrite docstrings/comments/log messages to say `c11`. Do NOT preserve `c11mux` anywhere (per `feedback_cmux_to_c11_naming`).
6. Update Lattice repo docs/skills (CLAUDE.md, Decisions.md, skills/delegator-example/SKILL.md). Keep lineage-talk paragraphs naming tmux → cmux → c11.
7. Verify: `cd code/Lattice && uv run pytest && uv run ruff check src/ tests/`. `grep -rinE \"cmux|c11mux\" src/ tests/` returns zero.
8. Open PR in the Lattice repo.

**Phase 3 — end-to-end verify:**
- `lattice restart` in `code/c11/`, dashboard shows `c11` in top-left.
- `lattice list` in `code/c11/` still works.
- New tasks created in c11 still get short_ids like `C11-NNN`.

## Out of scope (immutable history)

Historical data inside `c11/.lattice/` (artifacts payloads, old event jsonls, old `CMUX-NN` short_ids, descriptions containing `c11mux`) — leave as-is. Rewriting event logs is rewriting history.

## Open questions (need operator call before phase 2)

1. Historical data — leave as immutable history, or also rewrite? (Recommendation: leave.)
2. Lattice change lands as a PR vs direct push to main. (Recommendation: PR — touches integration code.)
3. Env-var compat — drop `CMUX_*` reads entirely vs read both. (Recommendation: drop — c11 dual-writes.)
4. Subprocess — `c11` only vs fallback to `cmux` if `c11` not on PATH. (Recommendation: `c11` only.)

## Provenance

Source: workspace `C11 improvements`, surface:113, claude-opus-4-7 planning session 2026-05-17.
Parent: C11-1 (c11mux → c11 rebrand pass — c11 repo slice, already partly landed in commit `7e0e0b282`).
