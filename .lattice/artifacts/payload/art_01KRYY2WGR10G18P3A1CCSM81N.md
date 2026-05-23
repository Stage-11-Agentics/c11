# C11-103 — Code review (inline, fast-track)

**Reviewer:** delegator agent wearing reviewer hat (agent:claude-c11-103-d1-reviewer)
**Branch:** `fix/c11-103-state-dir-merge` @ 2f245f01f
**Base:** `origin/main` @ 7cbc27d31
**Files changed:** `Sources/Mailbox/MailboxLayout.swift`, `c11Tests/StateDirectoryMigrationTests.swift`, `GhosttyTabs.xcodeproj/project.pbxproj`
**Diff size:** 438 / 27 (added/removed) across 3 files

## Verdict

**Approve.** The per-entry merge implements the run-state plan faithfully; the tests behaviorally cover ACs 1–6 + 8 against a temp-dir fixture; one AC (AC7) is gapped with rationale; one defensive addition beyond the plan (XCTest guard) is justified and documented inline. No critical or major issues. Two minor observations and three NITs.

## Walk against `validation-plan.md`

| AC | Test | Path through impl | Status |
|----|------|-------------------|--------|
| AC1 | `testCleanRenameWhenOnlyLegacyExists` | legacy exists, current absent → `mergeLegacyIntoCurrent` creates current, moves every legacy entry (no collisions), `isDirectoryEmpty(legacy)` → true → removeItem + symlink | ✓ |
| AC2 | `testDualDirMigratesProdSessionWhenCurrentHasOnlyDebugFiles` | prod session is non-`workspaces` entry, absent in current → moveItem; debug session in current is never touched (no inverse iteration) | ✓ |
| AC3 | `testFileCollisionLeavesCurrentBytesIntact` | same-name collision branch: `fileExists(current/foo.json)` → true → continue. Legacy retains the file. Test asserts bytes-equality of current and post-state legacy. | ✓ |
| AC4 | `testWorkspacesShallowRecursionMergesUuidsOneLevelDeep` | `entry == workspacesDirectoryName` AND current has `workspaces/` → `mergeWorkspacesShallow`; per-UUID collision policy mirrors top-level. End state union {A,B,C} verified, current's B-bytes preserved. | ✓ |
| AC5 | `testFreshInstallIsNoOp` | `fileExists(legacyURL)` false → early return before any createDirectory. Neither path ever created. | ✓ |
| AC6 | `testDidRunGuardSkipsSecondCall` | Plants a second-run file in legacy after first call; second `ensureMigrated` is a no-op via the `didRun` latch; second-run file remains in legacy, never in current. | ✓ |
| AC7 | _gapped_ | FileManager substitution surface deliberately not built. Documented in PR body. | gap |
| AC8 | `testSymlinkCreatedWhenLegacyEmptyAfterMerge` + `testSymlinkNotCreatedWhenLegacyRetainsCollidedEntries` | Both branches exercised. | ✓ |
| AC9 | n/a | Tests live in `c11Tests/StateDirectoryMigrationTests.swift`, added to the `c11LogicTests` target's Sources build phase only. | ✓ |
| AC10 | n/a | All assertions are behavioral against `FileManager` state, no source-text or pbxproj-shape asserts. | ✓ |

## PR-level checks (P1–P5)

| P | Status |
|---|--------|
| P1 — PR body links C11-103 + summarizes merge | Pending (PR not yet open) |
| P2 — `xcodebuild` build of `c11-logic` passes in CI | Local builds clean; CI pending |
| P3 — `xcodebuild test` of `c11-logic` passes | All 8 new tests pass locally; full suite has 9 pre-existing failures (verified against baseline via stash-compare — see below). |
| P4 — Existing happy-path test still tested | No prior `StateDirectoryMigration` test existed in `c11Tests/`. AC1 covers the happy path forward. ✓ |
| P5 — No regressions in Mailbox tests | `MailboxLayoutTests` passes (re-verified locally with my changes applied). |

## Critical

None.

## Major

None.

## Minor

