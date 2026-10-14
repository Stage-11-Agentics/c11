# Action-Ready Synthesis: c11-191-plan

Source pack: `notes/trident-review-C11-191-plan-pack-20260804-1613/` (9 reviews)
Plan under review: `.lattice/plans/task_01KZ732X0HCW7C324718YBZFTR.md`, section `# PLAN (agent:c11-191, 2026-08-04)`
Synthesized: 2026-08-04

## Verdict

**rework-then-rereview**

Reviewer verdicts disagree, and the disagreement is substantive:

| Review | Verdict |
|---|---|
| standard-claude | Needs revision (plan is pointed at the wrong ticket) |
| standard-codex | Needs revision before execution |
| standard-gemini | **Ready to execute** |
| adversarial-claude | Gates 8 minimum changes; scope + statistics unsound |
| adversarial-codex | **No-ship as written** |
| adversarial-gemini | Severe tunnel-vision objection |
| evolutionary-claude | Ship a stronger form; one correctness hazard escalated |
| evolutionary-codex | Should not ship as "memoize + drop" |
| evolutionary-gemini | Expand to an async FFI boundary |

Biasing to the more cautious verdict per the disagreement rule. Two things push this past
"revise-then-proceed":

1. **All 9 reviewers independently flagged the same correctness hazard** (B1 below): the Swift memo
   plus a lossy Zig drop can permanently strand a surface on a stale display link. That is not a
   wording fix; the plan needs to choose and specify a delivery contract, which is a design decision
   the plan does not currently contain.
2. **The plan's central scoping claim is contested** (S1 below), and settling it is an operator/author
   call that changes what acceptance criteria the work must satisfy.

The underlying engineering finding (the `.forever` push deadlock) is validated by every reviewer who
checked it, including the adversaries. This verdict is about the plan document and the fix's delivery
semantics, not about the discovery.

I independently verified the following while synthesizing, and they hold:
- `ghostty/src/apprt/embedded.zig:2176` is the only `.forever` push in `embedded.zig`; there are 18
  `.forever` pushes across `ghostty/src/`.
- `Surface.zig:3338` (`occlusionCallback`) pushes `.forever` with **no** dedupe;
  `Surface.zig:3354` (`focusCallback`) pushes `.forever` **with** a `self.focused == focused` guard.
- `renderer/generic.zig:1008 setMacOSDisplayID` has two silent early-return paths (null
  `display_link`; `setCurrentCGDisplay` error) that a Swift-side memo cannot observe.
- `Sources/` contains exactly **9** direct `ghostty_surface_set_display_id(` call sites and 7
  `ghostty_surface_set_focus(` / `ghostty_surface_set_occlusion(` call sites.

