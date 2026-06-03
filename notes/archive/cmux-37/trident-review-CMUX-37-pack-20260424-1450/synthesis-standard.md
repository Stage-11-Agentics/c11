## Trident Standard Review Synthesis — CMUX-37 Phase 1

- **Date:** 2026-04-24
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff97f99905bccd0bf74a81fe6b703f8c27
- **Inputs:** standard-claude.md (Opus 4.7), standard-codex.md (GPT-5), standard-gemini.md (Gemini 2.5 Pro)

---

## Executive Summary

The three Standard reviewers agree the snapshot/restore data model and seam discipline are solid: the converter is Foundation-only, the registry is opt-in and resolves by wire-name, capture is correctly main-actor isolated while parsing/validation stays off-main, and explicit terminal commands win over registry synthesis. Phase 0 behavior is preserved by default (`ApplyOptions.restartRegistry` defaults to nil).

The split appears at the **CLI boundary**: Codex caught two real correctness/safety bugs there that Claude flagged only as cosmetic and Gemini did not surface. Claude's list-snapshots `%s`-format note (item 14, "cosmetic only") is in fact a runtime crash in the printing path per Codex's Foundation probe. Codex also identified a snapshot-id injection vector through `cc --resume <id>` that the other reviewers missed.

### Merge Verdict: **ship-with-fixes (hold on the two Codex blockers)**

1. Claude says ship; Gemini identifies no blockers; Codex says hold on two confirmed blockers (input injection via session-id, list-snapshots crash) and three important CLI-contract bugs.
2. The data-model and seam discipline review is uniform-positive across all three. The blockers and most importants live in the CLI layer (`CLI/c11.swift` + `Sources/AgentRestartRegistry.swift`), which is small, isolated, and quick to fix.
3. After fixing the two Codex blockers and the three CLI-contract Important items, this is a clean ship.

---

## 1. Consensus Issues (2+ Models Agree)

