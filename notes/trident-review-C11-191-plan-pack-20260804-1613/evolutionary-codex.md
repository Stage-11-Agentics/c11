### Executive Summary

The plan has found something more consequential than a noisy tab-bar preference pass: c11 currently lets a routine UI reconciliation synchronously enqueue an unbounded renderer command. The immediate fix should remove that main-thread wait, but the larger opportunity is to establish a **latest-desired-state delivery contract** for renderer control. Display selection is state, not an event stream. Treating it as an idempotent, coalescible state update eliminates this wedge class, preserves the last correct display when a renderer is behind, and creates a reusable boundary for focus, scale, occlusion, and topology reconciliation.

The plan should not ship as only “memoize in Swift plus `instant` and drop in Zig.” That combination can make the app responsive while silently losing the one display update that would restart a stuck display link. The durable design is: callers never wait; repeated values collapse before the bounded mailbox; a full mailbox retains/retries the newest desired value; and observability distinguishes requested, accepted, coalesced, dropped/retried, and applied state.

### What's Really Being Built

At its core this is a renderer-control-plane boundary. Today SwiftUI/AppKit lifecycle traffic is allowed to behave like a reliable, unbounded command producer into a capacity-64 renderer mailbox. C11-191 can turn that accidental coupling into an explicit rule:

- UI lifecycle calls may request renderer state but must never synchronously wait for renderer progress.
- State-bearing controls use last-value-wins semantics, rather than one queue item per lifecycle callback.
- Recovery-critical transitions are observable and eventually delivered, rather than “forced” by producing more duplicate queue entries.

That boundary is especially valuable in c11 because a single process owns many active renderers and many agent sessions. It protects the operator's control plane from an overloaded or wedged data plane.

### How It Could Be Better

1. Replace the two-layer partial solution with one explicit delivery primitive. A Swift `lastDisplayID` memo prevents ordinary repetition, but it cannot protect other FFI clients or guarantee eventual delivery after an `instant` enqueue fails. Put the coalescing ownership beside the renderer mailbox (or expose a narrow C API whose implementation owns it): maintain a pending/latest display ID, arrange at most one queued wakeup/work item, and have the renderer consume the latest value. This bounds work at one pending update per surface.

2. Do not make “notify first, then one instant push, log-and-drop” the final protocol without a race analysis. The renderer can wake, observe no new item, and sleep between those operations; conversely, an instant failure after a full queue must not discard the current desired display forever. A nonblocking implementation should either enqueue then notify on success (and notify/retry-coalesce when full), or use an atomic/locked latest-value slot plus a queued-drain flag. The invariant to document and test is: no caller waits, and the renderer eventually sees the most recently requested valid ID once it can make progress.

3. Define `force` semantically, not as a list of call sites. The plan correctly preserves the stuck-vsync repair behavior, but “force every deliberate unstick site” risks retaining a broad producer surface and obscures why reset is needed. Specify whether force means “reapply even when the ID is equal because the display link must restart,” whether it must survive mailbox pressure, and which state transition proves it was applied. In particular, a screen-change notification can carry the same ID, while a focus/topology transition may need a restart; those are different intents.

4. Make the memo commit only after the state has been accepted into the coalescing mechanism, and scope it to the Ghostty surface lifetime. A failed enqueue followed by `lastSent = id` is the exact silent-loss bug this change must avoid. Resetting solely on create/destroy is insufficiently precise unless the plan says what happens through deferred creation, headless bootstrap, teardown, and a reparent to the same `TerminalSurface`.

5. Preserve the plan's correction to the Sentry interpretation, but separate evidence quality from causality. The 13h58 wait at `attachSurface + 372`, disassembly, and `.forever` queue operation are compelling. The plan should label the tab-bar stack as a misleading trigger/context rather than claim that it demonstrates a “guard failing”; the meaningful contract is independent of which SwiftUI subtree causes `updateNSView`.

### Mutations and Wild Ideas

- **Per-surface renderer health ledger.** Record desired versus last-applied display ID, pending age, mailbox saturation count, renderer heartbeat, and last successful frame. A surface whose control plane stops advancing can be visually marked and selectively restarted without sacrificing the whole c11 process or its agent PTYs.

- **State mailbox, event mailbox.** Split renderer messages into coalescible state (`displayID`, visibility, scale, focus) and ordered events (input, clipboard, resize where ordering matters). The former becomes a compact snapshot drained each frame; the latter stays queued. This removes a category error that invites future “forever” calls.

- **Fuzzed lifecycle harness.** Rather than depend only on a hand-built 21-surface repro, generate randomized mount/unmount, screen/focus, split-close, and renderer-pause sequences with an instrumented tiny queue. Its oracle is not source text: every UI request returns promptly, the final desired state is eventually applied after unpausing, and no terminal remains in stuck-vsync state.

- **Degraded renderer mode.** If the renderer has not acknowledged state for a bounded interval, stop producing redundant control work and show a recoverable per-surface placeholder/diagnostic. The operator keeps the rest of the workspace and agents alive while one terminal recovers.

### What It Unlocks

