# Standard Plan Review: c11-191-plan (Claude)

**Plan:** `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md` (C11-191)
**Reviewer model:** Claude
**Date:** 2026-08-04

---

## Executive Summary

This plan contains the best piece of root-cause engineering I have seen in this repo's notes: a
disassembly-verified, log-corroborated identification of a genuine main-thread deadlock
(`attachSurface` -> `reconcileAttachedWindowIfNeeded` -> `ghostty_surface_set_display_id` ->
`.forever` push on a full 64-slot `BlockingQueue` -> `cond_not_full` futex wait). I independently
re-ran the log counts and they hold: 9433 captures with leaf `__ulock_wait2`, 9423 containing
`attachSurface`. The `.forever` push at `ghostty/src/apprt/embedded.zig:2176` is real, the
14-hour wedge is real, and the fix direction is right. That bug should absolutely be fixed.

But the plan opens by "correcting" the ticket's reading, and **the correction is wrong.** The
ticket's reading was right, and I can show it from the same log the plan mines.

Three independent lines of evidence:

1. **The plan's own epistemic rule refutes it.** The plan states, correctly, that symbol names in
   the Sentry dump drift but "module attribution is." Apply that rule: the Sentry stack's frame 0
   is module `c11`, frames 1-3 `SwiftUICore`, frame 6 `SwiftUI`, frame 17 `AttributeGraph`. There
   is no `libsystem_kernel.dylib` frame anywhere in the quoted range. The attachSurface deadlock
   *always* has `libsystem_kernel.dylib __ulock_wait2` at frame 0, in every one of the 9433 local
   captures. A futex-blocked thread cannot present a leaf frame in `c11`. By module attribution
   alone, the Sentry hang is not this deadlock.

