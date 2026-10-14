# Evolutionary Plan Review: c11-191-plan (Claude)

**Plan:** `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md` (C11-191)
**Reviewer model:** Claude
**Timestamp:** 20260804-1613
**Posture:** evolutionary. Not "is this correct" but "what should this become."

---

## Executive Summary

This plan is much better than the ticket it answers, and it is much smaller than the finding it made.

The plan did something rare: it took a Sentry-derived ticket, refused its reading, went to a local
151 MB forensic corpus, resolved a return address by disassembling the shipped release binary, and
landed on an exact instruction. The result is a root cause that is *proven* rather than argued. That
is a genuinely high-grade piece of engineering work.

But the plan then spends that finding on the narrowest possible deliverable: memoize one display-id
call, and make one Zig export non-blocking. Three things of larger value are sitting unclaimed right
next to it:

1. **The bug is a class, not an instance.** `ghostty_surface_set_focus` and
   `ghostty_surface_set_occlusion` are called from c11's main thread and reach the *same* 64-slot
   renderer mailbox with the *same* `.forever` push, and `occlusionCallback` has the *same*
   push-before-notify ordering. Focus churn in c11 is far more frequent than display-id churn. The
   plan closes one door in a corridor of doors.
2. **The symbolication defect is worth more than the fix.** The plan proves that c11's outbound
   Sentry stacks contain impossible frames and untrustworthy c11-binary symbol names. Every Sentry
   ticket c11 has written or will write off those stacks inherits that defect. Fixing symbolication
   or on-device fingerprinting is a one-time change that upgrades the accuracy of an entire triage
   pipeline.
3. **The method is reusable and the corpus is a dataset.** 5001 episodes, 20778 captures, 59 pids,
   seven weeks. The plan mines one signature by hand. Turning that into a ranked, repeatable report
   makes signature #2 nearly free, and makes "wedged wall-clock time per release" a regression gate
   nobody currently has.

There is also one correctness hazard in the chosen design worth escalating: the Swift-side
optimistic memo can permanently strand a surface on a stale display link, because
`setMacOSDisplayID` has a silent failure path that the Swift memo cannot see. Details in
*How It Could Be Better*.

**The one-line version:** ship the ghostty half as the primary fix at the export boundary for
*all* main-thread-reachable exports, demote the Swift memo to a secondary optimization that only
records on confirmed success, and spend one extra day converting the forensic method into a skill
and a report. That turns a bug fix into an invariant, a triage pipeline, and an upstream
contribution.

---

## What's Really Being Built

The stated deliverable is "stop a main-thread deadlock."

What is actually being built, in descending order of durable value:

**1. A local, always-on, correctly-symbolicated hang profiler that outperforms the commercial one.**
`MainThreadHangMonitor` suspends main and walks its stack from a watchdog thread, which is exactly
the artifact a runloop observer cannot produce. Locally it produces frames good enough to
disassemble against. Remotely, the same records go through `backtrace_symbols()` and arrive at
Sentry semantically corrupted. c11 has, without noticing, built a better crash-adjacent
observability product than the one it pays for, and is currently throwing away the good version at
the network boundary.

**2. Proof that the main-thread/renderer-thread boundary in libghostty is not safe for embedders.**
This is not a c11 bug. It is a libghostty API-contract bug: exported C functions intended to be
called from the host's UI thread perform unbounded blocking waits on a fixed-size queue drained by
a thread the host does not control. Any embedder hits it. cmux hits it. That is an upstream-class
finding and an upstream-class contribution.

**3. A precedent for "reconcile, don't re-assert" in `updateNSView`.** The display-id memo is the
first instance of a general principle that the c11 SwiftUI/AppKit portal seam badly needs: an
`updateNSView` that fires on every state propagation must diff its intent before crossing into
native code. `displayID` is one field. The same function currently unconditionally pushes keyboard
copy mode, background, color scheme, overlays, notification rings, search overlay, pane
interaction, and key-state indicator on every pass.

**4. A working demonstration of a forensic method.** Sentry fingerprint → local hang log → symbol +
offset → `objdump` the *installed release binary* → exact `bl` target → source. Nobody at Stage 11
has this written down. It is the difference between "this ticket took a day" and "this class of
ticket takes twenty minutes forever."

---

## How It Could Be Better

### A. The memo as designed can strand a surface on a stale display link

