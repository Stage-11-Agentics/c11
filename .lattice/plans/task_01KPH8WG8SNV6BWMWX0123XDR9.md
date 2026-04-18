# CMUX-3: Tier 1 Phase 3: persist statusEntries (Tier 1a completion)

Persist `SidebarStatusEntry` (status pills, progress bars, sidebar state) across restart. Completes Tier 1a durability.

**Plan doc:** `docs/c11mux-tier1-persistence-plan.md` (Phase 3 section).

**Scope:**
- Extend `SessionStatusEntrySnapshot` with `url`, `priority`, `format`, `staleFromRestart` fields.
- Replace `statusEntries.removeAll()` at `Workspace.swift:246` with stamping restore (preserve entries with `staleFromRestart: true`).
- Patch `shouldReplaceStatusEntry` so a first real write with `staleFromRestart: true -> false` always wins (clears stale flag even if payload matches).
- Sidebar renders stale entries with reduced emphasis (opacity/italic).
- Rollback env var `CMUX_DISABLE_STATUS_ENTRY_PERSIST=1` (app-launch-scope).
- Tests: Swift unit (round-trip, staleFromRestart semantics, replacement rules) + Python socket (set-status, restart, assert restored with stale flag, write fresh status, assert flag clears).
- Observer infrastructure on `SurfaceMetadataStore` (deferred from Phase 2) likely lands here — Phase 3 is where observer plumbing belongs.

**Prerequisites:** Phase 2 (CMUX-2 #13) merged. Clean.

**When to pick up:** Whenever Tier 1a completion is prioritized. Should be a tight PR since Phase 2 did the hard schema work.
