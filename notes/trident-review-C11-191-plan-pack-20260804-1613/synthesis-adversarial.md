# Adversarial Trident Synthesis: C11-191 Plan

Synthesized: 2026-08-04
Plan under review: `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md` (C11-191)
Sources: `adversarial-claude.md`, `adversarial-codex.md`, `adversarial-gemini.md`
Stance: all three reviewers were designated adversaries. Nothing below is balanced by design.

---

## Executive Summary

1. **All three reviewers agree the finding is real and the ticket assignment is wrong.** The mechanism the plan describes, a `.forever` push into a full 64-slot `BlockingQueue` from the main thread inside `updateNSView`, is a genuine deadlock hazard. Claude independently verified the disassembly line by line and found it correct. None of the three disputes the mechanism.

2. **All three reject the plan's central claim: that this deadlock is Sentry issue C11-30.** The evidence against is four-way and available to the plan author: build mismatch (0.58.0+116 vs 0.60.1), duration shape (2335 ms bounded stall vs 13h58m permanent wedge with no `hang.end`), population (11 Sentry users vs 1 local pid), and event profile (941 events, roughly 85 per user, is a recurring-and-recovering signature, not a wedge). Claude adds a fifth: the quoted Sentry stack has no `libsystem_kernel` frame, which a `__ulock_wait2` block always carries, so under the plan's own "module attribution is trustworthy" rule the Sentry hang is not a futex block at all.

3. **The "one signature dominates" statistic is a counting artifact and it is the plan's load-bearing beam.** Claude re-ran the plan's own source log counting by *episode* instead of by *capture*: `attachSurface` appears in 11 of 5004 episodes (0.2%), while `TabBarView` appears in 32 (3x more) and `updatePreferences` in 232 (21x more). 9413 of 9423 `attachSurface` captures come from a single pid (6063), one never-ending episode sampled 9412 times by the persist loop. A watchdog that re-samples a permanent wedge structurally over-counts exactly the bugs that never terminate.

4. **The proposed Ghostty change is the single largest correctness risk, flagged by all three.** Replacing a blocking push with `.instant` + log-and-drop converts a *loud* main-thread hang into a *silent* stale display ID. The existing `force: true` reassertion sites exist specifically because a stale display ID means a stopped display link and a visually frozen surface. Non-blocking is mandatory; dropping is a product decision with visible rendering consequences, and the plan does not treat it as one.

5. **Two concrete implementation defects were found, both one-paragraph fixes.** (a) Notify-before-push is a lost-wakeup bug: the renderer can wake, drain, and sleep again before the push lands; the current post-push notify ordering is correct and must be kept. (b) Memoizing in Swift while dropping in Zig is an outright correctness bug: the memo records "sent" for a message that was discarded, and every later non-forced call is suppressed, producing a permanently stale display ID.

6. **The most valuable missing fix is one level down and only Claude found it.** `BlockingQueue.pop` and `drain().deinit()` each `signal()` exactly one waiter, while three producers (main, the IO thread at `stream_handler.zig:172`, and termio at `Termio.zig:516`) push into the renderer mailbox. Draining all 64 slots wakes one producer. That is the mechanism by which a producer waits 14 hours. The plan makes main immune and leaves termio and the IO thread still starving, which is a user-visible output stall that survives the plan intact.

7. **The validation plan cannot close the ticket and cannot detect the failure mode it introduces.** Counting `macos_display_id` pushes per session measures the symptom's precondition, not the bug. The ticket's stated acceptance criterion ("a reproduction, many tabs plus tab bar interaction, that stalls main >1s before the change and does not after") is not produced by anything in the plan. A push count can look excellent while a display link is dead.

8. **Verdict, converged: no-ship as written; high-value finding; wrong ticket; two fixable defects.** The recommended minimum is to split the ticket rather than redefine it in a plan file, recount the evidence by episode, fix the notify ordering and the memo/drop interaction, and replace push-counting with a real convergence and rendering test.

---

## 1. Consensus Risks (flagged by two or three models, highest priority)

### 1.1 Identity conflation: the local wedge is not Sentry C11-30 (3/3)
- Claude: build mismatch, duration shape, population, and the missing `libsystem_kernel` leaf; plus episode-level counts that favor the ticket's own markers 3x to 21x.
- Codex: no binary UUID, ASLR slide, symbol file, or capture record ties the sampled binary to the release that emitted C11-30; version provenance is load-bearing, not clerical.
- Gemini: "a ~2.3s hang versus a 13-hour wedge, are you sure these are the same thing, or did you find a different permanent wedge?"
- **Consequence all three name:** C11-191 gets closed, Sentry C11-30 keeps firing, and the correct hypothesis has been rhetorically pre-discredited in a plan document, making recovery more expensive than never having made the claim.