2. **The Sentry signature exists verbatim in the operator's local log, locally symbolicated.**
   Searching the same `hang.log` for the tab bar path: 32 distinct hang episodes across 10+ pids
   contain `Bonsplit.TabBarView`. Example, pid 63572, 2026-06-17, `stalledMs=2037` (note: the same
   ~2s magnitude as the Sentry issue's 2335ms):

   ```
   0  AttributeGraph  AG::Graph::mark_changed(...)                 <- leaf, CPU-bound, no kernel wait
   2  SwiftUICore     StatefulRule ... LayoutComputer<_PaddingLayout>
   9  SwiftUICore     StackLayout.makeChildren
   19-30 SwiftUICore  LayoutProxy.size / _PaddingLayout.sizeThatFits (recursive)
   ...
   93 c11             Bonsplit.TabBarView.body ... GeometryReader ... ScrollView ...
                      preference<TrailingAccessoryWidthKey> ...
                      preference<SplitButtonsIntrinsicWidthKey> ...
   ```

   That is the ticket's stack, fully symbolicated, with the preference keys named. The hang is a
   CPU-bound SwiftUI layout/preference storm, not a blocking wait.

3. **The frequency profile matches the ticket, not the plan.** Of the 9423 attachSurface captures,
   **9412 come from a single pid (6063) in a single 14-hour episode.** Counting *episodes* rather
   than captures, the attachSurface deadlock appears in roughly **8 episodes across 7 pids in 51
   days** of the operator's logs. The TabBarView signature appears in **32 episodes across 10+
   pids**, with `stalledMs` values from ~2s to ~39s. A Sentry issue with 941 events across 11
   distinct users in one day is a high-frequency, broadly-distributed, few-second stall. That is
   the TabBarView profile. It is not the profile of a signature that fires under ten times in
   seven weeks on the heaviest user's machine.

**The single most important thing:** this plan is a correct fix for a different, also-serious bug.
Land it, but not as C11-191, and not with C11-191's acceptance criteria. The plan as written will
ship, close the ticket, and the 941-event Sentry issue will still be there on the next release,
because nothing in the diff touches the code path that produces it.

---

## What the actual C11-191 fix looks like (handed over, since I found it)

`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`:

- Lines 730-749: two `GeometryReader` -> `.preference(...)` writers inside the trailing-accessory
  `HStack`, publishing `TrailingAccessoryWidthKey` and `SplitButtonsIntrinsicWidthKey`.
- Lines 794-809: `.onPreferenceChange` handlers for both keys write `@State`
  (`trailingAccessoryWidth`, `splitButtonsIntrinsicWidth`, `effectiveChromeWidth`) **with no
  equality or epsilon guard**.
- Line 722: `chromeWidth` (derived from that state) feeds `.frame(width:)` on a sibling in the same
  subtree.

That is the textbook SwiftUI preference/layout feedback loop: measure -> write state -> resize ->
re-measure. `max(0, width)` is the only normalization; a sub-point oscillation, a `.saturation`
change, or a hover flag re-entering the body restarts the cycle, and the cost is superlinear in tab
count because the recursion runs through the tab `ForEach`. The nested `_PaddingLayout` /
`StackLayout` recursion in the captured stack (frames 19-38 alternating identical padding/stack
frames) is what a 2.3s pass looks like from the inside.

The likely small fix: guard both `onPreferenceChange` writes behind an epsilon comparison
(`guard abs(normalizedWidth - trailingAccessoryWidth) > 0.5 else { return }`), and confirm
`effectiveChromeWidth` is only assigned when it actually changes. That change is testable with a
deterministic layout-pass counter and is a plausible one-afternoon PR. I would want that measured
before assuming it is sufficient, but it is where the evidence points, and it is exactly where the
ticket said to look.

---

## The Plan's Intent vs. Its Execution

The stated intent is "fix the top Sentry hang." The executed intent is "fix the hang I found in my
own logs." Those diverged the moment the plan decided the ticket's stack was untrustworthy, and the
plan never checked back.

The specific methodological gap: the plan applies a high standard of proof to the *fix* (disassemble
the shipped binary, match return-address offsets, read the Zig) and a low standard to the
*identification* (outer frames 16-21 look similar, therefore same bug). Frames 16-21
(`GraphHost.updatePreferences` -> `AGGraphGetWeakValue` -> `value_ref` -> `update_attribute` ->
`UpdateStack::update`) are the common prefix of essentially every SwiftUI-driven main-thread hang in
this app. Locally, `updatePreferences` appears 9658 times in a log where the attachSurface
signature accounts for at most 9423 lines and the TabBarView signature for another few hundred. It
is a shared trunk, not a fingerprint. Matching on it is like identifying a caller by "the call came
from a phone."

There is one cheap, decisive check the plan should have run and did not: take one Sentry event's
raw frames for the 0.58.0+116 build, and do to them exactly what the plan did to the local log,
namely resolve the offsets against that binary. If frame 0's offset resolves inside
`MiddleClickCapture` or anywhere in the tab bar subtree, the identification is settled against the
plan. If it resolves inside `attachSurface`, the plan wins outright. Either way the argument ends.

Credit where due: the plan's demolition of frame 4 (`Foundation.URL? outlined copy` cannot be a
caller, outlined copy helpers are leaves) is exactly right, and the general lesson (do not trust
nearest-exported-symbol names in a stripped release dump) is correct and worth keeping in the repo's
institutional memory. The error is in over-applying it to the module column too.

---

## Architectural Assessment (of the deadlock fix, on its own merits)

The two-part decomposition (reduce push frequency in c11, make the push non-blocking in ghostty) is
the right shape: one part reduces pressure, one part removes the failure mode. But the weighting is
backwards in the writeup, and there are four substantive technical problems.

### 1. The proposed notify-before-push ordering introduces a lost-wakeup bug

The plan says: "Notify the renderer first so it can drain, then push `.instant`."

`wakeup` is an `xev.Async`, which **coalesces**. Sequence: notify -> renderer wakes -> `drainMailbox`
drains everything -> renderer renders and parks -> *then* our `.instant` push lands in a now-empty
mailbox and succeeds -> no notify follows -> the message sits undelivered until some unrelated
future wakeup. The display id, whose entire purpose is to unstick a stalled `CVDisplayLink`, may
therefore be delivered arbitrarily late or effectively never on an idle surface. That is the exact
frozen-pane symptom this code path exists to prevent.

