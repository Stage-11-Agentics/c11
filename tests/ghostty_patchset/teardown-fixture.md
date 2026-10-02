# C11-294 AC1 teardown fixture

`teardown_host.m` creates two real EXEC surfaces with AppKit views and PTYs. It verifies a child-generated ACK on the survivor, fills the shared app mailbox, starts OSC title output in the other PTY, observes an actual blocked mailbox producer, and calls the public `ghostty_surface_free` on main. It does not tick or otherwise drain the app mailbox between filling it and the free returning. Successful free exercises the production renderer-first and IO joins. The survivor must then generate a second ACK through its PTY.

A five-second readiness deadline rejects runs that never reach saturation. Free must return within five seconds for this cooperative shell fixture. SIGALRM ends a hang after 30 seconds; a separate runner process imposes a 40-second ceiling. Neither timeout releases mailbox capacity. The two NSViews stay unshown, and the host does not connect to c11 or load tenant config files.

This is the recorded app-mailbox/PTY-reader cycle. It does not establish separate search-worker, renderer-mailbox, IO-mailbox, or pending GPU-health saturation coverage. Queue waiter instrumentation proves a real producer is blocked but does not identify that producer's thread; the PTY deliberately emits unlimited distinct OSC titles to reach the reader path.

## Test-only integration

Link the host to the opt-in archive rooted at `ghostty/src/c11_read_test.zig`, not the shipping GhosttyKit. That root must export these two functions; they must remain absent from `include/ghostty.h` and the shipping `main_c.zig` root:

```c
uint32_t c11_test_fill_app_mailbox(ghostty_surface_t surface);
uint32_t c11_test_app_waiter_count(ghostty_surface_t surface);
```

The fill hook takes the actual `embedded.Surface.core_surface.app.mailbox`, pushes harmless unowned messages with `.instant` until no capacity remains, and returns its final count. `.redraw_surface = surface` is suitable: accepted entries are later discarded safely by the existing dead-surface membership check. Do not call the consumer, add a spill entry, resize the queue, or create a synthetic producer thread. The waiter hook locks that same queue's mutex, reads `not_full_waiters`, unlocks, and returns the value. No host call uses the doomed surface after public free returns.

The native-read agent owns the archive's build root. The parent owner must add these exports and make the resulting `libghostty-c11-read-test.a` available to the runner. Unresolved symbols are a build failure, never a skipped test or pass.

## Atlas run

On Atlas with an unlocked macOS GUI session, build the opt-in native fixture archive using the repository remote build procedure. Then run:

```sh
tests/ghostty_patchset/run-teardown-host.sh \
  /absolute/path/libghostty-c11-read-test.a \
  /absolute/path/ac1-evidence
```

The runner compiles only this Objective-C host against that archive and writes `teardown.log`. Preserve the exact Ghostty SHA, parent SHA, archive hash, host hash, complete log, process exit status, saturation count/waiters, and free duration with the run evidence. A passing host is behavioral native teardown evidence; it is not tagged c11 UI proof or the broader C11-270 soak.

Status when authored: source only; no build or execution performed. The two native hook exports require parent integration.
