# Adversarial Plan Review: c11-191-plan (Claude)

Reviewed: 2026-08-04 16:13
Plan: `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md` (C11-191)
Reviewer stance: designated adversary. Nothing here is balanced by design.

---

## Executive Summary

The plan is well-executed engineering attached to the wrong ticket, resting on a
statistic that does not mean what the plan says it means.

The mechanism it describes is real and I verified it independently: `ghostty_surface_set_display_id`
does a `.forever` push into a 64-slot `BlockingQueue`, `push` waits on `cond_not_full`, the
notify happens after the push, and c11 calls this from `updateNSView` on the main thread on every
SwiftUI update. That is a genuine main-thread deadlock hazard and it deserves a fix. Good find.

But the plan's central claim, that this signature "dominates" and therefore explains Sentry issue
C11-30, is a counting artifact. I re-ran the operator's own `hang.log` (151 MB, the plan's own
source) and counted by **episode** rather than by **capture**:

| Marker | Episodes containing it | Share of 5004 episodes |
|---|---|---|
| `updatePreferences` | 232 | 4.6% |
| `TabBarView` | 32 | 0.6% |
| `__ulock_wait2` | 20 | 0.4% |
| **`attachSurface`** | **11** | **0.2%** |
| `ghostty_surface*` | 7 | 0.1% |
| `ScrollViewReader` | 2 | 0.0% |
| `MiddleClick` | 1 | 0.0% |

And by pid:

| pid | captures containing `attachSurface` | hang episodes in that pid |
|---|---|---|
| **6063** | **9413** | 168 |
| 58841 | 4 | 611 |
| 73428 / 49143 / 48286 / 47696 / 26839 / 1752 | 1 each | 111 to 466 |

9413 of 9423 `attachSurface` captures come from a **single process**, pid 6063, which is the
already-documented 2026-07-28 incident in `notes/BUG-main-thread-deadlock-attachSurface.md`. The
"dominant signature" is one never-ending episode sampled 9412 times by a persist loop. Across 59
process lifetimes and 5004 hang episodes, this bug shows up meaningfully **once**.

Meanwhile the marker the plan dismisses (`TabBarView`) appears in 3x more episodes, and the outer
SwiftUI shape the ticket names (`updatePreferences`) appears in 21x more episodes.

Reproduce:

```
awk '/^=== c11 hang\.begin/ {ep++; for(m in seen) if(seen[m]) c[m]++; delete seen; next}
     {if($0~/TabBarView/)seen["TabBarView"]=1; if($0~/attachSurface/)seen["attachSurface"]=1;
      if($0~/__ulock_wait2/)seen["ulock"]=1; if($0~/updatePreferences/)seen["updPrefs"]=1}
     END{for(m in seen) if(seen[m]) c[m]++; print "episodes="ep; for(m in c) print m, c[m]}' \
  ~/Library/Logs/c11/hang.log
```

**Single biggest issue:** the plan reclassifies a high-volume, 11-user, 941-event production issue
as a different, essentially single-machine, single-episode bug, and then proposes acceptance
criteria that cannot close the ticket's actual acceptance criteria. If this ships as written, C11-191
gets marked done and Sentry C11-30 keeps firing.

**Concern level: high on scoping and acceptance, medium on the fix itself** (two concrete defects
below, both fixable in an afternoon).

---

## How Plans Like This Fail

Failure patterns for "root-cause a production hang" work, and where this plan sits in each:

1. **Mechanism precision substitutes for sample representativeness.** The plan disassembles a release
   binary to byte offsets. That is genuinely impressive and it earns unearned trust for everything
   downstream, including the leap from "one process wedged" to "this is what 11 users hit." Precision
   at the instruction level tells you nothing about incidence. This plan makes exactly that trade.

2. **Capture-weighted statistics on a persist-sampling watchdog.** A watchdog that re-samples a
   permanent wedge produces unbounded capture counts for exactly the bugs that never terminate. Any
   metric computed over captures is structurally biased toward permanent deadlocks and away from the
   2.3 second stalls that actually annoy 11 users daily. The plan uses capture counts as its only
   quantitative argument.

