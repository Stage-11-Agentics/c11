# C11-303 — bounded structural layout follow-up

Planning only; owner agent:astra-hangs. Clean base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`; branch `c11-1.0/C11-303-layout-followup`. No tests/builds/runtime observations yet.

## Verified incident and architecture

Read ticket/seeded plan, `05-bug-sweep.md`, ledger B056/B067, Fable C5, Astra section 2 and reconciled tiers. `Sources/Workspace.swift::installLayoutFollowUpObservers` at 10137 observes every NSWindow update. `flushWorkspaceWindowLayouts` at 10238 visits all windows and calls layout/display. `attemptEventDrivenLayoutFollowUp` retries automatically only after progress (10392); otherwise it relies on another event until the two-second timeout. Removing the observer alone can therefore strand an incomplete split.

B067's current immediate edge survives: `beginEventDrivenLayoutFollowUp` at 10129 calls the attempt synchronously; browser zoom entry/exit at 9598/9727 and geometry requests at 10476 reach it. The old split-tab-bar trigger changed, but this remaining synchronous path still warrants deferral. A nested-display hang is inferred, not reproduced. Upstream's 254–512 ms figures are not c11 measurements. C11-197/202/205 are the local hang records this producer may contribute to.

## Smallest change

Only `Sources/Workspace.swift` production code:

- Remove `NSWindow.didUpdateNotification` from follow-up observers. Keep actual surface-ready, host-moved, portal registry/visibility and panel/topology signals.
- Replace immediate begin→attempt with `scheduleLayoutFollowUpAttempt`, so a structural mutation cannot synchronously enter all-window display. All flushes remain behind the deferred attempt and its reentrancy guard.
- Schedule the next attempt whenever work remains, even after no progress, using the existing 10 ms exponential backoff capped at 250 ms. Preserve the existing two-second overall episode deadline; clear/cancel on convergence, removal or expiry. A new explicit structural request may start a new episode; incidental update notifications must not extend it.
- Reset backoff for a genuine new structural/ready event; do not turn notifications caused by our own attempt into zero-delay retry storms. Coalesce to one queued attempt. Fence delayed attempts by episode identity or cancelable work item so an old episode cannot run against a new one after clear/rearm.
- Preserve existing geometry/focus convergence logic and flush coverage in this PR. The fix is removing scroll-driven triggering and synchronous entry, not a new window-layout engine. No unbounded timer and no display link.

## Acceptance → incident/fixture → proof

1. **AC1 / B056 scroll fan-out:** On Atlas tagged build, create two real windows and stream/scroll one terminal while a structural follow-up is active. Existing DEBUG `ws.layoutFollowUp.attempt` timing plus a bounded flush counter must show attempts follow the retry schedule and stop after convergence/expiry, not one per scroll/window update. Scroll again after settlement: zero follow-up flushes until a new structural request. Record baseline/candidate counts and timing.
2. **AC2 / observer-removal regression:** Host behavioral fixture in `c11Tests/WorkspaceUnitTests.swift`: delay attach/usable bounds for the first attempts, then release; convergence succeeds without any didUpdate event. A permanently unavailable fixture stops by two seconds plus one scheduling turn; clearing/rearming rejects stale delayed callbacks. If policy timing needs extraction, use a tiny production retry-policy value type tested with a deterministic clock, not source assertions. Tagged CUA performs split, divider drag, resize and workspace switch; confirms final ratio/bounds, readable terminal size and unchanged intended focus. Exercise terminal and mixed browser workspaces because both enter the same follow-up.
3. **AC3 / C11-197/202/205:** During scrolling in another area, type into the focused terminal and capture visible input. Record main-task timing and p50/p95/p99 typing/switching latency versus C11-270's registered baseline/budgets on identical host/workload. Explicitly report any multi-hundred-ms scroll-associated main task; no borrowed upstream timings. A short paired sample is preliminary if soak is pending.
4. **B067 / immediate display edge:** Invoke the production begin path from a controlled layout callback in a host fixture. No follow-up flush occurs before that callback unwinds; a later turn still converges. Tagged split/zoom/switch path provides real UI evidence. If later rebasing removes the edge, document exact evidence and skip its now-redundant change.

## Gates and limits

No Hyperion builds/tests. Atlas path after C11-216 and BUILD MODE; post-C11-294 baseline when available, but no dependency on that bump. C11-270 owns final soak budgets and coverage. Tagged QA launch only; enumerate display, hard self-termination timer, synthesized dismissal and screenshots. Diagnostic dlog/counters stay DEBUG-gated. No source-grep tests.

No browser portal changes (C11-287/B014), terminal portal bind (B049), mount cap, sidebar, initial-ratio rewrite or native renderer loop. Do not change `forceRefresh` behavior, `hitTest`, `TabItemView`/row equality, socket telemetry threading or autoreleasepool boundaries. Main work decreases and remains required AppKit layout. No new UI strings, CLI/skill contract, persistence migration or tenant configuration. Open decisions: none. Review via Orchestrator, max three cycles; one PR, no merge/release.

## Reset 2026-10-02 by agent:luna-303
