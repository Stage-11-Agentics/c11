## Code Review
- **Date:** 2026-04-24T18:56:30Z
- **Model:** Codex (GPT-5)
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff97f99905bccd0bf74a81fe6b703f8c27
- **Linear Story:** CMUX-37
---

General assessment: Phase 1's core app-side snapshot model is clean. The converter is Foundation-only, the store stays off-main, capture is correctly main-actor isolated, explicit terminal commands win over registry synthesis, and the restore registry is opt-in at restore time. The tests cover the pure converter/store/registry paths and an end-to-end capture/restore acceptance path without local execution.

Verdict: **hold** until the Blockers below are fixed. The main risks are in the new CLI/command boundary rather than the snapshot data model.

### Blockers

1. ✅ **Confirmed - `C11_SESSION_RESUME` can inject arbitrary terminal input from snapshot metadata.**  
   [Sources/AgentRestartRegistry.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/Sources/AgentRestartRegistry.swift:69) trims `claude.session_id` and interpolates it directly into `cc --resume \(id)` with no validation or shell quoting. Because snapshots can be restored from an explicit path in [Sources/TerminalController.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/Sources/TerminalController.swift:4524), a crafted snapshot with `claude.session_id` containing shell metacharacters or a newline can cause dangerous text to be queued into the restored terminal when resume is enabled. Fix by validating the ID against the actual Claude session-id grammar and/or shell-quoting it before constructing the command; add a negative registry test for metacharacters/newlines.

2. ✅ **Confirmed - `c11 list-snapshots` crashes once it tries to print rows.**  
   [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/CLI/c11.swift:2852) uses `String(format: "%-26s ...", Swift String, ...)`. In Swift/Foundation, `%s` expects a C string pointer, not a Swift `String`; validating the same formatting shape with `swift -e` produced a Foundation stack dump in `__CFStringAppendFormatCore`. This path runs whenever `snapshot.list` returns at least one entry, before printing the header. Use `%@` with `NSString`/`String` arguments or avoid C formatting here, and cover this with a CLI-formatting unit seam.

### Important

3. ✅ **Confirmed - `c11 snapshot` does not honor the documented current-workspace/caller contract, and its documented ref example is rejected.**  
   The help says no args resolve from `$CMUX_WORKSPACE_ID / $C11_WORKSPACE_ID` and gives `c11 snapshot --workspace workspace:2` as an example in [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/CLI/c11.swift:8109). The implementation sends no workspace parameter for the no-arg case in [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/CLI/c11.swift:2722), so the server falls back to `tabManager.selectedTabId` in [Sources/TerminalController.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/Sources/TerminalController.swift:5243). It also parses `--workspace` only as a UUID or `workspace:<uuid>` in [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/CLI/c11.swift:2862), so `workspace:2` fails client-side. This is especially risky for background agents: the snapshot can silently capture the operator-focused workspace rather than the caller's workspace. Pass the caller env workspace like other commands do, and let normal v2 ref resolution handle ordinal refs.

4. ✅ **Confirmed - the new commands document post-subcommand `--json`, but reject it.**  
   The global parser only consumes `--json` before the subcommand in [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/CLI/c11.swift:1365). The new handlers then treat remaining flags as unknown, so `c11 snapshot --json`, `c11 restore <id> --json`, and `c11 list-snapshots --json` contradict the help text at [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/CLI/c11.swift:8107). Either support local `--json` in these handlers or update the help/examples to the existing global form.

### Potential

5. ✅ **Confirmed - CLI coverage is missing for the behavior most likely to regress.**  
   The added tests exercise converter/store/registry/acceptance paths, but `rg` found no tests for `runSnapshotCreate`, `runSnapshotRestore`, `runListSnapshots`, `parseUUIDFromRef`, or the new help examples. That gap is why the `%s` crash, local `--json` rejection, and ordinal-ref mismatch survived. A small pure formatter/parser seam would satisfy the test-quality policy without launching the app.

6. ⬇️ **Lower priority - restored title/layout assertions are weaker than the acceptance-test comment claims.**  
   [c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-phase1/c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:180) says surface titles and layout structural match "implicitly follow" from plan equality, but that does not prove the restore executor actually wrote titles or reproduced live layout. Existing Phase 0 tests may cover much of this; still, CMUX-37's focus areas call out verbatim surface-name restore, so adding one direct restored-title assertion would close the loop.

### Validated Positives

- Converter purity holds: `WorkspaceSnapshotConverter.swift` imports only Foundation and does no env/file/store/AppKit work.
- Phase 0 behavior is preserved by default: `ApplyOptions.restartRegistry` defaults to nil, and executor synthesis only runs when non-nil.
- Explicit `SurfaceSpec.command` wins over registry synthesis in executor step 7.
- `claude.session_id` is surface metadata, not pane metadata, and the hook write uses advisory catch semantics.
- Storage locations match the brief: writes to `~/.c11-snapshots`, reads/listing merge current and legacy.
- Hot-path and submodule checks passed for the Phase 1 diff: only the DEBUG test accessor touched `GhosttyTerminalView.swift`; no `ghostty/` or `vendor/bonsplit/` changes were in scope.

Validation notes: I did not run the repository test suites per project policy. c11 socket orientation/status updates were also unavailable from this sandbox (`Operation not permitted` connecting to the app socket). I did run a tiny Swift/Foundation formatting probe outside the repo test suite to validate the `%s` crash; it failed with a Foundation stack dump, confirming finding 2.
