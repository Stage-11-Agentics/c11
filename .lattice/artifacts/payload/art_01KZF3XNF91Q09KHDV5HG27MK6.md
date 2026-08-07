# Plan Review: C11-191

Reviewer: claude (single-agent plan review), 2026-08-07
Task: `task_01KZ732X0HCW7C324718YBZFTR` (C11-191), status at review time: `planned`

---

## 1. Verdict

**FAIL (plan-level)**

With an important qualification the harness cannot see: the plan embedded in this
review prompt is **not the current plan for C11-191**. It was superseded 40 seconds
after this review started, and the work it proposes has already shipped under a
different ticket. The remediation is a **state correction, not a re-plan**. Sending
C11-191 back to `in_planning` would be the wrong response to this verdict, and the
reasoning is in Issues 1 through 4.

---

## 2. Summary

I reviewed the plan text carried in `prompt.md`: the 2026-08-04 plan that re-reads
C11-191's Sentry stack as a `ghostty_surface_set_display_id` mailbox deadlock, plus
its embedded trident FAIL findings (B1 through B7, I1 through I6, and the S1
blocked-on-operator question). That artifact cannot proceed to implementation for
three independent reasons: its Fix section already merged on 2026-08-06 as #403 under
the split-out ticket C11-200 (`done`), its own embedded review is an unresolved FAIL,
and its S1 question has since been answered in a way that removed the deadlock from
this ticket's scope entirely.

The live plan on disk is a different, 49-line document (`.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md`,
rewritten by `28a08837e` at 21:56:50 UTC, 40 seconds after this review's
`started_at` of 21:56:10Z). Every factual claim in that live plan that I could check
against the tree holds up. My substantive concern about it is narrow: it displaces the
ticket's original repro-based acceptance criterion without explicitly declaring it void.

---

## 3. Issues

**[CRITICAL] Whole plan — the reviewed artifact is stale; it is not the plan a reader gets today**

