# Plan Review — C11-192 (Standard)

- PLAN_ID: `c11-192-plan`
- MODEL: Claude
- Reviewed: 2026-08-04 16:18
- Target: `.lattice/plans/task_01KZ733HRN64WS7YSVCTT6WWRP.md`
- Branch: `c11-192-button-metadata` (PR #402, 2 commits, already open)

---

## Executive Summary

The diagnosis is excellent and the pivot is correct. The plan's central finding — that
Sentry issue C11-31 is not a generic-metadata bug but a *grouping artifact* caused by
`attachStacktrace = true` fingerprinting message events on the watchdog thread's
byte-identical stack — is the single most valuable thing in this document. It invalidates
the parent ticket, and by extension it casts doubt on how the whole Sentry audit of
2026-08-04 was read. That is worth more than the fix it proposes.

Three things temper my enthusiasm.

**First, this is not a plan.** It is a retrospective rationale written after the work
landed. The branch exists, both commits exist, PR #402 is open, and the plan's
"Verification" section is written in the past tense about work already done. Judged
against the brief I was given — "is this an executable implementation plan for an agent
on branch `c11-192-button-metadata`" — the answer is no. Section "Work" is four
declarative sentences naming four artifacts. A fresh implementer handed this cold would
have to re-derive the cause taxonomy, the frame windows, the parse format, the rule
precedence, and — critically — would have no way to reach the 875-event corpus the
verification depends on. They would produce *a* classifier, but not *this* classifier,
and since the bucket names **are the Sentry fingerprint**, a different taxonomy is a
different set of permanent issue groups. Reproducibility matters more here than in most
tickets, and the plan provides none.

**Second, the fix stops one step short of the bug it diagnosed.** The plan correctly
identifies that the *presentation* is what misled everyone: Sentry showed the watchdog's
stack, someone read it as the wedge, and C11-192 was filed against a Button that does not
exist. The change fixes *grouping* (explicit fingerprint) and *titling* (message names
the cause), but leaves `attachStacktrace = true` untouched. So the new `generic-metadata`
issue will still render the watchdog's stack in Sentry's primary stack-trace panel, with
the real 24-frame capture demoted to a context blob. The next person to open that issue
walks into exactly the same trap. `Sources/AppDelegate.swift:2623` already has a
`beforeSend` hook — the seam to swap or strip the misleading thread stack is sitting
there unused. This is the highest-value missing item in the change.

**Third — and this is the one I'd hold the PR on — the statistical table that justifies
the whole pivot is computed over the wrong unit.** More below, but in short: the 875
events are pre-#401 *recaptures*, one user contributed 816 of them, and each long
episode re-sent the same wedge every 5 seconds. "63.9% SwiftUI graph work / 5.7% generic
metadata" is therefore a distribution over *samples of episodes*, weighted by episode
duration and by one user's machine, not a distribution over *episodes*. Post-#401 the
monitor sends one event per episode, so the shipped classifier will produce a completely
different — and possibly inverted — ranking. The plan half-notices this (it flags the
816/875 skew in a throwaway line) and then never corrects the table, even though the
amended acceptance criterion is explicitly about per-cause *trend*.

Verdict: **needs revision** — small, targeted revisions, not a rethink. The engineering
is sound; the evidentiary framing and the plan-as-document are not.

---

## The Plan's Intent vs. Its Execution

The stated intent shifted mid-document, and the shift is legitimate but under-managed.

The ticket's intent: *find and fix a 10-second view-tree hang.*
The plan's intent: *make hang reports separable by cause so a future ticket can find and
fix the real hangs.*

That is a good pivot. When you discover the instrument is broken, fixing the instrument
before chasing the reading is right. What's missing is the bookkeeping that makes the
pivot honest:

1. **The original question is left open and unticketed.** The plan says "whether
   generic-metadata instantiation is worth attacking needs its own issue with its own
   trend." It does not file that issue. Same for the three follow-ups at the bottom (XPC
   sync waits up to 604s, the `hosting-begin-transaction`/`hosting-layout` split,
   `runloop-idle`). "Follow-ups exposed (separate tickets)" is a heading naming zero
   ticket IDs. The 604s XPC wedge in particular is described as a "real wedge class, no
   ticket" and then left with no ticket. Prose in a merged plan is where findings go to
   die.