3. **N=1 on the maintainer's own machine.** The operator runs 21+ surfaces with 22 agent TUIs under
   load average 7. That is not the 11-user population. Fixing what the maintainer's box does is the
   most common way a performance program drifts away from its users.

4. **Ticket drift without ticket amendment.** The plan rewrites the problem statement in a plan file.
   The ticket's ACCEPTANCE block still says "a reproduction (many tabs + tab bar interaction) that
   stalls main >1s before the change and does not after." Nothing in the plan produces that. A
   downstream validator will either block forever or rubber-stamp.

5. **Removing a defensive workaround without a regression test for the bug it was defending against.**
   The re-assert at `GhosttyTerminalView.swift:3285-3298` exists because surfaces visually froze
   during split-close restructuring. The plan turns it off. Its only proposed test counts pushes. No
   test, no repro, no screenshot covers "panes still render after split-close churn."

6. **Converting a visible block into an invisible drop.** Fix 2 turns a hang into a silently dropped
   message. Hangs are loud and get tickets. Stale display IDs are quiet and produce "sometimes a
   pane just stops updating" reports six weeks later that nobody connects to this change.

7. **Cross-repo fixes that underestimate the tax.** A ghostty submodule change in this repo means:
   push to `Stage-11-Agentics/ghostty` first, bump the pointer, then a ~10 minute Zig build in
   `build-ghosttykit`, then a second CI run to go green, with run 1 red by design. The plan says none
   of this.

---

## Assumption Audit

### Load-bearing, and I do not believe them

**A1. Sentry C11-30 and the local `attachSurface` deadlock are the same bug.**
This is the entire justification for the plan. Evidence against, all of it available to the plan author:

- **Build mismatch.** Sentry: `com.stage11.c11@0.58.0+116`, events dated 2026-07-25. Local incident:
  pid 6063, 2026-07-29, running 0.60.1 (121) per the BUG note.
- **Duration shape.** Sentry title is "main thread hang 2335ms," a bounded stall. Local signature is
  13h58m with no `hang.end`. A permanent deadlock does not present as a stable 2.3s title, and 941
  events across 11 users in one day is a recurring-and-recovering profile, not a wedge profile. Users
  who deadlock force-quit; they do not generate 85 events each.
- **Population.** 11 distinct Sentry users versus 1 local pid that actually reproduces it (7 other
  pids show a single incidental frame each).
- **The plan's own trust rule refutes it.** The plan says c11 symbol names in the Sentry dump are
  untrustworthy but "module attribution is." Apply that rule: Sentry frame 0 is module `c11`, frames
  1-3 and 5-8 are `SwiftUICore`/`SwiftUI`. There is **no `libsystem_kernel` frame anywhere in the
  quoted stack**. A `__ulock_wait2` futex block always has `libsystem_kernel.dylib` at the leaf. By
  the plan's own standard, the Sentry hang is not a futex block at all. The plan cannot have it both
  ways: either module attribution is reliable, in which case its conclusion is wrong, or it is not,
  in which case the plan has no evidence linking the two at all.

**A2. Sentry frames 16-21 are a distinguishing fingerprint.**
`GraphHost.updatePreferences -> AG::Graph::UpdateStack::update` is the generic shape of *any*
main-thread hang inside a SwiftUI update. It appears in 232 local episodes spanning many different
inner causes. Matching on it is like matching two crime scenes because both had oxygen.

**A3. The renderer thread stopping is the exogenous input, and c11 need not care why.**
The plan never asks why the renderer stopped draining. The prior BUG note has a candidate:
21 renderer threads thrashing `SharedGrid`'s exclusive write lock during glyph misses, with Zig's
`DefaultRwLock` offering no fairness. If that is the cause, then after this fix main no longer
deadlocks but **the surfaces are still frozen**, because the renderer is still starved. The plan
would ship, the beachball would go away, and the panes would still stop drawing. Nobody would know
whether the ticket was fixed.

