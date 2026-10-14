# Evolutionary Review Synthesis: C11-191 Plan

**Plan:** `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md` (C11-191)
**Sources:** `evolutionary-claude.md`, `evolutionary-codex.md`, `evolutionary-gemini.md`
**Posture:** evolutionary. Not "is this correct" but "what should this become."
**Synthesized:** 2026-08-04

---

## Executive Summary

All three models agree on the plan's central achievement and on its central under-reach, and they agree with unusual precision.

**The achievement:** the plan refused the ticket's Sentry-derived reading, went to a 151 MB local hang corpus, and resolved a return address by disassembling the shipped release binary down to an exact `bl` target. The root cause is proven rather than argued. Every reviewer treats this as high-grade work and none of them contests the diagnosis.

**The under-reach, stated three different ways but converging on one thing:** the plan spends a class-level finding on an instance-level deliverable. What was actually discovered is that c11's UI thread is an unbounded, synchronous producer into a bounded renderer mailbox drained by a thread it does not control. `ghostty_surface_set_display_id` is one door in a corridor of doors. Claude enumerates the siblings (`set_occlusion`, `set_focus`, same 64-slot mailbox, same `.forever` push, occlusion missing the dedupe its focus sibling already has). Gemini names a second, already-documented deadlock on the same path (`ghostty_surface_new` blocking on `SharedGridSet` lock contention, per `notes/BUG-main-thread-deadlock-attachSurface.md`), which the display-id memo does nothing for. Codex generalizes to the category error: state-bearing controls (display ID, focus, occlusion, scale) are being shipped through an ordered event queue when they want last-value-wins semantics.

**The one design objection all three raise independently, and the most important output of this review:** "log-and-drop on a full mailbox" is not safe. Drop the message and the renderer, once it drains, never learns its correct display ID and stays on a stale or absent display link. The plan's own Swift memo makes this worse: it records `lastDisplayID = id` at push time, so after a drop (or after `setMacOSDisplayID`'s silent early-return on `setCurrentCGDisplay` failure or a null display link) every subsequent `force: false` call is suppressed as redundant. That trades a 2.3 s hang for an intermittently and *silently* frozen pane, which is worse from the operator's seat. The unconditional re-assertion the plan removes is the thing currently papering over that failure mode. All three converge on the replacement: **coalesce and eventually deliver the latest desired value, do not drop it, and own the coalescing in ghostty rather than in a Swift shadow memo.**

**The one-line version:** keep the diagnosis, invert the emphasis. Ship the ghostty half as the primary fix, generalized from one export to a nonblocking latest-wins state channel for every app-thread-reachable export. Demote the Swift memo to a thin adapter that passes intent rather than maintaining shadow state. Add the one behavioral test the plan is missing (fill the mailbox, assert the call returns, release the consumer, assert the latest value applies). Then harvest the method: the forensic technique, the corpus, and the Sentry symbolication defect are each worth more than the bug fix.

---

## 1. Consensus Direction

Evolution paths that two or three models identified independently.

1. **Fix the class at the FFI boundary, not the instance at one call site.** (All three.) The deliverable should be an invariant: no exported `ghostty_*` function reachable from the host UI thread may perform an unbounded blocking wait. Claude scopes this to the sibling exports; Codex scopes it to a delivery contract; Gemini scopes it to moving all Ghostty interaction off main. Same direction, three radii.

2. **Replace "log-and-drop" with "coalesce and eventually deliver latest."** (All three, each flagging it as a correctness hazard rather than a preference.) Display selection is state, not an event. The renderer must eventually observe the most recently requested valid ID once it can make progress. A dropped message plus a Swift memo that already committed is silent, permanent divergence.

3. **The coalescing belongs in ghostty, not in Swift.** (Claude, Codex explicitly; Gemini implicitly via the pull-model proposal.) A Swift-side memo protects only c11, cannot observe whether the value was applied, and creates a shadow-state-drift bug class of its own. Claude's concrete route: grow the export to `ghostty_surface_set_display_id(surface, id, force)` and dedupe inside `setMacOSDisplayID` *after* a successful `setCurrentCGDisplay`, mirroring what `Surface.zig:3348` already does for focus. Codex's: `ghostty_surface_request_display_id(surface, id, restart_if_same)` owning duplicate collapse internally.