2. **The ticket identity is now wrong in three places.** C11-192's title still says
   "Main thread wedges 10s in `swift_getTypeByMangledName` under SwiftUI.Button.body."
   The branch is `c11-192-button-metadata`. Neither describes the work. Anyone searching
   the board six weeks from now for "did we ever fix the Button hang" will find a closed
   ticket that did not fix it. Either retitle C11-192 to what it became, or close it as
   invalid and move the work under a new ID.

3. **The amended acceptance is weaker than it looks.** "Hang reports group by cause,
   `generic-metadata` exists as its own Sentry issue with its own user count and trend."
   Two problems. (a) Nothing in the plan verifies this end-to-end against the real Sentry
   project — the verification is an offline `swiftc` replay plus unit tests, both of
   which prove the classifier is a function, not that Sentry honors the fingerprint on a
   message event with `attachStacktrace = true`. That is precisely the "green tests ≠
   working product" gate the repo's CLAUDE.md makes a hard rule. (b) The criterion is
   satisfiable by shipping and waiting, with no stated observation window, no threshold,
   and no owner. As written it will be marked done by whoever notices the deploy went
   out.

On the reviewer question I was asked directly — *does the plan say how to reproduce the
hang and capture a Time Profiler trace?* — no, and it argues persuasively that it
shouldn't have to. The evidence for that argument is genuinely strong (24 of 875 events
carry demangler symbols; no metadata-stack event names a c11-owned `Button`). I accept
the amendment in principle. But an amendment that replaces a falsifiable criterion (a
trace showing a symbol absent) with an unfalsifiable one (an issue exists and has a
trend) is a downgrade, and it should be replaced with something you can actually fail.
Concretely: *"After the next release, pull N days of hang events; ≥90% classify into a
named cause (not `other`/`unknown`), and the `generic-metadata` and `swiftui-update/*`
issues are distinct Sentry issues with independent event counts."* That is checkable and
can come back red.

---

## Architectural Assessment

The decomposition — pure classifier / generic Sentry plumbing / call-site wiring / tests
— is the right one, and cleanly done. The classifier is a free function over strings with
no AppKit or SDK dependency, which is why it can be replayed offline over 875 stacks and
tested in `c11LogicTests`. That is the correct shape, and the offline replay is a genuinely
good validation technique that I'd want to see used again.

Two design decisions deserve more scrutiny than the plan gives them.

**Classify-then-fingerprint vs. fingerprint-on-frames.** The plan defends coarseness well
(top-5-frame fingerprint → 645 groups, 607 singletons; classifier → 13). I agree with the
choice. But the argument as stated is a false binary — those are the two endpoints of a
spectrum, and the interesting middle was never explored. A fingerprint of
`[cause, phase, culprit]` would have produced something like 172 named-culprit groups
plus a tail, which is more groups than 13 but each one *actionable by symbol*. The plan
puts `culprit` in a tag instead, which is defensible (it stays facetable without splitting
the issue) but means the highest-signal field — the deepest c11-owned frame, 114 distinct
values — never drives grouping. Worth stating explicitly why 13 buckets with a facetable
culprit beats ~30 buckets keyed on the top few culprits. I lean toward the plan's choice,
but it should be a stated trade, not an implied one.

**Fingerprint strings are now a permanent, unversioned schema — and the plan never says
so.** This is the architectural gap that will bite. `["main-thread-hang", cause, phase]`
is the grouping key forever. Consequences nobody has written down:

- Renaming a cause (`swiftui-update` → anything) orphans its Sentry issue and resets its
  trend to zero.
- **Adding a phase rule silently migrates existing traffic.** Today a stack matching no
  `phaseRule` groups as `["main-thread-hang", "swiftui-update"]`. Add a rule that matches
  it and it becomes `[..., "swiftui-update", "new-phase"]` — a brand-new issue, with the
  old one's history stranded. Since `phaseRules` is explicitly a most-specific-first list
  that invites extension, this *will* happen, and it directly breaks the amended
  acceptance criterion, which is entirely about trends being readable over time.
- Reordering `causeRules` reclassifies retroactively-similar traffic.

