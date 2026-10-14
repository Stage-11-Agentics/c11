# BUG: Main-thread block in `GhosttyNSView.attachSurface` wedges entire UI

**Version:** c11 **0.60.1 (121)** (running app image; note `c11 version` on the CLI
reports 0.60.0 (118) — the CLI binary and the running app were out of step, which is
itself worth a look)
**Date:** 2026-07-28
**Severity:** High — full UI beachball, unrecoverable without force-quit
**Blast radius:** Force-quit kills every agent in the workspace (see *Collateral*)

---

## Summary

`GhosttyNSView.attachSurface(_:)` performs a **blocking futex wait on the main
thread**, called from inside SwiftUI's layout pass (`NSHostingView.layout()` →
`updateNSView`). When the ghostty side is slow to service the attach, the main
thread blocks inside AppKit's display-cycle flush and the entire app beachballs.

Observed with **21 open surfaces**, all actively rendering. The app was wedged
indefinitely — two samples minutes apart showed byte-identical stacks.

## Reproduction

Not yet reduced to deterministic steps. Observed conditions:

- 21 ghostty surfaces open in one c11 instance (21 renderer + 21 io + 21 io-reader threads)
- All surfaces actively producing output (22 agent TUIs: 11 `claude`, 11 `codex`)
- Sustained system load (load avg 7.41 at onset)
- Beachball began on surface attach — i.e. a new pane/surface mount or portal re-bind

Likely sensitive to surface count and render pressure. `scripts/repro-c11-18.sh`
drives portal churn and is the natural starting point for a reduction.

## Evidence

`/usr/bin/sample 6063 5` — **3416 of 3416 samples** on the main thread in one stack.
Re-sampled minutes later: **2147 of 2147**, identical frame. Not spinning — blocked.

```
main
└─ NSApplicationMain
   └─ __CFRunLoopDoSource0
      └─ CA::Transaction::commit()
         └─ NSDisplayCycleFlush                          ← AppKit display cycle
            └─ -[NSWindow layoutIfNeeded]
               └─ -[NSView _layoutSubtreeWithOldSize:]
                  └─ NSHostingView.layout()              ← SwiftUI layout pass
                     └─ ViewGraph.updateOutputs(at:)
                        └─ GraphHost.updatePreferences()
                           └─ AG::Graph::UpdateStack::update()
                              └─ PlatformViewChild.updateValue()
                                 └─ PlatformViewRepresentableAdaptor.updateViewProvider(_:context:)
                                    └─ GhosttyTerminalView.updateNSView(_:context:)   ← c11
                                       └─ GhosttyNSView.attachSurface(_:)             ← c11
                                          └─ Thread.Futex.Deadline.wait               ← c11 (Zig/ghostty)
                                             └─ __ulock_wait2                         ← BLOCKED
```

### What it is waiting on — traced to the exact lock

The chain, confirmed by reading the shipped source (not inferred from the stack,
which inlines the intermediate frames):

```
GhosttyNSView.attachSurface           GhosttyTerminalView.swift:4451
  └─ TerminalSurface.attachToView     GhosttyTerminalView.swift:3243
     └─ createSurface(for:)           GhosttyTerminalView.swift:3308  → :3324
        └─ ghostty_surface_new  ──────────────────────── into Zig
           └─ Surface.init            ghostty/src/Surface.zig:515
              └─ app.font_grid_set.ref(...)
                 └─ SharedGridSet.lock.lock()   ← std.Thread.Mutex, EXCLUSIVE
                    └─ __ulock_wait2            ← BLOCKED HERE
```

`SharedGridSet.zig:47` declares `lock: std.Thread.Mutex`. `ref()` (`:95`, taking the
lock at `:103`) and `deref()` (`:394`) both hold it exclusively — and `ref()` may
*create* a grid inside the critical section, which means font discovery and face
loading happen while the mutex is held. Every surface create and every surface
teardown serializes through this one mutex.

So the main thread is not waiting on "the renderers" loosely — it is waiting to
enter `SharedGridSet.ref` during `Surface.init`.

### The amplifier: `SharedGrid.lock` write contention

Separately, all 21 renderer threads were concurrently inside the **shared** font grid:

```
19  font.SharedGrid.renderGlyph   (in c11)
10  addGlyph                      (in c11)
 6  font.SharedGrid.getIndex      (in c11)
 9  rebuildRow                    (in c11)
24  drawFrame                     (in c11)
17  updateFrame                   (in c11)
68  backend.kqueue.Loop.tick      (in c11)
```

`SharedGrid.lock` is a `std.Thread.RwLock` (`SharedGrid.zig:63`). Both hot paths
take the **exclusive write** lock on a cache miss, and hold it across expensive work:

| Path | Read fast path | Write slow path | Work done under the write lock |
|---|---|---|---|
| `getIndex` | `:165` `lockShared` | `:171` `lock` | font fallback search + `getFace` (deferred face load, disk I/O) |
| `renderGlyph` | `:269` `lockShared` | `:275` `lock` | presentation resolve + glyph rasterization + atlas insert |

Cache *hits* are cheap and shared. Cache *misses* serialize globally. Twenty-one
agent TUIs emitting box-drawing, spinners, powerline separators, and emoji miss
constantly — so the exclusive lock is being taken and held continuously by 21
threads. Zig's `DefaultRwLock` makes no fairness guarantee, so a steady stream of
writers can starve a waiter indefinitely.

This is what turns `SharedGridSet.ref` from a fast call into an unbounded one:
grid creation inside `ref()` needs the font machinery that 21 renderers are
thrashing.