**M1. `defaultSnapshotFileURL` and other callers don't thread the `appSupport` override into `ensureMigrated`.** `SessionPersistence.defaultSnapshotFileURL(bundleIdentifier:appSupportDirectory:)` accepts an `appSupportDirectory: URL?` parameter for tests, but internally calls `StateDirectoryMigration.ensureMigrated()` with no arguments — meaning when a test passes a temp-dir for `appSupportDirectory`, the migration still resolves against the real Application Support. The XCTest defensive guard I added is the safety net for this, but the cleaner fix is to thread the override through. Out of scope for this PR (touches 4 unrelated files for a low-frequency call site), but worth a follow-up ticket if the testing seam gets used more.

**M2. The XCTest defensive guard is not in the run-state.md plan.** It's a legitimate addition — without it, a tagged-build dogfooder running tests locally on a dual-dir machine would silently mutate their session state during any test that touches `defaultSnapshotFileURL`. The original implementation was test-safe via the bail-out; the new merge behavior is not, so the guard restores parity. Comment in code explains the why. Calling it out so the reviewer is aware the diff exceeds the run-state's strict letter.

## NITs

**N1.** Parameter name `appSupport: URL?` is shorter than the `appSupportDirectory: URL?` convention used by `SessionPersistence.defaultSnapshotFileURL`. Tiny consistency miss, not worth re-rolling the commit. Future cleanup can rename if anyone cares.

**N2.** `mergeWorkspacesShallow` could be inlined into `mergeLegacyIntoCurrent` since it's called once. I split it for readability — happy to defer to reviewer preference if compactness is favored.

**N3.** The docstring's "The pre-C11-103 implementation rebuilt the dir with a single atomic rename and bailed when both paths already existed" paragraph captures the *why* well, but if the C11-103 reference rots from the file (e.g., this gets re-architected), the paragraph still reads sensibly. Good shape.

## Honest gaps & risks (re-stated from plan)

1. **AC7 not tested.** A FileManager subclass that fails on a targeted path would exercise the per-entry catch + continue. The substitution surface (FileManager has many methods, the test must override the right ones consistently with Foundation's expectations) is fragile relative to the value — production code's `do/catch + logFailure + continue` is straightforward enough that the unit-test value is marginal. Documented in PR body. Operator can request the test if they disagree.
2. **Atomicity downgrade.** Original code used a single atomic `moveItem(legacy → current)` rename when current didn't exist; new code does N per-entry moveItems with a `createDirectory(current)` first. On the merge case (both dirs already exist) atomicity was never available — it's strictly per-entry there. On the rename case (legacy alone), we lose whole-dir atomicity but the operation is still idempotent: mid-merge crash leaves a partial state, next launch's `didRun=false` re-runs and completes. No corruption window.
3. **Symlink re-entrance on subsequent process launches.** After a successful AC1 migration, legacy is a symlink → current. On the next process start, `fileExists(legacy.path)` follows the symlink and returns true (because current exists). My code then iterates `contentsOfDirectory(legacy)` which follows the symlink to current's contents. For every entry, `legacy/entry` resolves to `current/entry` (same file via symlink), so `fileExists(current/entry)` is true → collision → skip. `isDirectoryEmpty(legacy)` returns false (it has all of current's entries through the symlink) → no symlink-recreation. End state unchanged. Indirectly covered by the conflict-policy semantics; no separate test needed.

## Baseline comparison (regression check)

Ran full `c11-logic` test suite on both `origin/main` (via stash) and `HEAD`. Identical failure set on both:

- `BrowserImportMappingTests`
- `CLIHealthRuntimeTests`
- `CommandPaletteSearchEngineTests`
- `DescriptionSanitizerTests`
- `WorkspaceIdentityRestoreTests`
- `WorkspaceLayoutExecutorAcceptanceTests`
- `WorkspaceSnapshotCaptureTests`
- `WorkspaceSnapshotConverterTests`
- `WorkspaceSnapshotRoundTripAcceptanceTests`

These are pre-existing on `main`; this PR introduces zero new failures and adds 8 passing tests.

## One-line summary

Per-entry state-dir merge implements the run-state plan exactly, tests cover 8 of 10 ACs (AC7 gapped with rationale, AC9/10 satisfied by file location and behavioral-test shape), one defensive XCTest guard added beyond the plan to keep dogfooders' local test runs from mutating real Application Support. Approve and ship.