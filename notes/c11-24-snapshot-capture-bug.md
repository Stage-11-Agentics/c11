# C11-24 — Snapshot capture sync-bridge deadlock

**Status:** Root cause identified, fix applied, regression test added.
**Discovered:** 2026-05-05 during PR #95 (c11-24-conversation-store) loopy validation.
**Severity:** marquee feature non-functional. The store captured refs in memory but
zero refs ever made it to disk in any persisted snapshot (clean shutdown OR autosave),
so the documented "v1 = snapshot-only resume" path produced no resumes for any TUI.

## What the architecture doc claims

> **v1 production restore is snapshot-only.** Refs that landed in the snapshot at
> last clean shutdown resume; refs lost between snapshots do not.

`docs/conversation-store-architecture.md` § "v1 scope vs v1.1".

## What actually happened

| Layer | Pre-quit (in-memory) | Post-relaunch (loaded from disk) |
|---|---|---|
| `ConversationStore.shared` | `claude-code` ref `state=alive`, real session id captured by SessionStart hook | empty |
| Snapshot file `surface_conversations` | (n/a) | `{"history": []}` for every terminal panel |
| Surfaces / panes / browser / workspace name | resumed | resumed |
| Auto-typed `claude --resume <id>` on the surface | (n/a) | did not happen — there was no ref to plan from |

Reproduced twice in a tagged build (`./scripts/reload.sh --tag c11-24`):
launch claude, confirm trust, watch `c11 conversation list` show the alive ref,
AppleScript-quit the app, observe the freshly-written snapshot file is missing
the `active` field on every panel.

## Root cause

`Workspace` is `@MainActor`-isolated:

```swift
@MainActor
final class Workspace: Identifiable, ObservableObject { ... }
```

`Workspace.sessionPanelSnapshot(panelId:includeScrollback:)` ran a per-panel
synchronous bridge into the actor:

```swift
let sema = DispatchSemaphore(value: 0)
var captured: SurfaceConversations = .empty
Task {
    captured = await ConversationStore.shared
        .conversations(for: panelId.uuidString)
    sema.signal()
}
_ = sema.wait(timeout: .now() + 0.5)
```

Two interacting failures:

1. **Isolation inheritance.** An unstructured `Task { ... }` spawned inside a
   `@MainActor` context inherits `@MainActor` isolation. The task body must run
   on the main thread — but main is blocked on `sema.wait`. The body never
   executes; `sema.signal()` is never called. The semaphore times out, and
   `captured` is left at its `.empty` default.
2. **Per-panel hot path.** Even ignoring the deadlock, this pattern blocked
   main for up to *N panels × 0.5s* on every snapshot save. Diagnostic
   instrumentation (timeout bumped to 5s, written to
   `/tmp/c11-conv-snapshot-debug.log`) showed every panel timing out at exactly
   ~5002ms during normal operation — and main was held long enough to time out
   v2 socket calls (`c11 tree` returned `elapsed_ms=10001`). The `unchanged
   autosave fingerprint` skip path was the only thing keeping the app
   responsive between shutdowns.

The wider blast radius: every other `@MainActor` site that used the same
`Task { ... }` + `sema.wait` shape was subject to the same deadlock —
`SnapshotBridge.seedFromSnapshot`, `AppDelegate.suspendAllAlive`,
`AppDelegate.markAllUnknown`, `Workspace.pendingRestartPlans`. None of them
ever delivered work to the actor inside their bounded waits. The actor was
only ever reachable from non-`@MainActor` callers (the v2 socket handlers in
`TerminalController`, which is plain `class TerminalController` with no
isolation), which is why `c11 conversation list` returned the live ref and
in-memory operation looked healthy.

## Why the trident review missed it

Synthesis-action.md (`notes/trident-review-C11-24-pack-20260427-2343/`) flagged
the related concern at **S2** as "valid for Swift 6 strict concurrency, even
if it's not a deadlock today" — referring to `conversationStoreSync` in
`TerminalController`. The reviewer's framing matches the actor-isolation rules
literally: in non-`@MainActor` callers, the pattern works. The pattern only
deadlocks when the *caller* is `@MainActor`-isolated, and the trident
reviewers did not exercise the snapshot-capture path end-to-end against a
real `@MainActor` `Workspace`. Unit tests for the conversation store actor in
isolation passed; unit tests for `pendingRestartPlans` pre-seeded the actor
through a different path; nothing exercised the whole save/load round trip.

