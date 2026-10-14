# 2026-08-25 UI freeze — Surface.deinit teardown deadlock (root-caused)

**Status:** root cause identified with live evidence. The frozen process (pid 4759,
v0.64.0 build 125) was sampled twice while beachballing; both samples plus
`~/Library/Logs/c11/hang.log` agree exactly.

## TL;DR

Closing a terminal surface while its PTY read-thread is blocked pushing into the
**shared, 64-slot app mailbox** deadlocks the main thread permanently:

```
main thread          Surface.deinit (ghostty/src/Surface.zig:826)
                       └─ pthread_join(io thread)          ← blocked forever
io thread            Exec.threadExit (ghostty/src/termio/Exec.zig:226)
                       └─ pthread_join(read thread)        ← blocked forever
read thread          surfaceMessageWriter (ghostty/src/termio/stream_handler.zig:134)
                       └─ app.mailbox.push(.forever)       ← waits for space…
                          …and the ONLY consumer of that queue is the main thread
                          (App.drainMailbox via app tick). Circle closed.
```

Three-thread ABBA deadlock. Nothing recovers it; restart is the only exit.

## Evidence (2026-08-25, freeze began 2:25:52 PM ET)

- Two 5s `/usr/bin/sample` captures of pid 4759 at ~2:38 PM ET (freeze +13 min):
  main thread 2488/2488 samples in `Surface.deinit + 168 → _pthread_join → __ulock_wait`.
  Full files were in the session scratchpad; the durable copies of the key stacks are below.
- Thread census at capture: **333 threads — 41 io, 41 io-reader, 41 cf_release, but
  only 40 renderer.** The missing renderer is the dying surface's: `deinit` had already
  stopped+joined it (Surface.zig:816) before blocking on the io join (Surface.zig:826).
- The dying surface's io thread (Thread_7520488): 2488/2488 in
  `termio.backend.Backend.threadExit → _pthread_join → __ulock_wait`.
- **15 io-reader threads** hard-parked in `Thread.Futex.Deadline.wait` (condvar wait
  inside `BlockingQueue.push`), i.e. blocked producers on main-drained queues. One of
  them is the dying surface's reader; the other 14 are collateral (main stopped
  draining the shared mailbox the moment it entered deinit).
- `hang.log` (MainThreadHangMonitor): continuous `cause=lock-wait` captures with top
  frame `Surface.deinit + 168` from 18:25:52Z onward, `stalledMs` climbing past
  1,200,000. **First occurrence of this signature in the 13-day log window** — but see
  "chronic congestion" below for why it fired now.

Main-thread stack (from hang.log, identical to samples):

```
0  libsystem_kernel  __ulock_wait
1  c11               Surface.deinit + 168
2  libswift_Concurrency  swift::runJobInEstablishedExecutorContext   ← Task { @MainActor } from
                                                                        teardownSurface(), GhosttyTerminalView.swift:3286
3  libdispatch       _dispatch_main_queue_drain
…  NSApplicationMain
```

## Why "agents kept working"

PTYs, the socket accept loop, and the other 40 surfaces' io machinery are all on
background threads — agents genuinely keep executing. But:

- Any socket command that routes through `v2MainSync`/main-queue sync parks forever
  (observed: `TerminalController.processCommandUsingSocketExecutionPolicy` blocked in
  `__DISPATCH_WAIT_FOR_QUEUE__`). So agents' `c11` CLI calls hang during the freeze.
- The 15 parked readers mean those surfaces' PTY output is no longer consumed; once
  the kernel PTY buffer fills (~64KB), those agents block on stdout writes too. The
  freeze degrades the fleet progressively, not just the UI.

## Root cause chain (files and lines)

1. `Sources/GhosttyTerminalView.swift:3286` — `teardownSurface()` runs
   `ghostty_surface_free` on the main actor (necessarily; ghostty expects apprt thread).
2. `ghostty/src/Surface.zig:808-827` — `deinit` stops+joins the renderer thread, then
   stops+joins the io thread, synchronously on main.
3. `ghostty/src/termio/Exec.zig:194-226` — `threadExit` writes `"x"` to the read
   thread's quit pipe, then `read_thread.join()`. **The quit pipe only helps a reader
   sitting in `poll()`** (Exec.zig:1284-1337). A reader blocked inside
   `processOutput` never sees it.
4. `ghostty/src/termio/stream_handler.zig:128-135` — `surfaceMessageWriter` falls back
   to `surface_mailbox.push(msg, .{ .forever })` when the instant push fails.
   `Surface.zig:864-869` shows `surface_mailbox` is the **shared** `App.mailbox`;
   `App.zig:571` sizes it at **64 messages for the whole app**; `App.zig:238`
   (`drainMailbox`, called from `App.tick`) is its only consumer — main thread.