The mitigation is cheap and should be in the change: a comment above `causeRules` and
`phaseRules` stating that these strings are a wire format, that adding a phase splits an
existing issue, and that Sentry issue merging is the migration tool. Optionally a schema
version in the fingerprint (`main-thread-hang.v1`) so a deliberate taxonomy revision is a
clean cutover rather than a silent scramble.

**One thing the implementation gets right that the plan doesn't take credit for:**
`causeWindow = 16` and `moduleWindow = 8` both sit inside the `prefix(24)` frames actually
shipped in the event context. An operator reading the issue can verify the classification
from what's on screen. That's a real property and it should be written down before someone
"optimizes" the context to 10 frames and quietly makes the classification unauditable.
The exception: `culprit` scans all 96 captured frames, so `hang.culprit` can name a symbol
that appears nowhere in the visible stack. That's a small usability trap — either bound
`culprit` to the same 24, or ship enough frames to cover it.

---

## Is This the Move?

Mostly yes. Fixing observability before chasing a phantom is the right instinct, and the
"instrument is broken" finding is exactly the kind of thing that pays for itself many
times over.

Where I'd push back on prioritization:

**The evidence conflict with C11-191 is not addressed, and it should have stopped the
author.** C11-191's plan reports 9,433 local captures wedged on `__ulock_wait2`, 9,413 of
them with `GhosttyNSView.attachSurface` at frame 1 — a disassembly-proven main-thread
deadlock on a full ghostty renderer mailbox, one episode running **13h58m**. C11-192's
Sentry classification puts `lock-wait` at **10 events, 1.1%**. Those two readings of the
same watchdog cannot both be describing the same population.

Possible reconciliations, all consequential:
- The 816-event user is one long non-lock episode and swamps everything (in which case
  the table is an artifact and needs recomputing by episode).
- The deadlock episode never reported to Sentry (never recovered → maybe never flushed →
  the *worst* hangs are systematically invisible to Sentry, which would be a finding
  bigger than either ticket).
- The classifier mis-buckets `attachSurface`/`__ulock_wait2` stacks. Reading the rules,
  it shouldn't — `"ulock_wait"` is a `lock-wait` needle and `lock-wait` outranks the
  SwiftUI module check — but it's untested against a real C11-191 stack.

The last one is trivially fixable and should be a hard requirement: **add a test fixture
built from a verbatim C11-191 `attachSurface + 372` capture and assert it classifies as
`lock-wait`.** The operator has 151 MB of `~/Library/Logs/c11/hang.log`; the fixture costs
minutes. If the two tickets' dominant causes don't line up under the new classifier, the
classifier is not ready to be the thing future prioritization runs on. That is the single
most load-bearing test missing from this change.

**The corpus is the wrong unit, and the plan knows enough to have caught it.** #401
(merged, `42ce4c919`) added a per-episode Sentry throttle — at most one event per hang
episode. The 875 events predate it and are dominated by 5-second recaptures of long
episodes. So the percentages measure *seconds spent wedged, sampled, weighted by one
machine*, not *how often each cause fires*. A single 14-hour SwiftUI-graph beachball on
one user's Mac would produce ~10,000 recaptures and single-handedly manufacture the
"63.9%" headline. The plan states the 816/875 fact and then reasons from the uncorrected
table anyway. Recomputing per-episode (dedupe by user + episode, or drop
`recapture == true`) is a few minutes of work over a corpus already in hand, and it may
reorder the follow-up backlog entirely. Until that's done, the follow-up section is a
prioritization built on a duration-weighted sample.

**Number discipline slipped.** The share of generic-metadata events is given as **50
(5.7%)** in the table, **24 (2.7%)** two lines later under a stricter definition, and
**58** in the commit message for `93e655929`. Three numbers for one quantity, in one
change. The 50-vs-24 gap is explainable (classifier bucket vs. literal symbol presence)
and the plan does explain it; the 58 matches neither and is now in the permanent git
record. When the entire justification for amending acceptance is "the premise does not
hold, here are the counts," the counts have to be exact and consistent everywhere they
appear.

---

## Key Strengths

- **The root-cause finding is first-rate.** "Sentry fingerprints message events on the
  capturing thread's stack; our capturing thread is always the watchdog; therefore every
  hang is one issue titled after the most recent event" is a complete, mechanistic,
  verified explanation ("every event's `current: true` thread is the watchdog"). It
  explains the symptom, the misattribution, and why the parent ticket was filed against a
  Button that doesn't exist. This is what a diagnosis should look like.

