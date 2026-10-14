# Evolutionary Plan Review: c11-192-plan (Claude)

Reviewed 2026-08-04 16:18. Plan: `.lattice/plans/task_01KZ733HRN64WS7YSVCTT6WWRP.md`.
Branch `c11-192-button-metadata`, PR #402 (3 files, +394/-7).
Read alongside: sibling plan C11-191, `CLAUDE.md`, `Sources/MainThreadHangMonitor.swift`,
`Sources/SentryHelper.swift`, and the branch diff.

---

## Executive Summary

This plan is filed as a fix for a specific hang and is not one. It is something more
valuable: the first honest **sensor** c11 has ever had for main-thread wedges. The
ticket's premise was wrong (the demangler stack is 2.7% of the events, one user
contributed 93% of them), the plan proves it with data, and instead of fixing a
phantom it builds the instrument that would have prevented the phantom.

That reframing is correct and I would not undo it. But the plan under-claims and
under-builds what it just created. Three things stand out:

1. **The classifier is a pure function over stack text, and it is currently wired to
   the narrowest possible input.** `describe()` is called only inside the
   `shouldReportHangToSentry` branch: at most one capture per episode, only for
   episodes past 5000ms, only when the budget gate allows, only when telemetry consent
   is on. Every other capture, including the entire local hang log, stays unclassified.
   The operator's own machine holds 151 MB of untruncated, locally-symbolicated hang
   records (C11-191 mined it by hand to find a 13h58m deadlock). Running the same
   function over that log is a three-line change and it multiplies the plan's value.

2. **This is the missing input to C11-186.** "Make main-thread hangs survivable"
   cannot have a policy until something can say *what kind* of hang this is. A thread
   parked in `__ulock_wait2` for 14 hours is a deadlock and deserves a different
   response from a 6-second AttributeGraph pass. C11-192 builds the discriminator.
   Say so in the plan; it changes the ticket from "telemetry cleanup" to "the sensor
   half of the hang-survivability program."

3. **The fingerprint is now the durable identity of every hang trend, and it is
   derived from unstable Apple private symbols with no version stamp.** `phaseRules`
   matches fragments like `NSHostingViewC16beginTransaction`. Those rot on an OS
   update. When they rot, `phase` silently becomes nil, the fingerprint changes, the
   issue forks, and the trend history resets. You will read that as "the fix worked."
   This is the single highest-consequence latent hazard in the change.

The biggest opportunity: turn this from a Sentry grouping fix into **c11's hang triage
layer**, with the local log as the fast loop and Sentry as the fleet loop.

---

## What's Really Being Built

Not "better Sentry fingerprints." Three layered capabilities, none of them named in
the plan:

**A symptom taxonomy for a native app.** `MainThreadHangSignature` is a pure
`[String] -> (cause, phase, culprit)` function. It is the first piece of c11 that has
an opinion about what a stack *means*. Everything downstream, grouping, alerting,
recovery policy, CI gating, is a consumer of that opinion. The taxonomy is the asset;
the Sentry wiring is one consumer of it.

**A methodological correction with a blast radius wider than this ticket.** The real
finding is: *`attachStacktrace = true` plus a message event captured from a dedicated
worker thread destroys grouping, because Sentry fingerprints on the reporting thread's
stack, which is byte-identical every time.* That is not a hang-specific bug. It applies
to every `sentryCaptureWarning`/`sentryCaptureError` call site in c11 that fires from a
non-main, fixed-shape thread. Nobody has audited those. The plan fixes one instance of
a class.

**A governance precedent.** C11-192 and C11-191 both begin by refuting their own
ticket's stated reading, and both are right. Two for two. That is now evidence about a
process: **a ticket derived from a Sentry issue title is not evidence, it is a
hypothesis.** The durable output is a rule, and this plan is the second data point
supporting it.

---

## How It Could Be Better

Ordered by value-per-line-of-diff. All of these fit inside the existing PR except (G).

### A. Classify every capture, into the local log, not just the Sentry-gated one