The notify-first move also does not buy what it claims. If the renderer is healthy, the mailbox is
not full and the ordering is irrelevant. If the renderer is wedged (the case that matters), notify
does nothing and the `.instant` push fails anyway. So the reorder costs delivery reliability and
purchases a race that only helps in the narrow "renderer is slow but not stuck, and happens to drain
within microseconds" window.

Correct orderings, in preference order:
- `push(.instant)` then `notify()` (today's order, just with the timeout changed). On failure,
  `notify()` and handle the drop.
- `notify()`, `push(.instant)`, `notify()` if you really want the pre-drain attempt. Cheap, and it
  closes the lost wakeup.

### 2. Drop-on-full plus memoization can permanently strand a stale display id

These two fixes interact badly and the plan does not address it. `ghostty_surface_set_display_id`
returns `void`. If the push is dropped because the mailbox is full, the Swift side has no way to
know, so the memo records "display id X is current" for a value ghostty never received. Every
subsequent `force: false` site then skips the push. The surface is now pinned to a stale display
link with no non-forced path back. This converts a transient deadlock into a persistent visual
freeze, which is arguably a worse user experience than a 2s stall.

Fixes, in preference order:
- Change the export to `bool` (or a small status enum) and only update the memo on an accepted push.
  `void` -> `bool` is source-compatible for callers that ignore the result and ABI-safe here.
- Better: stop modeling this as an event at all. The display id is *latest-value-wins state*, not a
  message. Put a `std.atomic.Value(u32)` (plus a dirty flag) on the renderer thread, have
  `ghostty_surface_set_display_id` store it and notify, and consume it in the render/drain tick.
  It cannot block, cannot drop, cannot go stale, and it removes the memoization requirement on the
  c11 side entirely. That is a cleaner upstream contribution than a log-and-drop, and it makes fix 1
  a pure performance optimization rather than a correctness dependency.

### 3. `set_display_id` is not the only main-thread-reachable `.forever` push

The plan frames the ghostty change as fixing "the" blocking call. It is the only `.forever` push in
`embedded.zig`, which is probably where the impression came from. But the exports delegate into
`Surface.zig`, which has several:

- `ghostty_surface_set_focus` -> `Surface.focusCallback` -> `renderer_thread.mailbox.push(..., .forever)`
- `ghostty_surface_set_occlusion` -> `Surface.occlusionCallback` -> `... .forever`
- plus `setFontSize`, inspector toggles, and the size/config paths.

c11 calls both focus and occlusion from the main thread, frequently, on ordinary interaction
(`GhosttyTerminalView.swift:3825`, `:3842`, `:5254`, `:5283`, `:5596`, `:5669`). Any one of them
into a full mailbox wedges main identically. This matters directly for the plan's risk story:
**fix 1 (memoizing the display id) does not make main safe**, because focus and occlusion pushes
remain. The correct framing is a class fix: no apprt-facing export may block its caller. Either
convert those `.forever` pushes on app-thread-reachable paths, or add a `pushFromAppThread` helper
in `Surface.zig` that is `.instant` plus a notify, and make the blocking variant unavailable to
`embedded.zig`. That is also a stronger, more obviously-generic upstream offer.

### 4. The memo may silently revert "Fix frozen terminals after split churn" (#12)

The re-assert in `attachToView`'s reuse branch (`GhosttyTerminalView.swift:3285-3298`) is not
incidental; it was added by commit `50f0dd334` ("Fix frozen terminals after split churn", #12) and
carries a comment saying exactly why it must fire even when nothing appears to have changed: after
split-close restructuring the view is removed and re-added, window/screen can be transiently nil,
and the display link needs a kick or the surface looks frozen. `setMacOSDisplayID` in
`generic.zig:1008-1025` confirms this: on a re-assert with the *same* id it does a
`stop()`/`start()` of the display link precisely to recover the silent-no-callbacks state.

The plan lists "topology churn" among the `force: true` sites, but the reuse branch *is* the
topology-churn site, and the plan elsewhere names it as one of the two hot sites to be
de-forced. This is ambiguous at best and a regression at worst. The right discriminator is not
"did the display id change" but "did the attachment topology change." Suggestion: key the memo on
`(displayID, ObjectIdentifier(window), attachEpoch)` and bump the epoch on any view/window
reparent, so genuine churn still kicks the display link while steady-state SwiftUI updates
(hover, active markers, visibility flags, the actual high-frequency source) are suppressed. That
preserves #12 and still gets the ~N-to-1 reduction the plan wants.

---

## Is This the Move?

Partly. Ranked by what I would actually do:

1. **Fix the blocking-push class in ghostty.** Highest value per line of code. It converts an
   unrecoverable 14-hour UI death that force-kills 22 agent sessions into, at worst, a dropped
   frame. It is generic, it is small, and it is the kind of change that ages well. Do this first
   and do it for the whole class, not one export.
2. **Fix the actual C11-191 tab bar preference loop.** Highest user-visible frequency: 11 users in
   one day, 32 local episodes, some over 30 seconds. Small, local, testable.
3. **Memoize the display id in c11.** Genuinely good hygiene (calling into a cross-thread mailbox
   on every SwiftUI update is wasteful regardless), but with the ghostty fix landed it is an
   optimization, not a safety property. Doing it third also removes the pressure to rush the
   memo-vs-#12 interaction.

The plan effectively orders this 3, 1, and omits 2. That is the wrong order, and the omission is
the ticket.

One more priority note the plan should not drop: **why does the mailbox fill in the first place?**
64 slots and a renderer that never drains for 14 hours is not a transient. The prior note
(`notes/BUG-main-thread-deadlock-attachSurface.md`) traced 21 renderer threads thrashing
`SharedGrid`'s exclusive write lock across glyph rasterization and font fallback. Making main immune
is correct and urgent, but a renderer stalled long enough to fill 64 slots means a visually dead
pane for the user. That deserves its own ticket, not silence.

---

## Reconciling with the prior BUG note (the plan should do this explicitly)

The plan supersedes `notes/BUG-main-thread-deadlock-attachSurface.md`'s root cause without saying
so. Worth being explicit, because the note's own evidence actually *supports* the plan:

The note's `/usr/bin/sample` stack shows `Thread.Futex.Deadline.wait` above `__ulock_wait2`. In Zig
stdlib, `Futex.Deadline` is used by `std.Thread.Condition`'s futex implementation;
`std.Thread.Mutex`'s futex path calls `Futex.wait` directly, without a `Deadline`. So the sampled
frame is a **condition-variable** wait, i.e. `cond_not_full.wait`, not the `SharedGridSet.lock`
mutex the note inferred. The plan is right and the note is wrong, and the plan should say so and
update the note, because the note's proposed fix 3 (restructure `SharedGridSet.ref` and
`SharedGrid.getIndex`/`renderGlyph` locking) is currently the standing advice for anyone who reads
it next. That work may still be worth doing as the "why does the renderer stall" follow-up, but it
is not the fix for this deadlock.

Also worth stating in the plan: between `__ulock_wait2` (frame 0) and `attachSurface` (frame 1) the
real call stack has at least six frames (`pthread_cond_wait`, `Futex.Deadline.wait`,
`Condition.timedWait`, `BlockingQueue.push`, `ghostty_surface_set_display_id`,
`reconcileAttachedWindowIfNeeded`). They are missing because libghostty is built without frame
pointers, so the FP-walking backtrace skips them. That is fine, but a plan that spends a paragraph
teaching the reader not to trust symbolication should not then present a frame-skipped stack without
the caveat. One `lldb` thread backtrace from a live wedged process would remove all doubt.

---

## Key Strengths

- **Disassembly-verified attribution.** Matching `attachSurface + 372` and `+ 388` against actual
  `bl` targets in the shipped binary is the correct standard of proof for a symbol-drift
  environment, and it is rarely done. This is the plan's best move.
- **Reading the blocking primitive to ground truth.** Following `set_display_id` into
  `BlockingQueue.push`'s `.forever` branch and identifying the notify-after-push ordering is exactly
  the right depth. The bug is real and the analysis is airtight.
- **Correctly rejecting an impossible frame.** The outlined-copy-helpers-are-leaves argument is
  sharp and generalizes.
- **Preferring a local, untruncated, locally-symbolicated corpus to a truncated remote one.** Right
  instinct. The failure was in querying that corpus for only one signature.
- **Naming the ghostty change as generic and upstream-offerable.** Correct per the repo's
  bidirectional-upstream policy, and correct on the merits.

## Weaknesses and Gaps

- **Misidentification of the ticket's issue** (detailed above). Downstream effect: ticket closes,
  Sentry issue persists, next audit rediscovers it, and the AAR record says "we fixed C11-191"
  when we did not.
- **Notify-before-push lost wakeup** (detailed above). Downstream effect: intermittent frozen
  panes, the hardest class of bug to reproduce, introduced by a fix for freezing.
- **Drop plus memo strands stale state** (detailed above). Downstream effect: a persistent freeze
  replacing a transient hang.
- **Only one of several blocking exports addressed.** Downstream effect: the deadlock survives the
  fix on the focus and occlusion paths, and the next occurrence looks like a regression of a
  "fixed" bug.
- **Possible silent revert of #12.** Downstream effect: split-close freezes return with no test
  guarding them.
- **Acceptance criteria are not falsifiable for the work being done.** "The Sentry issue does not
  recur" cannot validate this fix (it will recur, because it is a different bug) and the plan
  inherits it unchanged. The right oracle is right there in the plan's own evidence: count
  `__ulock_wait2` + `attachSurface` episodes in `hang.log` over a comparable window post-fix. That
  is a clean, local, fast signal. Add "zero episodes over 14 days of normal operator use" as the
  gate.
- **No test for the ghostty change.** The described `c11LogicTests` memo test covers fix 1 only.
  Fix 1 is the optional half. The load-bearing half ships untested. Suggest: a Zig unit test that a
  full `BlockingQueue` returns 0 from an `.instant` push without blocking (trivial, and it locks
  the timeout choice in), plus a debug-gated "renderer stops draining" env flag that makes the
  deadlock reproducible on demand from a tagged build. Without a repro switch, nobody can prove the
  fix works before shipping it to users.
- **No mention of the ghostty submodule and checksum workflow.** `CLAUDE.md` documents that a
  ghostty SHA bump requires a matching `scripts/ghosttykit-checksums.txt` entry generated by the
  `build-ghosttykit` workflow, that run 1 will show three guard jobs red for ~10 minutes, and that
  the submodule commit must be pushed to `Stage-11-Agentics/ghostty` *before* the parent pointer is
  committed. A plan whose second half is a submodule change should schedule that, or the delegator
  will burn an hour rediscovering it and may commit an orphaned detached-HEAD SHA.
- **"Offer upstream" needs a routing correction.** The standing rule for this repo is never to
  push, branch, or PR against `manaflow-ai/*` (the ghostty submodule's `origin`). "Offer upstream"
  here means: land it in the Stage 11 fork, and flag it to the operator with a one-liner so they
  decide. The plan should say that, not imply a direct upstream PR.
- **Statistical framing.** "One signature dominates: 9433 captures" is technically true and
  practically misleading, since 9412 of them are one episode. A capture-weighted count of a
  persist-sampling watchdog is a duration metric, not a frequency metric. Report episodes and pids
  alongside captures. This is the specific analytical slip that produced the misidentification.
- **Unexamined: 7910 captures (roughly 40% of the corpus) have frame 0 =
  `libsystem_kernel.dylib mach_msg2_trap`**, i.e. main parked idle in `CFRunLoopServiceMachPort`
  while the watchdog declared a multi-second stall. Either the watchdog has a large false-positive
  class (main in a nested/tracking runloop mode not servicing the probe), or the probe mechanism
  itself is the thing being starved. Not this plan's job, but it bears on whether "941 events" is a
  trustworthy denominator at all, and it is worth a line to C11-186.

---

## Alternatives Considered

**A. Atomic latest-value-wins display id instead of a mailbox message.** Store the id in a
`std.atomic.Value(u32)` plus dirty flag, consume on the render tick. Cannot block, cannot drop,
cannot go stale, removes the need for the Swift memo to be correctness-critical, and it is a
smaller conceptual change to explain upstream than "this one message type is now lossy." Slightly
more divergence from the mailbox idiom. **I would pick this over the plan's approach.**

**B. Bounded push (`.ns = 5_000_000`) instead of `.instant` plus drop.** One-token change,
converts an unbounded deadlock into a 5ms worst-case stall, keeps delivery semantics essentially
intact, and needs no memo interaction analysis. Weaker than A but shippable today, and a good
*first* commit if the submodule/checksum dance means the real fix lands days later. Worth
considering as an immediate mitigation given this bug currently costs users 14-hour UI deaths.

**C. Make `attachSurface` fully asynchronous from `updateNSView`** (the prior note's fix 1). Fixes
the whole class on the c11 side, including any future blocking ghostty call from the layout pass.
But it is a large, racy change to a typing-latency-sensitive path with an existing deferred-attach
state machine, and it does not remove the underlying "an apprt export can block forever" hazard for
other callers. Right long-term, wrong for this ticket. The plan's choice to fix the callee is
better.

**D. Do nothing on the c11 side (skip fix 1 entirely).** With A or B landed, the memo is pure
optimization. Given that fix 1 is the piece with the #12 regression risk and the stale-memo
interaction, deferring it to a follow-up PR with its own review is defensible and would let the
safety fix ship faster and cleaner. I would at least consider splitting the PRs.

**E. For the real C11-191:** the alternative to epsilon-guarding the preference writes is
restructuring so the trailing accessory's width is not measured-then-fed-back at all (fixed/
intrinsic width, or measurement moved out of the layout-affecting subtree). Cleaner, more invasive,
and it touches vendored bonsplit. Start with the guard, measure, escalate only if the storm
persists.

---

## Readiness Verdict

**Needs revision.** Not because the engineering is weak, it is strong, but because the plan is
pointed at the wrong ticket and has four concrete technical defects in the fix as specified.

What changes the verdict to ready:

1. **Re-scope.** Either open a new ticket for the attachSurface deadlock (it deserves a P0 of its
   own: unrecoverable, 14 hours, destroys agent sessions) and leave C11-191 for the tab bar
   preference loop, or explicitly retitle C11-191 and re-file the Sentry issue. Do not close the
   Sentry issue's ticket with this diff.
2. **Replace the acceptance oracle** for the deadlock work with the `hang.log` episode count
   (`__ulock_wait2` + `attachSurface`, zero episodes over 14 days), and keep Sentry only as a
   long-tail confirmation.
3. **Fix the push ordering** to `push` then `notify` (or notify/push/notify). Do not ship
   notify-then-push.
4. **Close the stale-memo hole**, ideally by adopting alternative A, otherwise by returning a status
   from the export and only memoizing accepted pushes.
5. **Extend to the class**: `focusCallback` and `occlusionCallback` are equally main-reachable and
   equally `.forever`.
6. **State explicitly** how the `attachToView` reuse-branch memo preserves #12's frozen-terminal
   fix, and add a test or a documented manual check for split-close churn.
7. **Add the ghostty submodule/checksum sequence** to the execution steps.

If the plan author disagrees with the identification argument, item 1 can be settled empirically in
under an hour by resolving one Sentry event's frame-0 offset against the 0.58.0+116 binary. I would
do that before anything else, and I would be glad to be wrong.

---

## Questions for the Plan Author

1. What is the resolved symbol for **frame 0's offset** in a real Sentry event for 0.58.0+116, when
   resolved against that binary the same way you resolved `attachSurface + 372`? This settles the
   identification question outright.
2. How do you account for the Sentry stack having **no `libsystem_kernel.dylib` frame**, given that
   all 9433 local captures of the deadlock have `__ulock_wait2` at frame 0? Is there a capture path
   that would elide kernel frames in the Sentry variant but not the local one?
3. Did you search `hang.log` for the **TabBarView signature** before concluding the ticket's reading
   was wrong? It is present in 32 episodes across 10+ pids, with `stalledMs` from ~2s to ~39s, and
   the fully symbolicated frame 93 names `Bonsplit.TabBarView.body` with both preference keys. What
   is your read of that capture?
4. Of the 9423 attachSurface captures, **9412 are from pid 6063's single 14-hour episode**. Counting
   episodes rather than captures gives roughly 8 in 51 days. Does that frequency square with 941
   events across 11 users in one day, and if so, by what mechanism?
5. `wakeup` is an `xev.Async` and coalesces. In your notify-then-push ordering, what prevents the
   renderer from draining and parking before the `.instant` push lands, leaving the display id
   undelivered until an unrelated wakeup?
6. When a push is dropped because the mailbox was full, how does the Swift memo learn it must not
   record that id as sent? Are you willing to change `ghostty_surface_set_display_id` to return a
   status?
7. Have you considered replacing the message with an **atomic latest-value-wins field** on the
   renderer? It removes both the blocking and the drop, and makes the c11 memo purely an
   optimization. What argues against it?
8. `ghostty_surface_set_focus` and `ghostty_surface_set_occlusion` also reach `.forever` pushes via
   `Surface.zig`, and c11 calls both from main on ordinary interaction. Are those in scope? If not,
   what stops the same deadlock recurring through them, and does that change your view of how much
   safety fix 1 actually buys?
9. Which of the two hot sites (`attachToView`'s reuse branch, `reconcileAttachedWindowIfNeeded`)
   becomes `force: false`? If it is the reuse branch, how is commit `50f0dd334`'s frozen-terminal
   fix preserved, given `setMacOSDisplayID` deliberately restarts the display link even for an
   unchanged id?
10. Would keying the memo on `(displayID, window identity, attach epoch)` rather than displayID
    alone satisfy both goals, suppressing steady-state churn while still kicking the link on real
    topology changes?
11. How will the fix be **validated before it reaches users**? Is there a way to force the mailbox
    full on demand (a debug-gated flag that stops the renderer draining), so the deadlock is
    reproducible and the fix demonstrably closes it?
12. Are you adding any test for the ghostty half? The described logic test covers only the memo,
    which is the optional half.
13. What is the plan for the **submodule and checksum sequence** (push to `Stage-11-Agentics/ghostty`
    first, `build-ghosttykit` regenerating `scripts/ghosttykit-checksums.txt`, run 1 expected red)?
    Is that on the critical path for this ticket's timeline?
14. "Offer upstream" to whom, concretely? The standing rule here is no direct PRs against
    `manaflow-ai/*`. Is the intent to flag it to the operator?
15. Will you **update `notes/BUG-main-thread-deadlock-attachSurface.md`**? Its `SharedGridSet.lock`
    root cause is superseded (its own `Futex.Deadline.wait` frame indicates a condition variable,
    not a mutex), and its fix 3 is currently the standing advice for the next reader.
16. Why does the mailbox fill at all? A renderer that does not drain for 14 hours means a visually
    dead pane independent of the main-thread wedge. Is that a follow-up ticket, and does the prior
    note's `SharedGrid` write-lock analysis survive scrutiny as its cause?
17. Roughly 40% of local captures (7910) show main **idle in `mach_msg2_trap`** while the watchdog
    reported a multi-second stall. Is that a watchdog false-positive class? If so, how much of the
    941-event Sentry volume is real, and should that go to C11-186?
18. If the identification turns out to be wrong, do you want this work re-filed as its own ticket
    with its own acceptance criteria, or folded under C11-186 (make main-thread hangs survivable)?
19. Is there a case for shipping a **bounded push (`.ns = 5ms`)** as an immediate hotfix while the
    fuller fix goes through the submodule and review cycle? Users are currently exposed to a
    14-hour, force-quit-only failure that destroys running agent sessions.
