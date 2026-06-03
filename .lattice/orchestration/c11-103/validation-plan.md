# Validation plan — C11-103

Authored now while spec context is fresh. The delegator's code-review phase performs the audit; this file is the rubric it (and the operator) check against.

## Acceptance criteria (from C11-103 + the conversation)

| # | Criterion | Verification |
|---|---|---|
| AC1 | When `c11mux/` exists and `c11/` does not, the migration still moves the whole dir over (existing happy path preserved). | Unit test: build `c11mux/` with a session file in a temp dir, run `StateDirectoryMigration.ensureMigrated(fileManager: fm)` with a faked appSupport URL, assert `c11/session-com.stage11.c11.json` exists and `c11mux` is now a symlink. |
| AC2 | When both `c11mux/` and `c11/` exist and `c11/` lacks the prod-bundle-id session file but `c11mux/` has one, the migration moves the session file into `c11/`. | Unit test: build dual-dir state where `c11mux/session-com.stage11.c11.json` exists and `c11/` has only `session-com.stage11.c11.debug.tag.json`. Run migration. Assert `c11/session-com.stage11.c11.json` now exists with the legacy bytes. |
| AC3 | Conflict policy: if both `c11/` and `c11mux/` have a file of the same name, the `c11/` file wins (is left untouched). | Unit test: write `c11mux/foo.json = "legacy"` and `c11/foo.json = "current"`. Run migration. Assert `c11/foo.json` still reads "current"; legacy file should NOT have been moved. |
| AC4 | `workspaces/<uuid>/` subdirs migrate one level deep: each UUID present only in legacy moves over; UUIDs present in both stay in current. | Unit test: legacy has `workspaces/{A,B}`, current has `workspaces/{B,C}`. Run migration. Assert current has `{A,B,C}`. |
| AC5 | Fresh install (neither dir exists) is a no-op — does not create either path. | Unit test: empty temp dir. Run migration. Assert neither `c11mux` nor `c11` exists afterward. |
| AC6 | The `didRun` guard still prevents double-execution within a process. | Unit test: pre-populate dual-dir state, run migration twice on the same `StateDirectoryMigration` (reset via `resetForTests` if such hook exists, or via process-scope mocking). Assert the second call does not re-trigger any moves. |
| AC7 | Per-entry errors are best-effort: a `moveItem` failure on one entry does not abort migration of other entries. | Unit test (if feasible with FileManager substitution): use a stub FileManager that fails on a specific path. Assert other entries migrate successfully. Acceptable to skip if the substitution surface is too large; document the gap in the PR. |
| AC8 | Legacy symlink: only created when the legacy dir is empty after merge (preserves the downgrade-window intent of the original code). | Unit test: when merge leaves legacy non-empty (because some files collided), assert no symlink. When merge empties legacy, assert the symlink is at legacyURL pointing at `c11`. |
| AC9 | Test target: tests live in `c11LogicTests` (the host-less scheme), not `c11Tests`. | Inspection: test file under `Tests/c11LogicTests/`. CI builds and runs it via `c11-logic` scheme. |
| AC10 | No tests that grep source code or assert source-text shape. Tests verify observable migration behavior via `FileManager` + temp dirs. | Inspection in code-review. |

## PR-level checks

| # | Check | Verification |
|---|---|---|
| P1 | PR body links to C11-103 and summarizes the merge approach. | Visual inspection of PR. |
| P2 | `xcodebuild` build of `c11-logic` scheme passes in CI. | CI green on the PR. |
| P3 | `xcodebuild test` of `c11-logic` scheme passes in CI (all existing tests + the new C11-103 cases). | CI green on the PR. |
| P4 | Existing migration test (if any) still passes — the "happy path move when c11/ does not exist" branch must remain a tested code path. | grep `Tests/` for any existing `StateDirectoryMigration` test and confirm it survives. |
| P5 | No regressions in Mailbox tests (the migration lives in `Sources/Mailbox/`; existing mailbox tests must still pass). | CI green. |

## Out of scope for this PR

- Recovering Atin's specific orphaned state. Operator chose to leave the `c11mux/` dir untouched on his machine; manual restore path is documented in C11-103. Don't try to handle "user already has corrupted/empty session file in c11/" — that's a post-incident migration that the code can't safely automate.
- Removing the `c11mux` legacy path entirely. Per the existing comment ("symlink can be dropped in a later release once the downgrade window has closed"), retiring the legacy path is a separate future PR.
- Adding telemetry for "migration ran" / "merge fired." Nice-to-have, but the dlog statements already in MailboxLayout.swift are sufficient for the foreseeable bug surface.
