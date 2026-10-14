# Trident Standard-Track Synthesis: C11-191 Plan Review

**Plan under review:** `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md` (C11-191)
**Reviewers synthesized:** Claude (`standard-claude.md`), Codex (`standard-codex.md`), Gemini (`standard-gemini.md`)
**Track:** Standard / Analytical
**Date:** 2026-08-04

---

## Executive Summary

1. **All three models agree the plan contains genuinely excellent root-cause engineering.** The identification of a real main-thread deadlock (`attachSurface` -> `reconcileAttachedWindowIfNeeded` -> `ghostty_surface_set_display_id` -> `.forever` push on a full 64-slot `BlockingQueue` -> `cond_not_full` futex wait) is disassembly-verified, log-corroborated, and unanimously praised. Claude independently re-ran the log counts and confirmed them. Nobody disputes that this bug is real and worth fixing.

2. **All three agree the two-layer decomposition is architecturally correct**: reduce push frequency in c11 (memoization), and make the FFI boundary non-blocking in ghostty. All three also agree on the *weighting*: the ghostty change is the load-bearing safety fix, and the c11 memo is an optimization that cannot itself be the safety guarantee.

3. **The reviews split 2-1 on readiness.** Claude: needs revision. Codex: needs revision before execution. Gemini: ready to execute. The synthesized verdict is **needs revision** (Section 5).

4. **The single largest divergence is whether this plan fixes C11-191 at all.** Codex and Gemini accept the plan's "correction to the ticket's reading" as a strength. Claude rejects it, with three independent lines of evidence, and argues the plan is a correct fix for a *different* bug that will close the ticket while leaving the 941-event Sentry issue live. This disagreement is the highest-value item in the pack and is cheaply settleable (Section 2.1).

5. **Two technical defects were flagged independently by two models and should be treated as high-confidence**: the notify-before-push ordering is a lost-wakeup hazard, and drop-on-full combined with the c11 memo can permanently strand a stale display ID. Gemini raised the second as an open question rather than a defect, which is itself signal: the third model saw the shape of the problem but did not judge it disqualifying.

6. **Both deeper reviews independently found the same delivery-mechanics gaps**: the plan has no ghostty-side test, no exhaustive call-site/force table, no memo-lifecycle specification, and no submodule/checksum/upstream sequencing. None of these are design objections; all are execution blockers a delegator would hit within an hour.

---

## 1. Where the Models Agree (Highest-Confidence Findings)

### 1.1 Unanimous (3 of 3)

1. **The root-cause diagnosis is sound and the debugging is expert-level.** All three call out the rejection of the impossible Sentry frame (`Foundation.URL? outlined copy` at frame 4 cannot be a caller; outlined copy helpers are leaves) as sharp reasoning. Claude and Gemini both single out the disassembly verification (`attachSurface + 372` / `+ 388` matched against actual `bl` targets in the shipped binary) as a standard of proof rarely met.

2. **The two-part fix is the right shape, in the right layers.** Caller-side spam reduction plus callee-side non-blocking enforcement. Gemini frames it as `O(layout passes)` -> `O(display changes)`; Codex frames it as "remediation vs prevention"; Claude frames it as "one part reduces pressure, one part removes the failure mode." Same conclusion three ways.

3. **The ghostty-side fix is the load-bearing one; the c11 memo is not a safety property.** Codex is most explicit ("the c11 memo is then an optimization... rather than the mechanism that makes the application safe"). Gemini reaches it via the renderer-wedge argument. Claude ranks it explicitly: ghostty first, memo third.

4. **Dropping a display ID on a full mailbox has no specified recovery path.** All three raise it. This is the most-cited concrete concern in the pack. They differ on severity (Section 2.3).

5. **The ghostty change is correctly identified as generic and upstream-relevant.** All three endorse the fork-policy framing, though Claude adds a routing correction (Section 3.1.9).

### 1.2 Two-Model Agreement (Claude + Codex)

6. **Notify-before-push is a lost-wakeup bug as specified.** `wakeup` is an `xev.Async`, which coalesces. Both describe the same race: notify -> renderer drains -> renderer parks -> `.instant` push lands in a now-empty mailbox and succeeds -> no notify follows -> the message sits undelivered until an unrelated wakeup. Claude adds that the reorder does not even buy what it claims: if the renderer is healthy the ordering is irrelevant, and if it is wedged the notify does nothing.

