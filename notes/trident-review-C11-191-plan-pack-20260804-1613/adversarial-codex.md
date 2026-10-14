# Adversarial review — C11-191 plan pack

## Executive Summary

**No-ship as written.** The diagnosis is compelling enough to justify investigation, but the plan converts a deadlock fix into a potentially lossy, unacknowledged display-state protocol without specifying the required correctness contract or proving the production failure mode. Its headline validation never exercises the ticket's acceptance case (a real multi-tab interaction that first stalls and then does not) and cannot establish that a dropped display-id message is harmless. The single largest issue is the proposed Ghostty `.instant`/drop change: it prevents the caller from wedging, but it may silently leave a renderer on the wrong display or with a stopped display link—the exact frozen-terminal regression the c11 code has repeatedly worked around.

## How Plans Like This Fail

1. **A credible post-hoc stack story becomes a complete causal claim.** The plan identifies `attachSurface + 372` as the return after `reconcileAttachedWindowIfNeeded`, but does not attach the symbol/disassembly procedure, UUID/build identity, or a capture that proves the sampled binary is exactly the release that emitted C11-30. The ticket’s 0.58.0+116 Sentry report, the plan’s installed binary, and the separate 0.60.1/CLI mismatch in `notes/BUG-main-thread-deadlock-attachSurface.md` make version provenance load-bearing, not clerical.
2. **A liveness repair regresses delivery semantics.** `ghostty_surface_set_display_id` currently makes delivery mandatory by blocking. Replacing it with best-effort delivery changes the API contract. A full queue is not an exceptional logging event if the message carries state that controls `CVDisplayLink`; it is an explicit state-loss branch that needs coalescing/last-value delivery, not merely a drop.
3. **The local mitigation hides rather than removes the root cause.** Memoizing equal IDs reduces one producer, but every remaining force path can still block on `.forever` until the Ghostty change lands. Conversely, once Ghostty drops, the memo can suppress the only retry for a display update that was discarded. Neither side alone supplies both non-blocking behavior and eventual convergence.
4. **A seam test proves the abstraction, not the runtime.** A test that counts a mocked push cannot prove that SwiftUI’s `updateNSView`, portal reparenting, focused display-link restart, queue saturation, and real renderer behavior remain correct together.

## Assumption Audit

| Assumption | Load-bearing? | Why it is unsafe or unproven |
| --- | --- | --- |
| The 9,413 local captures and the 941 Sentry events are the same incident/signature. | Yes | Similar outer AttributeGraph frames are not an identity proof. The plan needs matching release/build UUID, time range, and signature grouping. |
| The return address after the `bl` uniquely proves the caller was blocked inside `ghostty_surface_set_display_id`. | Yes | It is strong evidence, but only if ASLR slide, architecture, binary UUID, and exact function layout are documented. The plan gives none of those reproducible inputs. |
| The renderer is merely asleep and notifying before push lets it drain. | Yes | If the renderer is itself wedged, crashed, stopped, or blocked before consuming the mailbox, notify does nothing. The plan calls this a permanent deadlock but proposes no renderer-health/state observation. |
| A display-id update is safely discardable. | Yes | Existing comments at `GhosttyTerminalView.swift:3650`, `:3802`, `:3827`, and `:5256` say reassertion is required to recover stuck vsync. That is direct counter-evidence to silent drop being safe. |
| Equality of a `UInt32` display ID represents equality of the needed renderer state. | Yes | The plan itself says reassertion intentionally restarts the display link. Therefore equal ID does not mean no work is needed; the proposed `force` taxonomy is the product contract and is currently only asserted, not derived or validated. |
| All needed force sites have been found. | Yes | There are nine direct display-id calls today (`rg -n 'ghostty_surface_set_display_id\\(' Sources`), while the plan lists categories rather than exact call sites and ownership. A future direct call bypasses the memo entirely. |
| `attachToView` reuse is one of the two per-`updateNSView` producers. | No, but it weakens the design | `updateNSView` calls `GhosttyNSView.attachSurface`; when already attached it takes `reconcileAttachedWindowIfNeeded` (`Sources/GhosttyTerminalView.swift:4477-4493`). The reuse branch is reachable from other lifecycle paths, notably `viewDidMoveToWindow` (`:4517`), not demonstrably every SwiftUI update. The plan's traffic model is imprecise. |
| A logic test can instantiate the desired seam safely. | Medium | The repository explicitly warns that `Workspace`/`TabManager` construction can crash bare `c11-logic`; the plan never identifies a pure seam that avoids AppKit/Ghostty while still testing behavior worth having. |