Once state delivery is explicit, c11 can safely make portal reconciliation more aggressive without turning visual correctness into mailbox pressure. It also provides a reusable performance primitive for multi-monitor moves, rapid split churn, workspace restoration, and future renderer operations. The same metrics can distinguish a SwiftUI invalidation storm from a renderer stall, reducing the time from a Sentry hang signature to a root-cause-quality diagnosis.

For upstream Ghostty, a nonblocking coalesced state channel is more broadly useful than a c11-specific display-ID workaround. It is a credible upstream contribution because it protects every embedder from blocking an application/UI thread while retaining the final state they asked the renderer to use.

### Sequencing and Compounding

1. First write the invariants and choose the delivery contract: nonblocking caller, latest valid display ID eventually applied after renderer progress, explicit reapply/restart semantics, and safe surface teardown.
2. Implement that contract in the Ghostty fork with focused Zig tests that fill/pause the mailbox, verify immediate return, then release the consumer and verify application of the latest ID. Avoid a test that merely asserts a source-level `instant` token.
3. Add the narrow Swift adapter (`setDisplayID`) and route all existing display-ID producers through it. Instrument requested/coalesced/applied counts and one bounded pending-age measure; do not count only producer calls, which makes a drop look like success.
4. Exercise the c11 behavior: targeted logic tests for adapter semantics, then a tagged build with the many-surface/portal-churn scenario and a deliberate renderer-pressure hook if one can be made safe. Demonstrate both no main-thread wait and that focus, same-screen reparent, screen move, and split close still produce frames. The ticket's pre/post >1s reproduction requirement should remain an acceptance gate, not be replaced by static or seam-only proof.
5. Land the Ghostty change using the declared submodule workflow: commit and push it on a real fork branch before the parent pointer, verify its remote ancestry, update `docs/ghostty-fork.md`, and account for the generated GhosttyKit checksum/expected two-run CI pattern. Offer the general patch upstream before adding c11-only diagnostics.
6. Only after this is stable, consider the health ledger/recovery work as a follow-on. C11-186 remains the broader survivability ticket; C11-191 should not turn into an unbounded recovery redesign.

### The Flywheel

The proposed instrumentation can create a productive loop:

1. Lifecycle pressure produces a bounded set of state requests and records coalescing/pending age.
2. Renderer acknowledgements expose whether pressure came from UI churn, a slow renderer, or a dead renderer.
3. Those signatures drive deterministic stress cases and upstream-quality fixes.
4. Each new renderer state API adopts the same nonblocking/latest-wins contract, reducing new hang sources and improving the diagnostic corpus.

Accelerate it by making the metric names and invariants part of the embedded API's documentation, so future callers cannot casually reintroduce `.forever` from a main-actor path.

### Concrete Suggestions

- Change the implementation decision from “memoize and drop” to “coalesce and eventually deliver latest.” A compact API sketch is `ghostty_surface_request_display_id(surface, id, restart_if_same)`; it must return without waiting and own duplicate collapse internally.
- Add a renderer-side acknowledgement/observability seam suitable for tests and debug builds: requested ID, last applied ID, whether a drain is scheduled, and saturation/retry count. Keep release telemetry bounded.
- Audit every `ghostty_surface_set_display_id` call in `GhosttyTerminalView.swift`, including creation, reuse attach, reattach reconciliation, `forceRefresh`, focus, `viewDidMoveToWindow`, first responder, and `windowDidChangeScreen`. Route them through one adapter so there is no direct escape hatch around policy.
- Specify the failure behavior for invalid/zero IDs, surface free racing a pending drain, and a renderer that never drains. The first two must be safe no-ops; the third must not cause retries or logging to spin indefinitely.
- Add an integration assertion that a deliberately full renderer mailbox cannot delay `updateNSView` beyond a small scheduling budget, then assert the final display ID applies after the renderer resumes. This is the behavioral regression test closest to the incident.
- Use the Sentry follow-up as a measured release experiment: compare issue presence and affected-user count at a comparable install population, while correlating local pending-age/saturation diagnostics. Do not set “zero events” as the success condition, consistent with the outbound budget change.

### Questions for the Plan Author

1. Is a display-ID update allowed to be lost, or is “latest valid value eventually applied” required? If the latter, why does the proposed full-mailbox behavior intentionally drop it rather than coalesce it?
2. What exact race-free ordering/ownership will guarantee that a renderer does not sleep after a pre-push wakeup and miss the latest request?
3. What is the formal meaning of `force`, and which observed renderer state proves that a same-ID force actually restarted versus merely entered a full mailbox?
4. Can the coalescing primitive live in Ghostty so every embedding client receives the safety property, rather than relying on each client to maintain a correct Swift-side memo?
5. Which current `set_display_id` call sites are intentional state transitions, and which are accidental lifecycle repetition? Please enumerate them before editing so the audit has a finite completion criterion.
6. How will testing create real mailbox saturation/renderer pause and prove recovery without using implementation-shape tests or relying on an uncontrolled production-like load incident?
7. What is the safety policy when a pending display update outlives `ghostty_surface_free` or a reparent/deferred-create transition?
8. Is the proposed scope deliberately limited to the confirmed display-ID mailbox wait, with the older `SharedGridSet.ref` attach contention documented as a separate issue rather than conflated with this root cause?
