# CMUX-4: Tier 1 Phase 4: Claude session index (Tier 1b, opt-in)

Observe-from-outside indexer for Claude Code sessions, so c11mux can offer 'resume this agent' on restart without hooking into Claude.

**Plan doc:** `docs/c11mux-tier1-persistence-plan.md` (Phase 4 section).

**Scope:**
- Read `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` — cwd-slug algorithm empirically confirmed as non-alphanumeric → `-`. Handle many-to-one collisions by reading the first-line `cwd` field from each JSONL to disambiguate.
- Store in per-surface metadata as `agent.claude.session_id` + `agent.claude.session_started_at`. Piggybacks on Phase 2 metadata persistence.
- Opt-in via `CMUX_EXPERIMENTAL_SESSION_INDEX=1`. Kill-switch via `CMUX_DISABLE_SESSION_INDEX=1`.
- Tests: unit test on slug algorithm + cwd disambiguation; socket test confirming index populates metadata after restart if env var set.

**Re-justify before starting:** after Phases 1-3 land, does Phase 2's metadata restore already cover the recovery story (user can see what was running in each pane, restart agents manually)? If yes, Phase 4 may be unnecessary or shrink to 'just record the session pointer' without discovery logic.

**Prerequisites:** Phase 3 (CMUX-3) landed and Tier 1a verified in daily use.

**Follows:** observe-from-outside principle — no hooks into Claude, c11mux reads the transcript store itself (see memory: `feedback_c11mux_no_agent_hooks`).
