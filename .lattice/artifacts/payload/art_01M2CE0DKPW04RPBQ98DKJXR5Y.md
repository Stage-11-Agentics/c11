# Plan Review: C11-221 — Hang precursor warning

## 1. Verdict

**FAIL (plan-level)**

The plan file is the task description with a title line prepended (byte-for-byte identical body, verified against `.lattice/tasks/task_01M2CDH8PTYCD62J9B0W1QRQBX.json`). The description is unusually prescriptive, so the revision is short, but two of the decisions it leaves open would produce a wrong implementation if taken literally, and one required change set (the closed events enum) is not visible from the description at all.

## 2. Summary

Reviewed the C11-221 plan against `Sources/MainThreadHangMonitor.swift`, `Sources/SentryHelper.swift`, `Sources/AppDelegate.swift` (Sentry `beforeSend`), `Sources/Events/*`, `spec/event-envelope.v1.schema.json`, `tests_v2/test_events_parity.py`, the `c11LogicTests` target membership in `project.pbxproj`, and the events reference in `skills/c11/references/events.md`. The approach in the description is sound and every piece it needs already exists in the codebase (a thread-safe `EventEmitter`, a `SentryEventBudgetGate` consulted once in `beforeSend`, a watchdog thread that already owns per-episode state). The plan, however, makes zero decisions of its own: no file list, no choice of Sentry category, no answer to "which signature does a completed episode carry", no acknowledgement that `hang.precursor` must be added to a closed schema enum with fixtures, docs, and an installed-skill sync. The key concern is the Sentry hang sub-budget: a precursor filed under `category: "hang"` is dropped in exactly the scenario it exists for.

## 3. Issues

**[CRITICAL] Fix, bullet 3 (Sentry) — Precursor competes with the wedge for the hang sub-budget and loses**
`SentryEventBudget` charges any event tagged `category == "hang"` against `hangsPerHour: 3` / `hangsPerDay: 15` (`Sources/SentryHelper.swift:163-164`, applied in `beforeSend` at `Sources/AppDelegate.swift:2667-2672`). In the C11-209 shape (seven episodes of 2.4–10.7 s), the ≥5 s episodes each already spend a hang slot via `shouldReportHangToSentry`. By the time N=3 same-fingerprint episodes have completed, the hourly hang budget is very plausibly exhausted, and a precursor filed with `category: sentryHangCategory` is silently dropped by `beforeSend`. The task says "through the existing `SentryEventBudgetGate` path", which is satisfied by any category; the plan must pick one deliberately.
**Recommendation:** File the precursor with a distinct category (e.g. `"hang.precursor"`), which `SentryEventBudget.Kind.classify` routes to `.other` and charges only against the global 20/hour, 50/day allowance. Keep `fingerprint: signature.fingerprint` and the `hang.precursor=true` tag so it still groups with the eventual wedge. State this in the plan and add a one-line comment at the call site explaining why the category is not `"hang"`. Also record in the hang.log precursor block the `SentryEventBudgetGate.shared.dropped` snapshot, as `handleRecovery` already does, so a forensic pass can see whether the precursor was suppressed.

**[MAJOR] Fix, bullet 3 (events stream) — `hang.precursor` is a new member of a closed v1 enum; the plan does not list the change set**
`EventEnvelope.EventType` is a closed enum (`Sources/Events/EventEnvelope.swift:45-64`), `spec/event-envelope.v1.schema.json` pins the same closed list (line 19-37), `tests_v2/test_events_parity.py` validates fixtures against that schema, and both `spec/README.md:20` and the events reference (`skills/c11/references/events.md:44`, "The fifteen taxonomy types below are the closed v1 enum") enumerate it. Adding the event without touching all of these leaves the schema rejecting real lines from the stream, which breaks the CLI-vs-file parity test whenever a precursor has fired.
**Recommendation:** The plan must enumerate: (1) new `case hangPrecursor = "hang.precursor"` in `EventType`; (2) enum entry in `spec/event-envelope.v1.schema.json` plus a `spec/fixtures/events/valid-hang-precursor.json` fixture; (3) new taxonomy row in `skills/c11/references/events.md` (the repo source, not the `~/.claude` copy the description points at) with the payload shape `{cause, culprit?, count, window_ms, durations_ms}` and the count word updated; (4) `spec/README.md:20`; (5) `scripts/sync-installed-skills.sh c11` after the edit, per the HARD RULE in `CLAUDE.md`. Decide and state whether this is a v1 taxonomy extension (schema `v` stays 1; the type is additive and consumers filter by `type`) or a schema bump. Additive with `v: 1` is the right call and should be written down.