### 1.2 Drop-on-full trades a visible hang for an invisible frozen surface (3/3)
- Claude: hangs are loud and get tickets; stale display IDs are quiet and produce "sometimes a pane just stops updating" reports six weeks later that nobody connects to this change.
- Codex: a full queue is not an exceptional logging event when the message carries state that controls `CVDisplayLink`; it is a state-loss branch requiring coalescing or last-value delivery, not a drop.
- Gemini: dropping a legitimate display change (monitor move) may break vsync permanently for that surface; the real fix is an unbounded queue, an atomic display-ID state, or finding out why the renderer is stuck.
- **Direct counter-evidence in the codebase, cited by two:** the comments at `GhosttyTerminalView.swift:3650`, `:3802`, `:3827`, `:5256` say reassertion is required to recover stuck vsync. That is the plan's own repo arguing against silent drop.

### 1.3 Notifying a wedged renderer does nothing, and notify-before-push loses wakeups (3/3, two distinct failure modes)
- Gemini and Codex, same point: if the renderer is deadlocked or starved rather than merely asleep, `wakeup.notify()` will not make it drain. Gemini rates the "renderer is just a little behind" assumption at zero likelihood to hold.
- Claude, a separate race: even with a healthy renderer, notify-then-push means the renderer can wake, drain an empty or partial queue, and sleep again before the push lands. Nothing then notifies it. The current notify-after-push ordering is correct. A pre-notify may be *added*; it cannot *replace* the post-notify. As specified, the plan trades a deadlock for a silently delayed display ID.