5. Under a heavy multi-agent run, main lags (see chronic congestion), the 64-slot
   queue is full much of the time, readers park regularly. Close any surface while
   its reader is parked → permanent deadlock.

Same trap exists on two sibling queues reachable from the read thread:
- `ghostty/src/termio/mailbox.zig:92` — termio/writer mailbox `.forever` push; its
  consumer is the io thread, which stops consuming during teardown.
- `ghostty/src/termio/stream_handler.zig:172` — renderer mailbox `.forever` push; its
  consumer (renderer thread) is joined **before** the io thread in `deinit`, so during
  teardown it is permanently gone.

Provenance: this logic is inherited upstream (ghostty-org via manaflow cmux fork;
submodule currently on `metal-deinit-drain`). Stock ghostty has the same theoretical
bug; c11's scale (40+ surfaces, agent-driven churn, congested main) makes it fire in
practice. Upstream-relevant fix — flag per CLAUDE.md bidirectional policy.

## Why it recurs on big runs ("slower and slower, then freezes")

`hang.log` (Aug 12 → Aug 25) shows **1,185 stall episodes, 155 of ≥30s**, dominated by
`swiftui-update/*`, `appkit`, `runloop-idle` — the known main-thread congestion theme.
The slowdown and the freeze are one causal chain: congestion keeps the shared mailbox
full → readers park → output stalls (more perceived slowness) → the deadlock trap is
armed → first surface close while its reader is parked springs it. The freeze is the
terminal state of the slowdown, which is why every big run trends toward it.

## Second finding — 62-minute stall via sync-from-SwiftUI-body

Episode 2026-08-25 09:02Z (`stalledMs` → 3,735,800; recovered without restart):

```
VerticalTabsSidebar.body (ForEach)
  → Workspace.surfaceTitleBarState(panelId:)        Sources/Workspace.swift:7703
    → SurfaceMetadataStore.shared.getMetadata(…)    (DispatchQueue.sync)
      → __DISPATCH_WAIT_FOR_QUEUE__                 ← main waited 62 min for the store's queue
```

A synchronous cross-queue hop inside sidebar body evaluation, executed per agent
surface per body pass ("sidebar-hot" by its own comment). Whatever held the metadata
store's queue held the entire UI. Deserves its own ticket: publish a main-actor
snapshot of title/description metadata instead of sync reads from body. (Related
prior art: C11-204 runModal pitfall; socket telemetry off-main policy.)

## Fix plan

**Decision (Atin, 2026-08-25): ship B (mailbox bump) first as the immediate risk
reducer; A (root fix) deferred pending fork-level discussion. Not yet implemented —
nothing committed in the submodule or parent as of this note.**

**A. Root fix (ghostty fork; upstream-worthy): teardown-abortable pushes on the read
thread.** Add an atomic quit flag visible to the read thread; `Exec.threadExit` sets
it *before* writing the quit pipe and joining. Replace the three `.forever` pushes
reachable from the read thread (stream_handler.zig:134, stream_handler.zig:172,
mailbox.zig:92) with a bounded-wait loop, e.g. `.{ .ns = 50ms }`, that re-checks the
quit flag and drops the message once quitting. Semantics are preserved in normal
operation (no message loss); during teardown, dropping is correct — the surface is
dying. Guarantees `join()` completes within ~one timeout tick, turning a permanent
freeze into ≤~100ms.

Note: reordering teardown alone cannot fix this — any join of the read thread from
main (direct or transitive) deadlocks while the reader can park on a main-drained
queue. The pushes must be abortable. There is also no sound embedder-side (Swift)
fix: freeing off-main violates ghostty's threading contract; pre-draining the
mailbox before free leaves the race open (40 producers can refill 64 slots between
drain and join).

**B. Mitigation (one-line, immediate): grow the shared mailbox.** `App.zig:571`
`BlockingQueue(Message, 64)` → 2048+. 64 slots shared across 40+ surfaces is the
pressure that both arms the deadlock and stalls agent output during congestion.
Cheap memory, large trigger-probability reduction. Not a correctness fix — pairs
with A.

**C. Separate ticket: `surfaceTitleBarState` sync-from-body** (second finding above).

**D. Optional hardening:** MainThreadHangMonitor already classifies this as
`cause=lock-wait` with `Surface.deinit` on top — after A lands, that signature
becomes a regression alarm worth asserting on in soak runs.

## Fork topology and the exact upstream-fix path

Three levels, all separate repos:

```
ghostty-org/ghostty          mainline (no local remote; syncs arrive as merge commits)
  └─ manaflow-ai/ghostty     cmux's fork — submodule remote `origin`
       └─ Stage-11-Agentics/ghostty   OUR fork — submodule remote `stage11`; the
                                      submodule pointer lives here
```