This is the one thing in the plan I would not ship as written.

`renderer/generic.zig:1008` `setMacOSDisplayID`:

```zig
display_link.setCurrentCGDisplay(id) catch |err| {
    log.warn("error setting display link display id err={}", .{err});
    return;
};
```

The failure path returns without applying the id. It also returns early if `display_link` is null.
A Swift-side memo that records `lastDisplayID = id` at push time has no visibility into either
outcome. After a transient failure, every subsequent `force: false` call is suppressed as
redundant, and the surface stays on the wrong (or no) display link until some `force: true` site
happens to fire.

The symptom of exactly that state is already documented in `attachToView`'s own comment at
`GhosttyTerminalView.swift:3278-3284`: "if it is missing or stale, the surface can appear visually
frozen until a focus/visibility change." The unconditional re-assertion the plan removes is the
thing currently papering over that failure mode. Removing it without moving the dedupe to where
success is observable risks trading a 2.3 s hang for an intermittently frozen pane, which is a
worse bug from the operator's seat because it is silent.

Three ways out, in increasing order of quality:

- **Weak:** memo only on `push() != 0`. Better than nothing, but still records "queued," not
  "applied."
- **Better:** move the dedupe into ghostty's `setMacOSDisplayID`, applied *after* a successful
  `setCurrentCGDisplay`. This mirrors what upstream already does for focus
  (`Surface.zig:3348`: `if (self.focused == focused) return;`). The display-id path is simply
  missing the guard its sibling already has.
- **Best:** grow the export to `ghostty_surface_set_display_id(surface, id, force)`. The `force`
  semantics the plan needs (deliberately restart the display link to unstick vsync) are a real,
  legitimate caller intent that the current API cannot express, which is exactly why c11 ended up
  expressing it by spamming the call. Making the intent explicit at the boundary is the honest fix
  and it deletes the need for a shadow memo in Swift entirely.

The third option is barely more work than the first, is more upstreamable, and removes an entire
category of "Swift memo drifted from ghostty state" bugs from the future.

### B. Fix the class at the export boundary, not the instance

Confirmed by reading the fork:

| Export | Core fn | Push | Notify order | Dedupe? | Called from c11 main thread |
|---|---|---|---|---|---|
| `ghostty_surface_set_display_id` | inline in `embedded.zig:2172` | `.forever` | push then notify | none | yes (10 sites) |
| `ghostty_surface_set_occlusion` | `Surface.occlusionCallback:3331` | `.forever` | push then `queueRender()` | **none** | yes (`SurfaceLifecycle.swift`) |
| `ghostty_surface_set_focus` | `Surface.focusCallback:3342` | `.forever` | push then app notify | yes (`self.focused == focused`) | yes (5+ sites in `GhosttyTerminalView.swift`) |

All three land in the same `BlockingQueue(Message, 64)`. `occlusionCallback` is the closest twin to
the bug being fixed: no dedupe, `.forever` push, notify afterward. Occlusion fires on window
visibility, workspace switching, and portal churn, which in c11 is exactly the high-churn regime
the plan's own evidence comes from.

If the plan ships as written, C11-191 closes and the same deadlock remains reachable through
`ghostty_surface_set_occlusion` on the next multi-surface pressure event, at which point it will
produce a *different* Sentry fingerprint and be triaged as a new bug. That is the expensive
failure mode.

**The stronger plan:** treat "no exported `ghostty_*` function called from the host UI thread may
perform an unbounded blocking wait" as the deliverable. Concretely:

- Add a `pushFromAppThread()` helper (notify first, `.instant` push, log-and-drop on full) and
  route every main-thread-reachable export through it.
- Add the missing `if (self.visible == visible) return;` guard to `occlusionCallback` so it matches
  its focus sibling.
- Add a debug-build assertion in `BlockingQueue.push` that `.forever` is never used from the
  registered app thread. That converts an invariant that lives in a code comment today into
  something a test run can fail on.

This is maybe half a day more than the current plan and it is dramatically more valuable, both
here and upstream.

### C. The acceptance criterion the plan quietly drops

The ticket asks for "a reproduction that stalls main >1s before the change and does not after."
The plan substitutes disassembly plus a memo unit test. The disassembly is stronger evidence of
*cause* than a repro would be, but it is not a *gate*: it cannot fail in CI next year when someone
reintroduces a blocking push.

