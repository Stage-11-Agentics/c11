# Socket-unlink diagnostic — C11-105 runbook

This runbook covers the kqueue-based diagnostic tool that ships alongside the **C11-105** fix. The original symptom — prod c11.app's socket at `~/Library/Application Support/c11/c11.sock` unlinked from the filesystem while the prod process stayed alive in-kernel — turned out to be local `xcodebuild -scheme c11-logic test` runs: `TerminalControllerSocketSecurityTests` was a `c11LogicTests` target member, and its `setUp()` called `TerminalController.shared.stop()`, which unlinked a default-initialized stable-default path. The three-part fix (test target moved back to `c11Tests`, `TerminalController.socketPath` defaults to `""` with a non-empty `unlink` guard, `.cmuxOnly` → `.c11Only` hygiene) lives in the rest of this PR.

## Why the tool still ships

The original C11-105 description guessed at "tagged debug-build shutdown" as the culprit. That guess was wrong, but the tool that was built to *empirically name the culprit* turned out to be load-bearing — it would have caught the actual mechanism in one repro and is the right defense against any future unlink source (Sparkle, an Xcode test fixture not yet audited, a third-party tool, a regression). Retained as a canary; do not assume the C11-105 fix closes the door forever.

## What ships in `tools/socket-watcher/`

- `c11-socket-watcher` — a standalone SwiftPM-built binary using kqueue `EVFILT_VNODE` (`NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE`). On each event, shells out to `lsof -U` and `ps -axww` (filtered to `c11|cmux`) and emits one JSON Lines record. After delete it pivots to a parent-directory `NOTE_WRITE` watch and re-arms when the file reappears, so multiple bounces are captured in one run.
- This runbook.
- A pointer in `code/c11/CLAUDE.md` Pitfalls.

## When to reach for this

- The "Socket not found" symptom re-appears with the fix landed — confirm via this watcher that the unlinker is NOT a recurrence of the `c11LogicTests` mechanism before chasing other hypotheses.
- A different file disappears unexpectedly from `~/Library/Application Support/c11/` — point the watcher at it.
- You're chasing a Sparkle / xcodebuild / third-party tool that may be touching the socket directory.

## Building & starting the watcher

From the repo root (a worktree on `main` is fine):

```bash
cd tools/socket-watcher
swift build -c release
```

Then run the watcher against the prod socket path, teeing to a log:

```bash
./.build/release/c11-socket-watcher watch \
  "$HOME/Library/Application Support/c11/c11.sock" \
  | tee /tmp/c11-socket-watch.jsonl
```

(Or via the SwiftPM runner: `swift run -c release c11-socket-watcher watch <path>`.)

The watcher will block, holding open a kqueue + vnode registration on the file. On any delete / rename / revoke event it will:

1. Capture the current ISO-8601 timestamp (millisecond precision).
2. Shell out to `lsof -U` (UNIX-domain sockets only) and `ps -axww -o pid,etime,command` filtered to lines mentioning `c11` or `cmux`.
3. Emit a single line of JSON to stdout with `ts`, `event`, `path`, `lsof`, and `ps` fields.
4. Pivot to watching the parent directory until the file reappears, then emit a `rebound` event and re-arm.

The same watcher can survive multiple bounces — useful when reproducing scenarios that involve several restarts.

## Reproduction scenarios

Run the scenarios below in order. Stop as soon as a delete event appears in the watcher's output; the `lsof` + `ps` snapshot at that timestamp names the suspect.

### Scenario 1 — confirmed historical cause: `c11-logic` test runs

> **Pre-fix only.** This reproduction works against any commit before the C11-105 fix landed. On the fix branch (and forward), the test setUp no longer touches the prod socket, so this scenario emits no `delete` event. Keep it documented for historical clarity and as a guard against regressions in the fix.

`TerminalControllerSocketSecurityTests` was a member of the `c11LogicTests` target. Its `setUp()` calls `TerminalController.shared.stop()`, and the singleton's `socketPath` defaulted to `SocketControlSettings.stableDefaultSocketPath`. Result: every local `c11-logic` run unlinked the prod c11's bind dentry while its FD stayed live in-kernel.

```bash
# In a separate terminal, with the watcher running and prod c11 alive:
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic \
  -configuration Debug -destination "platform=macOS" test
```