**A4. `.instant` + log-and-drop is safe.**
See "Challenged Decisions"; combined with fix 1's memo this is an outright correctness bug.

**A5. The enumerated `force: true` sites cover every unstick case.**
I checked: sites at `:3807` (topology churn), `:3835` (focus), `:5262` (becomeFirstResponder),
`:4541` (viewDidMoveToWindow), `:6620` (windowDidChangeScreen), `:3660` (createSurface) do exist and
their comments do describe the stuck-vsync scenarios. So this assumption is *plausible*. But
"plausible" is not "tested," and the reuse-branch comment at `:3278` explicitly lists a case the
force sites may not cover: the view being removed and re-added with `window`/`screen` briefly nil,
without a focus change and without a screen change. The plan asserts coverage; it does not
demonstrate it.

### Load-bearing and probably fine

**A6. `attachSurface + 372` is the return address after `bl reconcileAttachedWindowIfNeeded`.**
The disassembly is checkable and the +388 corroboration is a nice touch. I accept it.

**A7. `reconcileAttachedWindowIfNeeded`'s only blocking primitive is the display-id push.**
Verified by reading it: `releaseHeadlessStartupWindowIfNeeded` does `window.contentView = nil;
window.close()`, `screen.displayID` is a property read. Nothing else blocks. Accepted, though the
plan should state that it checked rather than asserting it.

**A8. The plan is right and the prior BUG note is wrong about the lock.**
The plan never says this, but it should, and it has stronger support than it realizes. The note's
`/usr/bin/sample` shows `Thread.Futex.Deadline.wait`. Zig's `std.Thread.Mutex` futex path calls
`Futex.wait` directly; `std.Thread.Condition`'s futex impl is what constructs a `Futex.Deadline`
(with a null timeout for the infinite case). So the sampled frame is consistent with
`cond_not_full.wait` and inconsistent with `SharedGridSet.lock`. The plan should make this argument
explicitly and supersede the note, because right now the repo contains two documents asserting two
different root causes for the same pid, and the next agent will re-litigate it from scratch.

### Invisible assumptions

- That the `BlockingQueue` is SPSC as its own doc comment claims. It is not: main, the IO thread
  (`stream_handler.zig:172`), and termio (`Termio.zig:516`) all push into the renderer mailbox. The
  plan inherits an already-violated invariant without noticing.
- That macOS display IDs are stable identities suitable for memoization. They are reused across
  display disconnect/reconnect.
- That `NSScreen.main` (the fallback in both hot sites) is an acceptable value to memoize. It is the
  screen with keyboard focus, not the surface's screen.
- That "offer upstream" is an action an agent may take. Per repo memory it is not: never push,
  branch, or PR against `manaflow-ai/*`. This must read "flag to operator."
- That a `c11LogicTests` test can construct the memo seam. CLAUDE.md warns that logic tests
  constructing `Workspace`/`TabManager`/surface objects crash locally on nil `NSApp`. The plan's
  test needs a pure seam and does not describe one.

---

## Blind Spots

**B1. The actual starvation bug, one level down, is untouched.** `BlockingQueue.pop` signals
`cond_not_full` **once**. `drain()`'s `deinit` also signals **once**, after emptying all 64 slots.
With three producers blocked on a full queue, draining the entire mailbox wakes exactly one of them.
That is the mechanism by which a producer waits 14 hours. The correct fix is `broadcast()` (or one
signal per popped item). The plan makes main immune and leaves the IO thread and termio still
subject to it. A starved termio producer means terminal output stalls, which is a user-visible bug
that survives this plan intact. This is the single most valuable thing the plan is missing.

**B2. A guard against the whole class.** There are 18 `.forever` pushes in ghostty. Exactly one is
reachable from main today. Nothing in the plan prevents the 19th. A debug-only assertion that
`.forever` is never used on the main thread (or a c11-side `assert(!Thread.isMainThread)` wrapper
around blocking libghostty entry points) would convert this from a one-off fix into a class fix.

