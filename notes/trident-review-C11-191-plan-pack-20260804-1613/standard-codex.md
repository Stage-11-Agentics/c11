# C11-191 Plan Review — Codex

## Executive Summary

This is a strong and important correction to the ticket: the evidence identifies a real, concrete main-thread wait in the Ghostty renderer mailbox, whereas the original Sentry-only tab-bar reading is not sufficiently symbolicated to justify a Bonsplit rewrite. The plan has the right two-layer shape: stop manufacturing redundant display-ID work in c11, and make the Ghostty C boundary nonblocking regardless of caller behavior.

It is not ready to execute quite yet. The proposed Ghostty `notify`-then-`.instant`-push-and-drop sequence can lose the one display-ID update that represents a real screen transition; c11's proposed memo would then suppress the retry that could repair it. The plan must define a lossless/coalescing delivery contract and test that contract, not merely count calls at the Swift memo seam.

## The Plan's Intent vs. Its Execution

The actual objective is not “make the tab bar cheaper.” It is “ensure a SwiftUI update can never synchronously wait behind a renderer thread, while preserving display-link recovery across portal and screen transitions.” The corrected diagnosis serves that objective very well: the sampled return address, the direct `.forever` queue push, and the long-lived `__ulock_wait2` signature connect the apparent SwiftUI preference frame to the blocking boundary.

The c11 half also matches the evidence. `updateNSView` repeatedly calls `hostedView.attachSurface`, and the reuse and reconciliation paths currently call `ghostty_surface_set_display_id` unconditionally. Deduplicating unchanged IDs removes the ordinary source of pressure, but it cannot be the safety guarantee: a future caller, a missed call site, or a new binding must still be unable to wedge the main thread.

## Architectural Assessment

The right invariant belongs at the Ghostty API boundary: `ghostty_surface_set_display_id` must have bounded, nonblocking behavior for every caller. The c11 memo is then an optimization and a reduction in churn, rather than the mechanism that makes the application safe.

However, display ID is state, not an edge-triggered event where loss is automatically harmless. A full renderer queue can safely collapse repeated requests only if it guarantees eventual application of the *latest* ID after the renderer resumes. “Log and drop” does not make that guarantee. It becomes particularly risky when the c11 memo marks the ID as sent before it knows the renderer accepted it: the only subsequent `force: false` reconciliation is suppressed, leaving the renderer associated with the old display.

The notification ordering needs the same precision. Waking before enqueueing can create a lost-wakeup window: the renderer may drain and return to waiting between the wake and the subsequent successful push. If the successful enqueue does not notify again, that message can remain pending until an unrelated wakeup. A nonblocking implementation should establish and document an ordering that cannot strand a newly enqueued message.

## Is This the Move?

Yes, with the delivery contract repaired. Reworking Bonsplit's preference machinery from the original ticket would treat the reporting context as cause and risk a broad typing-latency regression without addressing the independently proven futex wait. Moving `attachSurface` asynchronously, as the older investigation suggested, is also not the primary fix for this particular trace: it hides a blocking API behind scheduling and complicates surface lifecycle, while other callers could still block. The mailbox API must be made safe first.

I would sequence this as: define/test Ghostty's coalesced nonblocking display-ID handoff; land it in the fork and push it to the Ghostty remote; update c11 to use one explicitly named `setDisplayID` policy helper; then prove the real portal/screen/focus recovery paths on a tagged build. The c11 memo can land in the same change only after the force policy has an auditable call-site inventory.

## Key Strengths

- The plan rejects an attractive but weak stack-symbol narrative using stronger local evidence. That is exactly the right standard for a production hang investigation.
- It distinguishes remediation from prevention. Reducing duplicate sends fixes the pressure source; changing `.forever` at the FFI boundary removes the catastrophic failure mode.
- It preserves the deliberately redundant display-ID assertions that historically recover stuck vsync. Treating those as semantic recovery points rather than indiscriminate duplication is the correct direction.
- It proposes both deterministic and runtime evidence, and correctly treats the existing hang corpus as causal evidence rather than pretending a synthetic SwiftUI benchmark alone proves the production failure.

## Weaknesses and Gaps

1. **The plan permits loss without specifying eventual convergence.** A full queue plus a dropped transition to a new display can leave the renderer's display link on the old display. The memo's “last sent” value is then wrong from the renderer's perspective. Define whether the C API reports acceptance, whether it stores a pending/latest display ID, or whether the renderer mailbox coalesces this message type. The desired end state must be eventually applied after a renderer recovery.

2. **The proposed notification order is unsafe as written.** “Notify first, then push `.instant`” does not by itself ensure a successful later push wakes the consumer. State the exact algorithm and prove its wakeup behavior. A likely shape is a lock-protected/latest-value coalescing slot plus notification after publishing, or an immediate push followed by notification, with a deliberate nonblocking retry/coalescing path when full. The final design should be reviewed in the context of Ghostty's event-loop wake primitive rather than assumed from queue behavior.