## Blind Spots

- There is no implementation sequence across repositories. A Ghostty submodule edit requires a branch, push to the Stage11 fork before the parent pointer, a matching GhosttyKit build/checksum workflow, and an upstream decision. “Offer upstream” is not a delivery plan.
- The plan does not state whether C11-191 is allowed to change the Ghostty ABI/semantics, whether the two repos release atomically, or what happens if c11’s Swift change ships ahead of GhosttyKit. This is a split-release compatibility risk.
- There is no definition of success when `.instant` fails: metric, rate threshold, aggregation, debug/release logging policy, or an operator-visible recovery path. “log-and-drop” can create both a high-volume hot-path log and a hidden frozen surface.
- It omits queue ordering and coalescing. Display ID is last-value-wins state; a robust non-blocking design should preserve the latest pending ID (or offer a renderer-owned atomic/dirty bit), rather than rely on queue capacity and timing.
- It omits teardown races. A queued/late display-id message can target a renderer being stopped or a surface being freed. The current plan neither names the ownership/lifetime guarantees nor tests close/reopen during a saturated queue.
- It has no accessibility, multi-display, eGPU/DisplayLink, sleep/wake, monitor unplug, Space move, or rapid split-close scenario. Those are precisely the paths for which the existing forced reassertions were added.
- It does not meet the ticket’s stated before/after reproduction, nor does it define a reproducible saturation harness. Counting pushes per session is not a hang measurement and cannot detect a renderer that no longer receives the one push it needed.
- Release monitoring is absent. The ticket requires comparable-install-count Sentry issue/user-count interpretation; the plan does not define release cohort, observation window, baseline, dashboards/query, or rollback trigger.

## Challenged Decisions

### 1. Notify before `.instant` push

The ordering is asserted without proving the xev async’s wakeup semantics. More importantly, notification before a failed push can wake the renderer to find no new message, while a stalled renderer still cannot drain. The better question is not which order makes the current queue less likely to fill; it is how a state update becomes non-blocking **and eventually visible**. A coalesced latest-display-ID slot consumed by the renderer, plus a wakeup, is the natural counterproposal. If that is too invasive, a bounded retry/backoff or a deliberate recovery trigger needs an explicit UX and telemetry contract.

### 2. `TerminalSurface.setDisplayID(_:force:)` as the fix boundary

This centralizes calls only if all direct FFI call sites are removed and enforcement prevents new bypasses. The plan should name the exact nine sites, classify each as dedupe/force, and make the raw binding inaccessible outside the owner. Otherwise it adds a cache while leaving the dangerous API in general circulation.

The proposed cache reset also needs a precise state machine. Resetting on “surface create/destroy” is insufficiently defined when headless bootstrap, portal reparenting, an off-window deferred surface, and surface recreation are already distinct states. A reset at the wrong point can manufacture a redundant force; a reset missing a real renderer recreation can suppress the initial required update.

### 3. Preserving every existing `force: true`

This is an untested assumption, not a conservative choice. The stated root cause is an unbounded producer on the main thread. Keeping several unconditional force sites may retain a smaller but still user-visible blocking source until Ghostty is available, and once Ghostty drops messages it may preserve duplicate restart storms. Each force needs a named invariant (“screen changed”, “renderer recreated”, “focus transition after invalid pre-focus state”) and a runtime scenario.

### 4. “Generic, not c11-specific — offer upstream”

The upstream framing is reasonable, but the plan skips the difficult compatibility question: upstream may reject silent loss as semantically wrong. A generic fix may instead be an API that coalesces stateful renderer messages or distinguishes required commands from lossy hints. Do not implement a fork-only semantic change first and ask whether it was acceptable later.

## Hindsight Preview