**B3. The ghostty submodule and xcframework workflow.** Zero mention of: pushing to the
`Stage-11-Agentics/ghostty` fork before bumping the pointer, `scripts/ghosttykit-checksums.txt`
needing a matching entry, the `build-ghosttykit` workflow generating it, the expected run-1-red /
run-2-green pattern, or the 10 minute Zig build. A delegator following this plan will hit three red
CI jobs and misdiagnose them. Also: if the plan adds a return value to `ghostty_surface_set_display_id`
(recommended below), the vendored header changes too.

**B4. Existing repro tooling is ignored.** `scripts/repro-c11-18.sh` drives portal churn and
`C11_PORTAL_DEBUG=1` logs bind/detach/sync events to `/tmp/c11-portal.log`. The prior BUG note names
both as the natural starting point for a reduction. The plan uses neither.

**B5. No reproduction of either bug.** The plan has no repro for the deadlock (it is opportunistic
and happened once) and no repro for the tab-bar stall the ticket demands. "We fixed it" will be
unfalsifiable in both directions.

**B6. Post-ship verification has no owner or clock.** The ticket says judge by issue presence and
user count on the next release. Who checks? At what install count? For how long? What is the
rollback trigger? None of this is in the plan.

**B7. C11-186.** If the deadlock is 0.2% of episodes, then "make main-thread hangs survivable"
(C11-186) delivers far more user value than this fix, and the socket-alive-during-wedge finding from
the BUG note is the concrete lever. The plan does not position itself relative to that work.

**B8. The typing-latency angle is unclaimed.** Removing a per-`updateNSView` C call into libghostty
plausibly helps the hot path CLAUDE.md flags. The plan does not measure it, which is a missed cheap
win and a missed second line of defense for the ticket's actual acceptance criteria.

**B9. What actually dominates local hangs.** For 4257 of 5004 episodes, the topmost c11-module frame
is `main`, meaning the entire stack above it is AppKit/CoreFoundation/SwiftUI with no c11 code. The
named c11 offenders that follow are `TerminalController.v2AwaitCallback` (50 episodes),
`Workspace.readConversationsByPanelIdSync` (48), `WindowTerminalPortal.synchronizeLayoutHierarchy`
(22). Those are synchronous main-thread waits with 4x the episode count of `attachSurface`. The plan
had this data in hand and did not surface it. Also relevant: 990 of 5004 episodes exceeded 10s and
236 exceeded 60s, which suggests unbounded main-thread waits are a broad category, not one bug.

**B10. Multi-display and screen-reconfiguration behavior after memoization.** Not analyzed.

---

## Challenged Decisions

**C1. Drop-on-full instead of coalesce.**
`macos_display_id` is idempotent latest-wins state, not an event. Modeling it as a queue message is
the original sin. The strictly better fix: store the display id as an atomic field on the renderer
thread plus a dirty flag, and have `ghostty_surface_set_display_id` write the atomic and notify.
Never blocks, never drops, no memo needed on the c11 side, and it is *more* obviously correct to
propose upstream than a log-and-drop. The plan's version drops precisely when the mailbox is full,
which is precisely under heavy IO-thread traffic, which is precisely the 21-surface load case where
stuck vsync matters most. Counterargument for the plan's choice: smaller diff, less invasive to
upstream. That is a real argument, but it should be made, not skipped.

**C2. Notify-before-push is a lost-wakeup bug as written.**
Fix 2 says "Notify the renderer first so it can drain, then push `.instant`." The renderer can wake,
drain an empty-or-partial queue, and go back to sleep *before* your push lands. Nothing then notifies
it. The message sits until the next incidental wakeup. The current code's notify-after-push ordering
is correct and should be **kept**; a pre-notify may be *added*, but it cannot replace the post-notify.
As specified, the plan trades a deadlock for a silently delayed display id.

**C3. Memoizing in Swift while dropping in Zig is an outright correctness bug.**
Combine fix 1 and fix 2 as written: c11 memoizes "display id is now X," the Zig side drops the
message because the mailbox is full, and the renderer never learns. Every subsequent non-forced call
is suppressed by the memo. The result is a permanently stale display id and stuck vsync, arrived at
by two changes that are each defensible alone. Minimum fix: have the export return whether the
message was enqueued and only memoize on success. Better: C1, which makes the question disappear.