7. **Drop-on-full plus memoization strands stale state permanently.** `ghostty_surface_set_display_id` returns `void`, so a dropped push is invisible to Swift; the memo records "id X is current" for a value ghostty never received, and every subsequent `force: false` site then skips. Both models converge on the same two remedies: return an acceptance status, or (preferred by both) stop modeling this as a message at all.

8. **The right end-state is a coalescing latest-value-wins slot, not a queued message.** Claude's Alternative A (`std.atomic.Value(u32)` plus dirty flag on the renderer thread) and Codex's "coalesce display ID at the renderer-thread boundary" are the same proposal reached independently. Both rank it above the plan's approach. Codex's framing is the crisper articulation of *why*: **display ID is state, not an edge-triggered event where loss is automatically harmless.**

9. **The force taxonomy is asserted, not enumerated.** The plan names categories (`createSurface`, focus, topology churn, `viewDidMoveToWindow`, `windowDidChangeScreen`) but provides no caller-by-caller mapping. Codex names concrete omissions the plan glosses: `TerminalSurface.setFocus`, `GhosttyNSView.viewDidMoveToWindow`, `becomeFirstResponder`, `windowDidChangeScreen`, and notes there are *two independent focus paths*. Claude attacks the same gap from the regression angle (Section 3.1.3).

10. **Memo lifecycle is underspecified.** "Resets on create/destroy" does not cover: `ghostty_surface_new` failure, surface-pointer replacement, headless-startup-window to real-window migration, display ID unavailable, or request rejected/dropped. Both insist the memo must be bound to the specific ghostty surface's lifetime and must advance only on an *accepted* request.

11. **The test plan does not cover the fault boundary.** A `c11LogicTests` memo test proves Swift call suppression only. It cannot prove that `ghostty_surface_set_display_id` never waits, that a full mailbox does not lose the final ID, or that a wake is not lost. Both demand a ghostty-level test: fill the queue, push from a producer thread, assert prompt return, drain, assert the final ID was applied.

12. **Cross-repository delivery steps are missing entirely.** Both flag the ghostty submodule sequence: push to `Stage-11-Agentics/ghostty` before committing the parent pointer, then the `build-ghosttykit` workflow regenerating `scripts/ghosttykit-checksums.txt`, with run 1's three guard jobs expected red for ~10 minutes. Claude notes the risk of an orphaned detached-HEAD SHA; Codex notes the risk of "predictable but confusing guard failures" being misread as regressions.

13. **Runtime validation is too vague for the severity.** "Count `macos_display_id` pushes per session before/after" needs an instrumentation source, expected baselines, a way to distinguish intentional force from deduplicated from rejected, and a real portal-churn / screen-move / focus-recovery scenario on a tagged build.

### 1.3 Two-Model Agreement (Claude + Gemini)

14. **"Why does the renderer stop draining?" is unaddressed.** A 64-slot mailbox that fills and stays full for 14 hours is not transient. Gemini's framing is the cleanest statement of the residual: the fix converts a **global app hang into a per-surface hang**, a vast improvement, but the user still has a dead terminal. Claude ties it to the prior note's `SharedGrid` write-lock contention across 21 renderer threads and argues it deserves its own ticket rather than silence.

---

## 2. Where the Models Diverge (The Disagreement Is Signal)

### 2.1 Is this plan actually fixing C11-191? [MAJOR DIVERGENCE]

| Model | Position |
|---|---|
| Codex | The correction is "a strong and important correction to the ticket." Original Sentry-only reading is insufficiently symbolicated to justify a Bonsplit rewrite. |
| Gemini | The correction is a Key Strength: "expert-level debugging." Accepts without independent check. |
| Claude | **The correction is wrong.** The ticket's reading was right. This plan fixes a different, also-serious bug. |

Claude's three lines of evidence:

1. **The plan's own epistemic rule refutes it.** The plan says symbol names drift but "module attribution is [trustworthy]." Applying that rule: the Sentry stack has frame 0 in module `c11`, frames 1-3 `SwiftUICore`, frame 17 `AttributeGraph`, and **no `libsystem_kernel.dylib` frame anywhere**. All 9433 local captures of the deadlock have `__ulock_wait2` at frame 0. A futex-blocked thread cannot present a leaf frame in `c11`.

