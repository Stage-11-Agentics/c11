# C11-105 Plan — socket-unlink diagnostic harness

**Delegator:** agent:claude-c11-105-d1
**Branch:** `diag/c11-105-socket-watcher`
**Worktree:** `code/c11-worktrees/c11-105-socket-diag`
**Anchor:** `7cbc27d31`

## Problem recap

On 2026-05-18, the prod c11.app's socket file at `~/Library/Application Support/c11/c11.sock` was unlinked from the filesystem while the prod process remained alive and bound to that path in-kernel. Symptom: every `c11 <command>` returns "Socket not found"; recovery is the "Restart CLI Listener" command-palette action (workaround landed in CLAUDE.md Pitfalls). Original hypothesis (debug-build shutdown cleanup) is not supported by source-grep — no matching unlink/removeItem call near a teardown path. **This ticket ships a diagnostic harness, NOT a fix.** The fix follows on a separate ticket once the harness names the culprit.

## Watcher design

- **Language:** Swift CLI, macOS-native, no external deps.
- **Path layout:** Standalone SwiftPM package at `Tools/socket-watcher/` with a `c11-socket-watcher` executable target and a `SocketWatcherKit` library target. Build/run via `swift build` / `swift run c11-socket-watcher watch <path>`. **NOT added to `GhosttyTabs.xcodeproj`** — explicitly out of scope per the boot prompt (avoids pbxproj churn).
- **Primitive:** kqueue + `EVFILT_VNODE` with `NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE` on the target file. After the file disappears, the watcher pivots to watching the parent directory with `NOTE_WRITE` and re-arms when the file reappears.
- **Snapshot:** at each vnode event, the watcher shells out to `lsof -U` (filtered by grep for `c11|cmux` if a filter is wanted; default capture is unfiltered) and `ps -axww -o pid,etime,command` (filtered to lines matching `c11|cmux`), captures both as strings, embeds them in the event JSON.
- **Output:** JSON Lines on stdout, one event per line: `{"ts": "<iso8601>", "event": "delete|rename|revoke|rebound", "path": "...", "lsof": "...", "ps": "..."}`. Operator pipes to `tee logfile.jsonl` if they want a persistent log.
- **CLI shape:**
  - `c11-socket-watcher watch <path>` — main mode; emits JSON Lines until interrupted.
  - `c11-socket-watcher reset <path>` — unlink the file (useful for manual self-test in the runbook).
  - `--help` and `--version` per Swift convention.

## Runbook outline

`docs/c11-socket-unlink-diagnostic.md`:

1. Link to C11-105 + one-paragraph symptom recap.
2. Build & start commands:
   ```bash
   cd Tools/socket-watcher
   swift build -c release
   swift run -c release c11-socket-watcher watch "$HOME/Library/Application Support/c11/c11.sock" | tee /tmp/c11-socket-watch.jsonl
   ```
3. Reproduction scenarios:
   - **Tagged debug build dance** (primary hypothesis): build with `./scripts/reload.sh --tag <name>`, let it run, quit it; watch the JSON log for a delete event.
   - **xcodebuild test launches** (secondary): note that some test schemes spawn transient `c11 DEV.app` processes that may interact with the prod socket.
   - **Sparkle update simulation** (optional): documented but caller may skip if involved.
4. Interpreting output: the `lsof` snapshot tells you which c11/cmux processes had the path open; the `ps` snapshot catalogs every c11/cmux process alive at the unlink moment. Cross-reference + correlate.
5. Filing the follow-up fix ticket once the culprit is named (template snippet).

## Test plan

- **Coverage targets:** AC1–AC8, P1–P4 from `.lattice/orchestration/c11-105/validation-plan.md`.
- **Watcher behavior tests** live in the package itself (`Tools/socket-watcher/Tests/SocketWatcherKitTests/`), runnable via `swift test`. This is the simpler shape per the boot prompt ("if tests run as part of `swift test` against the package, document that in the runbook AND the PR body"). Locally runnable, host-less, fast — satisfies the spirit of AC7 (host-less + safe locally) even though it sits outside the `c11LogicTests` xctest target.
- **Tests:**
  1. `testWatcherEmitsDeleteEvent`: create a tempfile, start the watcher pointed at it, unlink, assert a `delete` event is emitted within 1s.
  2. `testWatcherReArmsAfterDelete`: same as above, but after the first delete the test recreates the file at the same path, unlinks again, and asserts a second delete event.
  3. (If feasible) `testWatcherSnapshotsIncludePsAndLsof`: assert the emitted event has non-empty `lsof` and `ps` strings (best-effort; lsof can fail in CI sandboxes — gate the assertion behind a "did the snapshot subprocess succeed" check).
- **`xcodebuild -scheme c11-logic test`** should remain green — we're not adding files to that target. Spot-check that the diff doesn't accidentally touch `GhosttyTabs.xcodeproj`.

## Risks

- **kqueue + macOS sandboxing.** kqueue + `EVFILT_VNODE` works fine for user-owned files outside SIP-protected paths. The target paths are in `~/Library/Application Support/c11/` (user-owned) and `/tmp/` (user-owned tempfiles in tests) — no sandbox/TCC issues expected.
- **`lsof` permissions.** Unprivileged `lsof -U` returns sockets for the current user's processes plus globally-visible ones. The runbook should note that running the watcher under the operator's normal user is sufficient.
- **Re-arm race.** Between the delete event firing and the parent-dir watch arming, a fast re-bind could be missed. Acceptable risk — the runbook's reproduction scenarios are deliberate (operator triggers the quit), so the window is bounded.
- **Spurious vnode events on `NOTE_RENAME` for atomic file replacement.** If something atomically replaces the file (write-temp + rename), the watcher will emit `rename` (good — that's still telling) but may need explicit re-arm in the rename case. Handle by treating delete/rename/revoke symmetrically: in all cases, drop the file watch, pivot to parent-dir watch, re-arm on next NOTE_WRITE.
- **JSON Lines vs. human readability.** Default to JSON. Add an optional `--pretty` flag if someone wants tail-friendly output. Skip on first pass; operator can pipe through `jq` if needed.
- **AC7 strict reading.** AC7 names `c11LogicTests` specifically. Choosing the SwiftPM-package-test path means the tests do NOT live there. Mitigation: state explicitly in the review and PR body that the simpler shape was chosen, both targets (logic xctest + package tests) satisfy "host-less + locally runnable" which is the criterion that actually matters. If a reviewer flags it, easy follow-up to add an adapter test in c11LogicTests that shells out to `swift test`; defer unless asked.

## Phases (fast-track, single delegator)

1. **Plan** (this file) → `planned`.
2. **Implement** the SwiftPM package, the runbook, the CLAUDE.md note, the in-package tests → commit, demo capture → `review`.
3. **Self-review** against AC1-8 + P1-4 → attach review note to Lattice.
4. **Push + PR** → `pr_open`, completion comment, stop.
