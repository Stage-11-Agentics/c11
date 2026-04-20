# CMUX-37: c11mux snapshot & restore: bit-exact Claude session resume + layout rebuild

Add `cmux snapshot` / `cmux restore` / `cmux list-snapshots` subcommands that capture a workspace's layout + per-surface state to JSON and rebuild it later — with bit-exact Claude session resume via `cc --resume <session-id>`.

**Why:** `claude --resume <id>` rehydrates full context and history, but nobody uses it because nobody tracks the IDs. Pair it with a layout snapshot and "come back to this tomorrow" becomes `cmux restore morning-work`.

**Plan:** docs/c11mux-snapshot-restore-plan.md

**Verified preconditions:**
- `cc --resume <id>` works (cc is an alias; flags pass through).
- SessionStart hook receives `session_id` on stdin JSON.
- `terminal_type = claude-code` is already being written to surface manifests today.

**Key design choices:**
- Agent-agnostic snapshot: reads `cmux tree --all --json` + per-surface manifests. No private files, no title heuristics.
- Claude session ID captured by an **operator-installed** SessionStart hook that writes `claude.session_id` + `cwd` to the surface manifest. c11mux does not install the hook (principle). Hook is documented in the `cmux` skill.
- `cmux tree --json` is flat — each pane carries `split_path` breadcrumbs. Restore reconstructs the binary split tree from the paths.
- Known-type restart registry inside `cmux restore`: `claude-code` + session_id → `cc --resume <id>`. Extensible per-agent without schema changes.
- Prior art: sanghun0724/cmux-claude-skills. Not adopting directly — its implementation uses c11mux's private session JSON, spinner-char detection, and fuzzy session-ID matching. We use the manifest instead.

**Phases:**
1. Subcommands + terminal surfaces + single workspace + Claude resume.
2. Browser/markdown surfaces + `--all` flag.
3. Skill docs + SessionStart hook snippet.
4. codex/kimi/opencode registry rows.

**Principle check:** fits "unopinionated about the terminal" — operates on c11mux primitives, writes only to `~/.cmux-snapshots/`, does not touch tenant settings files.

**Related:** supersedes CMUX-4 (manual Claude session index) via the hook-driven approach. Restore preserves CMUX-11 pane manifests + CMUX-14 lineage chains verbatim.