A real repro here is cheap and belongs in Zig, next to the fix: construct a surface, stop draining
the renderer mailbox, push 65 messages, call `ghostty_surface_set_display_id`, assert it returns.
That is a deterministic, sub-millisecond regression test for the actual defect. The proposed
`c11LogicTests` memo test is valuable but tests the *optimization*, not the *deadlock*. Shipping
only the memo test means the load-bearing half of the fix has no test at all.

### D. Name the measurement mechanism

"Count `macos_display_id` pushes per session before/after" does not say how. There is a
`log.info("updating display link display id={}")` in `setMacOSDisplayID` already, so `log stream`
is available, but that counts *drains*, not pushes, and it is a one-shot manual measurement that
expires the moment the PR merges.

Better: make the suppressed-push count a permanent per-surface counter exposed through
`c11 tree --json` or the debug window. Then "redundant native calls per SwiftUI update" becomes a
number the team can watch, and the next `updateNSView` regression is visible before it becomes a
Sentry issue. Same effort, permanent instrument instead of disposable one.

---

## Mutations and Wild Ideas

### M1. Ship the on-device fingerprint, not the symbol names (highest value per hour)

The plan proves that Sentry's grouping for c11 is built on untrustworthy symbols. `#401` just cut
event volume, so the team explicitly plans to judge recurrence by *issue presence and user count*.
That makes grouping correctness load-bearing in a way it was not before: if the fingerprint is
noise, "issue does not recur" is not evidence of anything.

The watchdog already has the raw addresses and the local symbolication is good. Compute the
fingerprint on device from `(leaf, frame1, frame2)` and send it as the Sentry fingerprint, plus the
raw `image + slide` addresses so the stack can be symbolicated server-side from a dSYM.

Payoff: 941 events collapse into a signature that actually means something, C11-191's own
verification becomes trustworthy, and every future Sentry-derived ticket stops needing a
"correction to the ticket's reading" section.

### M2. `hang-triage`: turn the corpus into a ranked report

The plan mined one signature by hand from 151 MB. Write the tool that does it:

- Group captures by `(leaf, frame1, frame2)`.
- Rank by **wall-clock time wedged**, not capture count. One 13h58m episode is worth more than
  5000 blips, and count-ranking would have hidden it.
- Emit a table: fingerprint, episodes, total wedged time, worst single episode, first/last seen,
  affected pids.

Consequences: signature #2 costs minutes. "Total main-thread wedged seconds per hour of use"
becomes a release-over-release metric. And you can run the tool against a pre-fix and post-fix
tagged build to satisfy C11-191's acceptance criterion quantitatively instead of by absence.

### M3. The self-healing watchdog

This is the interesting one.

The deadlock is: main sleeps on `cond_not_full`; the renderer is not draining. A *third party* can
break it. The watchdog thread already suspends main and knows exactly where it is wedged. Give it a
small table of known-recoverable signatures and one action: for a wedge whose leaf is
`__ulock_wait2` inside a surface path, call `wakeup.notify()` on every live surface's renderer
thread. The renderer drains, `cond_not_full` signals, main proceeds.

Value: it recovers from blocking pushes the team has *not yet found*, including any future one. It
is off-main, needs no UI, and composes perfectly with C11-186 ("make hangs survivable"). The
watchdog stops being a reporter and becomes a supervisor.

Risk is real (waking a renderer mid-teardown), so gate it: only after N seconds wedged, only on a
signature allowlist, log every intervention. But the concept, "we can already see the wedge from
outside, so stop only writing it down," is the single most leveraged idea adjacent to this plan.

### M4. `SurfaceDesiredState`: kill the whole reconciler class

Redesigning from scratch with the same constraints: `updateNSView` should compute one
`SurfaceDesiredState` value, compare it against the coordinator's last-applied state, and cross into
native code only for the fields that changed. Today it unconditionally calls `attachSurface`,
`setFocusHandler`, `setTriggerFlashHandler`, `setInactiveOverlay`, `setNotificationRing`,
`setSearchOverlay`, `attachPaneInteraction`, `syncKeyStateIndicator` on every pass, with ad-hoc
guards scattered underneath at varying depths.

One `Equatable` struct plus one diff replaces N hand-written guards, and per `CLAUDE.md`'s
typing-latency section this path is exactly the kind that pays a second dividend in keystroke
latency. The display-id memo is instance one of this pattern; naming the pattern now means
instances two through eight are trivial instead of eight more tickets.

