# C11-192 Evolutionary Review: Synthesis

Synthesis of three independent Evolutionary/Exploratory reviews of the C11-192 plan
(`.lattice/plans/task_01KZ733HRN64WS7YSVCTT6WWRP.md`, branch `c11-192-button-metadata`, PR #402).

Sources:
- `evolutionary-claude.md`
- `evolutionary-codex.md`
- `evolutionary-gemini.md`

---

## Executive Summary

1. **All three reviewers endorse the pivot.** The plan was filed as a fix for a specific
   SwiftUI generic-metadata stall, proved the premise wrong with data (the demangler
   stack is 2.7-5.7% of events; one user contributed 816 of 875), and built a hang
   classifier instead. Every reviewer calls this the more valuable outcome and none
   would undo it.

2. **All three say the plan under-claims what it built.** The framing they converge on:
   this is not a Sentry grouping fix, it is c11's first *semantic sensor* for
   main-thread wedges. Claude calls it "a symptom taxonomy for a native app," Codex
   calls it "a versioned diagnostic boundary," Gemini calls it "a client-side stack
   semantic analyzer." Same object, three names.

3. **The single most-agreed concrete gap: the classification never reaches the local
   hang log.** Claude, Gemini, and (by implication, via its replay-harness and
   raw-sample-retention arguments) Codex all land here. The classifier is a pure
   function currently wired to the narrowest possible input: one capture per episode,
   past 5000ms, budget-permitting, consent-permitting. Meanwhile the operator holds a
   151 MB untruncated locally-symbolicated hang log that C11-191 mined by hand. Running
   the same function into that log is roughly three lines and collapses the feedback
   loop from a release cycle to minutes.

4. **The most-agreed latent hazard: taxonomy rot with no version stamp.** The phase
   rules match Apple private-symbol fragments (`NSHostingViewC16beginTransaction`).
   When macOS rotates them, `phase` silently goes nil, the fingerprint changes, issue
   history forks, and the dashboard reads as "hangs stopped." Claude and Codex both
   demand a schema version in the fingerprint; Gemini raises the same fragility as a
   question about `backtrace_symbols` format drift.

5. **The sharpest divergence is process, not engineering.** Codex holds that a plan
   cannot unilaterally declare its own acceptance criteria unreachable and wants the
   ticket owner's decision recorded *before* implementation. Claude agrees the amendment
   is substantively right but wants it explicitly acknowledged as a precedent. Gemini
   does not raise it at all. This is the one item where a reviewer would block.

6. **Second divergence: how much context to attach.** Gemini wants workspace/pane/agent
   IDs on the event as tags. Codex wants a hard cardinality and privacy budget on tags,
   with anything unbounded pushed to context only. These are directly opposed and need
   an explicit call.

---

## 1. Consensus Direction

Evolution paths named by two or more models.

1. **Classify into the local log, not just the Sentry-bound capture** (Claude A +
   mutation 1; Gemini #1; Codex #6 keep-the-raw-sample and the replay harness). The
   local log is ungated, untruncated, and already exists on every machine. Header line
   becomes `cause=... phase=... culprit=...` and `grep` becomes triage.

2. **Version the taxonomy and treat rule changes as data migrations** (Claude D; Codex
   #3 and mutation 2). Fingerprint carries `v1`; a rule change becomes a deliberate
   visible fork rather than silent history mutation. Codex additionally wants
   `hang.signature_version` as a tag.

3. **Keep the fingerprint low-cardinality; push detail into tags/context** (Claude D+F;
   Codex #3). Fingerprint = version + cause + phase-or-none. `culprit` and `top_symbol`
   ride as tags/context, never as grouping keys, or a single new c11 symbol reshapes
   issue history.

4. **Build a reproducible replay corpus instead of a throwaway `swiftc` run** (Claude C;
   Codex #5 and mutation 1). The "13 issues from 1" verification is currently
   unreproducible by anyone else. Both want the 875 stacks sanitized, committed, and
   asserted against.

5. **Validate the actual Sentry envelope, not just the parser** (Claude G; Codex #6 and
   Q5). Nothing in the plan observes `scope.setFingerprint`, dotted tag keys, the
   190-char tag limit behavior, or the message-as-title rendering. Unit tests cover the
   part least likely to be wrong. Claude wants an induced hang on a tagged build; Codex
   wants a local test transport that captures the outbound envelope. Both work.

6. **Sensor eventually becomes actuator, but not in this PR** (Claude mutation 2; Gemini
   "proactive auto-recovery"; Gemini sequencing "defer"). Cause should eventually
   determine response: `runloop-idle` should perhaps not report at all, `lock-wait` past
   ~60s is a deadlock the app can name, `xpc-sync-wait` is "we are waiting on the
   system, not hung." Claude and Codex both explicitly want this deferred to C11-186.

7. **The one-user-816-events skew is a first-class finding, not a footnote** (all three,
   with three different responses: Claude wants per-user normalization baked into the
   Sentry-audit ticket template; Gemini wants client-side per-signature rate limiting;
   Codex wants it to define the "does not recur" measurement window).

8. **This is the missing input to C11-186** (Claude explicitly; Codex and Gemini imply
   it through recovery-policy discussion). "Make main-thread hangs survivable" has no
   policy until something can say what kind of hang this is.

---

## 2. Best Concrete Suggestions

Ranked by value per line of diff, merged across reviewers. Items 1-6 are small enough to
fold into the open PR.

1. **Move `describe()` from `reportTelemetry`'s Sentry branch up into `handleHang`, and
   write `cause=/phase=/culprit=` into the local hang-log header.** (Claude A, Gemini 1.)
   About three lines. Makes 151 MB of existing local corpus instantly queryable, gives
   the implementing agent an acceptance gate it can execute today, and works with
   telemetry consent off.

2. **Stamp the fingerprint `main-thread-hang.v1` (or `["c11-main-thread-hang","v1",
   cause, phase-or-none]`) and emit `hang.signature_version` as a tag.** (Claude D,
   Codex 2/3.) Note in the PR description that landing this *forks Sentry issue C11-31*:
   the old issue goes quiet and new ones appear, which will otherwise be misread as
   "hangs stopped."

3. **Commit a sanitized corpus fixture plus a replay test that asserts a distribution,
   not individual labels.** (Claude C, Codex 5.) Suggested assertions: zero
   frames-present stacks classify `unknown`; `swiftui-update` between 55% and 75%;
   fingerprint count between 8 and 20 (guards both collapse and singleton explosion);
   and the C11-191 `__ulock_wait2` / `attachSurface` stack classifies as `lock-wait`
   with `culprit` naming `attachSurface`. That last one is disassembly-verified ground
   truth and is the strongest available evidence the taxonomy works.

4. **Emit `hang.phase = "none"` explicitly rather than omitting the tag.** (Claude E.)
   The rate of `swiftui-update` with `phase = none` becomes a health metric for the
   classifier itself. A step change after a macOS release means Apple rotated the
   private symbols and the phase rules are dead. Same logic for `cause = other` (15.2%
   today) and `unknown`: those are confessed ignorance, and their trend tells you when
   to invest in more rules.

5. **Do not prefix-truncate the mangled culprit.** (Claude F.) `sentryTagValueLimit =
   190` applied to a mangled Swift symbol yields a string that will not demangle, on
   exactly the field that names c11's own code. Keep the full culprit in event context
   `data` alongside the truncated tag, or demangle client-side (`swift_demangle` via
   `@_silgen_name`) so the tag reads `c11.TerminalSurface.attachSurface(for:)`.

6. **Send `signature.label` and `culprit` to PostHog too.** (Claude H.) Two lines.
   `PostHogAnalytics.captureMainThreadHang(..., topFrame: stack.first ?? "")` still
   ships the raw leaf frame. After this change the two telemetry systems describe the
   same event in incompatible vocabularies, and the *ungated, higher-volume* one
   (PostHog has no per-episode gate and no budget cap) is the one still sending noise.

7. **Add a debug-only "Simulate main-thread hang (N seconds)" command** (Debug menu plus
   socket command so an agent can drive it). (Claude G/7.) Smoke gate becomes: tagged
   build, induce a 10s wedge, open Sentry, confirm the title names the cause and the
   tags are faceted. Not throwaway: it is the prerequisite for testing C11-186's
   survivability work and for any CI hang gate.

8. **Publish the release query recipe as part of the handoff.** (Codex mutation 3.)
   Issue counts and distinct users by `hang.cause`, `hang.phase`, app release, and
   signature version. The loop only closes if someone can answer "what should C11-193
   fix next?" without re-exporting 875 events.

9. **Specify `MainThreadHangSignature` as an API before implementation, not as a name.**
   (Codex 2/4.) Exact value fields, exhaustive cause list with precedence (what wins for
   mixed SwiftUI/IPC stacks, truncated stacks, `mach_msg`/runloop-idle), whether
   matching is leaf-first, first-matching-frame, or whole-stack, plus normalization
   rules: strip addresses/offsets/PID-dependent text, never include user paths, terminal
   text, or URLs.

10. **Add negative tests for the non-hang callers.** (Codex 4.) `SentryHelper`'s new
    optional `fingerprint:`/`tags:` must leave every existing caller's event shape
    byte-identical when omitted. Also cover telemetry-disabled, budget-denied, and
    `unknown`-classification paths so none of them emit a malformed empty fingerprint.

11. **Replace the amended acceptance criteria with gates the implementing agent can
    actually execute.** (Claude 9.) The current amendment is well-reasoned but
    substitutes an external, non-deterministic, release-cycle-long condition. Proposed
    merge gates: (a) replay corpus test green with asserted distribution; (b) tagged
    build plus induced hang produces a Sentry event whose title names the cause and
    whose tags are faceted, with a screenshot; (c) the local hang log for that induced
    hang carries `cause=` in its header. Keep "generic-metadata exists as its own issue
    with its own trend" as the *post-release* criterion, not the merge gate.

12. **Sweep every other non-main-thread Sentry capture site.** (Claude mutation 4.) The
    `attachStacktrace = true` plus fixed-shape-worker-thread collapse is a *class* bug,
    not a hang-specific one. Every `sentryCaptureWarning`/`sentryCaptureError` firing
    from a non-main, fixed-shape thread has the same defect. About an hour of work,
    likely re-partitions other issues that are currently lying about their volume.

13. **Fix the test file location/target mismatch.** (Claude, sequencing note.) The new
    tests live in `c11Tests/MainThreadHangDetectorTests.swift` on disk but are members
    of `c11LogicTests`. Functionally correct and it does get the fast CI gate, but this
    is precisely the mismatch that caused C11-105 (a test in `c11Tests/` belonging to
    `c11LogicTests` unlinked the production socket). Move the file or leave a comment.

14. **Add client-side per-signature deduplication.** (Gemini 2.) If the last N hangs
    share a signature, increment a local counter and send a summary rather than N full
    events. Directly addresses the 816-events-from-one-user quota burn. Note this is in
    tension with Codex Q7: dedup changes what "does not recur" means, so the counting
    rule has to be decided alongside it.

---

## 3. Wildest Mutations

Most creative and most ambitious ideas across the three, roughly by ascending risk.

1. **`c11 hang-report`: turn the local log into a triage command.** (Claude mutation 1.)
   Classifier plus 151 MB of local hang log equals a ranked table of what actually
   wedges this machine, computed in seconds, with no telemetry, no consent gate, no
   truncation, and no release cycle. Ship as a CLI subcommand or fold into `c11 health`.
   It inverts the economics of hang investigation: instead of waiting a release for
   seven users to hang, you interrogate a corpus you already own.

2. **Hang classification as a CI/perf gate.** (Claude mutation 3, Gemini "automated
   regression testing.") Combine the simulate hook with a scripted stress workspace
   (many tabs, heavy churn, the C11-191 scenario) on a tagged build and assert zero
   captures above threshold with the classifier running. Converts a production-only,
   seven-users-a-day signal into a pre-merge one. Gemini's version: assert "no SwiftUI
   layout hangs > 100ms" during UI/E2E runs, using the exact production classifier.

3. **Context-aware classification.** (Gemini "how it could be better," #3.) Combine the
   stack with app state at hang time: *which* XPC service, *which* workspace or pane was
   active, *which* agent was blasting output. Unlocks correlating agent behavior with
   specific stall signatures. Direct tension with Codex Q4 on tag cardinality and
   privacy; likely resolves as bounded context fields rather than faceted tags.

4. **Agent back-pressure over the socket.** (Gemini.) If the analyzer can classify a hang
   *while it is happening*, expose that state to agents running inside c11 via the
   socket. An agent flooding a terminal receives a `window.stalled` signal and throttles
   its own output. This is the most c11-native idea in the pack: it makes the operator's
   fleet self-regulating rather than merely observable. Gemini itself says defer it.

5. **Proactive auto-recovery per hang class.** (Gemini; matches Claude's mutation 2
   cause-to-response table.) For well-understood classes, the monitor triggers targeted
   recovery instead of watching it burn: re-evaluate the runloop, sever a stuck XPC
   connection, restart the wedged subsystem. That table *is* the C11-186 policy, and it
   is unwritable without C11-192.

6. **The "hang-to-ticket" pipeline.** (Gemini.) The classifier does not just fingerprint,
   it auto-generates a formatted Lattice/GitHub issue with the stack and hypothesized
   root cause for a newly seen signature, skipping the Sentry middleman entirely. Highest
   ambition, highest false-positive risk, but it is the logical endpoint of the triage
   flywheel.

7. **Extract the hang monitor as a public Swift package.** (Claude mutation 5.)
   `MainThreadHangMonitor` + `HangBacktrace.c` + `MainThreadHangSignature` is a
   self-contained answer to a problem every SwiftUI/AppKit app has and almost nobody
   solves well: cross-thread stack capture with `pthread_stack_frame_decode_np` for PAC
   stripping, allocation-free inside the suspend window, symbolication deferred until
   after resume, taxonomy on top. Near-zero marginal cost to publish, and per `CLAUDE.md`
   the upstream-cmux offer is the default for anything not c11-specific. This is about as
   not-c11-specific as code gets. Decide now while it is unentangled.

8. **Invert the ticket: fix how Sentry-derived tickets get written.** (Claude mutation 6.)
   93% of one issue's volume came from one user. That is a product finding, not a
   footnote. Every "N events" number in every Sentry-derived c11 ticket should read as
   "N events, possibly from one machine." Durable fix is a per-user normalization rule in
   the ticket template plus a `hang.session_id` tag so an episode's captures stay
   correlatable. Two tickets in a row (C11-191 and C11-192) have now been refuted by
   their own plans, which is a process signal, and skills outlast plans.

---

## 4. Flywheel Opportunities

1. **The triage flywheel** (all three, most fully articulated by Claude).
   Classifier names a cause → the cause gets its own issue with its own user count → a
   ticket targets the top cause → the fix ships → that cause's user count visibly drops
   *in its own issue* → confidence in the taxonomy rises → more triage gets delegated to
   it → the taxonomy earns more rules.

2. **Loop latency is the gating variable, and the local log is the accelerator.**
   (Claude, uniquely.) Through Sentry the loop is one release cycle plus enough users
   hanging to be statistically legible: weeks. Through the local hang log it is minutes,
   on one machine, today. This is the strongest single argument for suggestion 2.1, and
   it is also the cheapest item in the entire review pack.

3. **The taxonomy improvement loop.** (Claude Loop 2, Gemini's flywheel.) Every hang that
   gets root-caused teaches a new needle. C11-191's `__ulock_wait2` + `attachSurface` is
   the first. Each fix sharpens the classifier as a byproduct at zero marginal cost,
   which makes the next fix easier to find. Gemini adds the elegant corollary: as generic
   hangs get fixed, the remaining unclassified ones *stand out more clearly*, which
   itself drives rule refinement.

4. **Preconditions the flywheel needs to actually spin** (Codex, explicit): a stable
   signature schema, raw samples retained for audit, and the release query as part of the
   handoff. Without all three the loop looks like it is turning while the readings drift.
   Claude adds a fourth: a home for new needles plus a regression corpus to keep old ones
   honest.

5. **The credibility loop** (Claude Loop 3, weaker but real). A public hang-monitor
   package that other developers adopt sends back stack shapes from other apps, which
   enriches the taxonomy for free and makes c11 the reference implementation for a
   problem every native Mac developer has.

6. **The evidence-gate loop** (Codex). Trustworthy classification supplies the gate for a
   *future* generic-metadata ticket: first establish a stable `generic-metadata` trend,
   then reproduce that class locally, then use Time Profiler to target a view-tree change.
   The original C11-192 acceptance is not abandoned, it is deferred until it has evidence
   behind it. This is the cleanest reframing of the acceptance-criteria dispute.

---

## 5. Strategic Questions for the Plan Author

Deduplicated and merged. Items 1-3 are the ones a reviewer would block on.

**Governance and scope**

1. Has the C11-192 ticket owner explicitly approved replacing the mandated Time Profiler
   acceptance with a telemetry-classification outcome? Or should this become a new ticket
   while C11-192 retains its original performance scope? (Codex Q1, forcefully; Claude
   Q10 as a precedent question: changing a ticket's acceptance from inside its own plan
   is right here, but the next plan that wants to do it needs a standard to meet.)

2. What is the merge gate for this PR? As written the acceptance cannot be evaluated
   until a release ships and users hang. Is the team comfortable merging on unit tests
   alone, or should the induced-hang smoke be a blocker? Given that this PR's entire
   subject is telemetry that was silently wrong for months, shipping it without observing
   one real event is arguably the same mistake in a new costume. (Claude Q9, Codex Q5.)

3. Is C11-192 the sensor for C11-186? If yes, the cause taxonomy should be designed
   against C11-186's *response policy* (which causes are recoverable, which are
   reportable, which are ignorable) rather than against Sentry's grouping needs. Those
   are different requirements and should be reconciled before the taxonomy ossifies.
   (Claude Q2.)

**Taxonomy design**

4. What are the exact v1 cause/phase outputs and precedence rules, including `unknown`,
   truncated frames, and multiple simultaneously matching causes? Is matching leaf-first,
   first-matching-frame, or whole-stack? (Codex Q2.)

5. What canonicalization makes a fingerprint stable across ASLR, c11 release builds, and
   symbolication differences while still separating actionable causes? (Codex Q3.)

6. Who owns taxonomy rot? The phase rules match Apple private-symbol fragments. When
   macOS 27 lands and they stop matching, what notices? Is a `phase = none` rate an
   acceptable alarm, or does this need a periodic manual re-check? (Claude Q3, Gemini Q4
   on `backtrace_symbols` format drift across macOS versions and SDKs.)

7. Should the classifier run on every capture into the local log, or only on Sentry-bound
   ones? Was the Sentry-branch placement deliberate or incidental? (Claude Q1, Gemini Q1.)

**Payload, privacy, and cardinality**

8. Which fields are safe as Sentry tags under privacy and cardinality limits, and which
   must stay in bounded context only? (Codex Q4.) Directly related: can the currently
   active workspace ID / pane ID / agent identity be attached, and if so as tag or as
   context? (Gemini Q3.) These two questions pull in opposite directions and need one
   answer.

9. Are you willing to check in a redacted 875-stack corpus? The stacks contain module and
   symbol names but presumably nothing user-identifying. If not (privacy, size,
   provenance), what is the substitute regression gate for the classifier? (Claude Q4,
   Codex 5.)

**Measurement and interpretation**

10. The reported sample is systematically the *persist* capture roughly 7 seconds in, not
    the first (detection threshold 2000ms, Sentry threshold 5000ms, recapture interval
    5000ms). The taxonomy therefore measures what wedges *stay* wedged, not what wedges.
    Does that bias change how you read the 63.9%/5.7% table? Worth measuring
    first-capture versus persist-capture distributions once local-log classification
    makes it possible? (Claude Q5.)

11. What release/install-count comparison window defines "does not recur," given that
    event counts are budgeted and one user produced 816 of 875 reports? (Codex Q7.) And
    should client-side per-signature rate limiting be added to protect the budget, given
    it would also change what that window measures? (Gemini Q2.)

12. One user contributed 816 of 875 events. Is that user reachable? A single machine
    producing 93% of a signal is either a reproduction environment worth interviewing or
    a configuration worth understanding, and either is worth more than the aggregate.
    (Claude Q7.)

**Deferred but flagged**

13. The 96 XPC-wait events, blocking up to 604 seconds on LaunchServices/AppleEvents, are
    arguably the most alarming number in the plan and have no ticket. Ten minutes of a
    dead app is worse than any of the SwiftUI hangs. Deliberately deferred, or lost
    behind the bigger percentage? (Claude Q6.)

14. If a future generic-metadata group does exceed the action threshold, what exact
    workload, app state, and artifact location will make the Time Profiler comparison
    reproducible? (Codex Q6.) Worth writing down now while the reasoning is fresh, so the
    deferred acceptance is executable rather than aspirational.

15. Should hang telemetry be exposed over the c11 socket so agents can detect when they
    are overwhelming the UI? (Gemini Q5.) All three reviewers would defer the actuator
    work, but the socket surface is cheap to design for now and expensive to retrofit.

16. Should the hang monitor plus classifier be extracted and published (as a standalone
    Swift package, or offered to upstream cmux per `CLAUDE.md`'s default for
    non-c11-specific work)? Worth deciding now, while the code is fresh and unentangled,
    rather than after it grows c11-specific hooks. (Claude Q8.)

---

## Appendix: Where the Reviewers Disagree

1. **Ship shape.** Claude says the PR is open, do not re-split it: fold in the small
   items (local-log classification, corpus fixture, version stamp, culprit retention,
   PostHog parity) and file the smoke gate as a dated follow-up. Codex wants schema,
   precedence table, redaction policy, and the ticket-owner decision settled *before*
   code. Gemini says ship as planned and compound afterward.

2. **Tag richness.** Gemini wants more context on the event (workspace, pane, agent).
   Codex wants a strict cardinality and privacy budget with detail confined to context.
   Claude sits in between: full culprit in context, truncated in tag.

3. **Verification method.** Claude wants an induced hang on a real tagged build with a
   Sentry screenshot. Codex wants the outbound envelope captured through a local test
   transport. These are complementary, not exclusive, and doing both is not expensive.

4. **The `swiftc` standalone verification.** Codex objects that it validates nothing
   about Sentry SDK linkage, target membership, or the real call path, and should not be
   presented as project-level verification. Claude's objection is different: the work was
   careful but its output is unreproducible, and the same effort checked in becomes
   permanent. Both point at the same fix (commit the corpus, replay it in CI).
