# Socket-unlink diagnostic — C11-105 runbook

This runbook walks an operator (or future agent) through reproducing the bug filed in **Lattice C11-105**: the prod c11.app's socket file at `~/Library/Application Support/c11/c11.sock` is unlinked from the filesystem while the prod process is still alive and bound to that path in the kernel. Net effect: every `c11 <command>` returns "Socket not found" until either (a) the operator runs **Cmd+Shift+P → Restart CLI Listener** (the workaround), or (b) the prod c11.app is restarted (which on a machine still affected by C11-103 also wipes the workspace state — two bugs compound).

The original C11-105 description hypothesized that **tagged debug-build shutdown** was the culprit. A source-grep of `Sources/` did not find a matching unlink call near any shutdown path, so the hypothesis is unconfirmed. This runbook + tool exists to **name the actual unlinker empirically**.

## What ships with this PR

- `tools/socket-watcher/` — a standalone SwiftPM package containing `c11-socket-watcher`, a kqueue-based file watcher.
- This runbook.
- A pointer in `code/c11/CLAUDE.md` Pitfalls.

The fix follows on a separate ticket once the watcher names the culprit.

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

### Scenario 1 — tagged debug-build dance (primary hypothesis)

This is the scenario described in the C11-105 ticket. The hypothesis is that `c11 DEV <tag>.app`'s shutdown path includes a cleanup step that unlinks the stable default socket path even when the debug build bound elsewhere.

```bash
# In a separate terminal:
./scripts/reload.sh --tag c11-105-repro
# Wait for the tagged DEV build to launch. Use it normally for a few seconds
# — open a workspace, split a pane, type at the prompt — to ensure it has
# fully initialized any socket cleanup state.
# Then quit it:
osascript -e 'tell application "c11 DEV c11-105-repro" to quit'
# (or click the dock icon → Quit, or Cmd+Q from the foreground window)
```

Watch the JSON Lines log for a `delete` event timestamped at or just after the quit. The `lsof` rows tell you which c11/cmux processes had the prod socket path (or its inode) open at that moment. The `ps` rows catalog every c11/cmux process alive at the unlink. The unlinker is almost always one of the rows in `ps`; the `lsof` rows narrow it further.

### Scenario 2 — Sparkle update simulation (optional)

If Scenario 1 produces nothing, the Sparkle updater is the next-most-suspect (the symptom on 2026-05-18 included `last-socket-path` being repeatedly rewritten to `/var/folders/.../T/csec-cmux-*.sock` paths, which look like Sparkle staging paths). The simplest poke:

1. With a tagged DEV build running, trigger an in-app update check from the Help menu.
2. If a staged update exists, accept it and watch the apply / relaunch cycle.
3. Look for a `delete` event correlated with the relaunch.

(This scenario is involved; skip unless Scenario 1 produces nothing and you have time.)

### Scenario 3 — xcodebuild test runs (optional, low-priority)

Some `c11-unit` or `c11Tests` runs spawn a transient `c11 DEV.app` XCTest host process. The host quits when the run completes. If the watcher captures a `delete` correlated with `xcodebuild test` finishing, that points at the test-host's shutdown path rather than user-initiated quits. **Do not run this scenario locally if the operator's prod c11 is busy** — the test-host briefly monopolizes the main thread of its own process, and we've already documented an incident where this beachballed the host window (see `CLAUDE.md` Testing policy). CI is the safer venue.

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

## Filing the follow-up fix ticket

Once the watcher names the culprit, file a new Lattice ticket with the template:

```
Title: C11-XXX: <process-name> unlinks prod c11's socket on <event>

Symptom: from the C11-105 description (link).

Mechanism (now confirmed): <PID/process> unlinks <path> during <scenario>.
Watcher log attached.

Fix shape: <propose the same options C11-105 had — debug builds skip cleanup,
unlink-with-self-stat verify, prod c11 self-heal — picking based on the
mechanism>.
```

Attach the JSON-Lines log as an artifact and link to C11-105. Close C11-105 once the fix lands (the diagnostic ticket stays open as the harness; the fix ticket is the actionable follow-up).

## Tests

The watcher's behavior is covered by tests in the package itself:

```bash
cd tools/socket-watcher
swift test
```

Three tests run: a delete-event detection test, a re-arm test (delete → rebound → delete), and a JSON-Lines encoding contract test. They use temp files under `FileManager.default.temporaryDirectory` and a stub snapshotter, so they're fast (~0.5s total) and host-less. Safe to run locally; safe to run in CI.

## Why this isn't part of `GhosttyTabs.xcodeproj`

A standalone SwiftPM package avoids the pbxproj churn that comes with adding a new Xcode target (see the `CLAUDE.md` Pitfalls section on `xcodeproj` Ruby-gem normalization). The watcher has no runtime dependency on the c11 app; it's a small diagnostic CLI with one transitive dependency on Foundation. Keeping it out of the Xcode project also means `xcodebuild` invocations don't need to know about it, and `swift test` is the only thing that runs the package's tests.