`prompt.md` was written at 2026-08-07 21:56 UTC and `review_state` records
`started_at: 2026-08-07T21:56:10Z`. Commit `28a08837e` ("Board: rewrite the C11-191
plan to the delivered scope") landed at 2026-08-07 21:56:50 UTC and replaced the
207-line plan with a 49-line one, cutting 158 lines. The review harness snapshotted
the file 40 seconds before the rewrite, so this prompt carries the pre-rewrite text
ending in `## Reset 2026-08-04 by agent:trident-pane-C11-191`. Any verdict rendered
against it describes a document that no longer exists.

**Recommendation:** Treat this review as a review of the *ticket's* state rather than
of an implementable plan. If a plan-review gate is genuinely wanted on C11-191, re-run
it against the current file. My read of that file is in Issue 5 and in Positive
Observations, so a re-run is optional rather than necessary.

---

**[CRITICAL] Fix section — the proposed work is already merged, under a different ticket**

The plan's entire "Root cause" and "Fix" content shipped as `8c7422b4f` (#403,
2026-08-06), tracked as **C11-200**, whose title is literally "ghostty_surface_set_display_id
deadlocks the main thread permanently (fixed in #403, split from C11-191)" and whose
status is `done`. Verified in the tree rather than inferred from branch state:

- Fix half 1 (c11 memo): `GhosttyDisplayIDGate` at `Sources/GhosttyTerminalView.swift:2640`,
  with `admit(_:force:)` and `invalidate()`, wired through `TerminalSurface.displayIDGate`
  at `Sources/GhosttyTerminalView.swift:2689`.
- Fix half 2 (ghostty export): submodule pointer bumped to `7604624d`, carrying
  `caf199071` "apprt/embedded: never block the UI thread in ghostty_surface_set_display_id",
  which wakes first, pushes `.instant`, and logs-and-drops on a full mailbox.
- Tests: `c11Tests/GhosttyDisplayIDGateTests.swift` (111 lines, added by #403).
- Checksum: `scripts/ghosttykit-checksums.txt` gained the matching entry in the same PR.

Blocker B4 (the split-churn frozen-terminal risk from de-forcing the `attachToView`
reuse branch) was also resolved in #403's third commit, by invalidating the memo when
the hosted view leaves its window. Blocker B7 (the cross-repo sequence) was executed
correctly: fork commit first, then the parent pointer, then the checksum pin.

**Recommendation:** No implementation should be dispatched from this plan. It would
re-do merged work.

---

**[CRITICAL] S1 blocked-on-operator — answered, and the answer removed this plan's subject from the ticket**

The prior review's S1 asked "whether this plan is fixing C11-191 at all," and three
reviewers recommended splitting the deadlock into its own P0. The operator did exactly
that: `eea3a1c75` ("Board: operator decisions on C11-190/191/192/193; file C11-200 for
the deadlock"). C11-191 retained the Sentry-signature scope, which was then delivered
by `b2fb5caa5` (#411), confirmed present on `origin/main`.

The candidate root cause the prior review handed forward, `vendor/bonsplit .../TabBarView.swift`
730-749 / 794-809, is **refuted** by the current plan on measured grounds:
`swiftui-update/preferences` is 13 of 5,311 episodes (0.2%), `updatePreferences` and
`TabBarView` co-occur in 12 (0.23%), and the `onPreferenceChange` to `@State` to
`.frame(width:)` path is idempotent rather than divergent because the state feeds a
sibling backdrop, not the measured subtree. So the reworked plan the prior review asked
for would have been rework toward a dead hypothesis.

**Recommendation:** Close out the B1-B7 / I1-I6 rework contract as moot rather than
outstanding. Leaving it in the ticket's record invites a future agent to resume rework
on a scope that no longer belongs here.

---

**[MAJOR] Ticket state — C11-191 sits at `planned` while its own plan says "delivered and merged"**

This mismatch is almost certainly what fired this plan review. The live plan opens with
"STATUS: delivered and merged as b2fb5caa5 (#411) on 2026-08-07," yet the task JSON
still reads `status: planned`. A ticket in `planned` is a ticket advertising itself as
ready for an implementer to pick up, which would send that implementer at merged work.

**Recommendation:** Move C11-191 out of `planned` into the validation state, gated on
the plan's own stated verification (first release carrying #402 and #411; C11-30 stops
accumulating and splits per cause, with `runloop-idle` a fraction of its former volume;
judge by issue presence and user count per bucket, not total event count). Do **not**
route it back through `in_planning`.

---

**[MAJOR] Current plan — the ticket's original acceptance criterion is displaced, not explicitly voided**

The ticket's ACCEPTANCE has two clauses. Clause 2 (Sentry recurrence judged by issue
presence and user count) is carried forward faithfully and sharpened. Clause 1, "a
reproduction (many tabs + tab bar interaction) that stalls main >1s before the change
and does not after," is not delivered and, given the refutation, cannot be: there is no
tab-bar preference storm to reproduce. The live plan simply does not mention it.

This is the one blocker from the prior trident review that survives the scope change
intact. B6 asked for exactly this: "if the ticket's repro AC is waived, say so."

**Recommendation:** Add one line to the live plan stating that ACCEPTANCE clause 1 is
void because the hypothesis it was written against is refuted, and that the repro
obligation transfers to **C11-202** (`task_01KZF332EFFVN656Q6ZSSW9RZQ`, "SwiftUI
update/layout passes wedge main for 2.5-3s (28% of hang episodes, 39 pids)"), where a
driven repro plus a profiler is the stated approach. A silently dropped acceptance
criterion is the kind of thing that reads as an oversight in six months; a declared
waiver reads as a decision.

---

**[MINOR] This checkout cannot confirm the plan's central claim**

Local `main` is 13 commits behind `origin/main` and 1 ahead (the unpushed board commit
`28a08837e`). `b2fb5caa5` (#411) exists only on `origin/main`, so `reportedStack` and
the `hang.app_active` / `hang.window_visible` tags are absent from local `main`. A
reviewer or validator checking "delivered and merged as b2fb5caa5" from this working
copy with a plain `git grep` against `main` will conclude the claim is false. The
`ghostty` submodule is likewise checked out at `b4ef0ac2`, one commit behind the
`caf199071` that `main`'s pointer records.

**Recommendation:** Push `28a08837e` and fast-forward local `main` before any further
board work or validation pass in this checkout.

---

**[MINOR, out of this ticket's scope] The B1 stranding concern is live in shipped code and now unowned**

Recording it because C11-200 closed and nothing else names it. The shipped pair
memoises on **attempt**: `GhosttyDisplayIDGate.admit` sets `applied = displayID` and
returns `true` (`Sources/GhosttyTerminalView.swift:2650-2655`), after which the ghostty
export may log-and-drop the push on a full mailbox (`caf199071`). A dropped push leaves
the memo asserting an id the renderer never received, which is precisely the
"memo-on-attempt plus drop-on-full strands a stale display link" objection all nine
prior reviewers raised as B1. The reviewer-preferred coalesced latest-value slot was not
implemented.

In practice the blast radius is bounded rather than permanent: the `force: true` sites
(surface creation, focus gain, topology churn, window and screen moves) bypass the memo,
and #403 added invalidation when the hosted view leaves its window, so a stranded
display link recovers at the next attach, focus, or screen change instead of never.
That is a defensible trade, and the ghostty commit message argues it explicitly.

**Recommendation:** Record the acceptance on C11-200 in one comment, or file a small
follow-up. Do not leave a known, deliberately-accepted gap with no written owner. This
is not a reason to hold C11-191.

---

## 4. Positive Observations

**The superseded plan was excellent work, and it is why a real P0 got fixed.** Resolving
`attachSurface + 372` by disassembling the installed release binary to the
`reconcileAttachedWindowIfNeeded` call, then following it to the `.forever` push into a
64-slot `BlockingQueue` in `embedded.zig`, is proof rather than inference. It found and
closed a permanent, force-quit-only main-thread deadlock (13h58m observed in the field)
that no amount of reading the Sentry stack would have surfaced. Being wrong about which
ticket it belonged to does not diminish that.

**It self-corrected on framing under review rather than defending its best number.** The
"9433 captures" headline became "roughly 8 to 11 of about 5,004 episodes, so rare and
catastrophic, not dominant" once the trident review pointed out that a persist-sampling
watchdog makes capture counts a duration metric. Volunteering that the dramatic figure
was an artifact is the behavior you want.

**The prior review's S1 was the right call, and the operator's split was the right
response.** Refusing to greenlight rework until the "is this even C11-191?" question was
answered is exactly what a blocked-on-operator gate is for. It saved a P0 from being
buried inside a mis-scoped ticket and kept C11-191 honest.

**The live 49-line plan is a model of reframing under evidence.** It names three measured
defects in its own ticket's premise (C11-30 is a `{{ default }}` fingerprint bucket
spanning eleven releases, "2335 ms" is the detection threshold rather than a duration
with real median 6.7s and p90 49s, and the quoted frames were `stack.prefix(24)` noise),
refutes its own inherited candidate root cause with numbers instead of argument, names
the successor ticket that owns the remaining user-visible freeze, and states a
verification rule that matches what the telemetry can actually show. It is also
appropriately short, and says why.

**Test placement avoided the trap CLAUDE.md warns about.** The plan claims the behavioral
tests are in `c11LogicTests` "so CI's `build` job runs them," while the #411 diff shows
the file at `c11Tests/MainThreadHangDetectorTests.swift`. That looks like the exact
directory-versus-target confusion CLAUDE.md documents from the `TerminalControllerSocketSecurityTests`
incident, so I checked the pbxproj: build file `E9E24C866C5E61B887F6E726` sits in Sources
phase `37DDE3B0A6A70E75A7B2BEDF`, which belongs to target **`c11LogicTests`**. The claim
is accurate. Worth stating explicitly, since a future reader will make the same
directory-based assumption I did.