**C4. Dedupe on the wrong side of the boundary.**
`setMacOSDisplayID` in `generic.zig` already knows the current display and already guards the link
restart with `if (was_running and self.focused)`. A no-op check there would suppress the redundant
work for *all* callers, in one place, with no cross-language state to desync. The Swift memo
duplicates state the renderer already owns. Counterargument: the Swift memo also avoids the FFI call
and the queue push entirely, which is the point if the queue is the hazard. Fair, but C1 removes the
queue hazard, after which the Swift memo becomes optional rather than load-bearing.

**C5. `force: Bool` is the wrong shape.**
The "force" sites do not want "set the id harder." They want "restart the display link because vsync
may be stuck." Those are different operations that currently share an implementation by accident. Two
named entry points (`setDisplayID(_:)` and `restartVsyncForCurrentDisplay()`) would make every call
site self-documenting and would survive a future where re-asserting no longer restarts the link.
Boolean force parameters are how the next agent silently picks the wrong one.

**C6. Reinterpreting the ticket instead of splitting it.**
The right move is: open a new ticket for the deadlock with the disassembly evidence, and leave C11-191
on the Sentry signature with its stated acceptance criteria. The plan instead redefines C11-191 in a
plan file, which loses the Sentry issue, loses the 11-user problem, and makes the Lattice trail lie.
This is the cheapest fix to the whole review and I would insist on it.

**C7. Scoping out the blocking `createSurface` path.**
The prior BUG note called "never block main in `updateNSView`" the actual fix, with a bounded-wait
fallback as second choice. The plan removes only the display-id push. `attachToView` still calls
`createSurface` on main, which enters `ghostty_surface_new` -> `SharedGridSet.ref` and can block on
a mutex held across font discovery. Post-fix, that path still produces `__ulock_wait2` under
`attachSurface`, at a different offset. Anyone reading hang.log after the fix will see a nearly
identical signature and may conclude the fix failed. The plan needs to say explicitly that it is
narrowing scope and why, and predict the residual signature.

---

## Hindsight Preview

Things I expect to be said about this in three to six months:

- "We closed C11-191 and C11-30 kept firing on 0.61. We had the episode counts the whole time."
- "We removed the display-id re-assert and the frozen-pane-after-split-close bug came back, and it
  took two days to remember why the re-assert had been there."
- "The memo was lying. The push was being dropped and the memo recorded it as sent."
- "We never changed `signal` to `broadcast`, so the IO thread kept starving and we shipped output
  stalls under load."
- "We fixed a 14-hour deadlock that had happened once, on Atin's machine, while
  `readConversationsByPanelIdSync` and `v2AwaitCallback` were blocking main in 100 episodes."
- "Notify-before-push cost us a week of 'the pane doesn't wake up until you click it.'"

Early warning signals this plan has no mechanism to detect, and should add:

1. A counter of dropped `macos_display_id` pushes, surfaced somewhere an agent can read.
2. Episode-level (not capture-level) counts of `__ulock_wait2`-leaf hangs per release.
3. Sentry C11-30 unique-user count per release, tracked deliberately, not eyeballed once.
4. Any hang episode whose duration exceeds, say, 5 minutes: that is the deadlock class, and it
   should page rather than accumulate captures.

---

## Reality Stress Test

Three likely disruptions, hitting together:

**1. The ghostty CI tax bites.** The delegator bumps the submodule, three CI jobs go red because
`ghosttykit-checksums.txt` has no entry yet, and the plan never warned them. Best case they wait for
`build-ghosttykit`. Realistic case they hand-edit the checksum file or start "fixing" CI, and now the
PR has unrelated churn in it.

