# C11-217 implementation plan

Move `browser.eval`, `browser.wait`, and `browser.download.wait` into the
socket-worker policy and add explicit worker dispatch cases. These are the
browser wait/eval endpoints that can hold a caller for a caller-sized timeout.
Keep navigation, focus, tab/workspace, selector-action, snapshot, cookie,
screenshot, state, and unsupported browser handlers on their existing
main-actor route: they perform synchronous AppKit/WebKit/model mutations and a
broad rewrite would be unrelated to this acceptance seam.

Make the three moved handlers `nonisolated`. Each first runs a short
`Task { @MainActor }` phase that refreshes handle refs, resolves the
TabManager/workspace/surface, performs the C11-209 document guard, snapshots
the frame selector, and builds the response envelope. The worker then builds
the existing JS wrapper from that snapshot and waits with the semaphore branch
of `v2AwaitCallback`. WebKit evaluation is submitted with
`DispatchQueue.main.async`, so it starts on WebKit's required main thread while
the worker—not `v2MainSync`—waits for completion. Share pure wrapper/decode
helpers between the old main runner and the new off-main runner; do not read
actor state from the worker.

Use a lock/once cancellation gate: a timeout marks the request cancelled,
prevents a queued main invocation from starting, and ignores late WebKit
completion. Preserve the monotonic timeout, the existing wait condition and
one-second Swift grace, eval result normalization, and isolated-world retry.

Run `browser.download.wait`'s path watcher and notification wait on the
worker after main-phase surface validation. Preserve C11-222's serial-queue
state confinement, descriptor ownership/cancel-handler closure,
single-terminal-path, idempotent teardown, and waiter-observer removal. Pop
observed events in a short main phase so the controller queue remains the
single source of truth.

Also route legacy v1 `send`, `send_key`, `send_surface`, and `send_key_surface`
through worker phases that use the existing `waitForTerminalSurfaceOffMain`,
then re-hop to main to revalidate and inject. This removes the legacy
main-queue notification wait from socket-reachable paths without changing
unrelated terminal commands.

Add behavioral policy/await coverage for worker routing, timeout/late-result
cancellation, and independent concurrent waits where a host-free seam can
exercise it; retain the C11-209 pump and C11-222 watcher tests. Validate with a
lock-wrapped tagged build and QA socket probe: capture the 10.0 s pre-change
loaded-page `tree` baseline, then prove `tree` under 1 s during an unmet 20 s
wait, fast `no_document`, 120 s cap, loaded eval, early download completion,
and two simultaneous waits. Do not run local `xcodebuild test`, launch an
untagged app, modify Ghostty or `.lattice/`, merge, deploy, or claim browser
proof from source/tests alone.
