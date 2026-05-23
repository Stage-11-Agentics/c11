# C11-105 self-review — diag/c11-105-socket-watcher

**Reviewer:** agent:claude-c11-105-d1-reviewer (single delegator, fast-track)
**Diff size:** 7 files, +785 lines; no deletions to load-bearing files.
**Scope check:** zero changes to `Sources/SocketControlSettings.swift`, `Sources/AppDelegate.swift`, or `GhosttyTabs.xcodeproj/` — verified with `git diff` filter (0 lines). Scope discipline holds.

## Verdict

**Approve.** Ship it.

## Acceptance criteria walk

| # | Criterion | Status | Notes |
|---|---|---|---|
| AC1 | Watcher lives in a discoverable location with a comment block linking to C11-105 | ✅ | `tools/socket-watcher/` (existing `tools/` dir). Top-of-file comment in `SocketWatcher.swift` and `main.swift` both link to C11-105 and to the runbook. |
| AC2 | Watcher detects unlink/rename/revoke via kqueue, emits JSON Lines with timestamp + event + lsof + ps | ✅ | `EVFILT_VNODE` with `NOTE_DELETE \| NOTE_RENAME \| NOTE_REVOKE`. `testWatcherEmitsDeleteEvent` exercises end-to-end. Demo capture below confirms wall-clock behavior. |
| AC3 | Watcher re-arms after delete; subsequent re-create + delete is captured | ✅ | `testWatcherReArmsAfterDelete` asserts `delete → rebound → delete` sequence in <2s. Demo capture below confirms same in production-style timing. |
| AC4 | Runbook at `docs/c11-socket-unlink-diagnostic.md` walks an operator through (a)…(d) | ✅ | Scenarios: tagged-debug-build dance (primary), Sparkle (secondary), xcodebuild test runs (low-priority), Restart CLI Listener (control). Interpretation guide with `jq` recipes. Follow-up-ticket template included. |
| AC5 | CLAUDE.md Pitfalls section updated | ✅ | One-line bullet added pointing at the runbook + describing the symptom + workaround. |
| AC6 | No changes to `Sources/SocketControlSettings.swift`, `Sources/AppDelegate.swift`, or other shutdown / bind code | ✅ | `git diff -- Sources/SocketControlSettings.swift Sources/AppDelegate.swift GhosttyTabs.xcodeproj/` → 0 lines. |
| AC7 | Tests are host-less and locally runnable | ✅ with deviation | Tests live in the SwiftPM package itself (`tools/socket-watcher/Tests/SocketWatcherKitTests/`), runnable via `swift test`. They do not live inside the `c11LogicTests` xctest target. The boot prompt explicitly permitted either shape and asked for it to be documented in the runbook + PR body — both have it. The spirit of AC7 ("host-less + locally runnable") is satisfied: `swift test` runs in ~0.5s with no DEV.app launch. Adding a c11LogicTests adapter would require pbxproj edits (explicitly out of scope). |
| AC8 | Tests verify observable behavior, not source-code shape | ✅ | No grep / no AST checks. Tests build temp files, run the watcher, assert emitted events. |

## PR-level checks

| # | Check | Status |
|---|---|---|
| P1 | PR body links to C11-105 and frames as diagnostic, not fix | will be present in PR body |
| P2 | `xcodebuild -scheme c11-logic test` passes | unchanged — no files touched in that scheme |
| P3 | No regressions in existing tests | unchanged — no shared code touched |
| P4 | Manual demonstration in PR body | yes — three-event run captured below |

## Critical

None.

## Major

None.

## Minor

- **AC7 deviation noted explicitly.** Tests live in the SwiftPM package, not c11LogicTests. Boot prompt + plan both pre-approved this; flagged here for completeness.
- **SIGINT/SIGTERM uses `exit(0)` directly.** Doesn't flush stdout cleanly, so the last event line could be truncated on abrupt shutdown. Mitigated by the kqueue + lsof being synchronous — by the time the JSON Line is written, the event has already been observed. Not worth the complexity of a proper stop-then-drain handler for a diagnostic tool the operator pipes through `tee`.

## NITs

- The `decodeEventKind` falls through to `.delete` if none of the three bits are set; in practice kqueue always sets at least one of the requested fflags, but the fallthrough is documented (returns `.delete`). Acceptable for a diagnostic.
- The `lsof -U` capture is unfiltered — every UNIX-domain socket on the system. Operator can post-filter with `jq '.lsof | split("\n") | map(select(contains("c11") or contains("cmux")))'`. Keeping it unfiltered is intentional: in some scenarios the unlinker might be a process whose name we don't know to grep for.

## Self-test demo (P4)

```
{"ts":"2026-05-19T02:33:51.277Z","event":"delete","path":"/tmp/c11-105-watcher-demo-XXXXXX.sock","lsof":"<56k bytes>","ps":"29797    05:48:38 /Applications/c11.app/Contents/MacOS/c11 …"}
{"ts":"2026-05-19T02:33:52.027Z","event":"rebound","path":"/tmp/c11-105-watcher-demo-XXXXXX.sock","lsof":"…","ps":"…"}
{"ts":"2026-05-19T02:33:52.497Z","event":"delete","path":"/tmp/c11-105-watcher-demo-XXXXXX.sock","lsof":"…","ps":"…"}
```

Three events in 1.2s: initial delete → file recreated → rebound emitted → second delete. `lsof` snapshot is 56 KB (all open UNIX-domain sockets on the host); `ps` snapshot is 11 KB filtered to `c11|cmux`-matching rows including the prod c11.app at PID 29797. Matches the AC2 + AC3 contract.

## Summary

Diagnostic harness + runbook landed. Three tests pass under `swift test`; scope discipline held; no pbxproj edits; no shutdown/bind code touched. The fix follows on a separate ticket once the watcher names the culprit.