2. **The Sentry signature exists verbatim in the local log, fully symbolicated.** 32 distinct hang episodes across 10+ pids contain `Bonsplit.TabBarView`. Example pid 63572, `stalledMs=2037` (same ~2s magnitude as the Sentry issue's 2335ms), leaf frame `AG::Graph::mark_changed` (CPU-bound, no kernel wait), frame 93 naming `Bonsplit.TabBarView.body ... preference<TrailingAccessoryWidthKey> ... preference<SplitButtonsIntrinsicWidthKey>`.

3. **The frequency profile matches the ticket, not the plan.** 9412 of the 9423 attachSurface captures come from a *single pid in a single 14-hour episode*. Counted as episodes, the deadlock fires ~8 times across 7 pids in 51 days. The TabBarView signature fires in 32 episodes across 10+ pids. A Sentry issue with 941 events across 11 users in one day is a high-frequency, broadly-distributed, few-second stall: the TabBarView profile.

**How to weigh this divergence.** It is 2-1 by headcount but not by evidence. Codex and Gemini accepted the plan's correction as reasoning-internal; neither queried the underlying corpus. Claude is the only reviewer that independently re-ran the log counts and searched `hang.log` for the competing signature. Under evidence-weighting rather than vote-counting, Claude's position carries. It is also **cheaply falsifiable in under an hour**: take one Sentry event for build 0.58.0+116 and resolve frame 0's offset against that binary exactly as the plan resolved `attachSurface + 372`. If it lands in `MiddleClickCapture` or the tab bar subtree, the plan is misfiled; if it lands in `attachSurface`, the plan wins outright. **This check should run before any other revision work.**

Note the second-order effect the other two reviewers could not see: Claude also observes that the plan's matching criterion (Sentry frames 16-21 = `GraphHost.updatePreferences` -> `AGGraphGetWeakValue` -> `value_ref` -> `update_attribute` -> `UpdateStack::update`) is the **common prefix of essentially every SwiftUI-driven main-thread hang in this app**, appearing 9658 times locally. It is a shared trunk, not a fingerprint. That directly undercuts the "position for position the same" claim in the plan.

### 2.2 Notify-before-push ordering

| Model | Position |
|---|---|
| Claude | Concrete lost-wakeup bug. Prescribes `push` then `notify` (today's order, timeout changed), or `notify` / `push` / `notify`. |
| Codex | "Unsafe as written." Demands the exact algorithm be stated and its wakeup behavior proven against ghostty's event-loop wake primitive. |
| Gemini | Reads the plan as endorsing notify-first and asks only whether the notification mechanism itself blocks. Treats it as a confirmation, not a defect. |

**Synthesis:** two of three identify this as a real defect, and the third did not analyze the coalescing semantics of `xev.Async`. Treat as high-confidence: do not ship notify-then-push as written.

### 2.3 Severity of drop-on-full

| Model | Position |
|---|---|
| Gemini | "Dropping a display ID update is a very acceptable fallback compared to beachballing the app." Raises the recovery question but does not gate on it. |
| Claude | Converts a transient deadlock into a **persistent visual freeze**, "arguably a worse user experience than a 2s stall." Gates on it. |
| Codex | "Weakens correctness during the exact degraded state where recovery matters." Acceptable only with durable coalescing plus a guaranteed later drain. Gates on it. |

**Synthesis:** the disagreement dissolves once the memo interaction is added to the picture. Gemini analyzed the drop in isolation (where its read is fair); Claude and Codex analyzed drop *plus* memo (where the failure becomes permanent because no `force: false` path retries). The composite hazard is the real finding, and it is the strongest argument for the coalescing-slot alternative.

### 2.4 Does the plan close the whole failure class?

| Model | Position |
|---|---|
| Gemini | Yes: "Defense in Depth: fixing the spam on the Swift side *and* the blocking nature on the Zig side ensures the bug won't recur even if another spammer is introduced later." |
| Claude | **No.** `set_display_id` is the only `.forever` push in `embedded.zig`, but the exports delegate into `Surface.zig`, which has several more. `ghostty_surface_set_focus` -> `Surface.focusCallback` -> `.forever`; `ghostty_surface_set_occlusion` -> `Surface.occlusionCallback` -> `.forever`; plus `setFontSize`, inspector toggles, size/config paths. c11 calls focus and occlusion from main on ordinary interaction (`GhosttyTerminalView.swift:3825, :3842, :5254, :5283, :5596, :5669`). |
| Codex | Abstractly aligned with Claude ("a future caller, a missed call site, or a new binding must still be unable to wedge the main thread") but does not name the concrete other exports. |

**Synthesis:** Gemini's claim is directly contradicted by file-and-line evidence. The correct framing is Claude's class rule: **no apprt-facing export may block its caller.** Either convert those `.forever` pushes, or add a `pushFromAppThread` helper in `Surface.zig` that is `.instant` plus notify and make the blocking variant unavailable to `embedded.zig`. This is also a stronger, more obviously generic upstream offer.

### 2.5 Readiness verdict

Claude and Codex both land on needs-revision; Gemini on ready-to-execute. Gemini's review is the shortest and did no independent corpus work, and it raises as an *open question* (its Q1) precisely what the other two classify as a blocking defect. The three verdicts are consistent with a single depth gradient rather than a genuine three-way split.

---

## 3. Unique Insights (Single-Model Findings)

### 3.1 Claude only

1. **A concrete counter-diagnosis of the real C11-191 bug, with file and line numbers.** `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`: lines 730-749 are two `GeometryReader` -> `.preference(...)` writers publishing `TrailingAccessoryWidthKey` and `SplitButtonsIntrinsicWidthKey`; lines 794-809 are `.onPreferenceChange` handlers writing `@State` (`trailingAccessoryWidth`, `splitButtonsIntrinsicWidth`, `effectiveChromeWidth`) **with no equality or epsilon guard**; line 722 feeds the derived `chromeWidth` into `.frame(width:)` on a sibling in the same subtree. That is a textbook measure -> write state -> resize -> re-measure feedback loop, superlinear in tab count because the recursion runs through the tab `ForEach`. Proposed fix: epsilon-guard both `onPreferenceChange` writes (`guard abs(normalizedWidth - trailingAccessoryWidth) > 0.5 else { return }`), verify `effectiveChromeWidth` only assigns on change. Testable with a deterministic layout-pass counter; plausibly a one-afternoon PR.

2. **The decisive one-hour identification experiment** (resolve one Sentry event's frame-0 offset against the 0.58.0+116 binary). No other reviewer proposed a way to settle the question empirically.

3. **The memo may silently revert PR #12 ("Fix frozen terminals after split churn", commit `50f0dd334`).** The re-assert in `attachToView`'s reuse branch (`GhosttyTerminalView.swift:3285-3298`) was added deliberately, with a comment explaining that after split-close restructuring the view is removed and re-added, window/screen can be transiently nil, and the display link needs a kick. `setMacOSDisplayID` in `generic.zig:1008-1025` confirms it: on a re-assert with the *same* id it does a `stop()`/`start()` of the display link precisely to recover the silent-no-callbacks state. The plan lists "topology churn" as a `force: true` category but the reuse branch *is* the topology-churn site, and the plan elsewhere names it as one of the two sites to de-force. **Proposed resolution:** key the memo on `(displayID, ObjectIdentifier(window), attachEpoch)` and bump the epoch on any view/window reparent, so genuine churn still kicks the link while steady-state SwiftUI updates (hover, active markers, visibility flags) are suppressed.

4. **The prior BUG note's root cause is superseded and the plan does not say so.** `notes/BUG-main-thread-deadlock-attachSurface.md` blames `SharedGridSet.lock`. Its own `/usr/bin/sample` stack shows `Thread.Futex.Deadline.wait` above `__ulock_wait2`. In Zig stdlib, `Futex.Deadline` is used by `std.Thread.Condition`'s futex implementation; `std.Thread.Mutex`'s futex path calls `Futex.wait` directly without a `Deadline`. So the sampled frame is a **condition-variable** wait (`cond_not_full.wait`), not the mutex the note inferred. The plan is right and the note is wrong, but the note's fix 3 is currently the standing advice for the next reader and must be updated.

5. **Frame-pointer caveat.** Between `__ulock_wait2` (frame 0) and `attachSurface` (frame 1) there are at least six real frames (`pthread_cond_wait`, `Futex.Deadline.wait`, `Condition.timedWait`, `BlockingQueue.push`, `ghostty_surface_set_display_id`, `reconcileAttachedWindowIfNeeded`), missing because libghostty is built without frame pointers. A plan that spends a paragraph teaching skepticism about symbolication should not then present a frame-skipped stack without the caveat. One `lldb` backtrace from a live wedged process would remove all doubt.

6. **Statistical-framing critique, and its causal link to the misidentification.** "One signature dominates: 9433 captures" is technically true and practically misleading when 9412 are one episode. A capture-weighted count from a persist-sampling watchdog is a **duration metric, not a frequency metric**. Report episodes and pids alongside captures. Claude names this as the specific analytical slip that produced the misidentification.

7. **~40% of the corpus may be watchdog false positives.** 7910 captures have frame 0 = `libsystem_kernel.dylib mach_msg2_trap`, i.e. main parked idle in `CFRunLoopServiceMachPort` while the watchdog declared a multi-second stall. Either the watchdog has a large false-positive class (main in a nested/tracking runloop mode not servicing the probe), or the probe itself is being starved. Bears directly on whether "941 events" is a trustworthy denominator, and belongs in C11-186.

8. **Acceptance criteria are not falsifiable for the work being done.** "The Sentry issue does not recur" cannot validate this fix. Proposed replacement oracle, drawn from the plan's own evidence: count `__ulock_wait2` + `attachSurface` **episodes** in `hang.log`, gate on zero over 14 days of normal operator use, keep Sentry as long-tail confirmation only.

9. **"Offer upstream" needs a routing correction.** The standing rule is never to push, branch, or PR against `manaflow-ai/*` (the ghostty submodule's `origin`). "Offer upstream" here means land in the Stage 11 fork and flag it to the operator for the decision.

10. **A shippable-today mitigation: bounded push (`.ns = 5_000_000`).** One-token change converting an unbounded deadlock into a 5ms worst-case stall, no memo-interaction analysis required. Weaker than the coalescing slot but a good *first* commit if the submodule/checksum dance means the real fix lands days later, given users are currently exposed to a force-quit-only 14-hour failure that destroys running agent sessions.

11. **Split the PRs (Alternative D).** With the ghostty fix landed, the memo is pure optimization and carries all the regression risk. Deferring it to its own reviewed PR lets the safety fix ship faster and cleaner.

12. **Missing test for the ghostty half.** Suggests a Zig unit test that a full `BlockingQueue` returns 0 from an `.instant` push without blocking (locks in the timeout choice), plus a **debug-gated "renderer stops draining" env flag** making the deadlock reproducible on demand from a tagged build. Without a repro switch, nobody can prove the fix works before shipping it.

### 3.2 Codex only

13. **The sharpest conceptual framing in the pack:** "display ID is state, not an edge-triggered event where loss is automatically harmless. A full renderer queue can safely collapse repeated requests only if it guarantees eventual application of the *latest* ID after the renderer resumes. 'Log and drop' does not make that guarantee." This is the sentence that most cleanly explains why the plan's fix is under-specified rather than wrong.

14. **A test-seam warning grounded in this repo's documented failure mode.** "If the Swift test needs a seam, keep it a small behavioral counter/dispatcher seam; do not construct AppKit `TerminalSurface` in bare logic tests." This matches CLAUDE.md's documented `c11LogicTests` caveat: tests constructing a `Workspace`/`TabManager` crash the bare xctest runner locally on a nil `NSApp`. Codex is the only reviewer that anticipated the delegator writing a test that cannot run locally.

15. **The most complete enumeration of omitted call sites**, including the observation that there are **two independent focus paths** (`TerminalSurface.setFocus` and `becomeFirstResponder`), plus `GhosttyNSView.viewDidMoveToWindow` and `windowDidChangeScreen`. Demands a caller-by-caller table with intended `force` value and rationale, followed by a search-based audit that no direct C calls remain outside the policy helper.

16. **Memo lifecycle edge-case enumeration:** `ghostty_surface_new` failure, surface pointer replaced, attachment moves to the **headless startup window**, display ID unavailable, request rejected/dropped. The headless-startup-window to real-window migration is a c11-specific case no other reviewer surfaced.

17. **A concrete execution sequence:** define and test ghostty's coalesced non-blocking handoff -> land in the fork and push to the ghostty remote -> update c11 to use *one explicitly named* `setDisplayID` policy helper -> prove real portal/screen/focus recovery on a tagged build. Adds the gating condition that the c11 memo may land in the same change **only after** the force policy has an auditable call-site inventory.

18. **Explicit rejection of "move attachment off-main"** on grounds the other reviewers touched only partially: it changes ordering, focus, portal ownership, and teardown semantics, and it still leaves other FFI callers exposed. Keep as a separately justified lifecycle redesign, never as the C11-191 fix.

19. **A regression framing for the validation step:** "a reduction in messages is a regression if it revives stuck-vsync/no-frames." Naming the success metric's own failure mode.

### 3.3 Gemini only

20. **The "async dispatch from Swift" alternative, rejected on thread-leak grounds.** Swift could dispatch to a background queue and do the `.forever` push there. Gemini rejects it: it still blocks a thread, and **if the mailbox never drains you leak threads**. Neither other model evaluated this alternative, and it is the pattern a less careful implementer would reach for first. Worth keeping in the record as a pre-refuted option.

21. **The "increase mailbox size 64 -> 1024" naive alternative, correctly pre-rejected** as merely delaying the hang. Also worth keeping as a pre-refuted option.

22. **The cleanest statement of the residual risk:** the ghostty fix "turns a global app hang into a per-surface hang (the renderer thread is still stuck). This is a vast improvement (the app survives), but the user still has a dead terminal surface." One sentence, correctly scoped, and it names exactly what the follow-up ticket should own.

23. **The clearest complexity framing:** `O(layout passes)` -> `O(display changes)`.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews. Sources noted in brackets. Ordered by blocking priority.

### Tier 1: Blocking, and settleable before any other work

1. **What is the resolved symbol for frame 0's offset in a real Sentry event for build 0.58.0+116, resolved against that binary the same way you resolved `attachSurface + 372`?** This settles the identification question outright and takes under an hour. [Claude]

2. **How do you account for the Sentry stack having no `libsystem_kernel.dylib` frame, given that all 9433 local captures of the deadlock have `__ulock_wait2` at frame 0?** Is there a capture path that would elide kernel frames in the Sentry variant but not the local one? [Claude]

3. **Did you search `hang.log` for the TabBarView signature before concluding the ticket's reading was wrong?** It appears in 32 episodes across 10+ pids, `stalledMs` from ~2s to ~39s, with frame 93 naming `Bonsplit.TabBarView.body` and both preference keys. What is your read of that capture? [Claude]

4. **Of the 9423 attachSurface captures, 9412 are from pid 6063's single 14-hour episode, giving roughly 8 episodes in 51 days.** Does that frequency square with 941 events across 11 users in one day, and if so, by what mechanism? [Claude]

5. **If the identification turns out to be wrong, do you want this work re-filed as its own ticket with its own acceptance criteria, or folded under C11-186?** The attachSurface deadlock deserves a P0 of its own: unrecoverable, 14 hours, destroys running agent sessions. [Claude]

### Tier 2: Design defects in the fix as specified

6. **What exact mechanism guarantees that the newest display ID reaches the renderer after a full mailbox drains, rather than being permanently dropped?** [Codex, Claude, Gemini]

7. **What is the exact wakeup ordering, and what prevents the renderer from draining and parking between a pre-push notify and a successful `.instant` push?** `wakeup` is an `xev.Async` and coalesces. State the algorithm and prove its wakeup behavior against ghostty's event-loop wake primitive. [Claude, Codex, Gemini]

8. **When a push is dropped because the mailbox was full, how does the Swift memo learn it must not record that ID as sent?** Does the memo advance only after acceptance/coalescing? Are you willing to change `ghostty_surface_set_display_id` to return a status? [Claude, Codex]

9. **Have you considered replacing the message with an atomic latest-value-wins slot on the renderer** (a `std.atomic.Value(u32)` plus dirty flag, consumed on the render tick)? It removes both the blocking and the drop, makes the c11 memo purely an optimization, and matches the state-like semantics of the data. What argues against it, and what are its concurrency-ownership and teardown rules? [Claude, Codex]

10. **`ghostty_surface_set_focus` and `ghostty_surface_set_occlusion` also reach `.forever` pushes via `Surface.zig`, and c11 calls both from main on ordinary interaction (`GhosttyTerminalView.swift:3825, :3842, :5254, :5283, :5596, :5669`). Are those in scope?** If not, what stops the same deadlock recurring through them, and does that change your view of how much safety the c11 memo actually buys? Would a `pushFromAppThread` helper that makes the blocking variant unavailable to `embedded.zig` be the better shape? [Claude]

11. **Which of the two hot sites (`attachToView`'s reuse branch, `reconcileAttachedWindowIfNeeded`) becomes `force: false`?** If it is the reuse branch, how is commit `50f0dd334`'s frozen-terminal fix (#12) preserved, given `setMacOSDisplayID` deliberately restarts the display link even for an unchanged id? [Claude]

12. **Would keying the memo on `(displayID, window identity, attach epoch)` rather than displayID alone satisfy both goals**, suppressing steady-state churn while still kicking the link on real topology changes? [Claude]

13. **Please provide the exact source-location table for all current `ghostty_surface_set_display_id` call sites**, their intended `force` value, and the user-visible recovery scenario each `force: true` preserves. Include `TerminalSurface.setFocus`, `GhosttyNSView.viewDidMoveToWindow`, `becomeFirstResponder`, `windowDidChangeScreen`, and both independent focus paths. Then: what search-based audit proves no direct C calls remain outside the policy helper? [Codex]

14. **Which path owns the memo when `ghostty_surface_new` fails or replaces the surface pointer, and how is headless-startup-window to real-window migration represented?** What happens when a display ID is unavailable? [Codex]

15. **If a `force: true` push is dropped during a legitimate display change (window moved to another monitor), does the terminal render at the wrong refresh rate until the user interacts with the window again? Is that acceptable?** [Gemini]

### Tier 3: Validation and delivery

16. **What ghostty-level test will fill the renderer mailbox, invoke a display-ID update from a producer thread, prove prompt return, drain, and assert the final display ID was applied?** The described `c11LogicTests` memo test covers only the optional half; the load-bearing half currently ships untested. [Codex, Claude]

17. **Can the planned `c11LogicTests` seam run without constructing `Workspace`, `TabManager`, or AppKit terminal views in the bare xctest runner** (which crashes locally on a nil `NSApp`)? What behavior will it observe besides an internal call count? [Codex]

18. **Is there a way to force the mailbox full on demand** (a debug-gated flag that stops the renderer draining), so the deadlock is reproducible from a tagged build and the fix is demonstrably closed before it reaches users? [Claude]

19. **How will the tagged build instrument intentional vs deduplicated vs rejected/coalesced display-ID requests, and what numerical before/after assertion defines success?** Name the counter/log source and the expected counts for N `updateNSView` passes. [Codex, Claude]

20. **What portal-churn, focus-recovery, and cross-screen-movement flow will demonstrate that the historic stuck-vsync workaround remains intact on the tagged build?** A reduction in messages is a regression if it revives stuck-vsync. [Codex]

21. **Should the acceptance oracle be replaced?** "The Sentry issue does not recur" cannot validate this fix. Proposed: zero `__ulock_wait2` + `attachSurface` **episodes** in `hang.log` over 14 days of normal operator use, with Sentry as long-tail confirmation only. [Claude]

22. **What is the plan for the submodule and checksum sequence** (push to `Stage-11-Agentics/ghostty` before committing the parent pointer, `build-ghosttykit` regenerating `scripts/ghosttykit-checksums.txt`, run 1's three guard jobs expected red for ~10 minutes)? How will expected first-run guard failures be distinguished from real regressions, and is this on the critical path for the ticket's timeline? [Claude, Codex]

23. **"Offer upstream" to whom, concretely?** The standing rule here is no direct PRs against `manaflow-ai/*`. Is the intent to land in the Stage 11 fork and flag it to the operator? Which fork branch/remote carries it, and who owns pushing it before the c11 submodule pointer changes? [Claude, Codex]

### Tier 4: Adjacent and follow-up

24. **Why does the mailbox fill at all?** A renderer that does not drain for 14 hours means a visually dead pane independent of the main-thread wedge. Is it the `SharedGrid` write-lock contention from the prior BUG note, or something else? Is this a follow-up ticket? [Claude, Gemini]

25. **Will you update `notes/BUG-main-thread-deadlock-attachSurface.md`?** Its `SharedGridSet.lock` root cause is superseded (its own `Futex.Deadline.wait` frame indicates a condition variable, not a mutex), and its fix 3 is currently the standing advice for the next reader. [Claude]

26. **Roughly 40% of local captures (7910) show main idle in `mach_msg2_trap` while the watchdog reported a multi-second stall. Is that a watchdog false-positive class?** If so, how much of the 941-event Sentry volume is real, and should that go to C11-186? [Claude]

27. **Is there a case for shipping a bounded push (`.ns = 5ms`) as an immediate hotfix** while the fuller fix goes through the submodule and review cycle? Users are currently exposed to a force-quit-only 14-hour failure that destroys running agent sessions. [Claude]

28. **Should the two halves ship as separate PRs?** With the ghostty fix landed, the c11 memo is pure optimization and carries all the regression risk (#12, stale memo). [Claude]

---

## 5. Synthesized Readiness Verdict

**NEEDS REVISION.** 2 of 3 reviewers, and the two that did independent verification work.

### 5.1 Confidence-weighted summary

| Dimension | Verdict | Confidence |
|---|---|---|
| Root-cause diagnosis of the deadlock | Correct, well-proven | **Very high** (3/3, independently re-verified) |
| Two-layer fix decomposition | Correct shape | **Very high** (3/3) |
| Ghostty fix is load-bearing, memo is optimization | Correct | **High** (3/3, differing emphasis) |
| Notify-before-push ordering | Defective as specified | **High** (2/3 as defect; 3rd did not analyze coalescing) |
| Drop-on-full plus memo strands state | Defective as specified | **High** (2/3 as defect, 3/3 as concern) |
| Coalescing latest-value slot is the better mechanism | Recommended | **High** (2/3, reached independently) |
| Force taxonomy / memo lifecycle underspecified | Execution blocker | **High** (2/3) |
| No ghostty-side test, no delivery sequencing | Execution blocker | **High** (2/3) |
| Plan is filed against the wrong ticket | **Contested** | **Medium, but cheaply settleable** (1/3, best-evidenced) |
| Fix closes the whole blocking class | **No** | **Medium-high** (1/3 with file-and-line evidence contradicting the 3rd) |

### 5.2 Gate list to reach "ready"

Ordered so the cheapest disambiguating step runs first.

1. **Run the frame-0 offset resolution** against the 0.58.0+116 binary (Q1). One hour. Everything below branches on the result.
2. **Re-scope per the result.** If the deadlock is not the Sentry issue: open a dedicated P0 ticket for the attachSurface deadlock, leave C11-191 for the tab bar preference loop, and do not close the Sentry issue's ticket with this diff. If it is: state the resolved symbol in the plan and proceed.
3. **Replace the acceptance oracle** for the deadlock work with the `hang.log` episode count (Q21).
4. **Specify the delivery contract**: exact wake ordering that cannot strand a message, and an eventual-latest-value guarantee. Strongly prefer the coalescing slot (Q7, Q9) over log-and-drop.
5. **Close the stale-memo hole**: memo advances only on an accepted/coalesced request (Q8), and never on a mere FFI attempt.
6. **Extend to the class**, or state explicitly why `focusCallback` and `occlusionCallback` are out of scope (Q10).
7. **Produce the caller/force/rationale table** plus the audit proving no direct C calls outside the policy helper (Q13), and state how #12's frozen-terminal fix survives (Q11, Q12).
8. **Add the ghostty-side test** (full queue, prompt return, latest-ID convergence after drain) and a debug-gated repro switch (Q16, Q18).
9. **Add the submodule / checksum / upstream-routing sequence** to the execution steps (Q22, Q23).
10. **Add the tagged-build recovery scenario** (portal churn, focus, cross-screen) as a hard gate, not a nice-to-have (Q20).

### 5.3 Recommended sequencing (merged from Claude and Codex)

Both deeper reviewers independently proposed reordering the plan's own priority. Merged:

1. **Fix the blocking-push class in ghostty**, for the whole class, not one export. Highest value per line; converts an unrecoverable 14-hour UI death into, at worst, a dropped frame. Land in the Stage 11 fork, push before the parent pointer moves, flag upstream to the operator.
2. **Fix the actual C11-191 tab bar preference loop** (assuming Q1 confirms the misidentification). Highest user-visible frequency: 11 users in one day, 32 local episodes, some over 30 seconds. Small, local, testable.
3. **Memoize the display ID in c11**, as its own PR with its own review, once the force-policy inventory exists.
4. **Open a follow-up for "why does the renderer stall for 14 hours"** (Gemini's per-surface-dead-terminal residual; Claude's `SharedGrid` write-lock trace).

The plan as written orders this 3, 1, and omits 2 and 4.

### 5.4 Closing note

Nothing here impugns the quality of the investigation. All three reviewers rated the disassembly-verified attribution as the strongest piece of debugging in the pack, and the bug it found is real, severe, and worth a P0. The revisions requested are about **what the fix is filed against**, **whether the replacement delivery mechanism is actually lossless**, and **whether the work can be executed and validated as written**. The first of those is answerable in under an hour and should be answered before anything else.