### M5. Fix the watchdog's own pathology

The evidence the plan relies on is also an indictment of the tool that produced it: one episode
wrote 9412 consecutive captures. At roughly 7 KB per capture that is around 66 MB of disk from a
single hang, and `hang.log` is 151 MB unrotated on the operator's machine. Every user with the
release build is accumulating this.

Two small changes: rotate/cap the log, and dedupe within an episode (write frames once at
`hang.begin`, then emit delta lines on `hang.persist` when the fingerprint is unchanged). This is
a shipping defect discovered *by* this plan, adjacent enough to fold in, and it makes M2's corpus
cheaper to parse rather than more expensive.

### M6. Bundle the upstream contribution

The plan offers one fix upstream. There is a coherent theme available: **libghostty embedding
safety**.

- Non-blocking pushes at all app-thread-reachable exports (this plan).
- Missing dedupe on `occlusionCallback` (this review).
- `SharedGridSet.ref` constructing a grid inside its mutex, and `SharedGrid.getIndex` /
  `renderGlyph` rasterizing under the write lock, both already documented in
  `notes/BUG-main-thread-deadlock-attachSurface.md` and currently unclaimed.

Landing these as a themed set rather than three orphan patches builds standing as a serious
upstream contributor, which per `CLAUDE.md` is strategic leverage for every future merge in both
directions. It also stops c11 carrying three private divergences in shared code, which is exactly
the divergence tax the repo's own conventions warn about.

### M7. `c11-hang-forensics` as a skill

`CLAUDE.md` is explicit that generalizable tool learnings go in a skill, not a memory. This plan
produced a method: hang.log fingerprint → symbol + offset → `objdump` the *installed release*
binary at that offset → the `bl` target → source. That is not obvious, it worked, and it will work
again. Six paragraphs of skill turns a one-day investigation into a twenty-minute one, forever, for
every agent on the fleet.

### M8. The wild one: adversarial hang fuzzing

You now know the shape of the failure: a bounded queue plus a slow consumer plus an unbounded
producer on the UI thread. That is fuzzable. A debug-only mode that randomly stalls renderer drains
for 50-500 ms, run under the existing portal-churn harness (`scripts/repro-c11-18.sh`), would
surface every remaining blocking path in the embedding boundary in an afternoon. Speculative, but
the setup cost is low and the failure signal (`hang.begin` in the log) already exists.

---

## What It Unlocks

Once this ships, in its stronger form:

- **A trustworthy Sentry board.** With M1, ticket authors stop inheriting corrupted stacks. The
  compounding value here is large because every future triage rides on it.
- **A hang budget.** With M2, "total wedged seconds per hour" becomes a release gate, in the same
  family as the typing-latency guardrails already in `CLAUDE.md`. Right now the project has no
  quantitative main-thread-responsiveness metric at all.
- **A named invariant for the embedding boundary.** "No unbounded blocking from the app thread"
  becomes something reviewers can cite and CI can enforce, which is the difference between fixing
  this bug and fixing this bug's descendants.
- **Upstream standing.** A themed contribution set on embedding safety earns merge goodwill in both
  directions.
- **Reconciler discipline in the portal seam.** M4 gives future work a pattern to point at instead
  of eight more ad-hoc guards.
- **A recovery primitive.** M3's watchdog intervention is a direct input to C11-186 and, combined
  with the BUG note's observation that the control socket survives wedges, gets close to "c11 never
  needs a force-quit," which is a genuine differentiating product claim for an operator running
  twenty agent sessions.

---

## Sequencing and Compounding

The plan lists the c11 memo as step 1 and the ghostty fix as step 2. **I would invert that,** for
reasons that matter beyond aesthetics:

1. **The ghostty fix is the one that makes the failure impossible.** The memo makes it *less
   likely*. Every `force: true` site the plan preserves (`createSurface`, focus, topology churn,
   `viewDidMoveToWindow`, `windowDidChangeScreen`) still performs an unbounded blocking push. If
   the mailbox is full, those still deadlock.
2. **`windowDidChangeScreen` is a plausible primary trigger for the Sentry population.** Dragging a
   window between displays is a common operator action, and it is a `force: true` site. If that is
   what the 11 users are doing, the memo helps them *not at all* and only the ghostty half moves
   the number.
