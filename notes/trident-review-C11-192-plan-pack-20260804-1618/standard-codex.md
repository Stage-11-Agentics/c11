# C11-192 plan review — Codex

## Executive Summary

The investigation is strong enough to reject the ticket's original premise: the supplied Sentry issue is a heterogeneous bucket of main-thread hangs, not evidence that one `Button.body` or a generic-metadata tree caused 875 stalls. Replacing speculative SwiftUI surgery with cause-aware grouping is the right *product/telemetry* move.

It is not yet an executable implementation plan for C11-192 as currently scoped. The plan silently changes the ticket from "remove a proven metadata layout stall, demonstrated by Time Profiler" to "make future hang reports diagnostically separable." That may be the right change of course, but it needs an explicit ticket/acceptance amendment before an implementation agent can call the work complete. In particular, it neither gives a reproduction for the alleged metadata hang nor says how to acquire the required before/after Time Profiler trace; it declares that acceptance invalid instead.

**Verdict: needs revision, not rethinking.** Retain the corrected diagnosis and observability goal, then make the telemetry contract, Sentry grouping semantics, target membership, and release-validation path specific.

## The Plan's Intent vs. Its Execution

The original intent was to eliminate a ten-second user-visible wedge attributed to `swift_getTypeByMangledName`. The plan establishes that attribution was unsound: the watchdog's cross-thread main stack was placed in event context while Sentry grouped the event on the watchdog's own attached stack. Its 24/875 metadata-stack count, dominant single-user contribution, and absence of a c11-owned `Button` make view restructuring an unjustified fix.

The proposed work instead repairs triage. That is valuable and appropriately avoids cargo-cult `AnyView` or a broad `ContentView.swift` refactor. But grouping reports is a different deliverable from fixing the existing performance issue. The plan must explicitly state whether C11-192 is being retitled/re-scoped, or whether this is a prerequisite diagnostic ticket and C11-192 remains open for an independently reproduced generic-metadata stall. Without that decision, an agent can implement all four steps and still fail the ticket's stated Time Profiler acceptance.

## Architectural Assessment

Factoring a pure `MainThreadHangSignature` is the right seam: it makes the fragile `backtrace_symbols()` interpretation deterministic, keeps classifier work off the capture/suspend path, and supports fixture-backed logic tests. Explicit Sentry fingerprints are also the correct layer to repair event grouping; changing messages alone is not a reliable grouping strategy.

The plan needs the contract that turns those headings into code:

- Define the exact input grammar and normalization rules for a `backtrace_symbols()` line, including unsymbolicated addresses, image names with spaces, offsets, truncation, and non-c11 frames.
- Define the output model: the finite `cause` and `phase` enums, `culprit`'s optionality/value format, and the ordered precedence table. "SwiftUI graph work" and "host phase" are too broad for two implementers to make the same classifier.
- Define the exact fingerprint array, including a stable schema/version component. It should be based only on the bounded classifier dimensions (for example, `c11-main-thread-hang`, schema version, cause, phase), never a raw frame, address, or per-build symbol. The plan says top-five-frame grouping is too granular but does not say what will be sent instead.
- Define the tags' cardinality and sanitation policy. `hang.top_symbol` and an arbitrary `hang.culprit` can become high-cardinality indexed Sentry tags, contain paths/newlines, or vary with symbolication. Bound length, strip addresses/paths, use a sentinel for unknown, and prefer context rather than a tag for unbounded diagnostic detail.

This decomposition is stronger than the original view-tree framing because it respects what the watchdog can actually prove: one sampled program counter stack at a time, not elapsed time in an individual frame.

## Is This the Move?

Yes, provided the ticket is formally replanned. The immediate risk is recurrence of a blind telemetry bucket: after #401's budget gate, treating all reports as one issue throws away the scarce reports needed to decide what to fix next. A thirteen-cause taxonomy is a sensible coarse-grained first split.

The plan should not claim that CI alone validates the telemetry integration. `swiftc` proves neither Xcode target membership nor the Sentry SDK scope behavior, and parser unit tests cannot show that an outbound capture receives the intended fingerprint/tags. The local-testing policy can defer `xcodebuild test` to CI, but the plan still needs an executable integration seam/test or a release-staging inspection procedure that validates a captured event's title, fingerprint, tags, and `hang` context without using production users as the first test.

## Key Strengths

