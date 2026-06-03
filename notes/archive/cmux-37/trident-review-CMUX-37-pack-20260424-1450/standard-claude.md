## Code Review
- **Date:** 2026-04-24T14:50:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff97f99905bccd0bf74a81fe6b703f8c27
- **Linear Story:** CMUX-37 Phase 1
- **Worktree:** /Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1
---

## Summary

This is a high-quality Phase 1 implementation. The author has clearly internalised the Phase 0 patterns — partial-failure semantics, off-main parse + main-actor mutate, named-registry-on-the-wire, fixture-driven pure tests — and extended them cleanly without bleeding new responsibilities into the wrong layer. Per CLAUDE.md, no tests were run locally; this review is source-only.

The seam discipline is the most impressive part. `WorkspaceSnapshotConverter.swift` is rigorously `Foundation`-only, with the comment header treating Linux-portability as the test that proves the rule. `AgentRestartRegistry` resolves by string name (`"phase1"`) at the wire boundary so snapshot files don't lock in a registry version — Phase 5's codex/opencode/kimi rows really can be a one-line append. `ApplyOptions` Codable carefully omits the closure-carrying `restartRegistry` and round-trips the wire-visible knobs faithfully. The advisory hook pattern in `CLI/c11.swift` is correctly mirrored at the new metadata-write site (line 12653).

The acceptance fixture (`WorkspaceSnapshotRoundTripAcceptanceTests`) goes the full distance — seeds via the shared executor, captures live, writes through the store, reads back, converts, strips explicit commands, restores with `restartRegistry: .phase1`, and verifies that each terminal received `cc --resume <session-id>` via the new `#if DEBUG` `pendingInitialInputForTests` accessor. The negative case (registry off → no synthesised command) is also covered, which is exactly the bit-exact Phase 0 preservation the spec demands.

I have no blockers. A handful of important and potential items are below — none should hold the merge.

## Trace through (snapshot capture → restore + cc resume)

1. `c11 claude-hook session-start` (CLI/c11.swift:~12620) writes `claude.session_id` onto the current surface's metadata via `surface.set_metadata` (mode merge, source explicit). Socket-unreachable failures are absorbed into a telemetry breadcrumb via the existing `isAdvisoryHookConnectivityError` predicate — the hook never surfaces an error to Claude Code.
2. `c11 snapshot` → `snapshot.create` v2 → `LiveWorkspaceSnapshotSource.capture(...)` walks `TabManager`/`Workspace`/`SurfaceMetadataStore`/`PaneMetadataStore` on the main actor. Pane metadata attaches to the *first* surface in each pane only. `WorkspaceSnapshotStore.write(...)` produces `~/.c11-snapshots/<ulid>.json` atomically.
3. `c11 restore <id>` reads `C11_SESSION_RESUME` (or its `CMUX_*` mirror) at the CLI layer only. When truthy, it threads `restart_registry: "phase1"` into `snapshot.restore`.
4. `snapshot.restore` v2 reads the envelope (current dir then legacy fallback), runs `WorkspaceSnapshotConverter.applyPlan(...)` (envelope/plan version-checks → plan), pre-validates with `WorkspaceLayoutExecutor.validate(...)` off-main, resolves the registry by name, and dispatches `WorkspaceLayoutExecutor.apply(...)` on the main actor.
5. Executor step 7: for each terminal surface, explicit `SurfaceSpec.command` always wins. Otherwise, if `options.restartRegistry` is non-nil, the executor consults `AgentRestartRegistry` with `(terminal_type, claude.session_id, surface metadata)` and uses the synthesised command. A registry miss with matching inputs emits a `restart_registry_declined` ApplyFailure; the walk continues.
6. Bit-exact preservation: `ApplyOptions.restartRegistry` defaults to nil. The debug `c11 workspace apply` path and Phase 0 acceptance fixtures take the `else` branch (lines 222-224 of `WorkspaceLayoutExecutor.swift`) which preserves Phase 0 behaviour exactly.

## Findings

### Blockers
None.

### Important

