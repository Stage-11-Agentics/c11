### Executive Summary

The plan has uncovered the more valuable problem: c11 currently has a hang detector but not a trustworthy hang-observability taxonomy. Splitting the existing catch-all Sentry issue into a small, stable set of cause/phase signatures would turn future hang work from stack-title archaeology into a prioritized, user-counted queue. That is a strong C11-192 outcome.

It is not yet an executable implementation plan for the stated ticket. It changes C11-192 from “remove a proven generic-metadata layout stall, evidenced by Time Profiler” to “make hang reports diagnosable,” without a decision record approving that scope/acceptance change. More importantly, it does not specify the signature grammar, Sentry payload contract, or a reproducible profiler procedure. An implementer could produce a plausible classifier and green parsing tests while still shipping unstable grouping or an unverified Sentry integration.

### What's Really Being Built

This is a versioned diagnostic boundary between an unsymbolicated sampled main-thread backtrace and a product decision. The useful artifact is not merely `MainThreadHangSignature`; it is a bounded taxonomy with stable grouping keys, searchable tags, and enough raw evidence to revise a mistaken classification later.

That boundary must be deliberately conservative. `backtrace_symbols()` is lossy and can vary with ASLR, binary version, symbol visibility, and framework spelling. The plan correctly rejects top-five-frame fingerprints, but “the classifier gives 13” is an observation from one data set, not a specified production contract.

### How It Could Be Better

1. Make the ticket choice explicit before implementation: either amend C11-192 in Lattice to telemetry diagnosis (and record that the Time Profiler acceptance is superseded), or retain the original performance scope and create this as a separate telemetry ticket. A plan cannot unilaterally declare its own acceptance unreachable.

2. Specify `MainThreadHangSignature` as an API, not a name. Define its value fields and exact outputs for every supported input: `cause`, optional `phase`, optional c11 `culprit`, normalized `topSymbol`, fingerprint array, display message, and an `unknown` fallback. State the normalization rules: strip addresses/offsets and PID-dependent text; preserve module plus normalized symbol; cap tag length/character set; and never include user paths, terminal text, URLs, or other potentially sensitive symbol payloads.

3. Separate coarse grouping from diagnosis. The Sentry fingerprint should be a schema-versioned, low-cardinality value such as `["c11-main-thread-hang", "v1", cause, phase-or-none]`. `culprit` and `top_symbol` belong in tags/context only. Otherwise a new c11 symbol or a minor classifier refinement silently reshapes issue history, defeating the stated goal.

4. Bound the taxonomy. List the 13 intended classes and their precedence, including what wins for mixed SwiftUI/IPC stacks, missing/truncated stacks, and `mach_msg`/runloop-idle. State whether the class is based on the first matching leaf, first matching frame, or whole-stack pattern. “Every cause rule and its precedence” is a test aspiration, not an implementation instruction until those rules exist in the plan.

5. Specify the Sentry seam precisely. `SentryHelper.swift` currently accepts only message/category/data/contextKey and sets no scope fingerprint or tags. The plan should name the changed signatures, say whether `tags` merge with or replace SDK scope tags, and require that absent optional arguments preserve every existing caller’s event shape. It should also name the expected Sentry SDK method and any thread-safety constraint, since `reportTelemetry` runs on the watchdog thread.

6. Keep the raw sample. The current `hang.stack` context already has the first 24 frames. Preserve it unchanged or document the new retention/redaction rule; structured signature fields must supplement it, not replace the only primary evidence used to revisit a misclassification.

### Mutations and Wild Ideas

- Build a local “hang report replay” tool/harness around the pure signature parser. Given a sanitized hang-log fixture, it can emit the same classifications, tag values, and proposed Sentry groups as production. This is both a regression oracle and a fast way to evolve taxonomy rules without another production incident.

- Treat taxonomy changes as data migrations. Emit `hang.signature_version`, keep v1 groups stable, and intentionally introduce v2 when a rule changes rather than silently moving historical reports. That makes cause trends interpretable across releases.

- Add a small release dashboard/query recipe to the plan handoff: issue counts and distinct users by `hang.cause`, `hang.phase`, app release, and signature version. The implementation becomes a closed loop only if someone can answer “what should C11-193 fix next?” without re-exporting 875 events.

### What It Unlocks

Once trustworthy, this lets c11 distinguish real rendering debt (C11-191-style AttributeGraph work), synchronous XPC waits, runtime metadata construction, file I/O, and pathological false-positive-ish runloop samples. That supports prioritizing by affected users and duration rather than whichever sample happened to be Sentry’s latest title.

It also supplies an evidence gate for a future generic-metadata ticket: first establish a stable `generic-metadata` trend, then reproduce that class locally and use Time Profiler to target a view-tree change. It does not itself prove that any Button or layout pass is healthy.

### Sequencing and Compounding