3. **The test plan does not cover the fault boundary.** A `c11LogicTests` memo test can prove Swift call suppression, but it cannot prove that `ghostty_surface_set_display_id` never waits, that a full mailbox does not lose the final requested ID, or that a wake is not lost. Add focused Ghostty tests for a full queue and for latest-ID convergence after drain. If the Swift test needs a seam, keep it a small behavioral counter/dispatcher seam; do not construct AppKit `TerminalSurface` in bare logic tests.

4. **The force taxonomy is asserted, not enumerated.** The source has display-ID calls in reconciliation, attach reuse/reparent, creation, topology refresh, `TerminalSurface.setFocus`, `GhosttyNSView.viewDidMoveToWindow`, `becomeFirstResponder`, and `windowDidChangeScreen`. The plan names categories but not the exact mapping, including the two independent focus paths. It needs a caller-by-caller table with intended `force` value and why, then a search-based audit that no direct C calls remain outside the policy helper.

5. **Memo lifecycle and stale-state behavior are underspecified.** “Resets on create/destroy” does not say what happens when `ghostty_surface_new` fails, a surface pointer is replaced, attachment moves to the headless startup window, a display ID is unavailable, or a request is rejected/dropped. The memo must be tied to the lifetime of the specific Ghostty surface and must only advance on an accepted/coalesced request, not merely on an attempted FFI call.

6. **The runtime validation is too vague for this severity.** “Count pushes per session” needs an instrumentation plan: the exact counter/log source, expected baseline and post-change counts for N `updateNSView` passes, and how it distinguishes intentional force requests. It also needs a real tagged-build portal churn + screen/focus recovery scenario, because a reduction in messages is a regression if it revives stuck-vsync/no-frames.

7. **The cross-repository delivery steps are missing.** This changes the Ghostty submodule. The implementation plan needs the required submodule branch/commit/push to the Stage-11 Ghostty fork before the parent pointer update, an upstream PR/issue handoff, the parent commit, and the GhosttyKit checksum/CI sequence. Otherwise a correct local submodule change can be stranded or produce predictable but confusing guard failures.

## Alternatives Considered

### Only memoize in c11

This reduces ordinary traffic but leaves a `.forever` API reachable from every existing and future caller. It is insufficient as a safety boundary and should not be accepted alone.

### Make every display-ID message an instant push and drop it when full

This resolves the main-thread wedge but weakens correctness during the exact degraded state where recovery matters. It is acceptable only if the implementation coalesces the latest desired display ID somewhere durable and guarantees a later drain observes it.

### Move attachment off-main

This could reduce visible hangs but changes ordering, focus, portal ownership, and teardown semantics. It also leaves other FFI callers exposed. Keep it as a separately justified lifecycle redesign, not as the C11-191 fix.

### Coalesce display ID at the renderer-thread boundary

This is the strongest alternative to a general queue change: maintain one latest pending display ID per renderer surface, wake nonblockingly, and consume it before or alongside mailbox processing. It preserves last-write-wins semantics, bounds work, and avoids relying on the producer to retry. Its concurrency ownership and teardown safety need explicit design, but it best matches the data's state-like semantics.

## Readiness Verdict

**Needs revision before execution.** The diagnosis and overall decomposition should stand. Revise the Ghostty portion to specify a nonblocking, eventual-latest-value delivery mechanism and wake ordering; add direct Ghostty fault tests; provide an exhaustive c11 caller/force/memo-lifetime table; and add the submodule/upstream/tagged-runtime delivery steps. Once those are present, this is a high-confidence, narrowly targeted plan.

## Questions for the Plan Author

1. What exact mechanism guarantees that the newest display ID reaches the renderer after a full mailbox drains, rather than being permanently dropped?
2. Does the proposed c11 memo advance only after a request is accepted/coalesced by Ghostty? If not, how does a rejected request get retried?
3. What is the exact wakeup ordering, and what prevents a renderer from returning to wait between a pre-push notify and a successful push?
4. Will display-ID messages be coalesced in the renderer mailbox, in an atomic/pending slot, or via an acknowledgement-bearing API? What are the synchronization and teardown rules for that state?
5. Please provide the exact source-location table for all current `ghostty_surface_set_display_id` calls, their `force` policy, and the user-visible recovery scenario each `force: true` preserves.
6. Which path owns the memo when `ghostty_surface_new` fails or replaces the surface pointer, and how is headless-startup-window to real-window migration represented?
7. Can the planned `c11LogicTests` seam run without constructing `Workspace`, `TabManager`, or AppKit terminal views in the bare xctest runner? What behavior will it observe besides an internal call count?
8. What Ghostty-level test will fill the renderer mailbox, invoke display-ID update from a producer thread, prove prompt return, drain it, and assert the final display ID was applied?
9. How will the tagged build instrument intentional versus deduplicated versus rejected/coalesced display-ID requests, and what numerical before/after assertion defines success?
10. What portal churn, focus recovery, and cross-screen movement flow will demonstrate that the historic stuck-vsync workaround remains intact on the tagged build?
11. Which Ghostty fork branch/remote and upstream issue or PR will carry the generic fix, and who owns pushing it before the c11 submodule pointer changes?
12. How will the plan handle the required GhosttyKit checksum workflow and distinguish its expected first-run guard failures from a real regression?
