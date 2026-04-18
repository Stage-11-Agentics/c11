# CMUX-5: Tier 1 Phase 5: recovery UI (Tier 1b, depends on Phase 4)

On restart, show a gentle banner offering to resume detected agent sessions and copy-paste recreate commands for non-Claude surfaces.

**Plan doc:** `docs/c11mux-tier1-persistence-plan.md` (Phase 5 section).

**Scope:**
- If a workspace has surfaces with detected agent sessions (via Phase 4's metadata), show banner: 'N agents had live sessions — resume?'
- One-click runs `claude --resume <id>` in each surface.
- For non-Claude surfaces: show 'here's what was running — copy these commands to rebuild' (derive from persisted metadata: cwd, terminal_type, last command if available).
- Banner dismissible; respects user's 'don't ask again' preference per workspace.
- All strings localized via `String(localized:)`.

**Re-justify before starting:** by the time Phases 1-4 land, is the operator already able to rebuild a workspace in ~30s from restored metadata + muscle memory? If yes, Phase 5 may be a 'nice-to-have' that doesn't ship.

**Prerequisites:** Phase 4 (CMUX-4) merged. Phase 4 provides the `agent.claude.session_id` metadata this UI reads.

**Depends on:** Phase 4.