- **Willingness to invalidate the assigned premise.** The path of least resistance was to
  wrap a `Button` body in `AnyView`, claim the acceptance, and move on — and it would
  have been unfalsifiable, since the hang was never reproducible on demand. Refusing that
  is the highest-value judgment call in the document, and it deserves to be said plainly.

- **The 645-groups-vs-13 argument.** Empirically grounded, computed over the real corpus,
  and it forecloses the obvious "just fingerprint the top frames" objection before anyone
  raises it. Exactly the right way to defend a coarse design.

- **Pure-function decomposition.** The classifier has no SDK or AppKit dependency, which
  is what makes both the offline 875-stack replay and the `c11LogicTests` membership
  possible. It also keeps the work off the fast path in a meaningful way: classification
  is bounded string work over ≤96 frames on the watchdog thread, not main.

- **Parser realism.** Keying on the `0x` load address rather than whitespace, because
  image names contain spaces (`c11 DEV`, and the tagged builds produce `c11 DEV <tag>`),
  is the kind of detail that only comes from having actually run the thing over real
  input. Same for stripping the `+ <offset>` suffix, which would otherwise churn the
  grouping key on every build.

- **Tag-length handling.** The 190-char cap in `SentryHelper` correctly anticipates Swift
  mangled names blowing past Sentry's tag-value limit and the tag being dropped rather
  than truncated. Good catch — though it's in the code and *not* in the plan, which is
  part of the broader plan/implementation drift below.

---

## Weaknesses and Gaps

Ordered by how much damage each will do.

1. **`attachStacktrace = true` is untouched, so the misleading stack still renders.** The
   root cause of the misattribution was *what Sentry displays*, and that is unchanged.
   New issue titles will name the cause; the stack panel will still show the watchdog
   loop. Downstream: the next audit reads the watchdog stack again and files C11-2xx
   against another phantom. `Sources/AppDelegate.swift:2623` already has `beforeSend` —
   use it to replace or strip the thread stack on `category: "hang"` events, or synthesize
   frames from the captured main stack. Cheapest high-value item in the change.

2. **The distribution table is computed over recaptures, pre-#401.** Detailed above. The
   follow-up backlog, the "64% is SwiftUI graph work" headline, and the implicit
   deprioritization of `lock-wait` all rest on it. Recompute per-episode before anyone
   plans off these numbers.

3. **Unreconciled conflict with C11-191's evidence, and no test fixture from it.** A
   classifier whose output contradicts the one hang we have proven to the instruction
   level is not yet trustworthy as a prioritization input. Add the fixture; assert
   `lock-wait`.

4. **No end-to-end verification against real Sentry.** Everything is offline replay plus
   unit tests. Nothing confirms Sentry honors `scope.setFingerprint` for a message event
   when `attachStacktrace` is on, that the tags survive ingestion, or that the new issues
   actually separate. The repo's own rule — smoke-launch the real artifact, "green tests ≠
   working product" — applies squarely. A tagged build plus one forced hang plus one look
   at the Sentry UI closes it, and it is the difference between "should group" and
   "groups."

5. **Fingerprint schema has no stability contract.** Adding a phase rule silently splits
   an existing issue and strands its trend — while the amended acceptance is *entirely*
   about trends. Document it; consider a version segment.

6. **The verification is not reproducible by anyone else.** No corpus path, no replay
   script, no `swiftc` invocation, no Sentry query committed. "The new code compiled
   standalone and run over all 875 production stacks produces 13 issues from 1" is a
   claim no reviewer can check and no future agent can re-run against a new corpus.
   Committing the replay harness (`scripts/` or `tools/`) plus a redacted fixture set
   turns a one-time assertion into a reusable regression gate. Given that the classifier's
   whole value is its behavior on real-world input, this is the test that actually matters.