4. **`force` needs a semantic definition, not a call-site inventory.** (Claude, Codex.) The plan preserves stuck-vsync repair by listing five sites that keep `force: true`. Both reviewers argue the intent should be expressed at the API boundary instead. Codex adds the sharp distinction: a screen-change notification can carry the *same* ID while a focus/topology transition may genuinely need a link restart, and those are different intents that the current API cannot distinguish, which is exactly why c11 ended up expressing "restart" by spamming the call.

5. **The ticket's reproduction acceptance criterion should stay a gate.** (Claude, Codex.) The disassembly is stronger evidence of *cause* than a repro would be, but it cannot fail in CI in 2027 when someone reintroduces a blocking push. Both push for a behavioral test that creates real mailbox saturation. Both explicitly warn against source-shape tests (asserting an `.instant` token in source text), which `CLAUDE.md`'s test-quality policy already forbids.

6. **Instrumentation should be permanent, not disposable.** (Claude, Codex.) "Count `macos_display_id` pushes per session before/after" names no mechanism and expires the moment the PR merges. Codex adds the trap: counting only producer calls makes a *drop* look like a *success*. The counters that matter are requested / coalesced / dropped-or-retried / applied, plus pending age.

7. **This is an upstream-class contribution, not a c11 patch.** (All three.) A nonblocking coalesced state channel protects every libghostty embedder, including cmux. Claude proposes bundling it as a themed set (nonblocking pushes, the missing occlusion dedupe, and the `SharedGridSet.ref` / `SharedGrid` lock findings already sitting unclaimed in the BUG note) rather than three orphan patches, which also retires three private divergences in shared code at once.

8. **Recovery, not just prevention.** (All three, at different ambition levels.) Codex: a degraded renderer mode with a per-surface placeholder. Gemini: "Zombie Terminal Mode" plus a `c11 force-detach-surface` socket command. Claude: a self-healing watchdog that notifies wedged renderer threads. All three note the same enabling fact: the c11 control socket survives these wedges, so the process is reachable while a pane is dead. All three also agree this belongs to C11-186, not C11-191.

---

## 2. Best Concrete Suggestions

Ranked by value per unit of effort, merged across all three reviews. Items 1 through 5 are in-scope for C11-191 as written or nearly so.

