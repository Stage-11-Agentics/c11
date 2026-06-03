# Validation plan — C11-105 (socket-unlink diagnostic)

The deliverable is a diagnostic tool + runbook, not a code fix. ACs reflect that.

## Acceptance criteria

| # | Criterion | Verification |
|---|---|---|
| AC1 | The watcher binary/script lives in a discoverable location (e.g. `scripts/c11-socket-watcher.swift` or `Tools/socket-watcher/`) with a comment block at the top explaining its purpose and pointing at C11-105. | Inspection in code-review. |
| AC2 | The watcher detects unlink/rename/revoke of a target file path via kqueue (or equivalent macOS-native primitive). When the event fires, it emits a structured log entry (JSON Lines) containing timestamp, event type, and a snapshot of relevant system state (`lsof`, `ps`). | Unit test in `c11LogicTests`: build a temp file, run the watcher against it, unlink the file, assert a delete event is emitted within a bounded time (e.g. 500ms). |
| AC3 | The watcher re-arms after the target file disappears, so a subsequent re-creation (e.g. operator runs "Restart CLI Listener") is also captured. | Unit test extending AC2: re-create the file, unlink again, assert second delete event. |
| AC4 | The runbook at `docs/c11-socket-unlink-diagnostic.md` (path to be chosen by the delegator) walks the operator through: (a) starting the watcher, (b) triggering the reproduction (launching a tagged debug build and quitting it; optionally other candidate scenarios), (c) reading the log to identify the unlinker, (d) what to do with the finding (file a follow-up fix ticket). | Inspection: read the runbook and confirm an operator could execute it cold. |
| AC5 | `code/c11/CLAUDE.md` Pitfalls section is updated (or the existing post-recovery note from earlier this session is enhanced) to point at the runbook. | Inspection. |
| AC6 | No changes to `Sources/SocketControlSettings.swift`, `Sources/AppDelegate.swift`, or any other shutdown / socket-bind code. Out of scope for this PR. | Inspection of diff. |
| AC7 | Tests live in `c11LogicTests` (host-less, locally runnable). NOT `c11Tests`. | Inspection: test files under `Tests/c11LogicTests/`. |
| AC8 | Tests verify observable behavior, not source-code shape. | Inspection in code-review. |

## PR-level checks

| # | Check | Verification |
|---|---|---|
| P1 | PR body links to C11-105 and summarizes: "diagnostic tool, not a fix; fix follows when the watcher names the culprit." | Visual inspection. |
| P2 | `xcodebuild -scheme c11-logic test` passes locally and in CI. | Local + CI green. |
| P3 | No regressions in existing tests. | CI green. |
| P4 | The watcher tool has been **manually demonstrated** at least once: the delegator runs it, manually unlinks a test file, observes the event log. Screenshot or pasted log in the PR body. | PR body has the demonstration. |

## Out of scope for this PR

- Identifying the culprit. That's the operator's job to do later when they have time, using this tool. The delegator does NOT need to reproduce the original bug themselves (doing so would involve launching tagged debug builds alongside the operator's prod c11, which could disrupt active orchestrations).
- Filing the fix ticket. The fix ticket gets filed by whoever runs the watcher and identifies the culprit — could be the operator, could be a future agent picking up the diagnosis.
- Generalizing the watcher for other paths. Single-purpose tool.