1. **Pane metadata attached to first surface only** — fragile if the first surface fails to materialize.
   - Claude (Important #4): `Sources/WorkspaceSnapshotCapture.swift:153-156`; executor `writeSurfaceMetadata` lines 793-839; if first-surface kind-mismatch returns nil at executor line 533, the pane bails and pane metadata is lost.
   - Gemini (Important #2): same observation, less specific.
   - **Action:** Document the invariant in `WorkspaceSnapshotCapture.swift`; consider fallback to next surface in pane. Lower priority — theoretical today since seed terminal kinds match in all fixtures.

2. **`C11_SESSION_RESUME` truthiness/parsing** — strictly checks `"0" / "false" / "no" / "off"` (case-insensitive) plus empty.
   - Claude (Potential #10): correct but worth a regression test for the empty-string mirroring through `mirrorC11CmuxEnv`.
   - Gemini (Potential #3): suggests a more robust boolean parser.
   - **Action:** Confirm with regression test; current behavior is acceptable.

3. **`pendingInitialInputForTests` test seam in `Sources/GhosttyTerminalView.swift:2596-2604`** — `#if DEBUG`-gated and properly scoped.
   - Claude (Potential #15): confirmed properly scoped; no Release leak.
   - Gemini (Potential #4): suggests it should ideally be abstracted into a mock/stub terminal pattern.
   - **Action:** None needed for Phase 1; consider abstraction later if a mock pattern emerges.

4. **Phase 0 preservation, converter purity, explicit-command-wins, off-main parse + main-actor mutation, hot-path/submodule/installer untouched** — uniformly validated by all three reviewers as positives. No action required.

---

## 2. Divergent Views (Worth Examining)

1. **`String(format: "%-26s …")` in `runListSnapshots` — `CLI/c11.swift:2852` (Claude) / `:2861` (per Claude's later count).**
   - **Claude (Potential #14):** "Cosmetic only." Notes Swift's `String(format:)` handles both `%s` and `%@`, with the only risk being odd alignment for multi-byte UTF-8 titles.
   - **Codex (Blocker #2):** **Runtime crash.** `%s` expects a C string pointer, not a Swift `String`. Codex ran a Foundation probe outside the suite (`swift -e`) and reproduced a Foundation stack dump in `__CFStringAppendFormatCore`. This fires whenever `snapshot.list` returns at least one entry.
   - **Resolution:** Codex's analysis wins — Swift `String` bridges to `NSString` for `%@` but **not** for `%s`. Treat as a **blocker**; replace `%s` with `%@`. Add a CLI-formatting unit seam (Codex Potential #5).

2. **CLI contract gaps (`--workspace workspace:N`, post-subcommand `--json`, no caller-env workspace defaulting).**
   - **Codex (Important #3, #4):** Three concrete CLI bugs. Help advertises ordinal refs (`workspace:2`) but `parseUUIDFromRef` rejects them at `CLI/c11.swift:2862`; help advertises `--json` after the subcommand but the global parser at `:1365` only consumes it before; no-arg `c11 snapshot` fails to pass caller env workspace to the server, falling back to operator-focused `tabManager.selectedTabId` (risky for background agents).
   - **Claude / Gemini:** Did not surface any of these.
   - **Resolution:** Codex is correct on each. These are real correctness issues, especially the workspace-defaulting one for background-agent use. Treat as **Important** fixes.

3. **Verdict divergence: Claude (ship) vs Gemini (no blockers, implicit ship) vs Codex (hold).**
   - Codex's hold is grounded in two concrete confirmed bugs Claude/Gemini missed. The ship verdicts from Claude/Gemini are reasonable given their findings but underweighted the CLI layer. Resolution: ship-with-fixes.

---

## 3. Unique Findings

### Codex-only

1. **Snapshot-id injection through `cc --resume <id>`** — `Sources/AgentRestartRegistry.swift:69`.
   - `claude.session_id` is trimmed and interpolated directly into `cc --resume \(id)` with no validation or shell quoting. A crafted snapshot whose `claude.session_id` contains shell metacharacters or a newline can queue dangerous text into the restored terminal when resume is enabled. Snapshots can be restored from arbitrary paths via `Sources/TerminalController.swift:4524`, so this is reachable.
   - **Action:** Validate against the actual Claude session-id grammar and/or shell-quote before constructing the command. Add a negative registry test for metacharacters/newlines. **Blocker.**

2. **No CLI test coverage for the new commands.** `rg` found no tests for `runSnapshotCreate`, `runSnapshotRestore`, `runListSnapshots`, `parseUUIDFromRef`. Adding a small pure formatter/parser seam would catch the `%s` crash, the local `--json` rejection, and the ordinal-ref mismatch without launching the app.

3. **Acceptance test claims weaker than its comment** — `c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:180`. The "implicit follow from plan equality" comment doesn't prove the executor wrote titles or reproduced live layout. Adding one direct restored-title assertion would close the loop.

### Claude-only (none are blockers; numbered as in source)

1. **Five fixture snapshot ids are 25 chars, not 26** — violates documented `WorkspaceSnapshotID.generate` invariant. Decode works because `snapshot_id` is treated as opaque String by converter/store. Cosmetic; pad fixtures under `c11Tests/Fixtures/workspace-snapshots/` to 26 chars. (Important #1)

2. **`restart_registry_declined` heuristic** — fires when `terminalType != nil || sessionId != nil`. Correct for Phase 1; Phase 5 should tighten to "registry has a row for `terminal_type` but the row's resolver returned nil" once codex/opencode/kimi rows land. `Sources/WorkspaceLayoutExecutor.swift:211`. (Important #2)

3. **Snapshot-id-vs-path heuristic too loose** — `CLI/c11.swift:2774` treats any arg containing `/`, `.json`, or leading `~` as a path. Tighten to `hasPrefix("/") || hasPrefix("~/") || hasSuffix(".json")`. (Important #3)

4. **Fixture `claude-code-with-session.json` lacks layout `selectedIndex`** — defaults to 0; consider adding one to a Claude fixture for fuller round-trip coverage. (Important #5)

5. **`stringMetadata` silently drops non-string values** — `Sources/WorkspaceLayoutExecutor.swift:983-994`. Untested branch; add a small targeted test for mixed-type metadata. (Potential #6)

6. **`ApplyOptions` manual `Equatable` returns inequality whenever either `restartRegistry` is non-nil** — documented and intended for round-trip tests, but two `.phase1` registries compare unequal. Only test-relevant. (Potential #7)

7. **`v2SnapshotRestore` always constructs a fresh default-directory `WorkspaceSnapshotStore()`** — no test seam for directory injection through the v2 socket. Acceptance test sidesteps via direct executor call. Flag for Phase 3+. (Potential #8)

8. **`snapshot.create` hardwires `clock: { Date() }`** in `Sources/TerminalController.swift:4484` — capture takes a clock closure for tests but the v2 handler doesn't expose it. (Potential #12)

9. **`WorkspaceSnapshotStore.list()` sort by `createdAt` desc is non-deterministic on tied timestamps** — Swift's `sort` isn't stable. Add `snapshotId` tiebreaker if `list-snapshots` becomes scriptable. (Potential #11)

10. **`snapshot.restore` is correctly absent from `focusIntentV2Methods`** — but `c11 restore --select` help text doesn't mention focus is not stolen. Operator passing `--select true` will be surprised. `CLI/c11.swift:8138`. (Potential #17)

11. **`snapshot.create` accepts arbitrary `path`** — no path-jail; will atomic-write anywhere user has fs permissions. Same risk surface as Phase 0 `workspace.apply` fixture-path emit. (Potential #18)

12. **`claudeSessionId` literal "claude.session_id" duplicated** between CLI hook (`CLI/c11.swift:12639`) and app-side `SurfaceMetadataKeyName.claudeSessionId` (`Sources/WorkspaceMetadataKeys.swift:29`) because CLI doesn't link app keys file. Documented seam; acceptable. (Potential #16)

13. **Phase 5 prep notes** — registry append pattern, `restart_registry_declined` heuristic refinement, and `restartRegistryName: String?` Codable field as the cleanest path if a future Blueprint wants to declare "use registry phase1" on the wire.

### Gemini-only

1. **Telemetry-breadcrumb test coverage** — verify both skipped and failed advisory-hook paths in the `claude-hook` double-catch in `CLI/c11.swift`. (Important #1)

---

## 4. Consolidated Action List (Deduplicated, Prioritized)

### Blockers (must fix before merge)

1. **Validate / shell-quote `claude.session_id` before interpolation in `cc --resume <id>`** — `Sources/AgentRestartRegistry.swift:69`. Add negative tests for metacharacters, newlines, command-injection patterns. *(Codex)*

2. **Replace `%s` with `%@` in `runListSnapshots`** — `CLI/c11.swift` ~`:2852-2861`. `%s` expects a C string and crashes Foundation's format core on Swift `String`. Add a CLI-formatting unit seam covering at least one row. *(Codex; partial agreement from Claude as cosmetic)*

### Important (should fix in this merge)

3. **Pass caller env workspace (`$CMUX_WORKSPACE_ID` / `$C11_WORKSPACE_ID`) for no-arg `c11 snapshot`** — `CLI/c11.swift:2722`; today silently captures operator-focused `tabManager.selectedTabId` (`Sources/TerminalController.swift:5243`), which is risky for background agents. Let normal v2 ref resolution handle ordinal refs. *(Codex)*

4. **Accept ordinal `workspace:N` in `--workspace`** — `CLI/c11.swift:2862`; help at `:8109` documents `workspace:2` but parser rejects it. Either accept ordinals (preferred) or fix the help. *(Codex)*

5. **Decide on local `--json` for new subcommands** — global parser at `CLI/c11.swift:1365` only consumes `--json` before the subcommand; help advertises post-subcommand form. Either add local handling in the new handlers or update help/examples to the global form. *(Codex)*

6. **Add CLI test coverage for `runSnapshotCreate`, `runSnapshotRestore`, `runListSnapshots`, `parseUUIDFromRef`** via a pure formatter/parser seam (no app launch). Would have caught items 2, 4, 5 above. *(Codex)*

7. **Tighten snapshot-id-vs-path heuristic** in `CLI/c11.swift:2774` to `hasPrefix("/") || hasPrefix("~/") || hasSuffix(".json")`. *(Claude)*

8. **Cover advisory-hook telemetry breadcrumbs** (skipped vs failed) for the `claude-hook` double-catch. *(Gemini)*

9. **Document the "first surface carries pane metadata" invariant** in `Sources/WorkspaceSnapshotCapture.swift:153-156`; note the executor bail-out path at line 533 that loses pane metadata if the first surface fails. *(Claude + Gemini)*

10. **Add a direct restored-title assertion** in `c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift` (currently relies on plan equality "implicitly following"). *(Codex)*

11. **Pad fixture snapshot ids to 26 chars** (`c11Tests/Fixtures/workspace-snapshots/` — `01KQ0MIXEDCLAUDEMAILBOX00`, `01KQ0MIXEDSURFACES0000000`, `01KQ0VERSIONMISMATCH00000`, etc.). Cosmetic but matches the documented invariant. *(Claude)*

### Lower-priority / Phase 5 prep

12. Add a `selectedIndex` to a Claude fixture for fuller layout round-trip coverage. *(Claude)*
13. Add a targeted test for `stringMetadata` non-string filtering in `Sources/WorkspaceLayoutExecutor.swift:983-994`. *(Claude)*
14. Add a `snapshotId` tiebreaker to `WorkspaceSnapshotStore.list()` sort. *(Claude)*
15. Note in `c11 restore --select` help text that focus is not stolen. *(Claude)*
16. Note the lack of a path-jail on `snapshot.create`'s `path` param (parity with Phase 0 `workspace.apply`). *(Claude)*
17. Consider a `restartRegistryName: String?` Codable field on `ApplyOptions` for Phase 5 wire-declared registries (rather than making `AgentRestartRegistry` itself Codable). *(Claude)*
18. Tighten `restart_registry_declined` heuristic when more rows land (Phase 5). *(Claude)*
19. Robust boolean parser for `C11_SESSION_RESUME` (current strict check is acceptable). *(Gemini + Claude)*
20. Consider abstracting `pendingInitialInputForTests` into a mock terminal pattern. *(Gemini)*

---

## 5. Validated Positives (All Three Reviewers Agree)

1. `WorkspaceSnapshotConverter.swift` is rigorously Foundation-only; no env/file/store/AppKit imports.
2. `ApplyOptions.restartRegistry` defaults to nil; Phase 0 behavior preserved on the `else` branch (`Sources/WorkspaceLayoutExecutor.swift:222-224`).
3. Explicit `SurfaceSpec.command` wins over registry synthesis in executor step 7.
4. `claude.session_id` is surface metadata, not pane metadata; the hook write uses advisory-catch semantics via `isAdvisoryHookConnectivityError`.
5. Storage paths match the brief: writes to `~/.c11-snapshots/`, reads/listing merge current and legacy.
6. Hot paths untouched: `Sources/TerminalWindowPortal.swift`, `Sources/ContentView.swift`, `TerminalSurface.forceRefresh()` not in the diff. The only `GhosttyTerminalView.swift` change is the `#if DEBUG`-gated test accessor.
7. Submodules untouched: no `ghostty/` or `vendor/bonsplit/` changes.
8. No installer code introduced; pre-existing claude-code installer not modified.
9. Test quality policy upheld: all new tests verify runtime/codable behavior, no source-text or plist-grep tests.
10. `@MainActor` discipline: capture walker is `@MainActor`; converter/registry/store are nonisolated `Sendable`; v2 handlers parse off-main and confine main-actor mutation to small `v2MainSync` blocks. Matches CLAUDE.md "Socket command threading policy".

---

## 6. Files With Action Items (Quick Reference)

1. `Sources/AgentRestartRegistry.swift:69` — session-id validation/quoting (Blocker 1).
2. `CLI/c11.swift:2852-2861` — `%s` → `%@` (Blocker 2).
3. `CLI/c11.swift:2722` — caller env workspace defaulting (Important 3).
4. `CLI/c11.swift:2862` — ordinal `workspace:N` support (Important 4).
5. `CLI/c11.swift:1365` / `:8107-8109` / new handlers — `--json` placement (Important 5).
6. `CLI/c11.swift:2774` — path heuristic tightening (Important 7).
7. `CLI/c11.swift:8138` — `c11 restore --select` help text note (Lower 15).
8. `Sources/WorkspaceSnapshotCapture.swift:153-156` — pane-metadata invariant comment (Important 9).
9. `Sources/WorkspaceLayoutExecutor.swift:211-213` — Phase 5 heuristic refinement (Lower 18).
10. `Sources/WorkspaceLayoutExecutor.swift:983-994` — non-string metadata filter test (Lower 13).
11. `Sources/TerminalController.swift:4484` — clock injection seam for v2 handler (Phase 5 prep).
12. `Sources/TerminalController.swift:4524` — explicit-path restore is the reachability proof for Blocker 1.
13. `c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:180` — direct restored-title assertion (Important 10).
14. `c11Tests/Fixtures/workspace-snapshots/*.json` — pad ids to 26 chars (Important 11); add `selectedIndex` to Claude fixture (Lower 12).
15. New CLI test seam — covers `runSnapshotCreate`, `runSnapshotRestore`, `runListSnapshots`, `parseUUIDFromRef` (Important 6).