3. **The ghostty half has the longest CI tail.** Per `CLAUDE.md`, a submodule bump means a checksum
   commit, a ~10-minute Zig build, and the expected run-1-red pattern. Starting it first parallelizes
   the wait against the Swift work.
4. **The memo's correct design depends on the ghostty change.** As argued in section A, the honest
   dedupe either lives in ghostty or needs a `force` parameter on the export. Doing Swift first
   commits you to the optimistic-memo design, which is the one with the stranding hazard.

Suggested order:

- **Phase 0 (hours, parallel, no dependencies):** M2 `hang-triage` script. It is standalone, and its
  output is the before/after measurement Phase 2 needs anyway. Doing it first means the fix arrives
  with quantitative evidence rather than an argument.
- **Phase 1 (the real fix):** ghostty. Non-blocking `pushFromAppThread` at all app-thread-reachable
  exports, occlusion dedupe, `force` parameter on the display-id export, one Zig test that fills the
  queue and asserts non-blocking. Push to the fork, land the checksum, absorb the CI tail.
- **Phase 2 (the optimization):** c11. Route through the new `force`-aware export. The Swift side
  becomes "pass the right intent" rather than "maintain a shadow memo," which is a smaller and safer
  diff. Add the permanent suppressed-call counter from section D.
- **Phase 3 (harvest):** tagged build, re-run `hang-triage`, report before/after wedged-seconds.
  Write the `c11-hang-forensics` skill while the method is fresh. Open the upstream PR.
- **Deferred, separate tickets:** M1 fingerprinting, M3 self-healing watchdog, M4
  `SurfaceDesiredState`, M5 log rotation. Each is independently valuable and none should hold
  C11-191.

**Where the plan under-invests early:** the repro. Building the queue-full Zig test in Phase 1
costs perhaps an hour and becomes the permanent gate for the entire class. Skipping it means the
next embedder-safety regression is found by an operator's beachball rather than by CI.

**Where it over-invests:** the Swift memo's `force: true` site inventory. That careful enumeration
of five deliberate-unstick sites is real work that partly evaporates if the export grows a `force`
parameter, because the intent moves to the call site declaratively instead of being encoded in a
memo-bypass convention. Do the ghostty change first and some of that work is not needed.

---

## The Flywheel

There is a strong one available, and the plan is one turn into it without naming it:

**Better local forensics → correct root cause → correct fix → fewer misdirected tickets → more
trust in the corpus → more willingness to mine it → better forensics.**

The plan just completed one full turn: it distrusted a Sentry reading, went to the local corpus, and
got a provable answer. The turn cost a day because the method was improvised. Two changes make every
subsequent turn cheap:

- **M7 (the skill)** removes the improvisation cost.
- **M2 (the report)** removes the search cost.

There is a second loop that only spins if M1 lands:

**Correct on-device fingerprints → Sentry groups by true signature → issue rank reflects real
operator pain → fixing the top issue actually helps the most users → the board stays honest.**

Today that loop is broken at the first joint: the fingerprint is built from symbols the plan proved
are wrong. C11-191 is the demonstration that it is broken. Fixing it is the highest-leverage
single change adjacent to this plan, because it is the difference between a triage pipeline and a
random number generator with a nice UI.

**Joining the two loops is where it gets good.** If M1 lands, the remote population's stacks look
like Atin's local ones, and M2's ranked report can run over Sentry data instead of one machine's
`hang.log`. The corpus becomes the whole user base rather than one operator, and the hang budget
becomes a real product-quality metric rather than a local curiosity.

---

## Concrete Suggestions

Ranked by value per unit of effort.

1. **Grow the export: `ghostty_surface_set_display_id(surface, id, force)`.** Notify first, `.instant`
   push, log-and-drop on full, dedupe inside `setMacOSDisplayID` *after* a successful
   `setCurrentCGDisplay`. This is the plan's fix #2, one parameter richer, and it makes fix #1 a
   two-line call-site change instead of a memo with a stranding hazard.
2. **Apply the same treatment to `ghostty_surface_set_occlusion` and `ghostty_surface_set_focus`, and
   add the missing occlusion dedupe.** Same file, same afternoon, closes the rest of the corridor.
3. **One Zig test: fill the mailbox to 64, call the export, assert it returns.** The only test in the
   plan that actually gates the bug being fixed.