Watch the JSON Lines log for a `delete` event timestamped within seconds of the test action starting. The `ps` snapshot will name a Swift XCTest host process whose argv mentions `c11LogicTests.xctest`.

### Scenario 2 — tagged debug-build dance (original hypothesis, not the actual cause)

The original C11-105 description guessed this was the mechanism; it isn't. Still useful as a control: a clean run here should produce **no** `delete` event, confirming the tagged-build shutdown path is innocent.

```bash
./scripts/reload.sh --tag c11-105-repro
osascript -e 'tell application "c11 DEV c11-105-repro" to quit'
```

If you do see a `delete` event in this scenario, that's news — file a new ticket; the fix shipped under this PR did not cover it.

### Scenario 3 — Sparkle update simulation (optional)

The Sparkle updater is the next-most-suspect (the 2026-05-18 forensics included `last-socket-path` being repeatedly rewritten to `/var/folders/.../T/csec-cmux-*.sock` paths — but those turned out to be tempfiles generated by the `c11LogicTests` test itself, not Sparkle). The simplest poke:

1. With a tagged DEV build running, trigger an in-app update check from the Help menu.
2. If a staged update exists, accept it and watch the apply / relaunch cycle.
3. Look for a `delete` event correlated with the relaunch.

### Scenario 4 — operator hits "Restart CLI Listener" (control)

This is a sanity check, not a reproduction. After any delete event, run **Cmd+Shift+P → Restart CLI Listener** in the prod c11 window. The watcher should emit a `rebound` event as the prod process re-binds at the same path. If `rebound` does **not** fire, something is wrong with the watcher (or with the recovery path) and the diagnostic itself needs another look.

## Interpreting the watcher output

Each JSON line has:

```json
{
  "ts": "2026-05-18T21:21:14.482Z",
  "event": "delete",
  "path": "/Users/<you>/Library/Application Support/c11/c11.sock",
  "lsof": "<output of lsof -U at the moment of the event>",
  "ps": "<output of ps -axww filtered to c11|cmux>"
}
```

To read it:

```bash
# Pretty-print every event:
jq -C . < /tmp/c11-socket-watch.jsonl | less -R

# Show just the timestamps + event types:
jq -c '{ts, event}' < /tmp/c11-socket-watch.jsonl

# Show ps output for the first delete:
jq -r 'select(.event=="delete") | .ps' < /tmp/c11-socket-watch.jsonl | head -1
```

The `ps` rows list every c11/cmux process alive at the unlink. Cross-reference PIDs in `lsof` to figure out which of those processes had the socket open. The unlinker is almost always a process whose `etime` shows it was about to quit (long-running) or just started (Sparkle staging).

## Filing a new ticket if the watcher catches a different unlinker

The C11-105 fix closes the `c11LogicTests` mechanism. If the watcher fires a `delete` event from a different source, file a fresh Lattice ticket with the template:

```
Title: C11-XXX: <process-name> unlinks prod c11's socket on <event>

Symptom: same observable as C11-105 — "Socket not found" with prod c11 alive
and bound per `lsof`. The C11-105 mechanism (c11LogicTests stop()) is fixed,
so this is a new source.

Mechanism: <PID/process> unlinks <path> during <scenario>.
Watcher log attached.

Fix shape: <depends on the source — Sparkle gets a sandbox-aware skip,
xcodebuild test fixtures get tighter isolation, third-party tool gets a
defense-in-depth in c11 itself>.
```

Attach the JSON-Lines log as an artifact and link to C11-105 for the historical mechanism.

## Tests

The watcher's behavior is covered by tests in the package itself:

```bash
cd tools/socket-watcher
swift test
```

Three tests run: a delete-event detection test, a re-arm test (delete → rebound → delete), and a JSON-Lines encoding contract test. They use temp files under `FileManager.default.temporaryDirectory` and a stub snapshotter, so they're fast (~0.5s total) and host-less. Safe to run locally; safe to run in CI.

## Why this isn't part of `GhosttyTabs.xcodeproj`

A standalone SwiftPM package avoids the pbxproj churn that comes with adding a new Xcode target (see the `CLAUDE.md` Pitfalls section on `xcodeproj` Ruby-gem normalization). The watcher has no runtime dependency on the c11 app; it's a small diagnostic CLI with one transitive dependency on Foundation. Keeping it out of the Xcode project also means `xcodebuild` invocations don't need to know about it, and `swift test` is the only thing that runs the package's tests.
