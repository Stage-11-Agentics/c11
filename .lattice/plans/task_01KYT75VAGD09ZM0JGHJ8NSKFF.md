# C11-187: Main-thread deadlock: attachSurface blocks on Ghostty lock from inside updateNSView

A lock-order inversion between the main thread and Ghostty's callback threads can wedge c11's main thread indefinitely. Observed once for ~14 continuous hours (pid 6063, 2026-07-29 02:00-16:00 UTC), ending only when the process died.

## Evidence

Captured by MainThreadHangMonitor in ~/Library/Logs/c11/hang.log. The event is 168 hang.begin + 9447 hang.persist records - the monitor re-reporting ONE hang every ~5s, not thousands of separate hangs. Max stalledMs = 50,305,478 (14h). Frame 0 is __ulock_wait2 in 9,413 of them.

Main-thread stack (PROVEN - captured 9,413 times):

    __ulock_wait2
     <- GhosttyNSView.attachSurface(_:)            Sources/GhosttyTerminalView.swift:4477
     <- GhosttyTerminalView.updateNSView(_:context:)
     <- SwiftUI PlatformViewRepresentableAdaptor.updateViewProvider
     <- AttributeGraph update -> NSHostingView.layout -> _NSViewLayout

## Mechanism (counterparty INFERRED, not directly observed)

- Main thread: SwiftUI layout -> updateNSView -> attachSurface -> ghostty_* C API calls
  (ghostty_surface_set_display_id, updateSurfaceSize, applySurfaceBackground,
  applySurfaceColorScheme) -> blocks acquiring Ghostty's internal surface lock.
- Ghostty thread: holds that lock while invoking an app-action callback ->
  performOnMain (Sources/GhosttyTerminalView.swift:1902) -> DispatchQueue.main.sync ->
  blocks waiting for main.

Each waits on the other. Permanent, matching the 14h signature. There are 21 performOnMain
call sites, all in the Ghostty action-callback path, so exposure is broad rather than one
unlucky callback.

Evidence quality: the main-thread half is proven from real captured stacks. The counterparty
is inferred from performOnMain's shape and call sites - the hang monitor only walks main's
stack. Proving the other half needs a full-process spindump taken while wedged.

## Related symptom

updateNSView doing blocking work inside SwiftUI's layout pass is also what emits the
'NSHostingView is being laid out reentrantly while rendering its SwiftUI content' warnings.
Those correlate 1:1 with workspace.selected events (6/6 on 2026-07-30), ~37 warnings/sec per
switch. Same anti-pattern, lower severity.

## Fix direction (not yet attempted)

attachSurface must not call into Ghostty synchronously from updateNSView. Either (a) defer
the Ghostty-touching work off the layout pass, or (b) make performOnMain non-blocking (async,
with callbacks tolerating deferral) so a Ghostty thread never waits on main while holding a
lock. (b) is more complete and more invasive - 21 call sites, some returning values that
cannot trivially become async.

## Validation bar

This is in the typing-latency hot path fenced off in CLAUDE.md. Needs a real repro harness
plus a typing-latency regression check before landing - a lock-inversion fix that cannot be
validated risks trading a deadlock for a data race. Risk profile favours long-running
instances: pid 6063 was alive from 07-27 and deadlocked ~14h in.

## Not related

The 2026-07-30 13:18 EDT beachball that triggered this investigation was NOT this bug - that
was machine-wide CPU starvation (load 315 on 16 cores), main thread idle in __CFRunLoopRun.
