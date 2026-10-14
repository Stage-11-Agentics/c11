### Executive Summary

**Do not implement this as C11-192 yet.** The plan makes a credible case that the ticket's original aggregate-Sentry diagnosis is unsound, but it silently converts a targeted performance fix into a telemetry regrouping project. That may be the right next project; it is not an executable plan for the ticket's stated acceptance. Most importantly, it removes the required before/after Time Profiler proof without either supplying the required reproduction/capture protocol or recording an authorized re-scope.

The central correction is also only as trustworthy as an offline classification which the plan does not make reproducible in the repository. An implementer has no exact signature grammar, cause/phase precedence table, Sentry event contract, or live-validation route. The likely result is a PR that compiles and has parser tests but changes production grouping in an unmeasured, difficult-to-reverse way.

### How Plans Like This Fail

- An issue title is correctly challenged, then a convenient instrumentation fix is landed under the original performance ticket. The actual generic-metadata wedge is neither reproduced nor fixed, and the replacement work appears complete because the acceptance criteria were rewritten in the plan rather than approved in the ticket.
- Backtrace-symbol text is treated as a stable API. It varies with build flavor, architecture, OS symbolication, offsets, stripping, and frames missing from a partial cross-thread unwind. A classifier tuned to 0.58.0+116 can quietly route future reports to `other` or the wrong cause.
- “13 groups” is asserted from a one-off historical analysis, but the production payload/fingerprint differs from the analysis. Sentry can then create unintended issues, merge unrelated reports, or reject/truncate high-cardinality tags without any local test noticing.
- A hot diagnostic path grows parsing, string allocation, and Sentry-scope work precisely when the process is degraded. The plan does not establish a bounded cost, nor what happens when a capture is malformed or symbolication fails.

### Assumption Audit

| Assumption | Load-bearing? | Concern |
|---|---:|---|
| The 875-event offline corpus is complete, correctly attributed, and representative. | Yes | It is not committed or otherwise made reproducible; the claimed 13-group result cannot be independently rerun by the implementer or reviewer. |
| `current: true` reliably identifies the watchdog rather than the sampled main thread. | Yes | Plausible, but the plan needs one preserved/redacted event fixture demonstrating the relevant Sentry thread fields and the exact extraction rule. |
| `backtrace_symbols` has enough stable c11/SwiftUI text to classify release builds. | Yes | The sibling ticket explicitly demonstrates unreliable nearest-exported symbol names. This plan must define confidence/fallback behavior, not treat every token as authoritative. |
| Coarse fingerprinting by cause is the desired Sentry product behavior. | Yes | The plan says “13” but never defines the fingerprint tuple. Cause alone, cause+phase, and cause+culprit yield materially different issue counts and alerting behavior. |
| `hang.culprit` / `hang.top_symbol` are safe Sentry tags. | Yes | Tags must be bounded, normalized, and privacy-reviewed. Arbitrary symbol strings can be high-cardinality and can contain paths, module/build details, or user-controlled names. |
| One outbound event per episode still provides enough data to classify a moving wedge. | Yes | The plan acknowledges a sample is moving, but provides no confidence marker or rule for a later persist capture that has a more useful stack. |
| Extending every Sentry helper with `fingerprint` and `tags` has no collateral semantics. | No, but risky | This broadens a shared telemetry API without defining validation, reserved-key handling, precedence against existing scope data, or call-site compatibility. |

### Blind Spots

1. There is no exact `MainThreadHangSignature` contract: inputs, normalized frame representation, output enum cases, phase values, culprit selection, unknown/ambiguous state, and the precedence table are all absent. “Every cause rule” cannot be implemented from this plan because the rules are never listed.
2. There is no fixture strategy. “Verbatim frames from real reports” cannot be committed raw without deciding redaction and provenance, and the plan does not say where the fixture lives or how the corpus-level 13-group assertion runs in CI.
3. There is no Sentry payload contract. Specify exact message, fingerprint array, tag keys/values, context fields, and which values are omitted/truncated. The current helper uses a per-capture scope; the plan must name the Sentry SDK API and prove the fingerprint/tags attach only to this event.
4. There is no failure behavior for empty frames, failed `thread_suspend`, raw-address-only frames, an unknown OS symbol, or a stack with contradictory signals. These must route to a stable `unknown` (or intentionally not report), never a newly minted fingerprint per raw frame.
5. There is no rollout/rollback or success observation. CI cannot prove Sentry grouping. Define a tagged-build/local fixture harness that prints the payload, a staging/production observation window, the owner who checks the resulting issues, and a rollback condition if cardinality or privacy is wrong.
6. The original user-visible failure remains unaddressed. If generic metadata is only 24 events, the plan should identify whether those 24 are distinct episodes/users and create a traceable follow-up—not merely declare it someone else's future work.

### Challenged Decisions