7. **Plan/implementation drift.** The plan names `MainThreadHangSignatureTests` "in
   `c11LogicTests`"; the code appends that class to `c11Tests/MainThreadHangDetectorTests.swift`
   (on disk under `c11Tests/`, and correctly a member of the `c11LogicTests` target — the
   same on-disk/target split that caused C11-105's socket-unlink incident). Substantively
   fine, but the plan's four "Work" bullets also omit the 190-char tag cap and the
   `hang.recapture` tag that the code adds. Small drift, and evidence the document was
   written from memory rather than from the diff.

8. **`other` will become the second-largest issue and is unactionable.** 15.2% of events
   land in a bucket named `other`, with no phase and no refinement path. The plan doesn't
   say what happens to it. Either state that `other` is a known dumping ground to be
   triaged later, or add one more discriminator so it isn't the thing everyone learns to
   ignore.

9. **`runloop-idle` reports events for a thread that is idle.** The plan flags "decide
   whether that should report at all" and then ships it reporting. Ten events is
   negligible now, but under the #401 per-episode budget these consume the same quota as
   real wedges. Decide in this change.

10. **Follow-ups are prose, not tickets.** Three real findings — including a 604-second
    synchronous XPC wedge — exist only as bullets at the bottom of a plan file. File them.

11. **Branch and ticket names no longer describe the work.** `c11-192-button-metadata`
    for a change containing zero buttons and no metadata fix. Cosmetic, but it's the
    string future searches will hit.

---

## Alternatives Considered

**A. Ship nothing; just fix the Sentry SDK config.** Set `attachStacktrace = false` for
hang captures, or synthesize the real frames, and let Sentry group naturally on the
*correct* stack. Simpler, no new taxonomy, no permanent fingerprint schema to maintain.
Rejected implicitly — and correctly: the plan's own data shows natural grouping on real
frames gives 645 groups / 607 singletons, which is unusable. But the *stack-display* half
of this alternative is still needed and is exactly gap #1. The right answer is
"classifier **and** honest stack," not "classifier instead of honest stack."

**B. Fingerprint on `[cause, phase, culprit]`.** More groups, each named by a c11 symbol,
each directly actionable. Rejected in favor of culprit-as-tag. Reasonable — 114 distinct
culprits over 172 reports means most culprit groups would be singletons, reproducing the
problem at smaller scale. But the plan should say this out loud rather than leaving the
reader to infer it.

**C. Server-side grouping rules in Sentry (fingerprint rules / stack-trace rules).** Zero
client code, changes applied retroactively to existing events, tunable without a release.
Genuinely attractive here — the classification is a pure function of a text stack, which
is precisely what Sentry's server-side fingerprint rules operate on. The client-side
choice is still probably right (it's versioned with the binary, testable in CI, and works
on `extra.stack` which server rules can't reach as easily), but this alternative isn't
mentioned at all, and "changes take effect without waiting for a release and apply to
history" is a real advantage that was silently forgone.

**D. Do the C11-191 fix first and re-measure.** If `attachSurface` is deadlocking main for
14 hours at a stretch, fixing it removes the largest source of recapture volume and the
remaining Sentry distribution becomes far more legible. There's a defensible sequencing
argument that C11-191 lands first and C11-192's classifier is calibrated against the
post-fix population. The plan doesn't consider ordering against its sibling at all. I
don't think it changes the answer — the classifier is useful either way and the tickets
are independent — but the two plans were clearly written without reading each other, and
that's visible in the unreconciled `lock-wait` numbers.

---

## Readiness Verdict

**Needs revision.** The code is good and PR #402 is close. The blockers are small,
concrete, and mostly about evidence and durability rather than implementation.

Required before merge:

1. Add a `lock-wait` test fixture from a verbatim C11-191 `attachSurface + 372` /
   `__ulock_wait2` capture out of the operator's `hang.log`; assert the classification.
   If it doesn't come out `lock-wait`, that's a bug, not a fixture problem.
2. Recompute the cause distribution **per episode** (dedupe by user/episode, or exclude
   `recapture == true`) and correct the table. Update the follow-up ordering to whatever
   the corrected numbers say.
3. Reconcile the three counts (50 / 24 / 58) and correct the commit message or add an
   amending commit that states the right figure.
4. Add a fingerprint-stability note in the source above `causeRules`/`phaseRules`: these
   strings are a wire format; adding a phase splits an existing issue.
5. Real-artifact verification — tagged build, force a hang, confirm in the Sentry UI that
   the event carries the explicit fingerprint, that all four tags survive ingestion, and
   that a second hang with a different cause lands in a *different* issue. Screenshot it.

Strongly recommended, same change or an immediate follow-up:

6. Use the existing `beforeSend` at `Sources/AppDelegate.swift:2623` to stop shipping the
   watchdog's stack as the event's displayed stack for `category: "hang"`.
7. Commit the offline replay harness so the 875-stack verification is re-runnable.
8. File the follow-ups as real Lattice tickets (XPC sync wait, `hosting-begin-transaction`
   vs `hosting-layout`, `runloop-idle`), and file the "is generic-metadata real" ticket
   the plan promises.
9. Retitle C11-192 (or close-as-invalid and re-open under a new ID) so the board reflects
   what shipped.

Not blockers: branch name, plan/implementation drift, `other` bucket refinement.

---

## Questions for the Plan Author

1. **Are the 875 events deduplicated by episode?** #401 throttles to one event per
   episode, but this corpus predates it. If the 63.9% / 5.7% split is over raw recaptures
   with one user contributing 816, does the ranking survive a per-episode recount? Have
   you run that recount?

2. **How do you reconcile `lock-wait` at 1.1% here with C11-191's 9,413 captures wedged
   on `attachSurface` / `__ulock_wait2`?** Is the deadlock simply absent from Sentry
   (never recovered, never flushed), swamped by the 816-event user, or mis-bucketed?

3. **Has a real C11-191 stack been run through `describe()`?** Reading the rules it should
   land on `lock-wait`, but I don't see a fixture for it — and that's the one classification
   we can independently prove correct.

4. **Which number is right: 50, 24, or 58?** The commit message for `93e655929` says 58;
   the plan says 50 (classifier) and 24 (literal demangler symbols). Where does 58 come
   from?

5. **Why leave `attachStacktrace = true`?** Was swapping the displayed stack in `beforeSend`
   considered and rejected, or not considered? The new issue titles name the cause, but
   the stack panel will still show the watchdog — the exact thing that produced this
   ticket.

6. **Was server-side Sentry fingerprint/stack-trace rules considered?** It would apply
   retroactively to the existing 875 and be tunable without a release. What made
   client-side the better call?

7. **Where does the 875-event corpus live, and is the replay reproducible?** Can a future
   agent re-run the classifier over a fresh 30-day pull, or does that mean rebuilding the
   whole pipeline from scratch?

8. **What's the fingerprint's stability contract?** When someone adds a seventh `phaseRule`
   next month, events that grouped as `swiftui-update` start grouping as
   `swiftui-update/new-phase` — new issue, orphaned trend. Is that acceptable, or should
   the fingerprint carry a version segment?

9. **What happens to `other` (15.2%)?** It'll be the second-largest issue on the project
   and carries no actionable signal. Triage plan, or accept it as a dumping ground?

10. **Should `runloop-idle` report at all?** The plan raises the question; the code ships
    it reporting. Under the #401 budget these consume the same quota as real wedges.

11. **Has `hang.culprit` been checked against Sentry's tag-value rules end to end?** The
    190-char cap is in, but mangled Swift symbols can contain characters Sentry treats
    specially, and a rejected tag fails silently. Confirmed on a real ingested event?

12. **`culprit` scans all 96 frames but only 24 ship in the context.** How does an operator
    verify a `hang.culprit` naming a frame they can't see in the event?

13. **What's the concrete pass/fail for the amended acceptance?** "Groups by cause and has
    a trend" can't come back red. What observation window, what threshold, who checks?

14. **Should the three follow-ups be filed now?** The 604-second XPC wedge in particular
    sounds more severe than the ticket this plan is attached to, and it currently exists
    only as a bullet in a plan file.

15. **Should C11-192 be retitled or closed-as-invalid?** Its current title describes a bug
    the plan argues does not exist, and the branch name (`c11-192-button-metadata`)
    compounds it.

16. **Was this document written before or after the implementation?** It reads as
    retrospective (past-tense verification, PR link at the bottom, code containing items
    the "Work" section omits). If the review process expects a pre-implementation plan,
    that's worth naming explicitly rather than letting the two blur — a plan and a PR
    description have different jobs, and this document is currently doing the second while
    filed as the first.