4. **`scripts/hang-triage.py`:** cluster `hang.log` by `(leaf, frame1, frame2)`, rank by total wedged
   wall time, print a table. Standalone, no dependencies on the fix, produces the before/after
   number C11-191 needs.
5. **Debug assertion in `BlockingQueue.push`: `.forever` from the registered app thread is a
   programmer error.** Turns the invariant into something a test run can fail on.
6. **Rotate `hang.log` and dedupe frames within an episode.** 151 MB unbounded on every user's disk
   is a shipping defect this plan happened to walk past.
7. **`c11-hang-forensics` skill.** Six paragraphs. Write it in Phase 3 while the objdump incantation
   is still in scrollback.
8. **On-device Sentry fingerprint + raw addresses for server-side symbolication.** Separate ticket,
   but file it *now* with this plan's evidence attached, because that evidence is the strongest
   argument for it that will ever exist.
9. **Permanent suppressed-call counter surfaced through `c11 tree --json`.** Same cost as the
   disposable measurement, infinite shelf life.
10. **Watchdog intervention on a signature allowlist (M3).** File as a C11-186 child. Highest
    ceiling on this list, highest risk, correctly deferred, but do not let it go unrecorded.

---

## Questions for the Plan Author

1. **The memo's silent-failure hazard.** `setMacOSDisplayID` returns early on `setCurrentCGDisplay`
   failure and on a null display link. How does the Swift memo learn that the id was never applied?
   If it does not, what prevents a surface from being permanently stranded with a stale display link
   and the "visually frozen until focus change" symptom that `attachToView`'s comments say the
   unconditional re-assert exists to prevent?
2. **Why only `set_display_id`?** `ghostty_surface_set_occlusion` and `ghostty_surface_set_focus` are
   called from c11's main thread and reach the same 64-slot mailbox with the same `.forever` push,
   and occlusion has the same push-before-notify ordering with no dedupe. Was this scoped out
   deliberately, or not yet noticed? If deliberate, what closes those doors and when?
3. **Which trigger explains the 11 Sentry users?** If it is `windowDidChangeScreen` (dragging a
   window between displays), that is a `force: true` site and the memo does nothing for them. Do you
   have distribution evidence from the hang log on which call site dominates?
4. **Is the ticket's repro acceptance criterion being formally waived, or met?** The disassembly is
   stronger evidence of cause, but it is not a CI gate. Is a queue-full Zig test in scope, and if
   not, what fails when someone reintroduces a blocking push in 2027?
5. **Why is the renderer thread not draining in the first place?** A 13h58m block means the consumer
   was permanently stopped, not merely slow. The plan makes main survive that, which is right, but
   the renderer being dead for 14 hours is its own defect and the `BUG-` note's `SharedGrid` write-lock
   analysis is a strong candidate. Is that a follow-up ticket, and does it exist?
6. **Ordering: does the ghostty half definitely ship in the same release?** Given the submodule CI
   tail, if the Swift memo lands alone and the ghostty change slips, event volume drops (compounded
   by `#401`'s budget), the acceptance criterion reads as satisfied, and the deadlock is still
   reachable. What guarantees they ship together?
7. **How is "count pushes per session before/after" actually measured?** Named mechanism, and is it
   disposable or does it become a standing instrument?
8. **Sentry symbolication: is anyone owning it?** The plan proves the outbound stacks are
   untrustworthy for c11's own frames. That invalidates the reading of every past and future
   Sentry-derived ticket. Is there a ticket, and should this plan's evidence be attached to it?
9. **Is the hang corpus a one-off or an asset?** If M2 exists, what is signature #2 by wedged wall
   time? That answer is probably the next ticket and it is currently sitting unread in 151 MB on one
   machine.
10. **Upstream framing: one patch or a themed set?** Bundling the embedding-safety fixes with the
    `SharedGridSet.ref` / `SharedGrid` lock findings from the BUG note is a materially stronger
    contribution than three orphan patches, and it retires three private divergences in shared code
    at once. Worth the extra coordination?
11. **Should `SurfaceDesiredState` (M4) be filed now?** The display-id memo is instance one of a
    pattern with seven or eight more instances in the same function, and per `CLAUDE.md` that
    function is typing-latency-sensitive. Filing it now means the pattern is named before the next
    six ad-hoc guards accrete.
