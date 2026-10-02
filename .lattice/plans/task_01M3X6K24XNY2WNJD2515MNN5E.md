# C11-299 — Duplicate tab IDs during restore

Inspected base: `0ff8887e5e965400b01645ef40b85fd0b2605cf2`. Owner `agent:astra-crashes`. Planning only; no validation executed. Build on a new branch from refreshed origin/main, `c11-1.0/C11-299-duplicate-restore`; its own PR.

## Evidence and exact correction

B024 is confirmed at `Sources/Workspace.swift:275`: `Dictionary(uniqueKeysWithValues:)` consumes untrusted decoded panel records. A dictionary-only change is insufficient: `restorePane:1039` iterates repeated panel IDs within/across layout leaves, `createTab:1069` reuses persisted IDs, and `restoreSurfaceMetadataFromSnapshot:7400` iterates the original records, so a later duplicate can overwrite the first record's metadata.

Read upstream #16182 (`6f6618e28ff94f21def6a74508db6b66db0cf9ed`): it keeps the first record and deduplicates within and across leaves. c11 has no DockSplitStore and needs no dock port. `SessionAreaLayoutSnapshot` (`SessionPersistence.swift:416`) has an optional persisted pane ID used by a DEBUG metadata reload rail; production restore ignores that ID and creates fresh Bonsplit panes by structural position. The dictionaries at `Workspace.swift:8881,8925` and `sidebarOrderedTabIds:7528` consume live Bonsplit state, not snapshot pane IDs: leave them alone.

Sources: LEDGER B024; bug sweep, Fable C4 and Astra Restore/Wave 2; README/BACKLOG D15 preserves resetting ordinals. This is bounded malformed-input recovery, not a new migration system.

## Implementation

1. Add a small pure normalization helper beside the snapshot types in `Sources/SessionPersistence.swift`. Return an in-memory workspace snapshot plus duplicate diagnostics. Keep the first decoded panel record for each UUID, preserving array order and the complete first record, including metadata. No best-record heuristics, UUID renaming, or format bump.
2. Traverse layout leaves in existing first-then-second order. Keep each known panel UUID at its first layout occurrence only, using one workspace-local set. Remove repeated references within the same leaf and later leaves; preserve remaining order. If a leaf's selected ID was removed, select its first retained ID (or nil). Preserve metadata, rail state, split geometry and existing empty-leaf fallback behavior. Unknown references continue to be ignored as today.
3. At the entry to `Workspace.restoreSessionSnapshot`, normalize once and use that same result for dictionary construction, layout creation, surface metadata, subsequent selection, and both current/legacy agent-resume scheduling loops (`Workspace.swift:411,493`). Keep existing tab constructors and stable UUID restore. Log duplicate-record and duplicate-layout-reference drops with workspace UUID, tab UUID and reason through a release-available diagnostic logger; never log prompts, paths or snapshot contents. No unguarded DEBUG-only dlog.
4. Add pure normalization cases in a logic-target test file `c11Tests/SessionRestoreNormalizationTests.swift`, wiring membership if necessary. Extend host-required `c11Tests/TabIdentityRestoreTests.swift` for the full install path and `SessionPersistenceTests.swift` for save/load. Use small synthetic constructors/fixtures, not source-text assertions. Runtime harness/fixture: `tests_v2/test_duplicate_session_restore.py` and `tests_v2/fixtures/duplicate-session.json`.

## Acceptance → fixture → proof

| Criterion / incident | Behavioral tests and remote validation host tagged proof |
|---|---|
| AC1 B024 | Synthetic snapshot has panel records `[A(first metadata), A(conflicting metadata), B, C]`; first leaf references `[A,A,B]`, second `[A,C]`. Normalizer returns first A plus B/C, first leaf A/B, second C; first A's metadata wins. Host restore creates exactly one A and preserves B/C, selected IDs and tab-to-pane mapping. Structured diagnostics name synthetic A for each dropped occurrence. Add record-only and layout-only duplicates to isolate both mechanisms. |
| AC2 normal-session regression | Control captured from an isolated real tagged session contains terminal, markdown and local about:blank browser tabs across two areas. Restore preserves their UUIDs, order, selected tab, metadata and split layout. Existing TabIdentityRestoreTests remain green; pure normalizer leaves a valid fixture unchanged. Empty/unknown-reference leaf control retains today's fallback behavior. |
| AC3 second restart | Save the restored malformed fixture normally, load it, quit cleanly, and relaunch the same remote validation host tag with `C11_QA_LAUNCH=resume`. Restored graph still contains one A and B/C, and both restores complete without process death. Inspect actual packaged app's tree and socket metadata, not just the helper's return. |