**Replacing C11-192 instead of splitting it.** The evidence supports rejecting the original diagnosis, but changing the acceptance to “group by cause” requires ticket-owner approval. Either (a) close/re-scope C11-192 explicitly and create a new observability ticket, or (b) keep C11-192 focused on a demonstrably reproducible generic-metadata stall. A branch named `c11-192-button-metadata` especially makes the proposed work misleading.

**Using tags for per-report detail.** Sentry tags are indexed dimensions, not an unbounded evidence store. Put bounded taxonomy values in tags (`hang.cause`, perhaps `hang.phase`); keep normalized, length-limited evidence in context. Do not emit `top_symbol` or a free-form culprit as a tag until its finite vocabulary and data classification are approved.

**Classifier as the grouping key.** Coarse grouping is sensible, but only if the stable classifier version is included in the fingerprint or event context. Otherwise changing a rule silently changes the meaning of an existing issue trend. The plan needs an explicit versioned mapping and a compatibility decision for classifier revisions.

**Standalone `swiftc` as evidence.** That does not validate target membership, Sentry SDK integration, or `c11LogicTests`. The stated local testing constraint may defer `xcodebuild test` to CI, but the plan must still name the CI job and require it to run the new logic tests; compilation alone is insufficient.

### Hindsight Preview

Six weeks after release, the likely regret is: “we reported a reduction in generic-metadata hangs, but we actually changed grouping.” Prevent that by recording pre-release baselines by normalized cause, then comparing comparable release/install exposure and distinct users—not issue counts alone.

Early-warning metrics the plan should pre-register:

- percentage of events classified `unknown`/fallback, by app version and architecture;
- issue count and singleton rate per 100 hang reports after grouping;
- distinct `hang.culprit` values, with a hard ceiling and sampling/omission behavior;
- mismatch between local full-log classification and outbound event classification;
- time spent and allocations of signature construction on the watchdog thread.

### Reality Stress Test

1. **A macOS/Sentry SDK update changes symbol text.** Without an explicit unknown path and fixture matrix, reports fragment or misclassify just when a regression needs diagnosis.
2. **A single pathological user again dominates traffic.** Cause-level grouping can make that user's repeated symptom appear as a broad product issue. The plan needs episode/user-aware dashboards and a policy for repeated persistent hangs.
3. **C11-191 and a generic-metadata regression ship together.** The new classifier can separate reports only if phases and causes are deterministic; otherwise it creates a reassuring dashboard while neither root cause gets a reproduction or profiler trace.

### The Uncomfortable Truths

- The plan may be right that C11-31 is a bad Sentry grouping, but that does not prove there is no Button/view-tree defect. It proves only that the claimed aggregate count is invalid.
- “No specific expensive Button” is stronger than the supplied evidence warrants. A 24-event (or 50-event, depending on the stated metric) class can still be a severe, reproducible user failure.
- The amended acceptance is self-authored scope change. It cannot substitute for the ticket's existing acceptance, which requires a Time Profiler trace.
- A telemetry redesign that cannot be exercised against its real Sentry backend before broad release is an operational change, not a pure parser refactor. Treat it with corresponding rollout discipline.

### Hard Questions for the Plan Author

1. Who has approved replacing C11-192's view-tree/Time-Profiler acceptance with a Sentry regrouping objective? If nobody has, why is this not a new ticket plus an explicit correction/closure of C11-192?
2. What exact user interaction and app state reproduces the alleged generic-metadata layout stall, and what are the step-by-step Time Profiler capture settings, duration, symbol filter, and before/after pass criteria? If no reproduction exists, say so and remove any implication that the performance issue is resolved.
3. What is the complete, ordered classifier table—including regex/token rules, phase refinement, ambiguity resolution, and `unknown` behavior—and which fixture proves each row?
4. Where is the sanitized 0.58.0+116 corpus or a deterministic derived fixture, and how can CI reproduce the claim that it maps to exactly 13 stable groups?
5. What exact Sentry event fields will be emitted (message, fingerprint array, tags, context), how are lengths/cardinality bounded, and which values are prohibited from tags for privacy and indexing reasons?
6. Is `hang.culprit` a finite taxonomy or arbitrary symbol text? If arbitrary, why is it a tag rather than context, and what prevents thousands of indexed values after a build or OS update?
7. How does the classifier distinguish trustworthy module-level evidence from the known-unreliable c11 symbol attribution documented by C11-191?
8. How will an implementer verify event-scoped fingerprint/tag behavior without sending production telemetry, and what live release/install window determines success or rollback?
9. Does the one-event-per-episode budget intentionally discard a more diagnostic persist stack? If yes, what evidence says the first eligible sample is sufficient for cause/phase classification?
10. Which CI command/job runs `MainThreadHangSignatureTests`, and what artifact-level check proves the project target includes the new source/tests? “swiftc compiled” is not an answer.