1. **Grow the export to carry intent and own the dedupe: `ghostty_surface_set_display_id(surface, id, force)`.** Notify appropriately, nonblocking enqueue, coalesce duplicates internally, dedupe inside `setMacOSDisplayID` *after* a successful `setCurrentCGDisplay`. This makes the c11 side a two-line call-site change instead of a memo with a stranding hazard, and it deletes the shadow-state bug class entirely. (Claude #1, Codex's `request_display_id`.)

2. **One Zig test that gates the actual bug.** Construct a surface, stop draining the renderer mailbox, fill it to 64, call the export, assert it returns promptly. Then release the consumer and assert the *latest* requested ID is applied. This is the only proposed test that gates the deadlock rather than the optimization, and it is the behavioral regression test closest to the incident. (Claude #3, Codex step 2 and suggestion 5.)

3. **Apply the same treatment to `ghostty_surface_set_occlusion` and `ghostty_surface_set_focus`, and add the missing `if (self.visible == visible) return;` guard to `occlusionCallback`.** Same file, same afternoon. Occlusion is the closest twin to the bug being fixed: `.forever` push, push-before-notify, no dedupe, and it fires on window visibility, workspace switching, and portal churn, which is exactly the high-churn regime the plan's own evidence comes from. Without this, C11-191 closes and the same deadlock returns through a different fingerprint and gets triaged as a new bug. (Claude #2.)

4. **Route every display-ID producer through one Swift adapter with no escape hatch.** Codex's audit list: creation, reuse attach, reattach reconciliation, `forceRefresh`, focus, `viewDidMoveToWindow`, first responder, `windowDidChangeScreen`. Enumerate *before* editing so the audit has a finite completion criterion. (Codex suggestion 3.)

5. **Specify and test the ugly edges.** Invalid or zero IDs, surface free racing a pending drain, a pending update outliving `ghostty_surface_free`, a reparent to the same `TerminalSurface`, deferred creation, headless bootstrap, teardown. First two must be safe no-ops. A renderer that never drains must not spin retries or logging. "Memo resets on surface create/destroy" is under-specified against this list. (Codex suggestions 4 and 7.)

6. **A debug-build assertion in `BlockingQueue.push`: `.forever` from the registered app thread is a programmer error.** Converts an invariant that currently lives in a code comment into something a test run can fail on. (Claude #5.)

7. **`scripts/hang-triage.py`: turn the 151 MB corpus into a ranked report.** Cluster by `(leaf, frame1, frame2)`, rank by **total wedged wall-clock time**, not capture count (one 13h58m episode outweighs 5000 blips, and count-ranking would have hidden it), emit fingerprint / episodes / total wedged / worst episode / first-last seen / affected pids. Standalone, no dependency on the fix, and its output *is* the quantitative before/after that C11-191's acceptance criterion needs. Signature #2 then costs minutes instead of a day. (Claude M2 / #4.)

8. **Rotate and dedupe `hang.log`.** One episode wrote 9412 consecutive captures at roughly 7 KB each, about 66 MB from a single hang, and the operator's log is 151 MB unrotated. Every release-build user is accumulating this. Write frames once at `hang.begin` and emit delta lines on `hang.persist` when the fingerprint is unchanged. A shipping defect this plan walked past, and it makes the triage corpus cheaper to parse rather than more expensive. (Claude M5 / #6.)

9. **On-device Sentry fingerprinting plus raw `image + slide` addresses for server-side symbolication.** The plan *proves* c11's outbound stacks contain impossible frames and untrustworthy symbol names. Since #401 cut event volume, the team now judges recurrence by issue presence and user count, which makes grouping correctness load-bearing in a way it was not before: if the fingerprint is noise, "issue does not recur" is evidence of nothing. Separate ticket, but file it now with this plan's evidence attached, because that evidence is the strongest argument for it that will ever exist. (Claude M1 / #8.)

10. **Write the `c11-hang-forensics` skill while the incantation is still in scrollback.** Sentry fingerprint → local hang log → symbol + offset → `objdump` the *installed release* binary → exact `bl` target → source. Six paragraphs. Turns a one-day investigation into a twenty-minute one, forever, for every agent on the fleet. `CLAUDE.md` is already explicit that generalizable tool learnings go in a skill, not a memory. (Claude M7 / #7.)

11. **Permanent per-surface counters surfaced through `c11 tree --json` or the debug window:** requested, coalesced, dropped/retried, applied, pending age, mailbox saturation count. Same effort as the disposable measurement, infinite shelf life, and it makes the next `updateNSView` regression visible before it becomes a Sentry issue. (Claude #9, Codex suggestion 2.)

12. **Frame the Sentry follow-up as a measured release experiment, not a zero-events target.** Compare issue presence and affected-user count at a comparable install population, correlated against local pending-age and saturation diagnostics. Consistent with the outbound budget change in #401. (Codex suggestion 6.)

---

## 3. Wildest Mutations

Most creative or ambitious ideas, roughly ascending in risk. None of these should hold C11-191.

1. **State mailbox versus event mailbox.** (Codex.) Split renderer messages into coalescible *state* (display ID, visibility, scale, focus) and ordered *events* (input, clipboard, resize where ordering matters). State becomes a compact snapshot drained each frame; events stay queued. This removes the category error that invites future `.forever` calls rather than patching its instances.

2. **The shared-memory config block.** (Gemini.) Push the same idea further: put continuous UI state in a lock-free atomic struct that the renderer pulls on its next loop, and use the mailbox only for a lightweight "config changed" ping. Collapses 10,000 redundant updates into a single atomic write and structurally eliminates the "UI state mailbox full" deadlock class forever. Gemini frames this as the better *upstream architectural proposal* than tweaking push behavior.

3. **`SurfaceDesiredState`: kill the whole reconciler class.** (Claude M4.) `updateNSView` should compute one `Equatable` desired-state value, diff it against last-applied, and cross into native code only for changed fields. Today it unconditionally calls `attachSurface`, `setFocusHandler`, `setTriggerFlashHandler`, `setInactiveOverlay`, `setNotificationRing`, `setSearchOverlay`, `attachPaneInteraction`, and `syncKeyStateIndicator` on every pass with ad-hoc guards scattered underneath. One struct plus one diff replaces N hand-written guards, and per `CLAUDE.md` this path pays a second dividend in keystroke latency. The display-id memo is instance one of a pattern with seven or eight more instances in the same function.

4. **`GhosttyBridge` actor: move the whole FFI boundary off main.** (Gemini #1.) A dedicated serial queue or `@globalActor` serializing all calls to Zig, with `updateNSView` firing `Task { @GhosttyBridge in ... }` instead of calling `attachSurface` synchronously. This is the only proposal that catches *both* the mailbox deadlock and the `SharedGridSet` font-grid deadlock in one move, because it stops caring which Zig call blocks.

5. **The self-healing watchdog.** (Claude M3.) The watchdog thread already suspends main and knows exactly where it is wedged. Give it a signature allowlist and one action: for a wedge whose leaf is `__ulock_wait2` inside a surface path, call `wakeup.notify()` on every live surface's renderer thread. The renderer drains, `cond_not_full` signals, main proceeds. It recovers from blocking pushes nobody has found yet, including future ones. The watchdog stops being a reporter and becomes a supervisor. Gate it hard: only after N seconds wedged, only on an allowlist, log every intervention.

6. **Zombie Terminal Mode / degraded renderer mode.** (Gemini #2, Codex.) When a renderer stops acknowledging state for a bounded interval, detach the UI from it and show a recoverable "Ghostty Unresponsive: [Restart] [Debug]" per-surface overlay. The agent underneath is almost certainly still running and reachable via the c11 socket, so a catastrophic app wedge becomes a localized, manageable UI event. Pairs with Gemini's `c11 force-detach-surface --surface <ref>` off-main socket command, which lets an operator or a watchdog script nuke a wedged pane without force-quitting.

7. **Per-surface renderer health ledger.** (Codex.) Desired versus last-applied display ID, pending age, mailbox saturation count, renderer heartbeat, last successful frame. Makes "is this a SwiftUI invalidation storm or a renderer stall?" a lookup instead of an investigation, and is the data substrate every recovery idea above needs.

8. **Fuzzed lifecycle harness / adversarial hang fuzzing.** (Codex, Claude M8.) You now know the failure shape: bounded queue plus slow consumer plus unbounded UI-thread producer. That is fuzzable. Randomize mount/unmount, screen/focus change, split-close, and renderer-pause sequences against an instrumented tiny queue; or add a debug-only mode that randomly stalls renderer drains for 50 to 500 ms and run the existing portal-churn harness (`scripts/repro-c11-18.sh`) over it. The oracle is behavioral, not textual: every UI request returns promptly, the final desired state applies after unpausing, no terminal is left in stuck-vsync. Setup cost is low and the failure signal (`hang.begin`) already exists.

9. **The out-of-process renderer, the Chrome model.** (Gemini #3.) Ghostty surfaces in a separate XPC service, guaranteeing main-app stability at the OS level. Enormous, almost certainly not worth it, and included because it is the honest logical endpoint of the decoupling direction all three reviews point at. Worth knowing where the road goes even if you never drive it.

10. **Headless-first resilience.** (Gemini.) If the UI is genuinely decoupled from terminal state, the terminal can run headlessly and attach or detach from a UI on the fly. Roaming sessions, remote UI attachment. A downstream consequence of the decoupling, not a project.

---

## 4. Flywheel Opportunities

Self-reinforcing loops identified across the reviews, ordered by how close each is to spinning.

1. **The forensics flywheel (Claude), already one turn in.** Better local forensics → correct root cause → correct fix → fewer misdirected tickets → more trust in the corpus → more willingness to mine it → better forensics. The plan just completed one full turn: it distrusted a Sentry reading, went to the local corpus, and got a provable answer. The turn cost a day because the method was improvised. Two cheap changes make every subsequent turn cheap: the `c11-hang-forensics` skill removes the improvisation cost, and `hang-triage` removes the search cost.

2. **The honest-board flywheel (Claude), currently broken at the first joint.** Correct on-device fingerprints → Sentry groups by true signature → issue rank reflects real operator pain → fixing the top issue actually helps the most users → the board stays honest. Today the fingerprint is built from symbols this plan proved are wrong, so the loop does not close. C11-191 is the demonstration that it is broken. This is the highest-leverage single change adjacent to the plan, because it is the difference between a triage pipeline and a random number generator with a nice UI.

3. **Joining loops 1 and 2 is where it gets good.** If on-device fingerprinting lands, the remote population's stacks look like the operator's local ones, and `hang-triage` can run over Sentry data instead of one machine's `hang.log`. The corpus becomes the whole user base rather than one operator, and "total main-thread wedged seconds per hour of use" becomes a real product-quality metric and a release gate, in the same family as the typing-latency guardrails already in `CLAUDE.md`. The project currently has no quantitative main-thread-responsiveness metric at all.

4. **The instrumentation flywheel (Codex).** Lifecycle pressure produces a bounded set of state requests and records coalescing plus pending age → renderer acknowledgements expose whether pressure came from UI churn, a slow renderer, or a dead renderer → those signatures drive deterministic stress cases and upstream-quality fixes → each new renderer state API adopts the same nonblocking latest-wins contract, reducing new hang sources and improving the diagnostic corpus. Codex's accelerant: put the metric names and invariants in the embedded API's *documentation*, so a future caller cannot casually reintroduce `.forever` from a main-actor path.

5. **The resilience flywheel (Gemini).** Decoupled UI means the app never wedges → the operator confidently runs more agents simultaneously → increased concurrency stresses the renderer harder → Ghostty bugs surface as isolated pane hangs rather than full-app wedges → agents and maintainers use `c11-computer-use` and socket commands to auto-recover, report, and debug those panes → faster iteration on renderer stability. Fixing the isolation layer creates a safe environment in which to find every other Ghostty bottleneck.

6. **The upstream-standing flywheel (Claude, Codex).** A themed embedding-safety contribution set earns merge goodwill in both directions, which per `CLAUDE.md` is strategic leverage for every future merge, which makes the next contribution cheaper. Bundling the nonblocking pushes, the occlusion dedupe, and the `SharedGridSet` lock findings retires three private divergences in shared code at once instead of accruing them.

---

## 5. Where the Reviews Disagree

Worth surfacing explicitly, because the disagreement is about sequencing and the plan has to pick one.

1. **Ghostty first or c11 first?** Gemini says ship the Swift memo immediately to "stop the bleeding" on 941 events, then do the real fix. Claude argues the exact inverse and gives four reasons: the ghostty half is the one that makes the failure *impossible* while the memo only makes it less likely; every `force: true` site the plan preserves still performs an unbounded blocking push; the ghostty half has the longest CI tail (submodule bump, checksum commit, ~10 min Zig build, expected run-1-red pattern) so starting it first parallelizes the wait; and the memo's *correct* design depends on the ghostty change, since doing Swift first commits you to the optimistic-memo design that has the stranding hazard. Codex threads the needle: write the invariants and choose the delivery contract *first* (a document, not code), then ghostty, then a thin Swift adapter. Claude's argument is the strongest on the merits, and Codex's ordering is the safest expression of it.

2. **How radical should the boundary change be?** Claude scopes to "nonblocking at every app-thread-reachable export," which is roughly half a day beyond the current plan. Codex scopes to a documented delivery contract with a coalescing primitive. Gemini scopes to moving all FFI off the main thread via an actor, which is the only proposal that also catches the `SharedGridSet` deadlock but is by far the largest diff and the largest risk to typing-latency-sensitive paths. Reasonable read: ship Claude's scope in C11-191, file Codex's contract as the documented invariant it implies, and file Gemini's actor as a candidate follow-up with an explicit latency-regression gate.

3. **Race analysis of "notify first, then instant push."** Codex is the only reviewer to challenge the plan's proposed ordering directly: the renderer can wake, observe no new item, and go back to sleep between the notify and the push. Claude adopts notify-first without examining it. This is a real, unresolved technical question and it should be settled before implementation, not during.

---

## 6. Strategic Questions for the Plan Author

Deduplicated and merged across all three reviews. Roughly ordered by how much the answer changes the shape of the work.

1. **Is a display-ID update allowed to be lost, or is "latest valid value eventually applied" required?** If the latter, why does the proposed full-mailbox behavior drop it rather than coalesce it? How does the renderer learn its correct display ID after it finishes draining a queue that discarded the message?

2. **How does the Swift memo learn that the ID was never applied?** `setMacOSDisplayID` returns early both on `setCurrentCGDisplay` failure and on a null display link, and neither outcome is visible to a memo that records at push time. What prevents a surface from being permanently stranded on a stale display link with the "visually frozen until focus change" symptom that `attachToView`'s own comments (`GhosttyTerminalView.swift:3278-3284`) say the unconditional re-assert exists to prevent?

3. **Can the coalescing primitive live in ghostty instead of Swift**, so every embedding client gets the safety property rather than each maintaining a correct shadow memo? If not, what is the blocker?

4. **What exact race-free ordering and ownership guarantees that the renderer does not sleep after a pre-push wakeup and miss the latest request?** The plan's "notify first, then push `.instant`" has an unanalyzed window.

5. **What is the formal meaning of `force`?** Does it mean "reapply even when the ID is equal because the display link must restart"? Must it survive mailbox pressure? Which observed renderer state proves a same-ID force actually restarted the link versus merely entering a full mailbox? Note that a screen-change notification can carry the *same* ID while a focus or topology transition may genuinely need a restart, and those are different intents.

6. **Why only `set_display_id`?** `ghostty_surface_set_occlusion` and `ghostty_surface_set_focus` are called from c11's main thread and reach the same 64-slot mailbox with the same `.forever` push; occlusion has the same push-before-notify ordering with no dedupe, while focus already has the guard occlusion lacks. Was this scoped out deliberately or not yet noticed? If deliberate, what closes those doors and when?

7. **Should the entirety of `attachSurface` move off the main thread?** `notes/BUG-main-thread-deadlock-attachSurface.md` proves `ghostty_surface_new` also blocks `updateNSView` via `SharedGridSet` lock contention, which the display-id memo does nothing for. Is a `GhosttyBridge` actor or background serial queue in scope here, a follow-up ticket, or rejected on typing-latency grounds?

8. **Which trigger explains the 11 Sentry users?** If it is `windowDidChangeScreen`, dragging a window between displays, that is a `force: true` site and the memo helps them not at all; only the ghostty half moves the number. Is there distribution evidence from the hang log on which call site dominates?

9. **Which current `set_display_id` call sites are intentional state transitions and which are accidental lifecycle repetition?** Please enumerate before editing so the audit has a finite completion criterion, and route all of them through one adapter so there is no direct escape hatch around policy.

10. **Is the ticket's ">1s repro before, not after" acceptance criterion being formally waived or met?** The disassembly is stronger evidence of *cause*, but it is not a CI gate. Is a queue-full Zig test in scope, and if not, what fails when someone reintroduces a blocking push in 2027? Note that a source-shape test asserting an `.instant` token would violate `CLAUDE.md`'s test-quality policy.

11. **How will testing create real mailbox saturation and renderer pause, and prove recovery**, without relying on an uncontrolled production-like load incident?

12. **Do the ghostty half and the c11 half definitely ship in the same release?** Given the submodule CI tail, if the Swift memo lands alone and ghostty slips, event volume drops (compounded by #401's budget), the acceptance criterion reads as satisfied, and the deadlock is still reachable. What guarantees they ship together?

13. **How is "count `macos_display_id` pushes per session before/after" actually measured?** Name the mechanism, and say whether it is disposable or becomes a standing instrument. Counting only producer calls makes a dropped message look like a success, so what set of counters (requested / coalesced / dropped / applied / pending age) is actually needed?

14. **What is the safety policy for the ugly edges?** Invalid or zero IDs, a pending update outliving `ghostty_surface_free`, a reparent to the same `TerminalSurface`, deferred creation, headless bootstrap, teardown, and a renderer that never drains. "Memo resets on surface create/destroy" is under-specified against that list.

15. **Why is the renderer thread not draining in the first place?** A 13h58m block means the consumer was permanently stopped, not merely slow. Making main survive that is right, but a renderer dead for 14 hours is its own defect, and the BUG note's `SharedGrid` write-lock analysis is a strong candidate. Is that a follow-up ticket, and does it exist?

16. **Sentry symbolication: is anyone owning it?** The plan proves c11's outbound stacks are untrustworthy for c11's own frames, which invalidates the reading of every past and future Sentry-derived ticket, and matters more now that #401 makes issue presence and user count the recurrence signal. Is there a ticket, and should this plan's evidence be attached to it?

17. **Is the hang corpus a one-off or an asset?** If a ranked report exists, what is signature #2 by total wedged wall time? That answer is probably the next ticket and it is currently sitting unread in 151 MB on one machine. Relatedly: is the unrotated 151 MB log on every release user's disk in scope to fix here?

18. **Upstream framing: one patch or a themed set?** Bundling the embedding-safety fixes with the `SharedGridSet.ref` and `SharedGrid` lock findings is a materially stronger contribution than three orphan patches and retires three private divergences in shared code at once. Worth the extra coordination? And should the general patch go upstream *before* c11-only diagnostics are layered on?

19. **Should `SurfaceDesiredState` be filed now?** The display-id memo is instance one of a pattern with seven or eight more instances in the same typing-latency-sensitive function. Filing it now names the pattern before six more ad-hoc guards accrete.

20. **Is the plan's correction to the ticket framed as precisely as it can be?** Codex's note: label the tab-bar stack as *misleading trigger and context*, not as evidence that "TabItemView's Equatable guard is failing." The contract being fixed is independent of which SwiftUI subtree happens to drive `updateNSView`, and overclaiming on the tab bar risks a second ticket chasing a guard that is fine.