The likely retrospective is: “we stopped beachballing, but terminals intermittently froze after monitor/sleep/split churn and had no actionable evidence because we chose to drop the state update.” Early warning signals the plan should pre-register are:

- nonzero dropped/coalesced display-ID updates, grouped per surface and renderer generation;
- a display-id requested/applied acknowledgement or renderer generation counter, so a missing application is observable;
- focused visible surfaces whose last display-ID request is not acknowledged within a bounded interval;
- post-release rate of stuck-vsync recovery reassertions, blank/stale frame reports, and Sentry hangs per active-user cohort;
- a tagged-build artifact showing main-thread latency under forced mailbox saturation, not just total push counts.

The other likely hindsight failure is that the ticket’s original reproduction was dismissed too completely. The plan may have found a more specific blocking call, but it does not show that the tab-bar preference pass is merely the scheduler that exposes it rather than an independently expensive regression. A fix can eliminate the futex hang and still leave the >1 s tab-bar interaction problem.

## Reality Stress Test

Assume all three happen together: a user closes/reparents several panes, moves c11 between displays, and one renderer is slowed by GPU/DisplayLink trouble.

1. SwiftUI continues `updateNSView`; memoization suppresses most equal-ID writes.
2. A real screen transition emits a force update while the mailbox is full. Under the proposed Ghostty change it drops.
3. The user focuses the pane; the focus force may also drop. The terminal stays attached but may retain a stale/no-vsync display link.
4. The app remains responsive, so no hang watchdog/Sentry event proves the defect. The operator sees a frozen surface and must discover an unrelated recovery gesture.

That is an improvement only if the plan proves renderer state converges after queue pressure clears. It currently supplies no such proof, recovery, or telemetry.

## The Uncomfortable Truths

- The plan is better at explaining one sampled wedge than at proving a safe production change.
- “Never block the caller” and “drop on full” are not equivalent to correctness. The first is mandatory; the second is a product decision with visible rendering consequences.
- The stated real-artifact test is largely a measurement of the intended implementation, not a test of the customer-facing failure. A push count can look excellent while a display link is dead.
- The plan treats the release telemetry result as passive validation, but 11 affected users and 13h58m wedges make a post-release discovery too expensive. The destructive case needs pre-release fault injection.

## Hard Questions for the Plan Author

1. What exact binary UUID, load address/ASLR slide, symbol file, and capture records prove the local `attachSurface + 372` samples correspond to the production C11-30 release rather than a later, independently similar wedge?
2. What is the explicit delivery contract of `ghostty_surface_set_display_id` after this change: best effort, eventually latest-value-wins, or guaranteed? If best effort, why is a stale display ID safe given the existing stuck-vsync comments?
3. When `.instant` returns zero, what mechanism ensures the latest display ID is eventually applied after the queue drains? “The next incidental force” is not an answer.
4. Why is wakeup-before-push correct for the renderer event-loop implementation, and what evidence rules out a lost/ineffective wakeup when the renderer is stalled?
5. List all nine current direct call sites and, for each, state why it is `force: true` or `false`, the renderer invariant it protects, and the runtime scenario that tests it.
6. Why does the plan describe `attachToView`’s reuse branch as a per-`updateNSView` producer when the current `attachSurface` already-attached path calls `reconcileAttachedWindowIfNeeded` instead? What is the measured producer count by call site before the patch?
7. What deterministic harness fills the **renderer** mailbox while exercising a real visible terminal, proves the main thread remains responsive, then proves display ID/vsync converges after pressure is removed?
8. How will the proposed logic test avoid merely testing a mock counter? What production behavior does its seam observe, and why does that behavior imply no main-thread wait or frozen renderer?
9. What is the implementation/release order for the Ghostty fork, GhosttyKit artifact/checksum, c11 parent pointer, and any upstream PR? Which combinations are supported during rollout and rollback?
10. What is the exact before/after reproduction that satisfies the ticket acceptance criterion, including threshold, machine/load configuration, artifact capture, and result when it fails to reproduce before the change?
11. What post-release cohort/query, observation window, and rollback trigger determine that C11-30 is not recurring, given the outbound Sentry budget and the ticket’s instruction to use issue/user presence rather than raw events?