- It reverses a conclusion when the full event population disproves it. That is exactly the right response to sampled production telemetry.
- It distinguishes captured-stack attribution from Sentry's grouping stack, which explains both the misleading issue title and the mixed event population.
- It rejects a high-risk SwiftUI optimization without a owned culprit or reproducible profile. This protects the documented `TabItemView` typing-latency guard from unrelated churn.
- It deliberately chooses bounded coarse grouping over the attractive but operationally useless 645-group top-frame scheme.
- It preserves rich per-report diagnostics while making issue identity actionable, rather than confusing an incident duration with frame self time.

## Weaknesses and Gaps

1. **Acceptance is replaced, not implemented.** No reproduction instructions, test data, app launch procedure, Instruments target, interaction sequence, or Time Profiler capture/filter are supplied. The plan says why that is appropriate, but the existing acceptance still requires it.
2. **The implementation steps lack file- and API-level detail.** They name `MainThreadHangMonitor.swift` and `sentryCaptureWarning/Error`, but not the exact new API signatures, where the parser type lives, whether the main capture stack is retained in context, or the call-site message/fingerprint composition.
3. **Project/test-target work is unplanned.** Existing `MainThreadHangDetectorTests.swift` is in `c11Tests`, while the plan specifies new `c11LogicTests`. The agent needs explicit instructions to add the test file to the right Xcode target (and any shared source arrangement required by that target), with no accidental `pbxproj` membership omission.
4. **Classifier fixtures are not reproducible from the plan.** "Verbatim frames from real reports" needs a checked-in, redacted fixture set, the selected representative captures, and expected signatures. Otherwise the planned cause/precedence coverage is only asserted, not specified.
5. **Production success is underspecified.** "13 issues from 1" needs a defined Sentry query/window and an expected mapping. The future-release criterion needs a comparison population/time window and a statement that the metric is issue/user presence, not event count, as the plan correctly notes.
6. **Privacy and telemetry-budget consequences are absent.** Before forwarding symbol-derived fields as indexed tags, the plan needs a bounded field policy and confirmation that the event-budget behavior remains unchanged.

## Alternatives Considered

**Keep C11-192 as a performance fix.** First reproduce a generic-metadata layout stall locally, obtain a Time Profiler trace, identify an owned view subtree, and only then apply a narrowly measured extraction/erasure change. This satisfies the original ticket but is currently unsupported by the evidence.

**Split the work.** Create or retitle this ticket as hang-signature observability, and create a future generic-metadata performance ticket only once the new grouping demonstrates a meaningful trend. This is the cleanest option because it keeps acceptance criteria honest.

**Fingerprint on normalized top frames.** It offers more precise clusters but the plan's measured 645 groups/607 singletons demonstrates why it is inferior for an initial operational dashboard. Use a finite classifier fingerprint; retain normalized frames only in event context.

## Readiness Verdict

**Needs revision.** The plan is ready to guide implementation after it:

1. obtains owner approval to re-scope or split C11-192 and replaces the Time Profiler acceptance accordingly;
2. specifies the signature model, precedence table, fingerprint array, and tag/cardinality sanitation contract;
3. identifies exact source/test files and Xcode target membership;
4. supplies redacted fixtures plus expected classifications; and
5. adds a concrete CI/release-staging validation method for the actual Sentry scope output and a measurable post-release query.

If C11-192 must retain its current acceptance, this plan should be a prerequisite ticket rather than its implementation plan.

## Questions for the Plan Author

1. Has the ticket owner approved changing C11-192 from a performance fix to telemetry regrouping, or should this plan be split into a new diagnostic ticket?
2. What exact user flow/load reproduces the alleged generic-metadata layout hang, and who will capture the required before/after Time Profiler trace if the original acceptance remains?
3. What are the exact `MainThreadHangSignature` enums, parsing rules, and precedence ordering? Please include a compact decision table.
4. What exact Sentry fingerprint array will be set, and how will it be versioned so future classifier changes do not merge unlike signatures?
5. Which of `cause`, `phase`, `culprit`, and `top_symbol` are tags versus event-context fields? What are their maximum length, normalization, and unknown-value rules?
6. Are symbol names permitted telemetry data under the existing consent/privacy policy, especially if a frame embeds a local path or non-c11 image name?
7. What are the representative redacted `0.58.0+116` fixtures and expected signatures for each classifier rule, including malformed/unsymbolicated frames?
8. Will the new tests be added to `c11LogicTests` or the existing host-bound `c11Tests` target, and what exact project-file membership change is required?
9. How will CI or release staging assert that `scope.setFingerprint` and tags reach Sentry correctly, rather than only testing the pure parser?
10. What Sentry query, release window, and comparable-install criterion define success after rollout, and who will perform that check?
11. Does the outbound Sentry budget remain one event per hang episode after the refactor, and is the local full stack still retained while only the first 24 frames are sent?