Currently in `reportTelemetry`:

```swift
if shouldReportHangToSentry(gapMs: gapMs) {
    let signature = MainThreadHangSignature.describe(...)
```

Move `describe()` up into `handleHang`, and put the result in the local log header:

```
=== c11 hang.persist 2026-08-04T... stalledMs=10422 pid=1234 \
    cause=swiftui-update phase=hosting-layout culprit=$s3c11... ===
```

Cost: about three lines. Payoff:

- `grep 'cause=lock-wait' ~/Library/Logs/c11/hang.log | wc -l` becomes a real triage
  command on any machine, with **full untruncated frames** and no consent gate.
- The operator's existing 151 MB corpus becomes instantly queryable, which is a
  vastly better validation set than the 875 Sentry payloads (Sentry's payloads are
  truncated to 24 frames and symbolicated on-device by nearest exported symbol, which
  C11-191 showed is actively misleading for c11's own frames).
- It gives the implementing agent an acceptance gate it can actually execute today,
  which the amended acceptance criteria currently lack (see the sequencing section).

### B. The reported sample is systematically biased, and the plan should say so

Detection threshold is 2000ms; Sentry threshold is 5000ms; recapture interval is
5000ms. So the capture that reaches Sentry is usually **not** the first one, it is the
persist capture roughly 7 seconds into the wedge. (That is why the original issue title
reads "(persist)".) The taxonomy therefore measures *what wedges stay wedged*, not
*what wedges*. Those are different distributions: a fast AttributeGraph storm and a
permanent futex deadlock are wildly over/under-represented relative to each other.

This does not invalidate the classifier, but it changes what the numbers mean, and the
plan presents the 63.9%/5.7% table as if it described hangs generally. With (A) in
place you can measure the bias directly: classify first-capture and persist-capture
separately in the local log and compare. If they differ materially, that is itself a
finding worth a follow-up.

### C. Commit the 875-stack corpus as a fixture and assert the distribution

The plan's strongest verification, "compiled standalone with `swiftc` and run over all
875 production stacks, produces 13 issues from 1," is a **throwaway**. Nothing in the
repo can reproduce it. The next person who touches a needle re-derives it by hand or
does not check at all.

Check in a redacted corpus (`c11Tests/Fixtures/hang-stacks.jsonl`) and a replay test
that asserts a *distribution*, not individual labels:

- zero stacks with frames classify as `unknown`
- `swiftui-update` is between 55% and 75%
- `lock-wait` includes the C11-191 `__ulock_wait2` / `attachSurface` signature, with
  `culprit` naming `attachSurface`
- the corpus produces between 8 and 20 distinct fingerprints (guards both directions:
  collapse back to one, and explosion into singletons)

This is fully compliant with the repo's test-quality policy: real runtime data through
the real classifier, verifying observable behavior, not source text. It converts
taxonomy drift from a Sentry surprise into a red CI job. Highest-leverage single
addition in this review.

The C11-191 ground truth is the crown jewel here. That deadlock was found by
disassembly and manual grep. If the classifier labels it correctly and unaided, that is
the strongest possible evidence the taxonomy works, and it is a test you can write today.

### D. Version the fingerprint

```swift
var fingerprint: [String] {
    var parts = ["main-thread-hang.v1", cause]
```

The taxonomy *will* change: needles rot on OS updates, new causes get added, phase
rules get refined. Without a version, every such change silently mutates group identity.
You then cannot distinguish "we fixed the cause" from "we renamed the cause." With a
version, taxonomy changes are a deliberate, visible fork and the old issues stay
readable as history.

Related operational note that belongs in the PR description: **landing this forks
Sentry issue C11-31.** The old issue goes quiet and new ones appear. Anyone watching
the dashboard without that context will read it as "hangs stopped."

### E. Make the taxonomy self-monitoring

Emit `hang.phase = "none"` rather than omitting the tag when no phase rule matches.
Then the rate of `swiftui-update` with `phase = none` is a **health metric for the
classifier itself**. A step change in that rate after a macOS release means Apple
rotated the private symbols and the phase rules are dead. Without this, rot is silent
and looks like a distribution shift in the underlying problem.

Same idea applies to `cause = other` (15.2% today) and `unknown`. Those are not
failures, they are the classifier's confessed ignorance, and their trend is the signal
telling you when to invest in more rules.

### F. Do not truncate the one field that names your own code

`sentryTagValueLimit = 190` with `String(value.prefix(190))` is applied to
`hang.culprit`, a mangled Swift symbol. Mangled names for nested generic SwiftUI
closures routinely blow past 190 characters, and a prefix-truncated mangled name will
not demangle: you get a tag you cannot read, on exactly the field that points at c11's
own code.

Fix: keep the **full** culprit in the event context `data` dictionary (which is not
subject to the tag limit) alongside the truncated tag. The tag stays faceted and
searchable; the context stays demanglable. Better still, demangle client-side before
sending, so the tag reads `c11.TerminalSurface.attachSurface(for:)` instead of
`$s3c11...`. `swift_demangle` is reachable via `@_silgen_name`; if that feels too
sharp, at minimum preserve the full string in context.

### G. There is no proof any of this reaches Sentry (real-artifact gate)

Per `CLAUDE.md`: "Green tests are not a working product." Nothing in this plan
exercises the actual path. `scope.setFingerprint`, dotted tag keys (`hang.cause`),
the 190-char rejection behavior, whether the message-as-title actually renders: all of
it is asserted from reading the SDK, none of it observed. The unit tests cover the pure
classifier, which is the part least likely to be wrong.

Add a debug-only **"Simulate main-thread hang (N seconds)"** command (Debug menu plus a
socket command so an agent can drive it). Then the smoke gate is: tagged build, trigger
a 10s synthetic wedge, open Sentry, confirm the issue title names the cause and the
tags are present and faceted.

This hook is not throwaway. It is reusable infrastructure for C11-186 (you cannot test
hang survivability without inducing a hang), for every future hang ticket, and for
(H) below. Small build, compounding return.

### H. PostHog now disagrees with Sentry about what a hang is

`PostHogAnalytics.captureMainThreadHang(..., topFrame: stack.first ?? "")` still ships
the raw leaf frame, unparsed. After this change, two telemetry systems describe the
same event in two incompatible vocabularies, and the one that gets the *good*
vocabulary is the one with a 1-per-episode gate and a budget cap. PostHog has neither,
so it is the higher-volume, better-suited trend surface, and it is the one still
sending noise.

Send `signature.label` and `signature.culprit` to PostHog too. Two lines. It also means
you can build the per-cause trend chart without waiting on Sentry's grouping.

---

## Mutations and Wild Ideas

**1. `c11 hang-report`: turn the local log into a triage command.**
The classifier plus 151 MB of local hang log equals a ranked table of what actually
wedges this machine, computed in seconds, with no telemetry, no consent gate, no
truncation, and no release cycle. Ship it as a CLI subcommand or fold it into
`c11 health`. This is the fastest feedback loop available and it exists *today* on the
operator's machine. It also inverts the economics of hang investigation: instead of
waiting a release for seven users to hang, you interrogate a corpus you already own.

**2. Sensor becomes actuator.** Cause should determine response, not just grouping:

| cause | response |
|---|---|
| `runloop-idle` | do not report at all (the plan already flags this: 10 events of main parked at the top of the run loop while the heartbeat went unserviced, which is a monitor artifact, not a hang) |
| `lock-wait` persisting past ~60s | this is a deadlock, not slowness. The app knows. It can say so, offer recovery, or restart the wedged subsystem |
| `swiftui-update` | log, trend, do not interrupt the operator |
| `xpc-sync-wait` | the 96 events blocked up to **604 seconds** on LaunchServices/AppleEvents. Not c11's fault and not c11's fix, but c11 can absolutely tell the operator "we are waiting on the system, not hung" |

That table *is* the C11-186 policy, and it is unwritable without C11-192. Sequence the
two tickets explicitly.

**3. Move the signal left: hang classification as a CI/perf gate.**
Combine the simulate hook (G) with a scripted stress workspace (many tabs, heavy
churn, the C11-191 scenario) on a tagged build, and assert **zero captures above
threshold** with the classifier running. That converts a production-only, seven-users-a-
day signal into a pre-merge one. Given how many c11 tickets are typing-latency and
main-thread shaped, a hang gate in CI is worth more than most of the tests already there.

**4. Audit every non-main-thread Sentry capture site.** The `attachStacktrace`
collapse is a class bug. Sweep every `sentryCaptureWarning`/`sentryCaptureError` in the
tree, find the ones reported from a fixed-shape worker, and give each an explicit
fingerprint. About an hour of work, and it likely re-partitions other issues that are
currently lying about their volume in exactly the same way. Cheap, and it validates the
methodology on a second population.

**5. Extract it as a public Swift package.** `MainThreadHangMonitor` plus
`HangBacktrace.c` plus `MainThreadHangSignature` is a genuinely good, self-contained
answer to a problem every SwiftUI/AppKit app has and almost nobody solves well:
cross-thread stack capture with `pthread_stack_frame_decode_np` for PAC stripping,
allocation-free inside the suspend window, symbolication deferred until after resume,
plus a taxonomy on top. That is a real piece of engineering with near-zero marginal
cost to publish, and it is the kind of artifact that gets read. The immediate
beneficiary is upstream cmux, which per `CLAUDE.md` should be offered anything not
c11-specific, and this is about as not-c11-specific as code gets.

**6. Invert the ticket.** The plan quietly demonstrates that **93% of one issue's
volume came from one user**. That is not a footnote, it is a product finding: c11's
hang telemetry is dominated by whoever is having the worst week. Every "N events" number
in every Sentry-derived ticket on this project should be read as "N events, possibly
from one machine." The durable fix is not more classification, it is a per-user
normalization in how tickets get written. Consider a `hang.session_id` tag so an
episode's captures stay correlatable, and make "distinct users, not events" the
mandatory framing in the Sentry-audit ticket template.

---

## What It Unlocks

- **Honest "is it fixed?"** For the first time, per-cause user counts and trend lines
  exist. Today you cannot tell a fixed hang from a re-titled issue.
- **A prioritization instrument.** The plan already used it to prove generic-metadata
  is 5.7% (or 2.7% strictly). That single number retires the original ticket and
  probably retires the whole class of "restructure the view tree" work until the
  numbers say otherwise. Every future hang ticket now starts with a distribution.
- **Three follow-up tickets with evidence attached**, which the plan correctly
  enumerates: the 64% SwiftUI graph family (split 291 begin-transaction vs 179 layout,
  with C11-191 in that family), the 96-event XPC wedge class up to 604s (real, no
  ticket, arguably the most alarming number in the whole document), and runloop-idle.
- **A labeled corpus.** 875 classified stacks plus 151 MB of local log is a training
  and regression set for whatever the taxonomy becomes.
- **A reusable pattern.** Explicit fingerprint plus faceted tags plus a pure classifier
  is a template for any future telemetry that gets captured off the main thread.

---

## Sequencing and Compounding

The plan is a single PR containing all four work items and no feedback point before it
ships. The ideal ordering is different, and it matters because **the taxonomy cannot be
validated by the population it was derived from**:

1. **Classifier plus local-log classification.** Zero telemetry risk, no consent gate,
   immediately validated against the operator's own log and against C11-191's known
   answer. This is the learning step and it costs almost nothing.
2. **Corpus fixture plus distribution test.** Locks in what step 1 learned.
3. **Sentry fingerprint plus tags plus version stamp.** Now you are wiring something
   you have already seen work.
4. **Simulate-hang hook plus real-artifact smoke.** Proves the wire, and leaves behind
   reusable infrastructure.

The PR is already open, so do not re-split it. Fold **A, C, D, F, H** in now (they are
collectively small and all reduce future rework), and file **G** and mutation **1** as
immediate follow-ups with dates, not as "someday" bullets.

**Where the plan under-invests early, at future expense:** not committing the corpus.
Every subsequent taxonomy change will either re-derive 875 stacks by hand or, far more
likely, skip validation entirely. That is the expensive-rework seed.

**Where it over-invests:** the offline `swiftc` standalone verification. It is careful
work whose output is unreproducible. Same effort, checked in, becomes permanent.

**One executability note on the current branch:** the new tests live in
`c11Tests/MainThreadHangDetectorTests.swift` on disk but are members of the
`c11LogicTests` target (verified against `project.pbxproj`). That is functionally what
the plan claims and it does get the fast CI logic gate, but it is precisely the
disk-location/target-membership mismatch that caused C11-105 (a test living in
`c11Tests/` while belonging to `c11LogicTests` unlinked the production socket). Worth
either moving the file to match its target or leaving a comment, so the next person
does not have to re-derive the membership from the pbxproj the way I just did.

---

## The Flywheel

There is a real one here and the plan does not name it.

**Loop 1, the triage flywheel.** Classifier names a cause → cause gets its own issue
with its own user count → a ticket targets the top cause → the fix ships → that cause's
user count drops *in its own issue*, visibly → confidence in the taxonomy rises → more
triage gets delegated to it → the taxonomy earns more rules.

The gating variable is **loop latency**. Through Sentry the loop is one release cycle
plus enough users hanging to be statistically legible: weeks. Through the local hang
log (suggestion A plus mutation 1) it is minutes, on one machine, today. **Building
the local-log path is the accelerator for the entire flywheel**, and it is the cheapest
item in this review. That is the strongest argument for it.

**Loop 2, the taxonomy improvement loop.** Every hang that gets root-caused teaches a
new needle. C11-191's `__ulock_wait2` plus `attachSurface` is the first: a known,
disassembly-verified cause, already representable. Each fix makes the classifier
sharper as a byproduct, at zero marginal cost, which makes the next fix easier to find.
This loop only spins if there is a home for new needles and a regression corpus to keep
old ones honest, which is another argument for (C).

**Loop 3, the credibility loop (weaker, real).** A public hang-monitor package
(mutation 5) that other people use sends back stack shapes from other apps, which
enriches the taxonomy for free and makes c11 the reference implementation for a problem
every native Mac developer has.

---

## Concrete Suggestions

1. **Move `describe()` from `reportTelemetry`'s Sentry branch up into `handleHang`;
   write `cause=/phase=/culprit=` into the local log header line.** Three lines,
   largest value multiplier in the change.

2. **Commit `c11Tests/Fixtures/hang-stacks.jsonl` plus a distribution-assertion replay
   test.** Include the C11-191 `__ulock_wait2`/`attachSurface` stack as named ground
   truth. Assert: no `unknown` with frames, `swiftui-update` in 55-75%, fingerprint
   count in 8-20.

3. **Stamp the fingerprint `main-thread-hang.v1`.** Note in the PR description that
   landing this forks Sentry issue C11-31 and the old issue will go quiet.

4. **Emit `hang.phase = "none"` explicitly** so classifier rot after an OS update shows
   up as a metric rather than a silent regrouping.

5. **Keep the full mangled culprit in the event context** alongside the 190-char tag,
   or demangle client-side. A prefix-truncated mangled name is unreadable.

6. **Send `signature.label` and `culprit` to PostHog**, so the two telemetry systems
   agree and the ungated, higher-volume surface carries the good vocabulary.

7. **Add a debug-only "Simulate main-thread hang (N seconds)"** command (Debug menu
   plus socket command), and use it for a tagged-build real-artifact smoke: trigger,
   open Sentry, confirm title and tags. Reusable for C11-186 and every future hang
   ticket.

8. **Ship `c11 hang-report`** (or fold into `c11 health`): classify the local hang log,
   print a ranked cause table. Turns 151 MB of noise into a triage command and collapses
   flywheel latency from weeks to minutes.

9. **Replace the amended acceptance criteria with gates the implementing agent can
   actually execute.** The current amendment is well-argued (the Time Profiler trace
   genuinely cannot be produced, because the layout pass it names was never established
   as the cause) but it substitutes an external, non-deterministic, release-cycle-long
   condition. Better:
   - (a) replay corpus test green with asserted distribution
   - (b) tagged build plus induced hang produces a Sentry event whose title names the
     cause and whose `hang.cause` / `hang.phase` tags are present and faceted
     (screenshot the Sentry issue)
   - (c) the local hang log for that induced hang carries `cause=` in its header
   - (d) `generic-metadata` exists as its own issue with its own trend, as already
     proposed, kept as the *post-release* criterion rather than the merge gate

10. **Sweep every other non-main-thread Sentry capture site** for the same
    fixed-reporting-stack collapse. One hour, likely re-partitions other issues.

11. **Write the finding into the Sentry-audit ticket template**, not just this plan: a
    Sentry issue title is a hypothesis, not evidence; report distinct users, never
    event counts; check per-user concentration before writing "N events across M users"
    as if it were a distribution. Two tickets in a row have now been refuted by their
    own plans. That is a process signal, and skills outlast plans.

---

## Questions for the Plan Author

1. **Should the classifier run on every capture into the local log, or only on
   Sentry-bound ones?** I argue every capture, and that this is the change that makes
   the whole thing worth more than its Sentry fix. Is there a reason it was scoped to
   the Sentry branch beyond incidental placement?

2. **Is C11-192 the sensor for C11-186?** If yes, the cause taxonomy should be designed
   against C11-186's response policy (which causes are recoverable, which are
   reportable, which are ignorable) rather than against Sentry's grouping needs. Those
   are different requirements and they should be reconciled before the taxonomy
   ossifies.