1. **Five of the six fixture snapshot ids are not 26 chars.** `01KQ0MIXEDCLAUDEMAILBOX00` (25), `01KQ0MIXEDSURFACES0000000` (25), `01KQ0VERSIONMISMATCH00000` (25). The `WorkspaceSnapshotID.generate` helper produces a strict 26-char Crockford base32 stem, and `testSnapshotIDGenerateProducesCrockfordBase32Stem` asserts this — but the converter and store treat `snapshot_id` as an opaque String, so the fixtures decode fine. This is cosmetic but inconsistent with the documented invariant. Suggest padding to 26 chars in the fixture files. ✅ Confirmed (counted via Bash; see fixtures under `c11Tests/Fixtures/workspace-snapshots/`).

2. **`restart_registry_declined` only fires when `terminalType != nil || sessionId != nil`.** `WorkspaceLayoutExecutor.swift:211`. If a terminal has neither (a non-claude surface during a registry restore), the registry silently no-ops. That's the correct Phase 1 behaviour but worth a note in the doc: a terminal with `terminal_type=codex` will not produce a decline today (Phase 5 would fix this by adding a row), and a generic shell surface should not produce a decline. The current heuristic is fine for Phase 1; flag for Phase 5 to revisit so the message stays accurate when more rows land. ⬇️ Lower priority.