### 1.4 The prior BUG note is contradicted, not addressed (2.5/3)
- Gemini leads on this: `notes/BUG-main-thread-deadlock-attachSurface.md` analyzed the *same pid 6063* with `/usr/bin/sample` and concluded the main thread was blocked in `SharedGridSet.ref` on the font grid lock, held by 21 renderer threads. The plan claims "every wedged sample sits at `attachSurface + 372`" from `hang.log` while ignoring the `sample` data entirely.
- Claude reaches the opposite technical conclusion but the same process conclusion: the plan is *probably right* (the sampled `Thread.Futex.Deadline.wait` frame fits Zig's `Condition` futex path, not `Mutex`, so it corroborates `cond_not_full.wait` over `SharedGridSet.lock`), but the plan never makes that argument, so the repo now holds two documents asserting two root causes for one pid and the next agent will re-litigate it from scratch.
- Codex touches it through version provenance: the note's 0.60.1/CLI mismatch is part of why identity needs proving.
- **Both Gemini and Claude land on the same residual risk:** `attachToView` still calls `createSurface` to `ghostty_surface_new` to `SharedGridSet.ref` on main, under a mutex held across font discovery. Post-fix, that path still produces `__ulock_wait2` under `attachSurface` at a different offset, and a reader of `hang.log` may misread it as the fix having failed.

### 1.5 The memo and the drop do not compose; there is no convergence guarantee (2/3)
- Claude: c11 memoizes "display id is now X," Zig drops the message on a full mailbox, the renderer never learns, and every subsequent non-forced call is suppressed. Two individually defensible changes produce a permanently stale display ID.
- Codex: when `.instant` returns zero, nothing ensures the latest display ID is eventually applied after the queue drains; "the next incidental force" is not a convergence mechanism. Neither side alone supplies both non-blocking behavior and eventual convergence.
- **Minimum fix both converge on:** have the export return an enqueue result and memoize only on success. Better (both propose it independently): a renderer-owned atomic latest-value slot plus a dirty flag, which cannot block and cannot drop, after which the Swift memo becomes optional rather than load-bearing.

### 1.6 The validation does not test the product, and does not satisfy the ticket AC (3/3)
- Claude: no repro exists for either bug. "We fixed it" is unfalsifiable in both directions. Push-count deltas measure the symptom's precondition.
- Codex: a seam test that counts a mocked push proves the abstraction, not the runtime; it cannot prove `updateNSView`, portal reparenting, display-link restart, queue saturation, and real renderer behavior remain correct together. A push count can look excellent while a display link is dead.
- Gemini: the tab bar is likely still slow; the plan unblocks main from a side effect of that slowness without measuring the slowness.
- **All three note the ticket's ACCEPTANCE block is unmet and unamended.** A downstream validator will either block forever or rubber-stamp.

### 1.7 SwiftUI churn is accepted as a given rather than investigated (3/3)
- Gemini: why is `updateNSView` firing 64+ times before the renderer can drain? Memoizing makes the churn silent; it does not fix the CPU burn or the 2.3s stall if the churn itself is expensive.
- Claude: `updatePreferences` appears in 232 local episodes, 21x `attachSurface`; the outer SwiftUI shape the ticket names is by far the more common local signature and the plan had that data in hand.
- Codex: the plan does not show that the tab-bar preference pass is merely the scheduler exposing the blocking call rather than an independently expensive regression. A fix can eliminate the futex hang and still leave the >1s tab-bar problem.

### 1.8 The `force: true` site enumeration is asserted, not demonstrated (2/3)
- Claude verified the enumerated sites exist (`:3807`, `:3835`, `:5262`, `:4541`, `:6620`, `:3660`) and their comments do describe stuck-vsync scenarios, so the assumption is *plausible*, but the reuse-branch comment at `:3278` names a case the force sites may not cover: the view removed and re-added with `window`/`screen` briefly nil, no focus change, no screen change.
- Codex counts nine direct call sites today (`rg -n 'ghostty_surface_set_display_id\(' Sources`) against the plan's categories, and notes that any future direct call bypasses the memo entirely unless the raw binding is made inaccessible outside the owner.
- Both demand: name each site, classify it, state the renderer invariant it protects, and give the runtime scenario that tests it.

### 1.9 Removing a defensive workaround with no regression test for what it defended (2/3)
- Claude: the re-assert at `GhosttyTerminalView.swift:3285-3298` exists because surfaces visually froze during split-close restructuring. The plan turns it off and its only test counts pushes. No test, no repro, no screenshot covers "panes still render after split-close churn." Existing tooling for exactly this is ignored: `scripts/repro-c11-18.sh` plus `C11_PORTAL_DEBUG=1` writing to `/tmp/c11-portal.log`, both named in the prior BUG note as the natural starting point.
- Codex: the cache-reset state machine ("reset on surface create/destroy") is underspecified against the real states, headless bootstrap, portal reparenting, off-window deferred surface, surface recreation. A reset at the wrong point manufactures a redundant force; a missed reset suppresses the initial required update.

### 1.10 No cross-repo implementation, release, or rollback sequence (2/3)
- Claude: zero mention of pushing to `Stage-11-Agentics/ghostty` before bumping the pointer, `scripts/ghosttykit-checksums.txt` needing a matching entry, `build-ghosttykit` generating it, the expected run-1-red/run-2-green pattern, or the ~10 minute Zig build. A delegator will hit three red CI jobs and misdiagnose them, then either wait or hand-edit the checksum and add unrelated churn to the PR. Also: adding a return value to the export changes the vendored header.
- Codex: no statement on whether C11-191 may change the Ghostty ABI/semantics, whether the two repos release atomically, or what happens if the Swift change ships ahead of GhosttyKit. Split-release compatibility risk with no supported-combination matrix and no rollback path (the change is baked into a prebuilt xcframework).

### 1.11 The `c11LogicTests` seam is not identified and may not be constructible (2/3)
- Both Claude and Codex cite CLAUDE.md's warning that logic tests constructing `Workspace`/`TabManager`/surface objects crash bare `c11-logic` on nil `NSApp`. The plan needs a pure seam and never names one. If the answer is "CI only," say so.

### 1.12 No post-release monitoring contract (2/3)
- Claude: who checks Sentry C11-30, at what install count, for how long, what is the reopen trigger?
- Codex: no release cohort, observation window, baseline, dashboard/query, or rollback trigger, and the ticket explicitly requires interpreting issue presence and user count rather than event count because of the #401 event budget. Codex adds the sharper point: with 11 affected users and 13h58m wedges, post-release discovery is too expensive, so the destructive case needs **pre-release fault injection**.

---

## 2. Unique Concerns (raised by one model, worth investigating)

### From Claude
1. **`signal` should be `broadcast` in `blocking_queue.zig`.** `pop` signals one waiter; `drain().deinit()` signals once after emptying all 64 slots. With three producers blocked, draining the whole mailbox wakes exactly one. This is the actual starvation mechanism, and the plan leaves the IO thread and termio subject to it, meaning terminal output stalls under load survive the fix. Named as "the single most valuable thing the plan is missing."
2. **No guard against the class.** There are 18 `.forever` pushes in ghostty; exactly one is reachable from main today. A debug-only assertion that `.forever` is never used on the main thread, or a c11-side `assert(!Thread.isMainThread)` wrapper around blocking libghostty entry points, converts a one-off fix into a class fix. Nothing prevents the 19th.
3. **What actually dominates local hangs, from the same log the plan used.** For 4257 of 5004 episodes the topmost c11 frame is `main` (all AppKit/CoreFoundation/SwiftUI above it). The named c11 offenders that follow are `TerminalController.v2AwaitCallback` (50 episodes), `Workspace.readConversationsByPanelIdSync` (48), `WindowTerminalPortal.synchronizeLayoutHierarchy` (22), all synchronous main-thread waits with 2x to 4x `attachSurface`'s episode count. Also: 990 of 5004 episodes exceeded 10s and 236 exceeded 60s, suggesting unbounded main-thread waits are a broad category rather than one bug.
4. **The `BlockingQueue` is not SPSC despite its own doc comment.** Main, the IO thread, and termio all push into the renderer mailbox. The plan inherits an already-violated invariant without noticing.
5. **Display IDs are reused across disconnect/reconnect,** which makes them unsound as memoization identities.
6. **`NSScreen.main` is the fallback at both hot sites** and is the screen with keyboard focus, not the surface's screen. Memoizing it is questionable.
7. **"Offer upstream" is not an action an agent may take here.** Standing repo rule: never push, branch, or PR against `manaflow-ai/*`. The plan must read "flag to operator."
8. **`force: Bool` is the wrong shape.** The force sites do not want "set the id harder," they want "restart the display link because vsync may be stuck." Two named entry points (`setDisplayID(_:)` and `restartVsyncForCurrentDisplay()`) make every call site self-documenting and survive a future where re-asserting no longer restarts the link. Boolean force parameters are how the next agent silently picks the wrong one.
9. **Dedupe is on the wrong side of the boundary.** `setMacOSDisplayID` in `generic.zig` already knows the current display and already guards the link restart with `if (was_running and self.focused)`. A no-op check there suppresses redundant work for all callers, in one place, with no cross-language state to desync.
10. **Positioning against C11-186 is missing.** If the deadlock is 0.2% of episodes, "make main-thread hangs survivable" delivers far more user value, and the socket-alive-during-wedge finding from the BUG note is the concrete lever.
11. **The typing-latency win is unclaimed.** Removing a per-`updateNSView` C call into libghostty plausibly helps a hot path CLAUDE.md explicitly flags. Cheap, unmeasured, and a second line of defense for the ticket's actual AC.
12. **Split the ticket rather than redefine it.** Open a new ticket for the deadlock with the disassembly evidence; leave C11-191 on the Sentry signature with its stated AC. Redefining C11-191 in a plan file loses the Sentry issue, loses the 11-user problem, and makes the Lattice trail lie. Claude calls this "the cheapest fix to the whole review" and gates on it.
13. **Explicitly supersede the prior BUG note,** including the `Futex.Deadline` versus `Futex.wait` argument, so the contradiction does not outlive the fix.

### From Codex
14. **Teardown and lifetime races.** A queued or late display-id message can target a renderer being stopped or a surface being freed. The plan names no ownership or lifetime guarantee and tests no close/reopen under a saturated queue.
15. **The plan's traffic model is imprecise.** `updateNSView` calls `GhosttyNSView.attachSurface`; when already attached it takes `reconcileAttachedWindowIfNeeded` (`Sources/GhosttyTerminalView.swift:4477-4493`). The `attachToView` reuse branch is reachable from other lifecycle paths, notably `viewDidMoveToWindow` (`:4517`), not demonstrably every SwiftUI update. Nobody has measured producer counts by call site before the patch.
16. **Upstream may reject silent loss on semantic grounds.** A genuinely generic fix may instead be an API that coalesces stateful renderer messages, or one that distinguishes required commands from lossy hints. Do not implement a fork-only semantic change first and ask whether it was acceptable later.
17. **The log in "log-and-drop" is itself a hazard.** On a hot path under saturation it can produce a high-volume log with no defined debug/release policy, rate threshold, or aggregation.
18. **Missing environment matrix.** No accessibility, multi-display, eGPU/DisplayLink, sleep/wake, monitor unplug, Space move, or rapid split-close scenario, which are precisely the paths the forced reassertions were added for.
19. **Design an acknowledgement path, not just a counter.** A display-id requested/applied ack or renderer-generation counter makes a missing application observable; focused visible surfaces whose last request is unacknowledged within a bounded interval become a detectable early-warning signal.

### From Gemini
20. **Consider an unbounded queue** for the mailbox as an alternative to both blocking and dropping.
21. **"If a core thread's mailbox fills up, the system is already failing."** The `.instant` push is a band-aid on a saturation condition that is itself the defect. Treating full-mailbox as an ordinary branch normalizes a state that should never occur.
22. **The plan may be masking a catastrophic SwiftUI layout loop.** 64 pushes before the renderer can drain is itself the number worth explaining, independent of what the pushes do.

---

## 3. Assumption Audit (merged and deduplicated)

Load-bearing assumptions surfaced across all three reviews, consolidated. Verdict column reflects the harshest supported reading.

| # | Assumption | Load-bearing | Verdict | Flagged by |
|---|---|---|---|---|
| A1 | Sentry C11-30 and the local `attachSurface` deadlock are the same bug | Yes, the entire justification | **Rejected.** Four to five independent mismatches: build, duration shape, population, event profile, missing kernel leaf frame | All three |
| A2 | Sentry frames 16-21 (`GraphHost.updatePreferences` to `AG::Graph::UpdateStack::update`) are a distinguishing fingerprint | Yes | **Rejected.** Generic shape of any main-thread hang inside a SwiftUI update; present in 232 local episodes across many inner causes | Claude, Codex |
| A3 | The `attachSurface + 372` sample count establishes dominance | Yes | **Rejected as a counting artifact.** 9413/9423 captures from one pid; 11/5004 episodes | Claude |
| A4 | `attachSurface + 372` is the return address after `bl reconcileAttachedWindowIfNeeded` | Yes | **Accepted on mechanism** (Claude verified, +388 corroborates) but **unproven on provenance**: no binary UUID, ASLR slide, or symbol file recorded | Claude accepts, Codex challenges provenance |
| A5 | `reconcileAttachedWindowIfNeeded`'s only blocking primitive is the display-id push | Yes | **Probably true**, verified by reading (`window.contentView = nil; window.close()`, `screen.displayID` property read), but the plan asserts rather than states it checked | Claude |
| A6 | The renderer is merely asleep, so notifying lets it drain | Yes | **Unsafe.** If the renderer is wedged, crashed, or starved on the font rwlock, notify does nothing. No renderer-health observation proposed | Codex, Gemini |
| A7 | Notify-before-push is a safe reordering | Yes | **Wrong as specified.** Lost-wakeup race; the post-push notify must be kept | Claude |
| A8 | A display-id update is safely discardable | Yes | **Contradicted by the repo's own comments** at `:3650`, `:3802`, `:3827`, `:5256` describing reassertion as stuck-vsync recovery | All three |
| A9 | Equality of a `UInt32` display ID means no work is needed | Yes | **Contradicted by the plan itself**, which says reassertion intentionally restarts the display link. Equal ID does not imply equal required renderer state | Codex |
| A10 | The memo and the Zig drop compose correctly | Yes | **Wrong.** Memo records "sent" for a discarded message; all later non-forced calls suppressed; no convergence path | Claude, Codex |
| A11 | The enumerated `force: true` sites cover every unstick case | Yes | **Plausible, untested.** Nine direct call sites exist; the `:3278` reuse-branch comment names a case the force sites may not cover | Claude, Codex |
| A12 | Memo reset on "surface create/destroy" is a sufficient state machine | Yes | **Underspecified** against headless bootstrap, portal reparenting, off-window deferred surface, surface recreation | Codex |
| A13 | The `attachToView` reuse branch is a per-`updateNSView` producer | Weakens the design | **Imprecise.** The already-attached path calls `reconcileAttachedWindowIfNeeded`; the reuse branch is reached from other lifecycle paths. No measured per-site producer counts | Codex |
| A14 | Why the renderer stopped draining is exogenous and c11 need not care | Yes, implicitly | **Dangerous.** If the cause is `SharedGrid` write-lock contention across 21 renderers, main stops deadlocking and the surfaces stay frozen. The beachball goes away, the panes still do not draw, and nobody knows whether the ticket was fixed | Claude, Gemini |
| A15 | A `c11LogicTests` test can construct the memo seam | Medium | **Unproven.** CLAUDE.md warns that surface/workspace construction crashes bare `c11-logic` on nil `NSApp`. No pure seam identified | Claude, Codex |
| A16 | The `BlockingQueue` is SPSC as its doc comment claims | Invisible | **False.** Main, the IO thread (`stream_handler.zig:172`), and termio (`Termio.zig:516`) all push. The plan inherits a violated invariant | Claude |
| A17 | macOS display IDs are stable identities suitable for memoization | Invisible | **False.** Reused across display disconnect/reconnect | Claude |
| A18 | `NSScreen.main` (the fallback at both hot sites) is acceptable to memoize | Invisible | **Questionable.** It is the keyboard-focus screen, not the surface's screen | Claude |
| A19 | "Offer upstream" is an action an agent may take | Invisible | **False per standing repo rule.** Never push, branch, or PR against `manaflow-ai/*`. Must read "flag to operator" | Claude |
| A20 | The two repos can be changed and released without a compatibility plan | Yes | **Unaddressed.** No ABI/semantics decision, no atomic-release statement, no supported-combination matrix, no rollback for a change baked into a prebuilt xcframework | Codex, Claude |
| A21 | Post-release Sentry observation is sufficient validation | Yes | **Insufficient.** 11 users and 13h58m wedges make post-release discovery too expensive; the destructive case needs pre-release fault injection | Codex, Claude |
| A22 | The tab-bar preference pass is merely the scheduler that exposed the blocking call | Yes | **Unproven.** It may be an independently expensive regression; the fix can remove the futex hang and leave the >1s stall | Codex, Gemini, Claude |

---

## 4. The Uncomfortable Truths (recurring across models)

1. **The plan is better at explaining one sampled wedge than at proving a safe production change.** (Codex, verbatim; Claude and Gemini reach it independently.) Instruction-level precision earns unearned trust for everything downstream, including the leap from "one process wedged" to "this is what 11 users hit." Precision about mechanism tells you nothing about incidence.

2. **The most confident sentence in the plan is its least supported one.** "That reading does not survive contact with the evidence" is asserted about the ticket's hypothesis using evidence that, counted correctly, supports the ticket's markers 3x to 21x more often than the plan's. (Claude; Gemini's "severe tunnel vision" and Codex's "dismissed too completely" are the same observation.)

3. **This is "I found a great bug while looking for the assigned bug."** That is a good day. It is not a reason to overwrite the assigned bug. The value is high and the ticket assignment is wrong, and those are separable problems with an easy fix: split the ticket. (Claude, gated; Codex and Gemini both arrive at the same "you may be fixing a different bug" conclusion.)

4. **Nobody has reproduced anything.** Not the deadlock, not the tab-bar stall. Every claim on both sides is post-hoc stack reading. The plan should say so plainly instead of letting disassembly imply determinism. (Claude; Codex's "no deterministic saturation harness"; Gemini's implicit acceptance that both stories are inferential.)

5. **"Never block the caller" and "drop on full" are not equivalent to correctness.** The first is mandatory; the second is a product decision with visible rendering consequences that the plan does not own. (Codex, verbatim; Gemini: "a band-aid, if a core thread's mailbox fills up the system is already failing"; Claude: "converting a visible block into an invisible drop.")

6. **The tab bar is probably still broken and slow.** The plan unblocks main from a side effect of that slowness rather than addressing the slowness. (Gemini, verbatim; Claude via the 232-episode `updatePreferences` count; Codex via "can still leave the >1s tab-bar interaction problem.")

7. **The repo now contains two documents asserting two different root causes for the same pid**, and the plan does not mention the other one. Leaving that unstated guarantees a future agent re-derives the whole thing from scratch. (Claude, Gemini.)

8. **The stated real-artifact test measures the intended implementation, not the customer-facing failure.** A push count can look excellent while a display link is dead. (Codex, verbatim; Claude: "measures the symptom's precondition, not the bug.")

9. **The proposed fixes are, as literally specified, two bugs deep,** and they sit inside a document presented as disassembly-verified and rigorous, which is exactly the kind of document reviewers skim. (Claude.)

10. **Credit where it is due, and all three reviewers say some version of it:** the offset-level attribution, the +372/+388 corroboration, and the trace to the `.forever` push are excellent work. Claude verified it line by line and found it correct. The critique is about scope, statistics, and two implementation details. Do not let the critique bury the finding.

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews and grouped. Model attribution in brackets: [C]laude, [X] Codex, [G]emini.

### Identity and evidence

1. Episode-counted, `attachSurface` appears in 11 of 5004 local hang episodes (0.2%), `TabBarView` in 32, `updatePreferences` in 232. On what basis is the `attachSurface` signature "dominant," and does that basis survive being restated as "one process out of 59"? [C]
2. The quoted Sentry stack has no `libsystem_kernel` frame at position 0, and a `__ulock_wait2` block always does. Under the plan's own rule that module attribution is trustworthy, how is the Sentry hang a futex block? [C]
3. Sentry: 0.58.0+116, 2026-07-25, 941 events, 11 users, 2335 ms. Local: 0.60.1, 2026-07-29, one pid, 13h58m, no `hang.end`. Which of those four mismatches does the plan claim is explainable, and how? [C][G]
4. What exact binary UUID, load address / ASLR slide, symbol file, and capture record prove the local `attachSurface + 372` samples correspond to the production C11-30 release rather than a later, independently similar wedge? [X]
5. How do you reconcile the `hang.log` finding with the `/usr/bin/sample` data in `notes/BUG-main-thread-deadlock-attachSurface.md`, which concluded the same pid 6063 was blocked in `SharedGridSet.ref`? Did pid 6063 hit both, and if so why does the plan fix only one? Will the plan explicitly supersede that note, including the `Futex.Deadline` versus `Futex.wait` argument? [G][C]
6. Has the plan proven the tab-bar preference pass is merely the scheduler that exposed the blocking call, rather than an independently expensive regression? [X][G]

### Ticket, scope, and process

7. What is the plan's answer to the ticket's stated acceptance criterion, "a reproduction (many tabs plus tab bar interaction) that stalls main >1s before the change and does not after"? If the AC is changing, who signs off, and does the Sentry issue get its own ticket? "We don't know" here is a process failure, not a technical one. [C][X]
8. Why redefine C11-191 in a plan file instead of splitting: a new ticket for the deadlock carrying the disassembly evidence, C11-191 left on the Sentry signature with its stated AC? [C]
9. Given `attachSurface` is 0.2% of episodes while `TerminalController.v2AwaitCallback` (50), `Workspace.readConversationsByPanelIdSync` (48), and `WindowTerminalPortal.synchronizeLayoutHierarchy` (22) are all synchronous main-thread waits with 2x to 4x its episode count, and 990 of 5004 episodes exceeded 10s: why is none of that in the plan, given it came from the same log? How does this work position against C11-186? [C]

### Protocol semantics and correctness

10. What is the explicit delivery contract of `ghostty_surface_set_display_id` after this change: best effort, eventually-latest-value-wins, or guaranteed? If best effort, why is a stale display ID safe given the existing stuck-vsync comments at `:3650`, `:3802`, `:3827`, `:5256`? [X][G]
11. When `.instant` returns zero, what mechanism ensures the latest display ID is eventually applied after the queue drains? "The next incidental force" is not an answer. [X][C]
12. Combine fix 1 and fix 2: c11 memoizes display id X, ghostty drops the message on a full mailbox, the renderer never applies it, and every later non-forced call is suppressed. Is the export going to return an enqueue result so the memo only records successes, or is this defect being accepted? [C][X]
13. Fix 2 says notify first, then push `.instant`. What wakes the renderer for a message pushed after the notify was consumed? Why is the current post-push notify not simply kept, with a pre-notify added rather than substituted? [C]
14. If the renderer is wedged (font rwlock, crash, stop) rather than asleep, how does `wakeup.notify()` make it drain? What renderer-health or state observation exists to distinguish the two? [G][X]
15. Why a queue message at all for idempotent latest-wins state? What is the argument against a renderer-owned atomic field plus a dirty flag, which cannot block and cannot drop, or against an unbounded/coalescing slot? [C][X][G]
16. Why dedupe on the Swift side rather than a no-op check inside `setMacOSDisplayID` in `generic.zig`, where the renderer already owns the current display id and cannot desync from itself? [C]
17. `BlockingQueue.pop` and `drain().deinit()` each `signal()` exactly one waiter while three producers (main, the IO thread at `stream_handler.zig:172`, termio at `Termio.zig:516`) push into the renderer mailbox. Is that not the actual starvation mechanism, and why is `signal` to `broadcast` not in the plan? What happens to a starved termio producer, that is, terminal output stalls, after this fix? [C]
18. Nothing prevents the 19th of ghostty's 18 `.forever` pushes from reaching main. Why is a debug assertion against blocking libghostty calls on the main thread not part of this fix? [C]
19. Is `force: Bool` the right shape, given the force sites want "restart the display link because vsync may be stuck" rather than "set the id harder"? Why not two named entry points? [C]

### Call sites, state, and lifetimes

20. List all nine current direct `ghostty_surface_set_display_id` call sites. For each: `force: true` or `false`, the renderer invariant it protects, and the runtime scenario that tests it. What prevents a future direct call from bypassing the memo? [X][C]
21. What are the measured producer counts by call site before the patch, and why does the plan describe `attachToView`'s reuse branch as a per-`updateNSView` producer when the already-attached path calls `reconcileAttachedWindowIfNeeded` instead? [X]
22. What is the precise memo-reset state machine across headless bootstrap, portal reparenting, off-window deferred surface, and surface recreation? Which reset points risk a redundant force, and which risk suppressing a required initial update? [X]
23. Display IDs are reused across disconnect/reconnect, and `NSScreen.main` (the fallback at both hot sites) is the keyboard-focus screen rather than the surface's screen. Are those sound memoization keys? [C]
24. What are the ownership and lifetime guarantees for a queued or late display-id message targeting a renderer being stopped or a surface being freed? What tests close/reopen under a saturated queue? [X]
25. Why is `updateNSView` firing 64+ times before the renderer can drain? Is the plan masking a SwiftUI layout loop that is itself the 2.3s cost? [G]

### Validation, rollout, and monitoring

26. What deterministic harness fills the renderer mailbox while exercising a real visible terminal, proves the main thread stays responsive, and then proves display ID and vsync converge after pressure is removed? [X][C]
27. The re-assert at `:3285` was added to fix visually frozen surfaces during split-close restructuring. What test, repro, or screenshot proves the enumerated `force: true` sites cover that case? `scripts/repro-c11-18.sh` plus `C11_PORTAL_DEBUG=1` exists; why is it not the validation? [C]
28. What does the post-fix `hang.log` signature look like, given `attachToView` still calls `createSurface` to `ghostty_surface_new` to `SharedGridSet.ref` on main under a mutex held across font discovery? How does a reader avoid misreading a near-identical signature as the fix having failed? Why is that path out of scope? [C][G]
29. How does the proposed logic test avoid testing a mock counter? What production behavior does its seam observe, and what is the pure seam that avoids the nil-`NSApp` crash CLAUDE.md warns about? Does it run only in CI? [C][X]
30. What is the implementation and release order across the ghostty fork push, GhosttyKit artifact and `scripts/ghosttykit-checksums.txt`, the parent-repo pointer bump, and the expected run-1-red / run-2-green CI pattern? Which version combinations are supported during rollout, and what is the rollback path for a change baked into a prebuilt xcframework? [C][X]
31. What does "offer upstream" mean operationally, given the standing rule against writing to `manaflow-ai/*`, and given upstream may reject silent message loss as semantically wrong? [C][X]
32. What is the definition of failure for `.instant`: metric, rate threshold, aggregation, debug-versus-release logging policy, and operator-visible recovery path? How is the hot-path log volume bounded under saturation? [X]
33. What pre-registered early-warning signals ship with this? Candidates raised: dropped/coalesced display-ID counts grouped per surface and renderer generation; a requested/applied acknowledgement or generation counter; focused visible surfaces whose last request is unacknowledged within a bounded interval; episode-level (not capture-level) `__ulock_wait2`-leaf counts per release; any hang episode over five minutes paging rather than accumulating captures. [C][X]
34. What post-release cohort, query, observation window, baseline, and reopen/rollback trigger determine that C11-30 is not recurring, given the #401 event budget means judging by issue presence and user count? Who owns that check? Why is pre-release fault injection not required instead, given 11 users and 13h58m wedges? [C][X]

---

## 6. Recommended Minimum Gate (converged across reviewers)

Ordered by how cheaply each removes risk.

1. **Split the ticket.** New ticket for the deadlock with the disassembly evidence; C11-191 stays on the Sentry signature with its stated AC. Do not close C11-30 with this work. [C, gated]
2. **Recount the evidence by episode** and rewrite the "one signature dominates" section honestly. The finding survives the honest framing; it becomes "rare and catastrophic" rather than "dominant," which is a better argument anyway. [C]
3. **Keep the post-push notify.** Add a pre-notify only if it is additive. [C]
4. **Resolve the memo/drop interaction.** Either return an enqueue result and memoize only on success, or adopt a renderer-owned atomic latest-value plus dirty flag and drop the Swift memo entirely. [C, X]
5. **Change `signal` to `broadcast` in `blocking_queue.zig`, or state explicitly why not.** [C]
6. **Replace push-counting with a saturation harness plus a rendering check:** `repro-c11-18.sh` plus `C11_PORTAL_DEBUG=1`, split-close churn, and a real-artifact screenshot pass proving panes still render. [C, X]
7. **Enumerate all nine call sites** with invariant and test scenario per site, and make the raw FFI binding inaccessible outside the owner. [X]
8. **Write the ghostty submodule, checksum, CI, release-order, and rollback sequence into the plan** so the delegator does not discover it via three red CI jobs. Replace "offer upstream" with "flag to operator." [C, X]
9. **Explicitly supersede `notes/BUG-main-thread-deadlock-attachSurface.md`**, including the `Futex.Deadline` versus `Futex.wait` argument and an explicit statement of what remains unfixed on the `SharedGridSet` path. [C, G]
10. **Pre-register the monitoring and rollback contract** before merge, not after release. [X, C]