## Fix

### Use `Task.detached` for every `@MainActor` sync bridge

`Task.detached` does not inherit caller isolation, so the body runs freely on
the cooperative pool while main is blocked on the semaphore. **Six sites**:

- `Workspace.readConversationsByPanelIdSync` (new helper, replaces inline reads)
- `Workspace.pendingRestartPlans` — now calls the helper instead of inlining
- `Conversation/SnapshotBridge.seedFromSnapshot` — `Task.detached` for the seed
- `AppDelegate.applicationWillTerminate` — `Task.detached` for `suspendAllAlive`
- `AppDelegate.prepareStartupSessionSnapshotIfNeeded` — `Task.detached` for `markAllUnknown`
- `TerminalController.conversationStoreSync` — `Task.detached` for every v2
  conversation handler (`v2ConversationClaim/Push/Tombstone/List/Get/Clear`).
  This was the most insidious of the six: `TerminalController` is also
  `@MainActor`, so the v2 handlers silently returned `?? [:]` (the timeout
  fallback) for every call, even when the actor had data. The whole sync
  bridge in `TerminalController` was broken in exactly the same way as the
  Workspace one — verified by side-by-side diagnostics that showed the
  bridge's view of `bySurface` had 1 entry while the v2 handler's view of
  the same actor had 0.

### Bulk-read once, lookup per panel

`Workspace.sessionSnapshot(includeScrollback:)` now calls
`readConversationsByPanelIdSync` exactly once before iterating panels, and
threads the resulting `[String: SurfaceConversations]` map through to
`sessionPanelSnapshot(panelId:includeScrollback:conversationsByPanelId:)`,
which does a dictionary lookup instead of an actor round-trip. One detached
task per save, not N.

### Conversation activity in autosave fingerprint

`AppDelegate.sessionAutosaveFingerprint` now hashes the active ref's
`(surface_id, kind, id, state, captured_via)` for every entry the actor
holds. Without this, conversation activity never changed the fingerprint,
the autosave path skipped with `unchanged_autosave_fingerprint`, and the
only possible path to disk was the shutdown write. Fingerprint change
triggers the autosave write that lands the data on disk for crash-recovery
scenarios as well.

## Regression tests

`c11Tests/WorkspaceConversationResumeTests.swift`:

- `testReadConversationsByPanelIdSyncReturnsLiveData` — pushes two refs,
  hops into `MainActor.run`, calls `readConversationsByPanelIdSync`, asserts
  both refs are visible. Would have deadlocked under the old
  `Task { ... }` pattern.
- `testReadConversationsByPanelIdSyncEmptyStoreReturnsEmpty` — empty-store
  contract.

A full snapshot round-trip test (push ref → `workspace.sessionSnapshot()` →
decode → assert `active` round-trips) would also be valuable but requires a
live `Workspace` instance with at least one terminal panel; deferred to a
follow-up since the integration coverage already lives in the tagged-build
validation runbook.

## How to validate

Tagged build:

```bash
./scripts/reload.sh --tag c11-24
# In a c11 surface inside the tagged window:
claude   # accept trust prompt
# In another shell:
CMUX_SOCKET_PATH=/tmp/c11-debug-c11-24.sock c11 conversation list
# → expect: surface_id  claude-code  <session-uuid>  [alive]
osascript -e 'tell application "c11 DEV c11-24" to quit'
# Inspect the snapshot:
python3 -c '
import json, os
d = json.load(open(os.path.expanduser("~/Library/Application Support/c11mux/session-com.stage11.c11.debug.c11.24.json")))
for w in d["windows"]:
  for ws in w["tabManager"]["workspaces"]:
    for p in ws.get("panels", []):
      sc = p.get("surface_conversations")
      if sc and sc.get("active"):
        print(p["id"], sc["active"]["kind"], sc["active"]["id"], sc["active"]["state"])
'
# → expect: <panel-uuid> claude-code <session-uuid> suspended
```

Relaunch and confirm `c11 conversation list` shows the same ref, in
`state=suspended`. The surface should auto-type `claude
--dangerously-skip-permissions --resume <id>` via `pendingRestartPlans`.