**2. The bug does not reproduce.** It has occurred meaningfully once in 59 process lifetimes. There
is no repro script. The tagged-build validation the plan proposes ("count `macos_display_id` pushes
per session before/after") measures the *symptom's precondition*, not the bug. The reviewer asks
"did the hang stop?" and the honest answer is "we cannot tell, and we could not tell before either."
The PR stalls in review or gets waved through on the strength of the disassembly.

**3. Sentry does not move.** Next release ships, C11-30 still has 11+ users. Now the team is
reasoning from a plan document that opens with "the ticket's reading does not survive contact with
the evidence," so the obvious next hypothesis (the tab bar) has been rhetorically pre-discredited.
Recovering costs more than never having made the claim.

All three together produce the worst outcome: a merged, hard-to-validate cross-repo change; a closed
ticket; an unfixed production issue; and a documented rebuttal of the correct hypothesis.

---

## The Uncomfortable Truths

1. **The most confident sentence in the plan is its least supported one.** "That reading does not
   survive contact with the evidence" is asserted about the ticket's hypothesis, using evidence that,
   counted correctly, supports the ticket's markers 3x to 21x more often than the plan's.

2. **9412 of 9413 samples are the same frozen frame.** Presenting them as a dominant signature is the
   kind of number that does not survive a careful reader, and the plan's authority rests on it. This
   is not a small framing quibble; it is the load-bearing beam.

3. **This is "I found a great bug while looking for the assigned bug."** That is a good day. It is
   not a reason to overwrite the assigned bug. The value here is high and the ticket assignment is
   wrong, and those are separable problems with an easy fix.

4. **Nobody has reproduced anything.** Not the deadlock, not the tab-bar stall. Every claim on both
   sides is post-hoc stack reading. The plan should say so plainly instead of letting disassembly
   imply determinism.

5. **The repo now contains two documents with two different root causes for pid 6063** and the plan
   does not mention the other one. As it happens the plan is probably right (the `Futex.Deadline`
   frame fits a Condition wait, not a Mutex lock), but leaving that unstated guarantees a future
   agent re-derives the whole thing.

6. **Fix 2 as literally specified is wrong** (notify-before-push), and **fix 1 combined with fix 2 is
   wrong** (memo records a dropped message). Both are one-paragraph fixes. But they are in a plan
   presented as disassembly-verified and rigorous, which is exactly the kind of document reviewers
   skim.

7. **The credit where it is due:** the offset-level attribution, the +372/+388 corroboration, and
   tracing to the `.forever` push are excellent work that I verified line by line and found correct.
   The critique above is entirely about scope, statistics, and two implementation details. Do not
   let it bury the finding.

---

## Hard Questions for the Plan Author

1. Episode-counted, `attachSurface` appears in 11 of 5004 local hang episodes (0.2%), `TabBarView` in
   32, `updatePreferences` in 232. On what basis does the plan call the `attachSurface` signature
   dominant, and does that basis survive being restated as "one process out of 59"?

2. The Sentry stack has no `libsystem_kernel` frame at position 0. A `__ulock_wait2` block always
   does. Under the plan's own rule that module attribution is trustworthy, how is the Sentry hang a
   futex block?

3. Sentry: 0.58.0+116, 2026-07-25, 941 events, 11 users, 2335ms. Local: 0.60.1, 2026-07-29, one pid,
   13h58m, no `hang.end`. Which of those four mismatches does the plan claim is explainable, and how?

4. What is the plan's answer to the ticket's stated acceptance criterion, "a reproduction (many tabs
   plus tab bar interaction) that stalls main >1s before the change and does not after"? If the
   answer is "we are changing the AC," who signs off, and is the Sentry issue getting its own ticket?
   ("We don't know" here is a process failure, not a technical one.)

5. Combine fix 1 and fix 2: c11 memoizes display id X, ghostty drops the message on a full mailbox,
   the renderer never applies it, and every later non-forced call is suppressed. Is the export going
   to return an enqueue result, or is this defect being accepted?

6. Fix 2 says notify first, then push `.instant`. What wakes the renderer for a message pushed after
   the notify was consumed?