3. **`CLI/c11.swift` snapshot-id-vs-path heuristic is loose.** `CLI/c11.swift:2774` treats any argument with `/`, `.json`, or leading `~` as a path. A snapshot id containing a literal dot (none today, but the schema doesn't forbid it) would be misclassified. Tightening to `hasPrefix("/") || hasPrefix("~/") || hasSuffix(".json")` would be safer. ✅ Confirmed.

4. **Pane metadata attached to the first surface only.** `WorkspaceSnapshotCapture.swift:153-156` and executor `writeSurfaceMetadata` lines 793-839. This works for round-trip because `paneIdForPanel(panelId)` resolves to the same pane regardless of which surface in the pane carries the metadata. However, if the first surface fails to materialise (kind-mismatch replacement returns nil at executor line 533, then `return`), the entire pane bails — losing pane metadata even if the second/third tabs in the captured pane could have hosted it. Today this is theoretical (the seed terminal kind matches in all fixtures), but documenting the invariant in `WorkspaceSnapshotCapture.swift` would future-proof it. ⬇️ Lower priority.

5. **Fixture file `claude-code-with-session.json` does not have a layout `selectedIndex`.** Minor — defaults to 0 on read — but the converter test asserts metadata round-trip without exercising selection. Consider adding a `selectedIndex` to at least one Claude fixture so the round-trip surface area is more complete. ⬇️ Lower priority.

### Potential

6. **Wire format leaks `surfaceMetadata` non-string values silently.** `stringMetadata` (`WorkspaceLayoutExecutor.swift:983-994`) drops non-string values without a warning. The comment notes the store's `validateReservedKey` would have caught a non-string `terminal_type` at write time, which is true — but the acceptance fixture pipes string-only fixtures, so this branch is untested. A small targeted test (build a `SurfaceSpec.metadata` blob with mixed-type values, assert non-strings are filtered and the registry still resolves on the string ones) would close the loop. ⬇️ Lower priority.

7. **`ApplyOptions` manual `Equatable` returns inequality whenever either `restartRegistry` is non-nil.** That's documented and correct for the round-trip Codable test, but it does mean two non-nil registries — even the same `.phase1` literal — compare unequal. The executor doesn't compare options, so this is only relevant in tests, but if a later test wants to assert "applied with phase1" it'll need a separate path. ⬇️ Lower priority.

8. **`v2SnapshotRestore` always constructs a fresh `WorkspaceSnapshotStore()`** with default directory (`~/.c11-snapshots/`). No way to inject a test directory through the v2 socket interface. The acceptance test sidesteps this by calling the executor directly with a fixture; if a future integration test wanted to exercise the full v2 path against a tmp dir, it would need a `directory_override` param or a process-wide test seam. Acceptable for Phase 1; flag for Phase 3+. ⬇️ Lower priority.

9. **`v2SnapshotRestore` runs `WorkspaceSnapshotConverter.applyPlan` and `WorkspaceLayoutExecutor.validate` *outside* the `v2MainSync` block (good — these are nonisolated)**, but the `tabManager` lookup at line 4564 is also outside it. `v2ResolveTabManager` itself routes through `v2MainSync` for some lookups (line 3526+ in the helpers). Correct as written, but a brief comment in the handler noting the off-main pre-checks vs main-actor mutation split would help readers. ⬇️ Lower priority.

10. **`runSnapshotRestore` truthiness check** (`CLI/c11.swift:2873-2877`) treats `"0"`, `"false"`, `"no"`, `"off"` (case-insensitive) as off, plus empty. The skill doc only mentions `"empty / 0 / false / no / off"`. Aligned, but the `mirrorC11CmuxEnv` helper (`CLI/c11.swift:35`) doesn't strip any value — it copies whatever's set. So `C11_SESSION_RESUME=` (empty string) sets `CMUX_SESSION_RESUME=` (also empty), and both read as falsy. Correct but worth a regression test if not already covered. ⬇️ Lower priority.

11. **`WorkspaceSnapshotStore.list()` sort is by `createdAt` desc.** Two snapshots created in the same millisecond will sort non-deterministically (Swift's `sort` is not stable). Unlikely in practice (ULIDs are time-ordered + 80 random bits) but if `list-snapshots` becomes scriptable downstream, a tiebreaker on `snapshotId` would lock the order. ⬇️ Lower priority.

12. **`snapshot.create` always uses `clock: { Date() }` for both `snapshotId` ULID time and `createdAt`** (`TerminalController.swift:4484`). The capture method takes a `clock` closure for tests, but the v2 handler hardwires it to wall-clock. Acceptance harness gets around this by calling `LiveWorkspaceSnapshotSource.capture(clock:)` directly. Fine for Phase 1; just noting for the future record. ⬇️ Lower priority.

13. **`runSnapshotRestore` does not normalise paths**: `resolvePath(target)` is called on path-shaped targets (line 2776), but on snapshot ids no path resolution is needed (just the bare ULID is passed to the v2 method). Fine.

14. **`runListSnapshots` printf format strings use `%-26s` etc. with `String(format:)`.** On Swift, `%s` expects a C string; `%@` is the Objective-C accessor for `String`. Swift's `String(format:)` handles both, but `%-26s` specifically can produce odd alignment with multi-byte UTF-8 titles (truncated to 32 chars at line 2861). The truncation is character-count based (`s.count`), not byte-count, so the format may underflow for narrow-glyph titles. Cosmetic only. ⬇️ Lower priority.

15. **`pendingInitialInputForTests` test seam.** `Sources/GhosttyTerminalView.swift:2596-2604` is `#if DEBUG`-gated and only concatenates a private queue. Doesn't leak into Release. Acceptance test reads via `terminalPendingInput(_:)` which is also `#if DEBUG`. Properly scoped. ✅ Confirmed.

16. **`claudeSessionId` literal vs constant.** The CLI hook uses the bare string `"claude.session_id"` (`CLI/c11.swift:12639`) while the app target has `SurfaceMetadataKeyName.claudeSessionId` (`Sources/WorkspaceMetadataKeys.swift:29`). The CLI target doesn't link the app's keys file, so the duplication is structural. The capture walker (line 224) reads via `SurfaceMetadataStore.shared.getMetadata(...)` which returns the raw stored value, and the executor (`WorkspaceLayoutExecutor.swift:205`) reads via the canonical constant. Drift would require a coordinated rename in two places — flagged as a known seam in the deviation list, acceptable. The comment at the literal site (line 12634-12637) explicitly calls out the convention. ✅ Confirmed.

17. **`snapshot.restore` is intentionally not in `focusIntentV2Methods`.** That means even if the caller passes `--select true`, `v2FocusAllowed` returns `false` and `options.select` is zeroed (line 4575-4577). Same pattern as `workspace.apply` (cycle 2 IM1 fix). Per CLAUDE.md "Socket focus policy", that is correct and consistent — but the help text for `c11 restore --select` (`CLI/c11.swift:8138`) doesn't mention this, so an operator who runs `--select true` will see "OK workspace=… surfaces=N" with no foreground change and may be surprised. Suggest a help-text note that focus is not stolen by default. ⬇️ Lower priority.

18. **`snapshot.create` ignores explicit `path` outside the snapshot directory**. The `path` param accepts any URL; if a caller passes `/etc/passwd.json` the store will atomic-write there (subject to fs permissions). This is the same risk surface as Phase 0 `workspace.apply`'s acceptance-fixture path emit — the v2 socket runs with the user's privileges and can already read/write anywhere they can. Worth noting that the socket has no explicit path-jail. ⬇️ Lower priority.

19. **Submodules untouched.** `git diff 43807212^..HEAD -- ghostty vendor/bonsplit` returns no output. ✅ Confirmed.

20. **No install code introduced.** The pre-existing claude-code installer (`CLI/c11.swift:13807+`) is not touched by this branch. `git diff 43807212^..HEAD -- CLI/c11.swift | grep -i 'settings\.json\|\.claude/'` returns nothing. ✅ Confirmed.

21. **Hot paths untouched.** `Sources/TerminalWindowPortal.swift` and `Sources/ContentView.swift` are not in the changed set. The only `GhosttyTerminalView.swift` change is the `#if DEBUG`-gated `pendingInitialInputForTests` accessor far from `forceRefresh`/`hitTest`. ✅ Confirmed.

22. **Test quality policy.** All new tests exercise runtime behaviour or codable round-trips. `AgentRestartRegistryTests` runs the resolver with various inputs; `WorkspaceSnapshotConverterTests` round-trips through JSON; `WorkspaceSnapshotCaptureTests` writes and reads tmp dirs through the actual store; `WorkspaceSnapshotRoundTripAcceptanceTests` runs the live executor against a TabManager. No grep-the-source or "read Info.plist" tests. ✅ Confirmed.

23. **`@MainActor` discipline.** Capture walker (`LiveWorkspaceSnapshotSource`) is `@MainActor`. Converter, registry, store are non-isolated (`Sendable`/`nonisolated static`). Env reads are CLI-only (`runSnapshotRestore`). v2 handlers parse off-main and confine main-actor mutation to small `v2MainSync` blocks. Matches CLAUDE.md "Socket command threading policy". ✅ Confirmed.

## Verdict

**Ship.** All the Phase 1 acceptance criteria from the delegator brief check out. The few items flagged above are quality-of-life improvements and Phase 5 forward-looking notes — no blockers. The seam discipline (especially `WorkspaceSnapshotConverter.swift`'s Foundation-only ascetic stance and `AgentRestartRegistry`'s wire-name resolution) is exactly the kind of design that makes Phase 5 a one-row append rather than a schema migration. Worth congratulating the impl on.

## Phase 5 prep notes (non-blocking)

- Adding `codex` / `opencode` / `kimi` rows: append `Row(...)` instances to `AgentRestartRegistry.phase1` (likely renamed `.current` or `.allKnown` then). Wire-name resolution in `AgentRestartRegistry.named(_:)` will need a new case or a default that returns `.current`. The `restart_registry_declined` failure message generation (`WorkspaceLayoutExecutor.swift:211-213`) currently triggers on `terminal_type != nil || session_id != nil` — once more rows exist, this should fire only when the registry has a row for `terminal_type` but the row's resolver returns nil. That's a tighter heuristic and a small refactor.
- `ApplyOptions` Codable currently strips `restartRegistry`. If a future Blueprint wants to declare "use registry phase1" on the wire, the cleanest path is a parallel `restartRegistryName: String?` field that's Codable and resolves by name in the executor (mirroring the v2 handler today). Don't make `AgentRestartRegistry` itself Codable.