---

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: Memo-on-attempt plus drop-on-full can permanently strand a stale display link**
  - Where in the plan: Fix 1 ("Memoised `TerminalSurface.setDisplayID(_:force:)`; hot sites pass
    `force: false`") combined with Fix 2 ("push `.instant`, log-and-drop on a full mailbox").
  - Problem: `ghostty_surface_set_display_id` returns `void`, so Swift cannot learn that a push was
    dropped. The memo records "id X is current" for a value ghostty never received, every later
    `force: false` call is then suppressed, and the surface is pinned to a stale or stopped display
    link with no non-forced path back. This is worse than the hang it replaces: silent, persistent,
    and it is exactly the "visually frozen until a focus/visibility change" state that the existing
    unconditional re-assertion was added to paper over. Independently, `setMacOSDisplayID` itself
    returns early on a null display link and on a `setCurrentCGDisplay` failure, so even an
    *accepted* push is not proof of application.
  - Revision: The plan must state an explicit delivery contract for display ID and show how it
    converges. Required properties: (a) the caller never waits; (b) the **latest** requested valid
    display ID is eventually applied once the renderer makes progress; (c) the Swift memo advances
    only on state the renderer has actually accepted, never on a mere FFI attempt. Name the chosen
    mechanism from these candidates and justify it: (i) change the export to return an
    accepted/enqueued status and memoize only on success; (ii) hold a coalesced latest-value slot
    (atomic `u32` + dirty flag, or a per-surface pending field) that the renderer consumes on drain,
    which cannot block or drop and makes the Swift memo a pure optimization; (iii) dedupe inside
    `setMacOSDisplayID` *after* a successful `setCurrentCGDisplay`, mirroring the guard
    `focusCallback` already has. Multiple reviewers prefer (ii); the plan may choose otherwise but
    must argue it.
  - Sources: **all nine** — standard-claude (§2, Alt A), standard-codex (Weakness 1, Q2),
    standard-gemini (Weakness "Dropped Display ID Risk", Q1), adversarial-claude (C1, C3, Q5, Q12),
    adversarial-codex (Challenged Decision 1, Assumption table, Q2/Q3), adversarial-gemini
    (Assumption 3, Challenged 1, Q4), evolutionary-claude (§A), evolutionary-codex (§1, §4, Q1),
    evolutionary-gemini (§2, Concrete suggestion 2, Q1).

- **B2: Notify-before-push is a lost-wakeup bug as literally specified**
  - Where in the plan: Fix 2, "Notify the renderer first so it can drain, then push `.instant`."
  - Problem: `wakeup` is an `xev.Async` and coalesces. The renderer can wake on the notify, drain,
    and park *before* the subsequent `.instant` push lands; nothing then notifies it, so the message
    sits undelivered until an unrelated future wakeup. The reorder also buys nothing in the case that
    matters: a healthy renderer means the mailbox is not full and ordering is irrelevant; a wedged
    renderer ignores the notify and the `.instant` push fails anyway. Net effect as written: trades a
    deadlock for a silently delayed display ID, i.e. the frozen-pane symptom this code path exists to
    prevent.
  - Revision: Keep a notify **after** a successful push. Acceptable orderings, in preference order:
    `push(.instant)` then `notify()` (today's order with only the timeout changed), or
    `notify()` / `push(.instant)` / `notify()` if a pre-drain attempt is genuinely wanted. Do not
    ship notify-then-push alone. State the ordering explicitly in the plan and say what wakes the
    consumer for a message enqueued after a consumed notify.
  - Sources: standard-claude (§1), standard-codex (Weakness 2, Q3), standard-gemini (Q3),
    adversarial-claude (C2, Q6), adversarial-codex (Challenged Decision 1, Q4), evolutionary-codex
    (§2, Q2). Note: evolutionary-claude's Concrete Suggestion 1 endorses notify-first; it is the lone
    dissent and does not engage the coalescing argument.

- **B3: The `force` policy is asserted by category, not enumerated by call site**
  - Where in the plan: Fix 1, "hot sites pass `force: false`, every deliberate unstick-vsync site
    (`createSurface`, focus, topology churn, `viewDidMoveToWindow`, `windowDidChangeScreen`) keeps
    `force: true`".
  - Problem: There are exactly 9 direct `ghostty_surface_set_display_id(` call sites in `Sources/`
    (`GhosttyTerminalView.swift` lines 2949, 3296, 3343, 3660, 3807, 3835, 4541, 5262, 6620). The
    plan names five categories and two unspecified "hot sites"; the mapping from categories to those
    nine lines is not derivable from the plan, and two independent focus paths exist
    (`TerminalSurface.setFocus` and `becomeFirstResponder`). A delegator cannot execute this without
    re-deriving the policy, and any site missed bypasses the memo entirely.
  - Revision: Add a table with one row per current call site: file:line, the `force` value it will
    receive, the renderer invariant that value protects, and the user-visible scenario that would
    regress if it were wrong. Define `force` semantically ("re-apply even when the ID is equal
    because the display link must be restarted") rather than as a list of sites. Add a step making
    the raw FFI binding private to the policy helper plus a grep-based audit that no direct
    `ghostty_surface_set_display_id(` calls remain outside it.
  - Sources: standard-codex (Weakness 4, Q5), adversarial-codex (Assumption "All needed force sites
    have been found", Challenged Decision 2, Q5), adversarial-claude (A5), evolutionary-codex (§3,
    Concrete suggestion "Audit every call", Q5), evolutionary-claude (§A "best" option).

- **B4: Removing the re-assert risks silently reverting the split-churn frozen-terminal fix, with no validation planned**
  - Where in the plan: Fix 1 de-forces "the two per-`updateNSView` sites", one of which is
    `attachToView`'s reuse branch; Fix 1 separately lists "topology churn" as a `force: true` site.
  - Problem: The reuse-branch re-assert (`GhosttyTerminalView.swift` ~3285-3298, added by
    `50f0dd334` / PR #12, "Fix frozen terminals after split churn") exists precisely because after
    split-close restructuring the view is removed and re-added with window/screen transiently nil,
    with no focus change and no screen change. `setMacOSDisplayID` deliberately stop/starts the
    display link on a same-ID re-assert to recover the stuck-vsync-no-frames state. The plan is
    ambiguous about whether the reuse branch is a hot site (de-forced) or the topology-churn site
    (forced), and its only proposed test counts pushes, which cannot detect a frozen pane.
  - Revision: State explicitly which of the two per-`updateNSView` sites becomes `force: false` and
    how #12's behavior is preserved. Consider keying the memo on attachment topology rather than
    display ID alone (e.g. `(displayID, ObjectIdentifier(window), attachEpoch)`, epoch bumped on any
    view/window reparent) so genuine churn still kicks the link while steady-state SwiftUI updates
    are suppressed. Add a concrete validation step: `scripts/repro-c11-18.sh` portal churn with
    `C11_PORTAL_DEBUG=1`, plus a real-artifact tagged-build screenshot pass proving panes still
    render after split-close.
  - Sources: standard-claude (§4, Q9/Q10), adversarial-claude (Failure pattern 5, A5, C-question 10,
    Minimum change 6), adversarial-codex (Challenged Decision 3, Assumption table), evolutionary-claude
    (§A, citing the `attachToView` comment at 3278-3284), standard-codex (Weakness 4).

- **B5: No test or fault-injection covers the ghostty half, which is the load-bearing half**
  - Where in the plan: "Evidence / measurement" — "Deterministic: `c11LogicTests` behavioural test
    over the memo seam".
  - Problem: The described test exercises the Swift memo, which is the optimization. The change that
    makes the deadlock impossible (the non-blocking push) ships with no test and no repro, so nobody
    can demonstrate before/after that the fix closes the bug. Per repo policy, "count pushes per
    session" is a measurement of the intended implementation, not of the customer-facing failure.
  - Revision: Add a Zig-level test next to the fix: fill the renderer mailbox to capacity, invoke
    `ghostty_surface_set_display_id` from a producer thread, assert it returns promptly (no block),
    then drain and assert the **latest** requested display ID was applied. Add a debug-gated
    fault-injection switch that stops the renderer draining, so the deadlock is reproducible on
    demand from a tagged build and the fix is demonstrable pre-release rather than post-release.
  - Sources: standard-claude (Weakness "No test for the ghostty change", Q11/Q12), standard-codex
    (Weakness 3, Q8), adversarial-claude (B5, Reality stress test 2), adversarial-codex (Blind spots,
    Q7/Q8), evolutionary-claude (§C, Concrete suggestion 3), evolutionary-codex (Sequencing 2,
    "Add an integration assertion...").

- **B6: The acceptance oracle is not falsifiable for the work being done**
  - Where in the plan: "Evidence / measurement" section as a whole; the plan inherits the ticket's
    ACCEPTANCE block unchanged.
  - Problem: The ticket's stated AC is "a reproduction (many tabs + tab bar interaction) that stalls
    main >1s before the change and does not after" plus non-recurrence of the Sentry issue. Nothing
    in the plan produces that repro, and "count `macos_display_id` pushes per session" measures a
    precondition, not a hang. A downstream validator will either block indefinitely or rubber-stamp.
  - Revision: Write an explicit, falsifiable acceptance section for the work actually being done. At
    minimum: (a) a local oracle over `~/Library/Logs/c11/hang.log` counted **by episode**, e.g. zero
    hang episodes with leaf `__ulock_wait2` under `attachSurface` over N days of normal operator use
    post-fix; (b) the queue-full test from B5 as the CI gate; (c) for the Sentry half, name the
    release cohort, comparable install count, observation window, who checks, and the trigger to
    reopen or roll back (noting rollback is complicated by the prebuilt xcframework). If the ticket's
    original repro AC is being waived, say so explicitly and record who signs off (see S1).
  - Sources: standard-claude (Weakness "Acceptance criteria are not falsifiable", Readiness item 2),
    standard-codex (Weakness 6, Q9), adversarial-claude (Failure pattern 4, B6, Q4/Q16/Q17),
    adversarial-codex (Blind spots on success definition and release monitoring, Q10/Q11),
    evolutionary-claude (§C, §D, Q4), evolutionary-codex (Sequencing 4, Concrete suggestion on the
    release experiment).

- **B7: The cross-repository delivery sequence is entirely absent**
  - Where in the plan: Fix 2 changes the ghostty submodule; the plan contains no execution steps for
    it.
  - Problem: Per `CLAUDE.md`, a ghostty change must be committed on a real fork branch and pushed to
    `Stage-11-Agentics/ghostty` **before** the parent pointer is committed (or the submodule commit
    is orphaned), and any submodule SHA bump requires a matching `scripts/ghosttykit-checksums.txt`
    entry that the `build-ghosttykit` workflow generates, producing an expected run-1-red /
    run-2-green pattern after a ~10-minute Zig build. A delegator following this plan will hit three
    red CI jobs and misdiagnose them, or hand-edit the checksum file. If the export grows a return
    value or parameter (B1/B3), the vendored header changes too.
  - Revision: Add an implementation-sequence section covering: fork branch + push to
    `Stage-11-Agentics/ghostty`, ancestry verification (`git merge-base --is-ancestor HEAD
    origin/main`), parent pointer commit, `build-ghosttykit` / checksum expectations with the
    run-1-red note called out as expected, any vendored header regeneration, and an update to
    `docs/ghostty-fork.md`.
  - Sources: standard-claude (Weakness "No mention of the ghostty submodule and checksum workflow",
    Q13), standard-codex (Weakness 7, Q12), adversarial-claude (B3, Reality stress test 1, Minimum
    change 7), adversarial-codex (Blind spots, Q9), evolutionary-claude (Sequencing 3),
    evolutionary-codex (Sequencing 5).

### Important (revise before implementation starts)

- **I1: Fix 1 does not make the main thread safe; other `.forever` exports remain main-reachable**
  - Where in the plan: Fix 2's framing as *the* blocking call; the plan's implicit claim that the two
    fixes together remove the wedge.
  - Problem: Verified: `ghostty_surface_set_focus` -> `Surface.focusCallback` (`Surface.zig:3354`)
    and `ghostty_surface_set_occlusion` -> `Surface.occlusionCallback` (`Surface.zig:3338`) both
    push `.forever` into the same 64-slot renderer mailbox, and c11 calls both from the main thread
    on ordinary interaction (7 call sites in `Sources/`). `occlusionCallback` additionally has **no**
    dedupe guard, unlike its focus sibling. There are 18 `.forever` pushes in `ghostty/src/` total.
    After this plan ships as written, the identical deadlock remains reachable through focus and
    occlusion, and will present as a different fingerprint and be triaged as a new bug.
  - Revision: Either extend the fix to the class (a `pushFromAppThread` helper used by every
    app-thread-reachable export, plus the missing `if (self.visible == visible) return;` guard in
    `occlusionCallback`), or state explicitly in the plan that the residual exposure through focus
    and occlusion is knowingly out of scope, with a filed follow-up. Also consider a debug-build
    assertion that `.forever` is never used from the registered app thread, which converts a comment
    into something CI can fail on. Do not leave the plan implying main is safe when it is not.
  - Sources: standard-claude (§3, Q8, Readiness item 5), evolutionary-claude (§B with the verified
    export table, Q2, Concrete suggestions 2 and 5), adversarial-claude (B2, Q18), standard-codex
    (Architectural Assessment: "a future caller, a missed call site, or a new binding must still be
    unable to wedge the main thread").

- **I2: "One signature dominates" is capture-weighted and misleading**
  - Where in the plan: "Root cause" evidence — "One signature dominates: 9433 captures wedged with
    leaf `__ulock_wait2`; 9413 of those with frame 1 = `GhosttyNSView.attachSurface`".
  - Problem: Both Claude reviewers re-ran the operator's log and found that ~9412 of those captures
    come from a **single pid (6063) in a single ~14h episode**. Counted by episode rather than
    capture, `attachSurface` appears in roughly 8-11 of ~5004 episodes (0.2%) across 51 days, while
    `TabBarView` appears in 32 and `updatePreferences` in 232. A persist-sampling watchdog produces
    unbounded capture counts for exactly the bugs that never terminate, so capture-weighted counts
    are a duration metric, not a frequency metric. This is the specific analytical step that produced
    the plan's scoping claim.
  - Revision: Rewrite the evidence section to report **episodes and distinct pids alongside
    captures**, and restate the finding honestly as "rare and catastrophic" rather than "dominant".
    Note that the finding survives the honest framing and is arguably stronger for it. This revision
    is applicable regardless of how S1 is resolved.
  - Sources: standard-claude (Executive summary point 3, Weakness "Statistical framing"),
    adversarial-claude (Executive summary tables with reproducible awk, Uncomfortable truth 2),
    evolutionary-claude (M2: rank by wedged wall-clock time, not capture count).

- **I3: Memo lifecycle and keying are underspecified**
  - Where in the plan: Fix 1, "Memo resets on surface create/destroy."
  - Problem: "Create/destroy" does not cover the states this codebase actually has: `ghostty_surface_new`
    failure, a replaced surface pointer, deferred/off-window surface creation, headless-startup-window
    to real-window migration, portal reparenting, and teardown racing a pending update. Separately,
    both hot sites fall back to `NSScreen.main` (the screen with keyboard focus, not the surface's
    screen), and macOS display IDs are reused across disconnect/reconnect, so ID equality is a weak
    identity for the memo. A reset at the wrong point manufactures a redundant force; a missed reset
    suppresses the initial required update.
  - Revision: Specify the memo as a small explicit state machine scoped to the lifetime of a specific
    ghostty surface pointer: what invalidates it, what it is keyed on (see B4's topology-keying
    suggestion), what happens on surface-creation failure and pointer replacement, and the behavior
    for invalid/zero IDs and for a pending update outliving `ghostty_surface_free`. Name the
    multi-display cases the design must survive: monitor unplug/replug, sleep/wake, Space move,
    window drag between displays.
  - Sources: standard-codex (Weakness 5, Q6), adversarial-codex (Challenged Decision 2 "cache reset
    also needs a precise state machine", Blind spots on teardown races and multi-display),
    adversarial-claude (Invisible assumptions: display ID reuse, `NSScreen.main`; B10),
    evolutionary-codex (§4, Concrete suggestion on invalid IDs and free races).

- **I4: Sequencing is inverted, and the two halves must ship together**
  - Where in the plan: "Fix" section, numbered 1 (c11) then 2 (ghostty).
  - Problem: The ghostty change is what makes the failure impossible; the memo only makes it less
    likely, and every preserved `force: true` site still performs an unbounded blocking push until
    ghostty lands. The ghostty half also has the longest CI tail (submodule + checksum + Zig build).
    Worse, if the Swift memo ships alone, event volume drops (compounded by #401's outbound budget),
    the acceptance criterion reads as satisfied, and the deadlock is still reachable. The memo's
    correct design also depends on the delivery contract chosen in B1, so doing Swift first commits
    to the hazardous optimistic-memo shape.
  - Revision: Reorder the plan: ghostty delivery contract and tests first, then the c11 adapter
    routed through the resulting API. State as an explicit requirement that both halves ship in the
    same release, and say what happens if they do not (split-release compatibility: what is the
    supported combination of a newer c11 Swift layer against an older GhosttyKit?).
  - Sources: evolutionary-claude (Sequencing section, Q6), standard-claude ("Is This the Move" ranked
    list; the plan orders this 3, 1), standard-codex ("I would sequence this as: define/test
    Ghostty's coalesced nonblocking display-ID handoff... then update c11"), adversarial-codex (Blind
    spot: split-release compatibility risk, Q9).

- **I5: The plan does not reconcile with `notes/BUG-main-thread-deadlock-attachSurface.md`**
  - Where in the plan: absent — the plan never cites the prior note, which analyzes the same pid 6063.
  - Problem: The repo will contain two documents asserting two different root causes for the same
    incident. The prior note's `SharedGridSet.lock` / `SharedGrid` write-lock analysis is currently
    the standing advice for the next reader, and its proposed fixes are not the fix for this
    deadlock. One reviewer treats the note as *refuting* the plan; two others argue the plan is right
    and the note is wrong (the note's own `/usr/bin/sample` frame shows
    `Thread.Futex.Deadline.wait`, which in Zig stdlib is the `std.Thread.Condition` futex path, not
    the `std.Thread.Mutex` path, and is therefore consistent with `cond_not_full.wait`). Leaving this
    unstated guarantees a future agent re-litigates it.
  - Revision: Add a short section that explicitly addresses the prior note: state the relationship
    (supersede, complement, or both-deadlocks-present), give the `Futex.Deadline` vs `Futex.wait`
    argument, and update the note itself. Separately answer the question every reviewer asked: **why
    did the renderer stop draining for 14 hours?** A renderer dead that long is a visually dead pane
    independent of the main-thread wedge. State that as a filed follow-up ticket with the note's
    `SharedGrid` analysis as the leading hypothesis, and predict the post-fix `hang.log` signature
    (`attachToView` -> `createSurface` -> `ghostty_surface_new` -> `SharedGridSet.ref` can still
    produce `__ulock_wait2` under `attachSurface` at a different offset) so nobody misreads it as a
    regression.
  - Sources: standard-claude (§"Reconciling with the prior BUG note", Q15/Q16), adversarial-claude
    (A3, A8, C7, Q8/Q9, Minimum change 8), adversarial-gemini (Executive summary, Blind spot 1,
    Q1/Q2), standard-gemini (Weakness 2, Q2), evolutionary-claude (Q5, M6), evolutionary-gemini (§1,
    Q2), evolutionary-codex (Q8).

- **I6: The `c11LogicTests` seam is not identified, and the obvious construction crashes locally**
  - Where in the plan: "Deterministic: `c11LogicTests` behavioural test over the memo seam."
  - Problem: `CLAUDE.md` warns that logic tests constructing `Workspace`/`TabManager`/AppKit terminal
    views crash the bare xctest runner locally on a nil `NSApp`. The plan does not name a pure seam,
    so the delegator will discover this the hard way or write a test that only runs in CI. A test
    that counts a mocked push also risks testing the mock rather than any production behavior.
  - Revision: Name the concrete seam: a small pure type (or protocol-injected dispatcher) that owns
    the memo and the force policy, constructible without AppKit, and state what observable behavior
    the test asserts beyond an internal call count.
  - Sources: standard-codex (Weakness 3, Q7), adversarial-claude (Invisible assumptions, Q14),
    adversarial-codex (Assumption table row "A logic test can instantiate the desired seam safely",
    Q8).

### Straightforward mediums

- **M1: "Offer upstream" needs a routing correction**
  - Where in the plan: Fix 2, "Generic, not c11-specific -- offer upstream."
  - Problem: The standing rule for this repo is never to push, branch, or PR against
    `manaflow-ai/*`, which is the ghostty submodule's `origin`. As written, an agent may read this as
    authorization to open an upstream PR directly.
  - Revision: Reword to: land the change in `Stage-11-Agentics/ghostty`, and flag it to the operator
    with a one-line note so they decide whether and how to offer it upstream. Note also that upstream
    may reject silent message loss as semantically wrong, which is a further argument for the
    coalescing design in B1.
  - Sources: standard-claude (Weakness "'Offer upstream' needs a routing correction", Q14),
    adversarial-claude (Invisible assumptions, Q13), adversarial-codex (Challenged Decision 4).

- **M2: Specify the measurement mechanism and the drop/suppression telemetry**
  - Where in the plan: "Real artifact: tagged build, count `macos_display_id` pushes per session
    before/after."
  - Problem: No mechanism is named. The existing `log.info("updating display link display id={}")`
    in `setMacOSDisplayID` counts drains, not pushes, and any manual one-shot count expires when the
    PR merges. Separately, "log-and-drop" has no defined logging policy, so a hot-path drop can spin
    a high-volume log, and a dropped update is otherwise invisible.
  - Revision: Name the exact counter/log source, the expected baseline and post-change values for N
    `updateNSView` passes, and how intentional force requests are distinguished from deduplicated and
    dropped/coalesced ones. Make the counters permanent per-surface values surfaced somewhere an
    agent can read (`c11 tree --json` or the debug window) rather than a disposable measurement, and
    state the release-vs-debug logging policy for drops.
  - Sources: evolutionary-claude (§D, Concrete suggestion 9), adversarial-claude (Hindsight early
    warning 1), adversarial-codex (Blind spot on success definition and logging policy, Hindsight
    early warnings), evolutionary-codex (Concrete suggestion on requested/applied/coalesced counts),
    standard-codex (Weakness 6).

- **M3: Document the disassembly provenance and caveat the frame-pointer gap**
  - Where in the plan: "Root cause (disassembly-verified)" — the `objdump` excerpt and
    "Every wedged sample sits at `attachSurface + 372`".
  - Problem: The plan spends a paragraph teaching the reader not to trust symbolication, then
    presents a disassembly with no reproducible inputs (binary path, build/UUID, architecture, slide
    handling) and a stack that is silently frame-skipped: between `__ulock_wait2` (frame 0) and
    `attachSurface` (frame 1) the real stack has roughly six frames (`pthread_cond_wait`,
    `Futex.Deadline.wait`, `Condition.timedWait`, `BlockingQueue.push`,
    `ghostty_surface_set_display_id`, `reconcileAttachedWindowIfNeeded`), absent because libghostty
    is built without frame pointers.
  - Revision: Record the exact binary path, version/build, and the offset-resolution procedure so the
    finding is reproducible, and add one sentence noting the missing intermediate frames and why. If
    cheap, add one `lldb` thread backtrace from a live wedged process, which removes all doubt. Also
    state (rather than assert) that `reconcileAttachedWindowIfNeeded` was read and contains no other
    blocking primitive.
  - Sources: standard-claude (§"Reconciling with the prior BUG note", final two paragraphs),
    adversarial-codex (Assumption table rows on binary UUID / ASLR slide, Q1), adversarial-claude
    (A7).

### Evolutionary clear wins

*(None promoted. The strongest evolutionary items either duplicate B1's design question, expand
scope materially, or belong to follow-up tickets. See "Evolutionary worth considering" and
`synthesis-evolutionary.md`.)*

---

## Surface to user (do not apply silently)

- **S1: Is this plan fixing C11-191 at all? (the identification dispute)**
  - Why deferred: disagreement + author-intent-needed + strategic ticket-management call
  - Summary: The plan opens by "correcting" the ticket's reading. Reviewers split hard on whether the
    correction is right. Against the plan: (a) the Sentry stack has **no `libsystem_kernel.dylib`
    frame** anywhere in the quoted range, while all ~9433 local `attachSurface` captures have
    `__ulock_wait2` at frame 0, so by the plan's own "module attribution is trustworthy" rule the
    Sentry hang is not a futex block; (b) frames 16-21 (`GraphHost.updatePreferences` ->
    `UpdateStack::update`) are the common trunk of essentially every SwiftUI-driven main-thread hang
    and appear in ~232 local episodes, so matching on them is not a fingerprint; (c) profile mismatch
    (Sentry: 0.58.0+116, 2026-07-25, 941 events / 11 users / bounded 2335ms; local: 0.60.1,
    2026-07-29, one pid, 13h58m, no `hang.end`); (d) the `TabBarView` signature exists **verbatim and
    locally symbolicated** in the same `hang.log` in ~32 episodes across 10+ pids with `stalledMs`
    from ~2s to ~39s, with the preference keys named. For the plan: standard-codex and
    standard-gemini both accept the correction as correct expert debugging, and standard-gemini rates
    the plan ready to execute. Standard-claude went further and located a candidate root cause for
    the *original* ticket: `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift` lines
    730-749 write `TrailingAccessoryWidthKey` / `SplitButtonsIntrinsicWidthKey` from
    `GeometryReader`, lines 794-809 consume them in `.onPreferenceChange` into `@State` with no
    equality or epsilon guard, and line 722 feeds the derived `chromeWidth` back into `.frame(width:)`
    on a sibling: a measure -> write state -> resize -> re-measure feedback loop, superlinear in tab
    count. **The decisive check both Claude reviewers propose costs under an hour:** take one real
    Sentry event for 0.58.0+116 and resolve frame 0's offset against that binary the same way the
    plan resolved `attachSurface + 372`. If it lands in the tab bar subtree, the plan is
    misidentified; if it lands in `attachSurface`, the plan wins outright. The downstream
    recommendation from three reviewers is to **split the ticket**: file the deadlock as its own P0
    (unrecoverable, 14 hours, destroys agent sessions) and leave C11-191 on the Sentry signature with
    its stated acceptance criteria, rather than redefining C11-191 inside a plan file. This is your
    call, not the synthesizer's: it changes ticket scope, acceptance criteria, and what "done" means.
  - Sources: standard-claude (Executive summary, §"What the actual C11-191 fix looks like",
    Readiness item 1, Q1-Q4), adversarial-claude (Executive summary, A1/A2, C6, Q1-Q4, Minimum change
    1), adversarial-codex (Assumption table row 1, Q1), adversarial-gemini (Executive summary,
    Assumption 1, Q5), evolutionary-claude (Q3), evolutionary-codex (§5) — against; standard-codex
    (Executive summary, "Is This the Move"), standard-gemini (Key strengths, Readiness verdict) —
    for.

- **S2: `BlockingQueue` wakes exactly one waiter, which is the actual starvation mechanism**
  - Why deferred: single-reviewer + scope-creep into a shared primitive
  - Summary: `BlockingQueue.pop` signals `cond_not_full` **once**, and `drain()`'s `deinit` also
    signals once after emptying all 64 slots. Three producers push into the renderer mailbox (main,
    the IO thread at `stream_handler.zig:172`, and termio at `Termio.zig:516`), so draining the
    entire mailbox wakes exactly one of them. That is plausibly the mechanism by which a producer
    waits 14 hours. Changing `signal()` to `broadcast()` (or one signal per popped item) would fix
    the class for all producers, not just main. Note this also means a starved termio producer stalls
    terminal output, a user-visible bug that survives the plan intact. The reviewer also observed
    that `BlockingQueue`'s own doc comment claims SPSC while three producers exist. Worth a decision:
    in scope, separate ticket, or explicitly declined with a reason.
  - Sources: adversarial-claude (B1, Invisible assumptions, Q7, Minimum change 5).

- **S3: Ship a bounded push (`.ns = 5ms`) as an immediate mitigation ahead of the full fix**
  - Why deferred: design-needed + single-reviewer + it is an operator risk-appetite call
  - Summary: A one-token change from `.forever` to a bounded timeout converts an unbounded deadlock
    into a 5ms worst-case stall, keeps delivery semantics essentially intact, and needs none of the
    memo-interaction analysis in B1. Weaker than the coalescing design, but shippable immediately.
    Given that users are currently exposed to a 14-hour, force-quit-only failure that destroys running
    agent sessions, and given that the full fix carries a multi-day submodule/checksum/CI tail, there
    is an argument for landing this first as a hotfix commit. The counter-argument is that it adds a
    second submodule round-trip.
  - Sources: standard-claude (Alternative B, Q19).

- **S4: Split the PRs — land the safety fix without the memo**
  - Why deferred: author-intent-needed + interacts with S1's outcome
  - Summary: With the ghostty delivery contract landed, the Swift memo is a pure optimization rather
    than a safety property. Fix 1 is also the piece carrying the #12 regression risk (B4) and the
    stale-memo interaction (B1). Deferring it to a follow-up PR with its own review would let the
    safety fix ship faster and cleaner. Two other reviewers propose a related restructuring: move the
    dedupe into ghostty entirely (`setMacOSDisplayID` gains the guard its `focusCallback` sibling
    already has), or grow the export to
    `ghostty_surface_set_display_id(surface, id, force)` so the "restart the display link" intent is
    expressed at the boundary and the Swift shadow memo disappears. Any of these materially changes
    the plan's shape and should be the author's call.
  - Sources: standard-claude (Alternative D), evolutionary-claude (§A "Better"/"Best", Concrete
    suggestion 1), adversarial-claude (C4, C5), evolutionary-codex (§1).

- **S5: `createSurface` on the main thread is a second, unaddressed blocking path under the same frame**
  - Why deferred: disagreement on whether it belongs in this ticket
  - Summary: `attachToView` still calls `createSurface` -> `ghostty_surface_new` -> `SharedGridSet.ref`
    on the main thread, under a mutex held across font discovery. Two reviewers argue this makes the
    plan incomplete and that the whole of `attachSurface` should move off-main (a `GhosttyBridge`
    actor / dedicated serial queue). Two others argue the opposite: that is a large, racy change to a
    typing-latency-sensitive path with an existing deferred-attach state machine, it does not remove
    the "an apprt export can block forever" hazard for other callers, and fixing the callee is the
    better move for this ticket. Either way, the plan should predict the residual post-fix signature
    so the next reader does not mistake it for a regression (folded into I5), but whether to attack
    it here is unresolved.
  - Sources: adversarial-gemini (Blind spot 1, Q2), evolutionary-gemini (§1, Sequencing 2, Concrete
    suggestion 1) — for; standard-claude (Alternative C), standard-codex ("Move attachment off-main")
    — against; adversarial-claude (C7) — wants scope stated either way.

- **S6: ~40% of local captures show main idle in `mach_msg2_trap` during a declared stall**
  - Why deferred: single-reviewer + it bears on whether the 941-event denominator is trustworthy at all
  - Summary: 7910 of ~20778 captures have frame 0 = `libsystem_kernel.dylib mach_msg2_trap`, i.e.
    main parked idle in `CFRunLoopServiceMachPort` while the watchdog declared a multi-second stall.
    Either the hang watchdog has a large false-positive class (main in a nested/tracking runloop mode
    not servicing the probe), or the probe mechanism itself is being starved. Not this plan's job,
    but it affects how much of the 941-event Sentry volume is real, and therefore how to read B6's
    acceptance oracle. Probably a line to C11-186.
  - Sources: standard-claude (Weakness "Unexamined: 7910 captures", Q17).

- **S7: `hang.log` is 151 MB and unrotated on every release user's disk**
  - Why deferred: scope-creep (a separate shipping defect this plan walked past)
  - Summary: One episode wrote 9412 consecutive captures at roughly 7 KB each, about 66 MB from a
    single hang. Two small changes fix it: rotate/cap the log, and dedupe within an episode (write
    frames once at `hang.begin`, then delta lines on `hang.persist` when the fingerprint is
    unchanged). Worth filing as its own ticket; it also makes any future corpus mining cheaper.
  - Sources: evolutionary-claude (M5, Concrete suggestion 6).

---

## Evolutionary worth considering (do not apply silently)

- **E1: Make "no exported ghostty function called from the host UI thread may block" the deliverable, and bundle it as a themed upstream contribution**
  - Summary: Rather than one export made non-blocking, establish a general renderer control-plane
    contract: state-bearing controls (display ID, visibility, focus, scale) use coalescing
    last-value-wins delivery; ordered events keep the queue; no app-thread-reachable export performs
    an unbounded wait; a debug assertion enforces it. Bundled with the missing `occlusionCallback`
    dedupe and the `SharedGridSet.ref` / `SharedGrid` lock findings from the prior BUG note, this is a
    coherent "libghostty embedding safety" contribution rather than three orphan patches, and it
    retires three private divergences in shared code at once.
  - Why worth a look: it is the strongest-supported evolutionary idea in the pack (five of nine
    reviewers converge on it), it subsumes B1 and I1 into one design, and per `CLAUDE.md` upstream
    standing is strategic leverage in both directions.
  - Sources: evolutionary-codex (§"What's Really Being Built", §1, Mutation "State mailbox, event
    mailbox"), evolutionary-claude (§B, M6, Concrete suggestions 1/2/5), evolutionary-gemini
    (Mutation 1 "Shared Memory Config Block", Concrete suggestion 2), standard-claude (Alternative
    A), adversarial-claude (C1).

- **E2: Fix c11's outbound Sentry fingerprinting, not just this bug**
  - Summary: The plan proves that c11's Sentry stacks contain impossible frames and untrustworthy
    c11-binary symbol names, because `backtrace_symbols()` symbolicates on-device by nearest exported
    symbol. Compute the fingerprint on device from `(leaf, frame1, frame2)` where local symbolication
    is good, and ship raw `image + slide` addresses for server-side dSYM symbolication. Since #401
    cut event volume, the team now plans to judge recurrence by **issue presence and user count** —
    which makes grouping correctness load-bearing in a way it was not before.
  - Why worth a look: it is a one-time change that upgrades the accuracy of every past and future
    Sentry-derived ticket, and it is what makes C11-191's own verification trustworthy.
  - Sources: evolutionary-claude (M1, Concrete suggestion 8, Q8), standard-claude (Executive summary
    §1, "Correction" analysis).

- **E3: Turn the 151 MB hang corpus into a ranked, repeatable report**
  - Summary: A `scripts/hang-triage.py` that clusters `hang.log` captures by `(leaf, frame1, frame2)`
    and ranks by **total wedged wall-clock time** (not capture count), emitting fingerprint /
    episodes / total wedged time / worst episode / first-last seen / affected pids. Standalone, no
    dependency on the fix. It would have surfaced I2's counting error automatically, it makes
    signature #2 nearly free, it produces the before/after number B6 needs, and it makes "total
    main-thread wedged seconds per hour of use" a release-over-release metric the project does not
    currently have.
  - Why worth a look: the cheapest item in the pack that converts a one-off investigation into
    standing infrastructure, and it directly serves this plan's own acceptance oracle.
  - Sources: evolutionary-claude (M2, M7, Concrete suggestions 4 and 7), adversarial-claude
    (Hindsight early-warning signals 2 and 4).