**[MAJOR] Fix, bullet 1 — A completed episode has no signature at recovery time; the plan must say where it comes from**
`handleRecovery(durationMs:)` (`Sources/MainThreadHangMonitor.swift:515`) receives only a duration. The `MainThreadHangDescriptor` is computed per capture inside `handleHang` and discarded. Recaptures within one episode can classify differently (the first sample may hit one cause, a later `hang.persist` sample another).
**Recommendation:** Add watchdog-thread-only state `currentEpisodeSignature: MainThreadHangDescriptor?` set on `hang.begin` and updated on each `hang.persist` (or held at the begin sample; pick one and say why). Recommend the *latest* capture: it is the sample nearest the recovery and the one whose cause the operator would read last in the log. Feed `(fingerprintKey, cause, culprit, durationMs, endUptime)` to the tracker from `handleRecovery`, and clear the state there. Define `fingerprintKey` as `descriptor.fingerprint.joined(separator: "|")` (cause + optional phase), not `cause` alone, so the precursor groups at the same granularity as the Sentry issue.

**[MAJOR] Fix, bullet 2 — "Once per fingerprint per window (re-arm after the window slides past)" is under-specified and the tests depend on the reading**
Two readings are consistent with the text: (a) after firing at time T, the fingerprint is suppressed until `now - T > window`, then any N-in-window count fires again; (b) after firing, the entries that contributed are consumed and a fresh N must accumulate. They give different answers to the test "same fingerprint does not fire again until the window has slid" and to a real 25-minute run of repeated episodes.
**Recommendation:** Pick (a) with a per-fingerprint `lastFiredUptime` map: fire when `count(sameKey, endUptime > now - window) >= N` and (`lastFired == nil` or `now - lastFired >= window`). It is constant-time, bounded by the 64-entry ring, and matches the description's "re-arm after the window slides past". Write the rule and the tests it implies (including the boundary at exactly `window`) into the plan.

**[MAJOR] Tests — No statement of how the test file joins `c11LogicTests`**
Logic tests live on disk in `c11Tests/` but are members of the `c11LogicTests` Sources phase (`37DDE3B0A6A70E75A7B2BEDF` in `project.pbxproj`); `MainThreadHangDetectorTests.swift` is the precedent (`project.pbxproj:1827`). A new `HangPrecursorTrackerTests.swift` that is only dropped on disk is compiled by nothing and CI stays green while proving nothing.
**Recommendation:** Plan should name the test file, state it is added to the `c11LogicTests` phase by hand-editing `project.pbxproj` (two entries: `PBXBuildFile` + `PBXFileReference`, plus the group and the Sources phase list), and note the `CLAUDE.md` warning that the `xcodeproj` gem rewrites the whole file. Use `@testable import c11` / `c11_DEV` exactly as the sibling test does. The tracker must be a pure struct with an injectable `now: TimeInterval` (uptime) and no AppKit or `EventEmitter` dependency, so it runs under the bare xctest runner (the "`NSApp` is nil" local crash applies only to `Workspace`-constructing tests).

**[MINOR] Fix, bullet 1 — Say explicitly that every completed episode (≥2 s detector threshold) feeds the tracker, not only ≥5 s Sentry-eligible ones**
The C11-209 precursors were 2.4–10.7 s; several were below `sentryReportThresholdMs`. The description implies all episodes count, but the current `reportTelemetry` code applies the 5 s threshold, and an implementer could reuse it by reflex.
**Recommendation:** One sentence in the plan: the tracker records every `hang.end`, filtered only by `isWorthReporting(cause:)`. Also state that the tracker runs in `handleRecovery`, which is outside the `thread_suspend`/`thread_resume` window, so the "no allocation in the suspend window" constraint is satisfied by placement; preallocate the 64-slot ring in `init` anyway to honor "constant time per episode".

**[MINOR] Fix, bullet 4 — Drop the optional notification for this pass**
`TerminalNotificationStore` is keyed by tab and surface (`Sources/AttentionModel.swift:318-336`); a process-wide hang precursor has neither. Wiring it in would mean inventing a subject or a new notification kind.
**Recommendation:** State that the optional operator hint is out of scope; hang.log, the events stream, and Sentry are the three deliverables. If a visible hint is wanted later, file it as its own ticket.

**[MINOR] Validation — A local runtime check without a build exists and the plan should claim it**
`python3 tests_v2/test_events_parity.py` runs its schema layer with no app and no build (the CLI layer skips cleanly). After the schema and fixture edits it proves `hang.precursor` validates.
**Recommendation:** List it as the one local check; everything else is tests plus CI, stated plainly as the description asks.

## 4. Positive Observations

- The task description (and therefore the plan) is precise about the three sinks, the off-main constraint, the cost bound, and the exact test matrix. That is rare and the reason the revision needed here is short.
- The proposed shape is a good fit for the code as it exists: `EventEmitter.shared` is documented as callable from any thread with no hop required (`Sources/Events/EventEmitter.swift:3-8`), `SentryEventBudgetGate` is already read from the watchdog thread, and the watchdog already keeps per-episode state (`reportedCurrentEpisode`) on the same thread, so cross-episode state slots in without new locking.
- Insisting on an injectable-clock pure struct and forbidding source-text assertions matches the repo's test-quality policy exactly.
- Grouping the precursor under the same Sentry fingerprint as the eventual wedge is the right call for triage; once the category decision above is fixed, the Sentry side needs nothing else.
