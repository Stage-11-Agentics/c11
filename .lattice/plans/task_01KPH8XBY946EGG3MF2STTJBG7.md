# CMUX-6: Tier 1 cleanup: remove rollback env vars + remap scaffolding

One-release-later cleanup for the Tier 1 persistence rollback safety nets. Delete after a stable release confirms the new behavior works.

**Scope:**
- Delete `CMUX_DISABLE_STABLE_PANEL_IDS` env var + associated fallback path (from Phase 1 / PR #10).
- Delete `CMUX_DISABLE_STABLE_WORKSPACE_IDS` env var + associated fallback path (from Phase 1.5 / PR #12).
- Delete `CMUX_DISABLE_METADATA_PERSIST` env var + associated skip paths (from Phase 2 / PR #13).
- Delete `CMUX_DISABLE_STATUS_ENTRY_PERSIST` if added in Phase 3 (from CMUX-3).
- Remove the `oldToNewPanelIds` remap scaffolding that Phase 1 kept as identity-map for safety.
- Remove documentation of these env vars from `docs/socket-api-reference.md` and any operator-facing rollback docs.

**When to pick up:** after Phases 1, 1.5, 2 (and ideally 3) have been stable in production for at least one release. If an issue surfaces that required the rollback path, delay this cleanup until root cause is fixed.

**Estimate:** small — this is pure deletion work, no new behavior. Biggest risk is missing a codepath reference. Tests are the existing persistence test suites; they should continue to pass with rollback removed.

**Prerequisites:** at minimum Phases 1-2 stable for one release.