`tripwire` (`renderGlyph_tw`, `init_tw`) was checked and ruled out — `src/tripwire.zig`
contains no blocking primitives; it is pure tracing.

## Root cause

`Sources/GhosttyTerminalView.swift:7518` → `:4451` → `:3243`

```swift
// :7518 — called from updateNSView, i.e. on the main thread inside layout
func attachSurface(_ terminalSurface: TerminalSurface) {
    surfaceView.attachSurface(terminalSurface)
}
```

```swift
// :4451
func attachSurface(_ surface: TerminalSurface) {
    ...
    if !isAlreadyAttached {
        surface.attachToView(self)      // ← enters ghostty, blocks on futex
    }
    ...
}
```

Two compounding defects:

1. **A blocking wait on the main thread.** `attachToView` crosses into ghostty
   (Zig) and waits on a futex. Nothing that blocks may run on the main thread,
   least of all inside a layout pass.

2. **It runs inside `updateNSView`.** SwiftUI re-drives `updateNSView` on every
   layout pass, so the wait is re-entered continuously and cannot self-clear.
   Even though the wait carries a *deadline*, the result is a livelock: each
   layout pass blocks for the deadline, forever.

`attachToView` already has fast-path early returns (`:3259`, `:3275`) for the
already-attached cases. The blocking path is the genuine first-attach /
re-parent case — precisely the portal-bind path.

## Collateral: force-quit destroys agent sessions

Agent processes are **descendants** of c11:

```
claude(39184) ← zsh(38639) ← login(38638) ← c11(6063) ← launchd
```

Force-quitting c11 hangs up every PTY and takes down all 22 agent TUIs. In this
incident that was 11 `claude` + 11 `codex` sessions.

Worth noting the agents themselves were **unaffected** by the wedge — all in
normal `S`/`S+` sleep, none blocked on PTY writes, transcripts still being
written to `~/.claude/projects/` seconds before inspection. Only the UI was dead.
The user therefore loses sessions **only** if they force-quit to escape a UI bug.

## Diagnostic finding: the socket survives the wedge

The control socket stayed responsive throughout:

| Command | Result |
|---|---|
| `c11 ping` | `PONG` |
| `c11 version` | `c11 0.60.0 (118)` |
| `c11 list-windows` | *empty* |
| `c11 list-workspaces` | *empty* |
| `c11 list-panes` | *empty* |
| `c11 capabilities` | *empty* |

Handlers that touch no app state answer fine; everything that marshals to the
main thread returns empty. So the socket layer **outlives main-thread wedges**
but offers no escape hatch, because every useful recovery command needs main.

## Proposed fixes

**1. Never block the main thread in `updateNSView`** *(the actual fix)*

Make `attachSurface` non-blocking. Kick the ghostty attach asynchronously and
let the surface mount when ready — `updateNSView` should schedule work, not
await it. Surfaces already tolerate deferred creation (see the deferred-attach
path at `:3290` and `viewDidMoveToWindow` at `:4492`), so the machinery for a
"not yet attached" state exists.

**2. Bound the wait**

If a synchronous attach must stay, cap the deadline hard (~50 ms) and fall back
to the deferred path on timeout. A dropped frame beats a dead app.

**3. Stop holding locks across expensive work** *(upstream-shaped — see below)*

Two specific changes, both "shrink the critical section":

- **`SharedGridSet.ref` must not build a grid under its mutex.** Reserve the slot,
  drop the lock, construct the grid (font discovery, face loading), then re-acquire
  to publish. Today every surface create/destroy serializes behind grid construction.
- **`SharedGrid.getIndex` / `renderGlyph` must not rasterize under the write lock.**
  Render outside the lock, then take the write lock only to insert into the map/atlas.
  Double-checked insert already exists at `:176`/`:279`, so a losing racer just
  discards its work — cheap compared to serializing 21 threads.

This is the difference between "attach is slow" and "attach is unbounded."

Both changes live in shared ghostty code rather than c11-specific paths, so per
`CLAUDE.md`'s upstream policy this should be flagged to the operator for possible
contribution to `manaflow-ai/cmux` / ghostty rather than silently diverging in
the fork.

**4. Add a main-thread-free recovery command** *(defense in depth)*

The socket is alive during a wedge — that's an asset. A
`c11 force-detach-surface --surface <ref>` (or `c11 recover`) handled entirely
off-main would have rescued this session without losing 22 agents. Pairs well
with the existing "Restart CLI Listener" precedent in `CLAUDE.md`.

**5. Make the hang monitor act**

`com.stage11.c11.hang-monitor` is running (`MainThreadHangMonitor.runLoop()`) and
was sleeping through a total main-thread block. It should at minimum log the
stack and surface a notification; ideally trip the recovery path in (2).

## Notes for the fixer

- `Thread.Futex.Deadline.wait` is Zig stdlib inside libghostty — the Swift-side
  entry point is `attachToView`, so the fix belongs on the c11 side (don't await
  it on main) rather than in the submodule.
- This is *architectural* cost in the SwiftUI/portal-bind path, not intrinsic
  per-surface ghostty renderer cost. Distinguishing the two matters here: adding
  surfaces is expected to cost NSView/Metal/renderer resources; it is not
  expected to make surface attach unbounded.
- The `C11_PORTAL_DEBUG=1` instrumentation (C11-18, writes to `/tmp/c11-portal.log`)
  covers `bind`/`detach`/`sync.result` and should capture this path. Enable it
  when attempting a reduction.