3. **Who owns taxonomy rot?** The phase rules match Apple private-symbol fragments.
   When macOS 27 lands and they stop matching, what notices? Is `phase = none` rate an
   acceptable alarm, or does this need a periodic manual re-check?

4. **Are you willing to check in a redacted corpus?** The 875 stacks contain module and
   symbol names but presumably nothing user-identifying. If yes, (C) is straightforward.
   If not (privacy, size, provenance), what is the substitute regression gate for the
   classifier?

5. **The reported sample is systematically the persist capture around 7 seconds in, not
   the first.** Does that bias change how you read the 63.9%/5.7% table? Is it worth
   measuring first-capture versus persist-capture distributions once (A) makes it
   possible?

6. **The 96 XPC-wait events, blocking up to 604 seconds on LaunchServices/AppleEvents,
   are the most alarming number in the plan and have no ticket.** Ten minutes of a dead
   app is worse than any of the SwiftUI hangs. Is that deliberately deferred, or did it
   get lost behind the bigger percentage?

7. **One user contributed 816 of 875 events.** Is that user reachable? A single machine
   producing 93% of a signal is either a reproduction environment worth interviewing or
   a configuration worth understanding, and either is worth more than the aggregate.

8. **Should the hang monitor plus classifier be extracted and published?** Offering it
   to upstream cmux is the `CLAUDE.md` default for non-c11-specific work, and this
   qualifies. A standalone package is a larger move with real credibility upside.
   Worth a decision now, while the code is fresh and unentangled, rather than after it
   grows c11-specific hooks.

9. **What is the merge gate for this PR?** As written the acceptance criteria cannot be
   evaluated until a release ships and users hang. Is the team comfortable merging on
   unit tests alone, or should the induced-hang smoke (suggestion 7) be a blocker? Given
   this PR's whole subject is telemetry that was silently wrong for months, shipping it
   without observing one real event feels like the same mistake in a new costume.

10. **Does the amended acceptance need operator sign-off?** Changing a ticket's
    acceptance criteria from inside its own plan is the right call here and the
    reasoning is sound, but it is a precedent. Worth an explicit acknowledgment rather
    than an implicit one, so the next plan that wants to rewrite its acceptance has a
    standard to meet.