7. `BlockingQueue.pop` and `drain().deinit()` each `signal()` exactly one waiter, while three
   producers (main, IO thread, termio) push into the renderer mailbox. Is that not the actual
   starvation mechanism, and why is `signal` -> `broadcast` not in the plan?

8. After this fix, why did the renderer thread stop draining in the first place? If the answer is
   `SharedGrid` write-lock contention (the prior note's finding), does the user still see frozen
   panes after the fix, and how would we know?

9. `attachToView` still calls `createSurface` -> `ghostty_surface_new` -> `SharedGridSet.ref` on the
   main thread, under a mutex held across font discovery. The prior BUG note called removing that the
   actual fix. Why is it out of scope, and what will the post-fix hang.log signature look like so
   nobody misreads it as a regression?

10. The reuse-branch re-assert at `:3285` was added to fix visually frozen surfaces during split-close
    restructuring. What test, repro, or screenshot proves the enumerated `force: true` sites cover
    that case? `scripts/repro-c11-18.sh` plus `C11_PORTAL_DEBUG=1` exists; why is it not the
    validation?

11. Why is dedupe on the Swift side rather than a no-op check inside `setMacOSDisplayID`, where the
    renderer already owns the current display id and cannot desync from itself?

12. Why a queue message at all for idempotent latest-wins state? What is the argument against an
    atomic field plus dirty flag, which cannot block and cannot drop?

13. Where in the plan is the ghostty submodule workflow: push to `Stage-11-Agentics/ghostty` first,
    bump pointer, `build-ghosttykit`, `ghosttykit-checksums.txt`, run-1-red/run-2-green? And what does
    "offer upstream" mean operationally given the standing rule against writing to `manaflow-ai/*`?

14. The proposed `c11LogicTests` memo test: what is the seam? CLAUDE.md says logic tests that
    construct surface/workspace objects crash locally on nil `NSApp`. Is there a pure type to test,
    or does this test only run in CI?

15. `TerminalController.v2AwaitCallback` (50 episodes), `Workspace.readConversationsByPanelIdSync`
    (48), `WindowTerminalPortal.synchronizeLayoutHierarchy` (22): all synchronous main-thread waits,
    all with 2x to 4x the episode count of `attachSurface`. Why is none of this in the plan, given it
    came from the same log?

16. Who watches Sentry C11-30 after the next release, at what install count, for how long, and what
    is the trigger to reopen? (If the answer is "we'll look," say so and let the operator decide
    whether that is enough.)

17. Is there a rollback path for the ghostty change if display-id drops turn out to cause stuck vsync
    in the field, given the change is baked into a prebuilt xcframework?

18. Nothing prevents the 19th `.forever` push from reaching main. Why is a debug assertion against
    blocking libghostty calls on the main thread not part of this fix?

---

## Recommended Minimum Changes Before This Plan Proceeds

Not a wish list; these are the ones I would gate on.

1. **Split the ticket.** New ticket for the deadlock with the disassembly evidence. C11-191 stays on
   the Sentry signature with its stated AC. Do not close C11-30 with this work.
2. **Recount the evidence by episode** and rewrite the "one signature dominates" section honestly.
   The finding survives the honest framing; it just becomes "rare and catastrophic" instead of
   "dominant," which is a better argument anyway.
3. **Fix the notify ordering.** Keep the post-push notify.
4. **Resolve the memo/drop interaction.** Either return an enqueue result and memoize only on
   success, or adopt the atomic-latest-value design and drop the Swift memo entirely.
5. **Add `signal` -> `broadcast`** in `blocking_queue.zig`, or state explicitly why not.
6. **Add the split-close churn validation** using `repro-c11-18.sh` plus `C11_PORTAL_DEBUG=1`, with a
   real-artifact screenshot pass. Push counts are not sufficient evidence that panes still render.
7. **Write the ghostty submodule and checksum sequence into the plan** so the delegator does not
   discover it via three red CI jobs.
8. **Explicitly supersede `notes/BUG-main-thread-deadlock-attachSurface.md`**, including the
   `Futex.Deadline` versus `Futex.wait` argument, so the contradiction does not outlive the fix.