The implementation order should be:

1. Obtain the ticket-owner decision to amend/split scope and write the replacement acceptance criteria.
2. Define the v1 signature schema, exhaustive classifier table, normalization/redaction policy, and fixture provenance before code.
3. Implement the pure parser/classifier in `Sources/MainThreadHangMonitor.swift`, with fixtures representing each rule, precedence collision, malformed/truncated captures, a no-c11-frame stack, and release-symbol format variation.
4. Implement the `SentryHelper` optional fingerprint/tags API with backward-compatible defaults; test the observable event/scope mapping through an injectable capture seam or the SDK’s test transport, rather than only testing source-independent parser outputs.
5. Wire `reportTelemetry` to emit one bounded v1 fingerprint plus tags/context, preserving `stalled_ms`, `recapture`, and raw stack evidence. Confirm telemetry consent and the existing per-episode/budget gates remain unchanged.
6. Perform a tagged-build validation: induce or replay one classified hang, capture the outbound envelope through a local test transport/logging seam, and inspect that the issue key and tags are exactly the v1 contract. Then use the release dashboard/query recipe after deployment.

The original Time Profiler requirement needs an explicit branch in the plan. If it remains an acceptance criterion, define a reproducible workload and capture protocol: launch a tagged build with a clean workspace, create the named high-tab/high-metadata state (including exact counts and interaction), record a Time Profiler trace from before the triggering action through the stall, filter/call-tree-invert on `swift_getTypeByMangledName`, save the trace artifact, and state the threshold. If the diagnosis invalidates that work, mark it as a rejected acceptance criterion with the evidence and make it a separate follow-up only when generic-metadata grouping has enough users/trend. The current plan does neither.

### The Flywheel

The flywheel is: sampled stack -> stable signature -> Sentry distinct-user trend -> focused local reproduction/profile -> narrowly verified fix -> new release trend. Each completed cause becomes a regression fixture and improves confidence in the next classification. It only spins if the signature schema is stable, raw samples remain available for audits, and the release query is part of the handoff.

### Concrete Suggestions

1. Add a short “Files and symbols” section: `Sources/MainThreadHangMonitor.swift` (new pure signature type plus `reportTelemetry` wiring), `Sources/SentryHelper.swift` (optional `fingerprint` and `[String: String]` tags), and a new `c11Tests/MainThreadHangSignatureTests.swift` added to `c11LogicTests`. State that no `ContentView.swift`/Button restructuring is in scope.

2. Define a compact, stable payload contract, for example:

   - fingerprint: `c11-main-thread-hang`, `v1`, `<cause>`, `<phase-or-none>`;
   - tags: `hang.signature_version`, `hang.cause`, `hang.phase` when present, `hang.culprit` only when normalized and allowlisted, and `hang.top_symbol` only if bounded/redacted;
   - context: existing `stalled_ms`, `recapture`, first 24 raw frames, plus a structured signature object.

   Do not put the numeric stall duration in the message or fingerprint: it creates needless message/group variation. Use a constant human-readable message such as `main thread hang: <cause> (<phase>)` if Sentry’s title uses message text.

3. Replace “compiled standalone (`swiftc`)” with project-level verification appropriate to the repo. The plan should require `xcodebuild` only in CI per the stated local policy, plus a local pure replay executable/harness if needed. It must not claim `swiftc` validates Sentry SDK linkage, target membership, or the actual `SentryHelper` call path.

4. Add explicit negative tests for no regression to existing non-hang Sentry callers, telemetry-disabled behavior, budget-denied hangs, and `unknown` classification. The new helper must never cause those paths to receive a malformed empty fingerprint/tag.

5. Preserve the 875-event analysis as a committed/sanitized fixture manifest or documented artifact with hashes/counts, rather than relying on prose. “13 issues from 1” should be reproducible by a future maintainer and should include expected class counts and the outlier user concentration caveat.

### Questions for the Plan Author

1. Has the C11-192 ticket owner explicitly approved replacing the mandated Time Profiler acceptance with a telemetry-classification outcome, or should this plan become a new ticket while C11-192 retains its original performance investigation?
2. What are the exact 13 v1 cause/phase outputs and precedence rules, including `unknown`, incomplete frames, and multiple matching causes?
3. What canonicalization makes a fingerprint stable across ASLR, c11 release builds, and symbolication differences while still separating actionable causes?
4. Which fields are safe as Sentry tags under privacy and cardinality limits, and which must stay only in bounded context?
5. How will the implementation validate the actual Sentry envelope/scope fingerprint locally or in a tagged build, rather than infer it from parser tests?
6. If a future generic-metadata group exceeds the action threshold, what exact workload, app state, and artifact location will make the Time Profiler comparison reproducible?
7. What release/install-count comparison window defines “does not recur,” given that event counts are budgeted and one user produced 816 of the prior 875 reports?