Run all targeted logic/host tests on remote validation host through C11-216 after BUILD MODE. Full tagged relaunch uses an isolated test domain and synthetic session file; never mutate production state. Computer-use check confirms visible areas, selection and restored content; enumerate the display, impose a hard timeout and prove dismissal, keep tree layout readable, and retain screenshots/logs. No runtime proof is claimed in this plan.

## Impact and cut line

Startup-only O(records + layout references) normalization. No new typing, focus implementation, sidebar, worker-thread, or input hot-path work; existing selection behavior is preserved. No localized product strings; diagnostics only. No persistence schema change or manual file rewrite; only normal successful autosave records the repaired graph. No tenant config writes or submodule changes.

C11-216 required for tagged proof; C11-297 may touch the same files, so branch from origin/main after its integration or resolve the small independent hunks without stacking PRs. C11-257 remains off limits until landed. Out: duplicate workspace IDs across windows, general snapshot validation, live-layout dictionaries, B004/B355 (C11-297), history/poorer-save policy, teardown, stable ordinals and B081.

Open decisions: none. Keep-first is the ticket's settled choice. Orchestrator owns review routing (maximum three cycles), Merge Captain owns merge; await BUILD MODE.

## Build-mode implementation note (2026-10-01)

The stored plan remains the cut line. The owner launch overrides remote validation host availability: until the Orchestrator sends REMOTE BUILDS LIVE, GitHub CI on draft PR #499 supplies compile/logic and advisory host-test evidence. No local Swift build/test or app launch is permitted. Tagged restore/relaunch and computer-use proof remain explicitly unperformed until that rail is enabled.

Membership correction found on implementation: TabIdentityRestoreTests was in c11LogicTests despite constructing Workspace. Move that existing file to c11Tests for the planned host proof; the new SessionRestoreNormalizationTests belongs to c11LogicTests. Existing SessionPersistenceTests gets the pure temporary-file save/load case. The runtime oracle is read-only and takes an explicit guest socket; its docstring defines the two-launch fixture scenario. It does not launch or seed the operator's app.

## Reset 2026-10-02 by agent:astra-crashes


## Round 1 correction: normalize before startup recovery

Review ev_01M3XEGCB92M3WTXX1SVQ9XTXC identified an earlier reader missed by the original plan: AppDelegate.prepareStartupSessionSnapshotIfNeeded derives activity floors, scrape contexts and bridge seed records before Workspace.restoreSessionSnapshot. Duplicate Codex records can therefore trap reconciliation, and conflicting conversation refs can overwrite the first record during seeding.

Add SessionRestoreNormalization.prepareStartupSnapshot to apply the existing workspace-local repair across all loaded windows/workspaces and emit the existing drop diagnostics. Invoke it immediately after SessionPersistenceStore.load; assign that same normalized value to startupSessionSnapshot and use it throughout startup recovery. Keep Workspace.restoreSessionSnapshot's normalization for direct/debug callers; an already normalized startup snapshot emits no repeat drops.

Regressions: logic tests decode an app snapshot with duplicate Codex records, preserve the first activity floor/cwd, derive exactly one scrape context, collect an empty candidate batch and apply it through the conversation store without a trap. Cover every workspace/window and diagnostic idempotence. Host WorkspaceConversationResumeTests cover conflicting native conversation refs without terminal_type, plus the first record having no conversation and a later duplicate having one; assert the first state/absence through bridge seeding, pendingRestartPlans, actual workspace snapshot capture and temporary-file save/load. No resume command is executed. No unrelated scraper, bridge, migration, or identity changes.

The Orchestrator's adopted batch-validation ruling still applies: relaunch/visual proof is not a pre-merge gate for this low-risk ticket. New-head Swift validation uses GitHub CI until remote validation host is enabled for this seat. Exactly one repair commit and push, followed by review handoff.

## Reset 2026-10-02 by agent:astra-crashes

## Reset 2026-10-02 by agent:codex-validator