State verified 2026-08-25: submodule HEAD `b4ef0ac2c` on branch `metal-deinit-drain`,
clean, identical to the parent repo's committed pointer, and already contained in
both `stage11/main` and `stage11/metal-deinit-drain`. The fork carries ~10 documented
local patches (`docs/ghostty-fork.md`), rebased onto upstream v1.3.0+ (March 2026
sync). Patching our fork does not touch mainline ghostty, cmux, or any standalone
Ghostty.app install — GhosttyKit is statically linked into c11.

Landing steps for any ghostty-level change (A and/or B), per repo convention:

1. Branch in `ghostty/` from current HEAD; implement; commit.
2. Push to `stage11` BEFORE committing the parent pointer (CLAUDE.md submodule
   safety; verify `git merge-base --is-ancestor HEAD stage11/<branch>` after push).
3. Add a new numbered section to `docs/ghostty-fork.md` (commit hash, files, summary,
   rebase-conflict notes — termio files conflict rarely; App.zig constant is trivial).
4. Parent repo: `git add ghostty docs/ghostty-fork.md`, commit the SHA bump.
5. CI: expect the documented two-run pattern — run 1 red on the three guard jobs
   until `build-ghosttykit` pushes the auto-generated
   `scripts/ghosttykit-checksums.txt` entry; run 2 green.
6. Local validation needs the ~10-min Zig GhosttyKit rebuild, then
   `./scripts/reload.sh --tag <slug>` and a real teardown smoke test: heavy output
   into several surfaces (fill the app mailbox) while closing one repeatedly.
7. Upstream offering (for A, per the repo's bidirectional policy): PR to
   ghostty-org/ghostty — the bug exists in mainline; frame as "surface close
   deadlocks when the read thread is blocked pushing to the full app mailbox," with
   the three-thread join chain above as the repro narrative. Also flag to
   manaflow-ai/cmux. If mainline accepts, our patch dissolves at the next sync.

## Addendum: post-restart instance (2026-08-25 afternoon) — NOT the deadlock

The restarted instance (pid 74522, up 2:51 PM ET) beachballed again within hours.
Diagnosed live: **different pathology — congestion storms, not the teardown
deadlock.** Main thread samples show it alive (mostly idle + layout bursts); no
lock-wait, no `Surface.deinit` frames; every hang has a matching `hang.end`.

Numbers from `hang.log` for pid 74522, 2:52–5:00 PM ET (~2h): **50 hang episodes**,
longest 352s / 315s / 295s / 279s / 178s / 170s / 148s — all recovered. Census at
5:02 PM ET: 29 surfaces, 143 threads. Cause buckets: `runloop-idle` ×28,
`swiftui-update/hosting-begin-transaction` ×12, `appkit` ×7, `other` ×6,
`hosting-layout` ×4, `swiftui-update` ×3, `generic-metadata` ×1.

Three faces, with representative stacks:

1. **AttributeGraph dirty-propagation storms** (up to ~278s):
   `NSHostingView.beginTransaction → GraphHost.flushTransactions →
   AG::Graph::propagate_dirty` — SwiftUI dependency-graph invalidation costing
   minutes under 29+ surfaces of agent-driven state churn. Earlier episodes on the
   pre-restart pid put `VerticalTabsSidebar.body` / `SurfaceTitleBarView.headerRow`
   in this bucket.
2. **`runloop-idle` = late heartbeat** (up to 352s): per the monitor's own docs this
   is main parked at the *outermost* event loop with the heartbeat arriving late —
   i.e. the main queue's backlog is minutes deep even though the run loop spins.
   Backlog, not a wedge.
3. **Hover hit-test recursion** (the 120s beachball ending 5:00:22 PM ET,
   `cause=generic-metadata`): `mouseMoved → HoverEventDispatcher →
   MultiViewResponder.containsGlobalPoints` recursing through the responder tree
   with `__swift_instantiateCanonicalPrespecializedGenericMetadata` churn — mouse
   movement over the 29-surface hierarchy held main for two minutes.

Relationship between the two bugs: congestion is the *armed state* for the deadlock
(full mailbox → parked readers → any surface close springs it). This session the
trap hasn't fired; the beachballs are the congestion itself. Fixing the deadlock
removes the terminal freeze; the congestion is its own workstream (aligned with the
existing finding that per-surface ghostty cost is baseline and the architectural
cost — SwiftUI cascades, hover/hit-test scale, sync-from-body reads — is the target).

## Operational notes

- The frozen instance cannot self-recover; restart is correct. Agents in panes die
  with the app (they're child processes) — session-resume wrappers/`--resume` apply.
- Raw sample files from this incident: session scratchpad
  (`.../scratchpad/c11-hang/sample{1,2}.txt`); durable evidence in
  `~/Library/Logs/c11/hang.log` (232MB — consider rotation; it's growing unbounded).
