# Adversarial Review Synthesis: C11-192

**Plan:** `.lattice/plans/task_01KZ733HRN64WS7YSVCTT6WWRP.md` (C11-192)
**Branch / PR:** `c11-192-button-metadata`, PR #402 (open, 2 commits already pushed)
**Sources:** `adversarial-claude.md`, `adversarial-codex.md`, `adversarial-gemini.md`
**Synthesized:** 2026-08-04
**Posture:** all three inputs were designated adversaries. This document is not balanced by design. It reports what the critics agree on, not what a defense would say.

---

## Executive Summary

1. **All three models converge on the same core objection: this is a scope swap with self-graded acceptance.** The ticket asked for a fix to a 10s main-thread hang and required a before/after Time Profiler trace. The plan instead ships a client-side stack classifier that reorganizes Sentry, declares view-tree work a non-goal, and rewrites the acceptance criteria itself. No model disputes that the diagnosis (Sentry fingerprints message events on the capturing thread's stack because `attachStacktrace = true`) is correct and non-obvious. Every model disputes that a correct diagnosis licenses replacing the ticket's acceptance without a ticket-owner sign-off.

2. **All three models challenge the chosen layer.** Client-side semantic parsing of `backtrace_symbols` for Apple's private frameworks is the most brittle available implementation of "make Sentry group hangs correctly." Sentry-side alternatives (an explicit fingerprint from a hash, a synthesized `threads` payload marking the wedged main as `current: true`, server-side fingerprint rules) were never presented as options and never rejected in writing. Claude adds the strongest form of this: server-side rules could have been applied retroactively to the 875 events already held, validating the taxonomy before shipping anything.

3. **All three models reject the evidence table as load-bearing.** 816 of 875 events came from one user, and the plan reasons from the un-reweighted per-event distribution anyway. Claude adds that the corpus predates #401 (already on `main`), which capped reporting to one event per episode plus 3/hour and 15/day, meaning the distribution is over *recaptures under a regime that no longer exists* and can never recur. Gemini adds the inverse hypothesis nobody tested: if the heavy user produced the AttributeGraph hangs and the other six produced the 50 generic-metadata hangs, then the "5.7%" class is the *most widespread* issue by user count and the plan's central dismissal inverts.

4. **Two models independently find that the analysis cannot be reproduced.** The classifier script and the 875-event dump are not committed. "13 issues from 1," "172 reports naming 114 distinct symbols," and every row of the table exist only in a dead context window. Codex adds that the plan also lacks the classifier contract itself: no ordered rule table, no phase precedence, no `unknown` behavior, no fixture strategy, so an implementer handed this plan could not rebuild the classifier from it.

5. **The instrument ships into a moment when the data goes quiet.** Claude's strongest unique finding: #401's throttle cuts event volume by roughly 98% by design, so each of 13 buckets receives a trickle, the amended acceptance criterion ("its own user count and trend") has no numerator, and the `hang.recapture` tag the change adds is dead on arrival because `reportedCurrentEpisode` guarantees one event per episode. Simultaneously the fingerprint change creates a hard discontinuity in the historical record at exactly the release where the instrument is installed.

6. **Net verdict across the three:** approve the direction of the code, reject the document as an executable plan, reject the self-authored acceptance criteria, and do not treat the follow-up sizing as trustworthy until the classification is re-run per episode and per user with the script committed. Two of three models would additionally hold the merge until the change is observed working against real Sentry on a tagged build.

---

## 1. Consensus Risks (flagged by two or more models)

Ordered by number of models plus severity.

### 1.1 Unauthorized scope swap under an existing ticket ID (Claude, Codex, Gemini)
1. The ticket's acceptance requires a Time Profiler trace. The plan declares it unmeetable and substitutes an observability outcome authored by the same agent that will be graded against it.
2. The branch is named `c11-192-button-metadata` and contains no button and no metadata work. Claude: "six months from now the archaeology is: ticket says fix a Button, branch says button metadata, PR says fingerprint hangs."
3. Codex frames the correct remedy as a fork: either close/re-scope C11-192 explicitly and open a new observability ticket, or keep C11-192 pointed at a reproducible generic-metadata stall. Claude reaches the same conclusion independently. Gemini is blunter: "You don't get to redefine a bug fix as an analytics task just because the bug is hard to find."
4. Consequence all three note: the acceptance criteria are written by the implementer, so the change cannot fail.

### 1.2 Wrong layer: a bespoke client classifier where SDK or server-side grouping would do (Claude, Codex, Gemini)
1. Gemini: the Sentry misattribution is real, but the fix "should take 5 lines of Sentry SDK configuration (`scope.setFingerprint(...)`), not a new `MainThreadHangSignature` module with its own unit tests."
2. Claude's sharper version: fix the *event shape*. Synthesize a `threads` payload with the wedged main marked `current: true`. That fixes grouping, fixes the Sentry UI display (which is still showing the watchdog's loop, unsymbolicated), and hands Sentry's own grouper the correct input, making the hand-rolled classifier optional rather than load-bearing.
3. Claude's second alternative: server-side fingerprint rules, editable in minutes rather than a release cycle, and retroactively applicable to the 875 events already received. That would have validated the 13-bucket taxonomy before any code shipped.
4. Codex's version of the same concern: grouping rules compiled into the binary calcify. Any classifier revision silently changes the meaning of an existing issue trend unless the classifier version is part of the fingerprint or context.
5. None of these alternatives appears in the plan as a considered-and-rejected option. All three models treat that omission as the plan's biggest unexamined default.

### 1.3 The evidence base is unrepresentative and un-reweighted (Claude, Codex, Gemini)
1. 816 of 875 events from one user. The plan states this and then quotes per-event percentages anyway.
2. Gemini's inversion test: if the six other users account for the 50 generic-metadata events, that class is the broadest issue in the fleet by user count. Nobody ran the per-user cut.
3. Claude's regime argument: all 875 events predate #401, whose own commit note says re-sending the same wedge every 5s was roughly 98% of c11's entire event volume. The table therefore describes recaptures, not hangs. The plan has the `recapture` flag in hand and never dedupes by it.
4. Codex: the corpus is neither committed nor reproducible, so no reviewer can check any of the above.
5. Claude and Gemini both note this makes the plan's own headline refutation ("only 5.7%") the weakest part of an otherwise strong argument, and the first thing a hostile reviewer attacks.

### 1.4 Brittleness of string-matching Apple's private framework frames (Claude, Codex, Gemini)
1. Gemini: one macOS point release that renames a `SwiftUICore` or `AttributeGraph` frame dumps 64% of hangs into `unknown`. "We are taking on the maintenance of a mini-crash-reporter." Who owns it when macOS 27 ships?
2. Codex: backtrace-symbol text varies with build flavor, architecture, OS symbolication, offsets, stripping, and frames missing from a partial cross-thread unwind. A classifier tuned to `0.58.0+116` is a snapshot, not an API.
3. Codex also flags that C11-191 already demonstrated unreliable nearest-exported-symbol attribution for c11's own frames, which the plan's `hang.culprit` extraction depends on.
4. Claude's runtime-specific instance: `ownModule` is `ProcessInfo.processInfo.processName`, matched against a `backtrace_symbols` image name. Untested at runtime; tests inject `"c11"`. If they ever diverge, `hang.culprit` silently goes to zero fleet-wide and nothing notices.

### 1.5 Tag cardinality and privacy are unbounded and unreviewed (Claude, Codex)
1. `hang.top_symbol` is unbounded. Claude: unresolvable frames yield a per-launch `0x...` string, so `parse` mints a new "symbol" per launch. Nothing caps, buckets, or monitors this.
2. `hang.culprit` is already at 114 distinct values by the plan's own count, with no ceiling.
3. Codex: Sentry tags are indexed dimensions, not an unbounded evidence store. Bounded taxonomy values belong in tags; normalized, length-limited evidence belongs in context. `top_symbol` and a free-form culprit should not be tags until the vocabulary is finite and the data classification is approved.
4. Claude's privacy note: mangled c11 symbol names now leave the machine as searchable tags in a third-party index, leaking unreleased feature names. Legally covered by `TelemetrySettings.enabledForCurrentLaunch`, but it earns one sentence and gets none.
5. Claude: the 190-character tag cap rests on a code comment asserting Sentry rejects rather than truncates. Unverified, untested.

### 1.6 No real-artifact validation, no rollout plan, no rollback (Claude, Codex)
1. The change's entire behavior is remote. CI's `build` job compiles and runs logic tests. It cannot observe a Sentry event.
2. Nothing verifies that Sentry accepts `hang.cause` / `hang.phase` / `hang.culprit` / `hang.top_symbol` as tags, accepts the 3-element fingerprint, or renders the message as intended.
3. Claude cites the global rule directly: green tests are not a working product, and this is exactly the class of defect that only lives in the shipped bundle. The smoke test is cheap: tagged build, dev DSN, forced synthetic stall, open the event, screenshot it.
4. Codex adds the missing operational scaffolding: a payload-printing harness, a staging or production observation window, a named owner who checks the resulting issues, and a stated rollback condition for cardinality or privacy failure.
5. Claude: because the taxonomy is compiled in, there is no server-side override and therefore no path back if the buckets turn out worse than one big issue.

### 1.7 The analysis is not reproducible and the classifier contract is not written down (Claude, Codex)
1. Neither the classification script nor the event dump is committed. Every load-bearing number is unverifiable.
2. Codex: the plan never states the classifier contract at all. Inputs, normalized frame representation, output enum cases, phase values, culprit selection, ambiguity handling, and the precedence table are all absent. "Every cause rule" cannot be implemented from this plan because the rules are never listed.
3. Codex: no fixture strategy. "Verbatim frames from real reports" cannot be committed without a redaction and provenance decision, and the plan does not say where the fixture lives or how the corpus-level 13-group assertion runs in CI.
4. Claude: without the artifact, "13 issues from 1" and "172 reports naming 114 distinct symbols" are assertions, not evidence.

### 1.8 The user-visible hang is not fixed and no follow-up is filed (Claude, Codex, Gemini)
1. Gemini: "If the plan succeeds perfectly, the user still experiences a 10-second hang."
2. Claude: the plan names three follow-up classes (`xpc-sync-wait` up to 604s, the SwiftUI graph family, `runloop-idle`) and files zero tickets, names no owner, sets no date. The entire justification for the change is "which this change makes possible," and possibility is not a deliverable.
3. Codex: if generic metadata really is only 24 events, establish whether those are distinct episodes and users and create a traceable follow-up, rather than declaring it someone else's future work.
4. Claude names this the modal death of taxonomy work: the classifier lands, the buckets appear, and `other` and `unknown` become the new C11-31, an unactionable pile nobody triages.

### 1.9 Blindness to the sibling ticket C11-191 (Claude, Codex, Gemini)
Each model reaches this from a different direction, which makes the convergence notable.
1. **Claude (data contradiction):** C11-191 reports 9433 of 20778 local captures wedged on `__ulock_wait2`, with one pid wedged 13h58m across 9412 consecutive persist captures. C11-192 reports `lock-wait` at 10 of 875, 1.1%. Same watchdog, same era, same fleet. The likely reconciliation is that Sentry systematically under-samples the worst wedges, because a 14-hour wedged main cannot flush its transport. If so, the new taxonomy's trends inherit the same survivorship bias and the amended acceptance criterion is built on a sensor that is blindest exactly where the damage is worst. The plan never mentions the sibling ticket despite both being reviewed in the same session.
2. **Gemini (distribution shift):** if C11-191 removes the AttributeGraph hangs, that is 64% of the bucket gone, and generic-metadata becomes the dominant unresolved class. The plan treats the distribution as static.
3. **Codex (confounding):** if C11-191 and a generic-metadata regression ship together, the classifier can separate them only if causes and phases are deterministic. Otherwise it produces a reassuring dashboard while neither root cause gets a reproduction or a profiler trace.
4. **Claude (measurement collapse):** 0.58 events are grouped by watchdog stack and 0.59+ by cause, so a post-fix shift cannot be attributed to C11-191's fix versus the taxonomy change. Both tickets lose their measurement at the same moment, and each will be tempted to claim the other's improvement.

### 1.10 No failure threshold and no early-warning instrumentation for the classifier (Claude, Codex)
1. Nothing notices if `hang.culprit` coverage silently drops to zero, or if `other` plus `unknown` swells to 40 or 60% of events.
2. Codex proposes pre-registering: percentage classified `unknown` by app version and architecture; issue count and singleton rate per 100 hang reports; distinct `hang.culprit` values against a hard ceiling; mismatch between local full-log classification and outbound event classification; time and allocations spent building the signature on the watchdog thread.
3. Claude proposes the same in different form, adding the sign that actually predicts failure: nobody has opened a Sentry hang issue thirty days after release.

---

## 2. Unique Concerns (raised by exactly one model, worth investigating)

### Claude only
1. **#401 invalidated the corpus and killed a tag on arrival.** `hang.recapture` will always be `"false"` post-#401 because `reportedCurrentEpisode` guarantees one event per episode. This is direct evidence the change was not reconciled against current `main` (`42ce4c919`).
2. **Severity is now invisible in the issue list.** The message drops the duration by design and `stalled_ms` moves to context, which Sentry cannot facet, alert, or sort on. A 2.0s stutter and a 604s wedge become the same row. In a change whose whole purpose is Sentry legibility, this is a regression. A `hang.duration_bucket` tag is one line.
3. **The Sentry UI still shows the wrong stack.** `attachStacktrace = true` remains at `Sources/AppDelegate.swift:2615`. The event's Stack Trace panel is still the watchdog's loop; the real stack is a 24-frame string blob in context, with no symbolication, no frame navigation, no suspect commits, no in-app frame highlighting. Grouping was fixed; display was left broken.
4. **The general bug is fixed at one of three call sites.** `sentryCaptureError` at `Sources/TerminalController.swift:857` and `:1679` still fingerprint on the capturing thread. The shared helpers gained `fingerprint:`/`tags:` but only one call site uses them. Either those sites have the same defect and belong in this PR, or someone should state why they do not.
5. **The explicit fingerprint has no `{{ default }}` and no release component.** Every cause becomes one permanent issue across all releases, resolvable-and-regressible but never closable. The ticket's own language ("does not recur on the next release") is structurally unsatisfiable under the fix the plan ships. This is a legitimate design call that was never made explicitly.
6. **Migration and comms for C11-30 and C11-31.** Both go silent. Any alert rule, assignment, saved search, or dashboard keyed to them stops firing. Nobody owns the Sentry-side cleanup, and historical continuity across the taxonomy change is simply lost.
7. **Test file placement re-creates the C11-105 footgun.** `MainThreadHangSignatureTests` was appended to `c11Tests/MainThreadHangDetectorTests.swift`, a file that lives in `c11Tests/` on disk but is a member of the `c11LogicTests` target. CLAUDE.md documents this exact disk/target mismatch as the root cause of C11-105, where a `c11Tests/`-resident file that was secretly a `c11LogicTests` member unlinked the operator's production socket. Nothing here touches sockets, so it is not dangerous today; it re-establishes a pattern the repo already got burned by, in a file whose name now lies about two of its three classes. Also a plan/implementation drift signal: the plan promised a file, the branch appended a class.
8. **`causeWindow = 16` and `moduleWindow = 8` are undefended magic numbers** with no test pinning boundary behavior.
9. **The 645-vs-13 comparison is a strawman.** Nobody proposed top-5-frame fingerprinting. `cause + phase + module-of-culprit` is the obvious middle and is never evaluated. 13 buckets may be right; it is shown only to be better than a bad alternative.
10. **The plan over-argues its own case.** The two robust arguments (the `attachStacktrace` grouping mechanism, and "no metadata-stack event names a `Button` c11 owns") stand alone. Leading with the distribution table hands a hostile reviewer the weakest evidence first.
11. **One thing the plan gets right and does not say:** `describe()` runs on the watchdog thread inside `reportTelemetry`, off main, consistent with the socket/telemetry threading policy. Worth an explicit line, because any reviewer scanning "new string parsing in the hang path" will ask.

### Codex only
1. **No versioned classifier in the fingerprint or context.** Changing a rule silently changes the meaning of an existing issue trend. An explicit versioned mapping plus a compatibility decision for classifier revisions is required.
2. **Cost on a degraded process.** Parsing, string allocation, and Sentry-scope work grow on the hot diagnostic path precisely when the process is already wedged. The plan establishes no bounded cost and no behavior for a malformed capture or failed symbolication.
3. **The shared telemetry API was broadened without a contract.** Adding `fingerprint:` and `tags:` to every helper needs validation rules, reserved-key handling, precedence against existing scope data, and a call-site compatibility statement.
4. **Standalone `swiftc` proves nothing about target membership.** It does not validate that the new source and tests are in the project targets, nor Sentry SDK integration. The plan must name the CI job that runs `MainThreadHangSignatureTests` and require an artifact-level check of target membership.
5. **The one-event-per-episode budget may discard the more diagnostic stack.** A later persist capture can carry a better stack than the first eligible sample. The plan has no confidence marker and no rule for preferring a later capture.
6. **`current: true` as the watchdog identifier needs a fixture.** Plausible, but the plan should preserve one redacted event demonstrating the relevant Sentry thread fields and the exact extraction rule.
7. **Deliberate baseline capture before release.** Record pre-release baselines by normalized cause and compare comparable release/install exposure and distinct users, not issue counts, or the six-week retrospective reads "we reported a reduction in generic-metadata hangs, but we actually changed grouping."

### Gemini only
1. **The per-user inversion (the single highest-value unique finding).** If the one heavy user generated the AttributeGraph hangs and the other six generated the 50 generic-metadata hangs, the dismissed class is the most widespread issue in the fleet. This is cheap to check and would reverse the plan's central conclusion.
2. **"No `Button` c11 owns" is a cop-out given a finite audit surface.** SwiftUI type erasure and internal view wrapping routinely obscure the owning view name; `NSHostingView` is the boundary, and c11 knows exactly what it hosts in AppKit: sidebar, tab bar, toolbars, command palette. That is a small, enumerable set. Absence of a name in a stack is not absence of an owner.
3. **The single-sample argument cuts both ways.** The plan correctly notes 10422ms is the stall duration at sample time, not time in the sampled frame. Gemini's counter: if the thread has not returned to the runloop in 10 seconds and the sample catches it in `swift_getTypeByMangledName`, a massive view-tree layout is still the most probable cause. Technical correctness is being used to dismiss the obvious reading.
4. **Ownership of the classifier as a long-lived asset.** Nobody is named as the maintainer of a mini-crash-reporter that must track Apple's internal framework churn.
5. **The bluntest framing of the outcome:** "We are shipping a completely unfixed 10-second beachball to our users while patting ourselves on the back for having better dashboards."

---

## 3. Assumption Audit (merged and deduplicated)

Load-bearing assumptions are those whose failure makes the plan collapse or actively mislead.

| # | Assumption | Stated in plan? | Raised by | Verdict |
|---|---|---|---|---|
| A1 | The 875-event corpus represents the fleet's hang population | Partially (the one-user fact is stated, then ignored) | Claude, Codex, Gemini | **Fails.** 816/875 one user, recapture-dominated, pre-#401 regime. Never reweighted per user or per episode. |
| A2 | Sentry's received events are an unbiased sample of hangs | Invisible | Claude | **Probably fails.** Contradicted by C11-191's local log; the worst wedges likely never transmit. |
| A3 | Event volume post-change will support per-cause trends | Invisible | Claude (Codex adjacent) | **Doubtful.** #401 caps at 1/episode, 3/hour, 15/day/user. The amended acceptance has no numerator. |
| A4 | 13 buckets is the right coarseness | Argued, against a strawman | Claude | Plausible but unproven. No middle option (`cause + phase + module`) evaluated. |
| A5 | The taxonomy belongs compiled into the client binary | Invisible | Claude, Codex, Gemini | **Contestable and undefended.** SDK fingerprint, synthesized `threads` payload, and server-side rules all do the job and are release-independent. |
| A6 | `ProcessInfo.processInfo.processName` equals the `backtrace_symbols` image name | Invisible | Claude | Probably true for `c11` / `c11 DEV`. Untested at runtime; tests inject the value. Silent fleet-wide `hang.culprit` loss if it diverges. |
| A7 | Sentry rejects rather than truncates over-limit tag values, and 190 is safe | Asserted in a code comment | Claude | Unverified, untested. |
| A8 | Someone will read the new buckets and file the follow-up tickets | Invisible | Claude, Codex, Gemini | **The most fragile assumption in the document.** No owner, no date, no mechanism, zero tickets filed. |
| A9 | The original Time Profiler acceptance is genuinely unmeetable | Argued | Claude (accepts), Codex (rejects), Gemini (rejects) | **Contested.** Claude calls it the plan's strongest section. Codex and Gemini both say "we could not find it" is not "it cannot be found," and Gemini names the finite `NSHostingView` surface that was never audited. |
| A10 | `backtrace_symbols` text is stable enough to classify release builds | Implicit | Codex, Gemini, Claude | **Fragile.** Varies with flavor, arch, symbolication, stripping, partial unwind, and OS release. C11-191 already showed unreliable c11 symbol attribution. |
| A11 | `current: true` reliably identifies the watchdog, not the sampled main | Asserted as verified | Codex | Plausible; needs one preserved redacted fixture demonstrating the fields and the extraction rule. |
| A12 | `hang.culprit` and `hang.top_symbol` are safe as Sentry tags | Invisible | Claude, Codex | **Fails on cardinality.** Unbounded, unnormalized, unreviewed for privacy, no ceiling. |
| A13 | One outbound event per episode carries a sufficiently diagnostic stack | Invisible | Codex | Unexamined. A later persist capture may be strictly better. |
| A14 | Extending shared Sentry helpers with `fingerprint:`/`tags:` has no collateral semantics | Invisible | Codex | Risky. No validation, reserved-key handling, or precedence rules defined. |
| A15 | Generic-metadata being 5.7% of events means it is not the primary issue | Stated as the plan's central conclusion | Gemini | **May invert.** Per-user, it could be the broadest class in the fleet. Untested. |
| A16 | A single sample catching the demangler does not implicate the view tree | Stated as a non-goal justification | Gemini | Technically defensible, practically weak. Ten seconds off the runloop plus a demangler frame is not neutral evidence. |
| A17 | The classifier's rules will remain stable enough that trends stay comparable | Invisible | Codex, Claude | **Unaddressed.** No classifier version in the fingerprint or context; any rule change silently redefines an existing issue's history. |
| A18 | CI green is sufficient verification | Effectively assumed | Claude, Codex | **Fails.** CI cannot observe a Sentry event. The change's entire behavior is remote. |

Cosmetic (non-load-bearing but undefended): exact bucket names; `causeWindow = 16`; `moduleWindow = 8`. No test pins boundary behavior for the windows.

---

## 4. The Uncomfortable Truths (recurring hard messages)

1. **The plan is right about the diagnosis, and that is what makes it dangerous (Claude, echoed by Codex).** The `attachStacktrace` grouping mechanism is genuine, non-obvious, good work. It is being used to license three things that would not survive on their own: a scope swap inside someone else's ticket ID, acceptance criteria written by the implementer, and a distribution table that cannot bear the weight put on it. Reviewers who nod at the diagnosis will nod at the rest.

2. **Proving the aggregate count is invalid is not proving the bug does not exist (Codex, Gemini).** C11-31 may well be a bad Sentry grouping. That establishes nothing about whether a Button or view-tree defect exists. A 24 or 50-event class can still be a severe, reproducible user failure, and per-user it may be the most widespread one in the fleet.

3. **The user's experience is unchanged (Gemini, Claude).** After this ships, the app still beachballs for ten seconds. The deliverable is 13 tidy Sentry issues documenting it. Gemini: "The author couldn't find the Button causing the hang, so they wrote a telemetry tool to prove they didn't need to look for it."

4. **The amended acceptance is self-authored scope change and cannot substitute for the ticket's acceptance (all three).** Independence of the grading criteria is the thing being spent here, and it is spent silently.

5. **This document is a PR description wearing a plan's clothes (Claude).** The work is committed, PR #402 is open, and the Verification section is written in the past tense. Asked "is this an executable implementation plan," the honest answer is no, and it never could have been, because the implementation came first. Reviewing it as a plan launders a hole in the workflow, and a plan review has no mechanism to catch plan/implementation drift that has already occurred.

6. **Nobody is going to look at these buckets (Claude, Codex, Gemini).** Three follow-up classes named, zero tickets filed, no owner, no date. The whole justification is "which this change makes possible." Claude's proposed single highest-leverage edit to the plan is one line: file the follow-up tickets before this PR merges.

7. **A telemetry redesign that cannot be exercised against its real backend before broad release is an operational change, not a parser refactor (Codex, Claude).** It deserves rollout discipline: a payload harness, an observation window, a named owner, a rollback condition. It has none of these.

8. **The instrument arrives exactly when the data goes quiet (Claude).** #401 cut volume ~98%, the fingerprint change breaks historical comparability, and C11-191's fix (if it lands) shifts the distribution. The rational conclusion available to a future reader is "hangs got better," which may or may not be true and cannot be checked.

9. **"No claim that a metadata hang was fixed" is honest, and it means C11-192 closes without fixing a hang (Claude).** That may be entirely correct. It should be said out loud to whoever tracks the board rather than absorbed into an amended acceptance that reads as if the ticket succeeded.

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews. Source model in brackets. Bold items are the ones the reviewers marked as currently unanswered and blocking.

### A. Ticket integrity and process
1. **Who approved replacing C11-192's Time Profiler acceptance with a Sentry regrouping objective?** If nobody, why is this not a new ticket plus an explicit correction and closure of C11-192? [Codex, Claude, Gemini]
2. The work is committed and PR #402 is open. What precisely is an implementation agent on `c11-192-button-metadata` supposed to do with this document? If the answer is "nothing, it is a write-up," say so and route it to code review instead. [Claude]
3. Should C11-192 be closed as invalid with a new ticket for the fingerprinting work, so the acceptance criteria are not written by the agent graded against them and the branch name stops lying? [Claude, Codex]
4. If the plan succeeds perfectly, the user still experiences a 10-second hang. Is that acceptable for a performance-fix ticket, and who is told? [Gemini]

### B. The evidence
5. **Re-run the classification deduped by episode and weighted per user. What does the table look like?** Does `generic-metadata` survive as a distinct class, or was it one user's one afternoon? [Claude]
6. **How many of the 7 users experienced the 50 `generic-metadata` hangs?** If it was six of seven, does that not make it the most widespread issue in the fleet despite the lower event count? [Gemini]
7. **Why does C11-191 find `__ulock_wait2` in 45% of 20778 local captures while this plan finds `lock-wait` in 1.1% of 875 Sentry events?** Pick one: Sentry is a biased sensor, or one of the two classifications is wrong. If it is bias, that belongs in the plan, in every follow-up ticket, and in CLAUDE.md, because every future hang ticket will reason from the same stream. [Claude]
8. **Where are the classifier script and the 875-event dump?** Neither is committed. How does a reviewer reproduce "13 issues from 1," "172 reports naming 114 distinct symbols," or any row of the table? [Claude, Codex]
9. Where does the sanitized `0.58.0+116` corpus (or a deterministic derived fixture) live, with what redaction and provenance policy, and how does CI reproduce the 13-group assertion? [Codex]
10. If C11-191 removes the AttributeGraph hangs (64% of the bucket), does generic-metadata not immediately become the dominant unresolved class? Why does the plan treat the distribution as static? [Gemini]

### C. Design of the fix
11. **Why is the taxonomy compiled into the client rather than expressed as Sentry server-side fingerprint rules**, which would have let you reclassify the 875 events you already hold and validate the buckets before shipping anything? [Claude]
12. **Why not fix the event shape** by synthesizing a `threads` payload with the wedged main marked `current: true`, so Sentry groups correctly on its own and the UI displays the right stack? Considered and rejected, or not considered? [Claude, Gemini]
13. What is the complete ordered classifier table, including token/regex rules, phase refinement, ambiguity resolution, and `unknown` behavior, and which fixture proves each row? [Codex]
14. How does the classifier distinguish trustworthy module-level evidence from the known-unreliable c11 symbol attribution documented by C11-191? [Codex]
15. What is the failure behavior for empty frames, a failed `thread_suspend`, raw-address-only frames, an unknown OS symbol, or contradictory signals? Confirm these route to a stable `unknown` and never mint a new fingerprint per raw frame. [Codex]
16. `causeWindow = 16` and `moduleWindow = 8`: where did these come from, and what test pins behavior at the boundary? [Claude]
17. The 645-groups-at-top-5-frames comparison is a strawman. Why was the obvious middle (`cause + phase + module-of-culprit`) never evaluated? [Claude]
18. Is the classifier version part of the fingerprint or context? If not, how does anyone interpret a trend across a classifier revision? [Codex]
19. How does parsing `backtrace_symbols` survive the next macOS update when Apple renames internal `SwiftUICore` or `AttributeGraph` frames, and who owns the classifier when it does? [Gemini]

### D. The Sentry contract
20. **What exact fields are emitted** (message, fingerprint array, tag keys and values, context fields), how are lengths and cardinality bounded, and which values are prohibited from tags for privacy and indexing reasons? [Codex]
21. Is `hang.culprit` a finite taxonomy or arbitrary symbol text? If arbitrary, why is it a tag rather than context, and what prevents thousands of indexed values after a build or OS update? [Codex, Claude]
22. `hang.top_symbol` is unbounded: unresolvable frames yield a per-launch `0x...` string. What caps this tag's cardinality? [Claude]
23. The 190-character tag cap rests on a code comment asserting Sentry rejects rather than truncates. What verifies that, and where is the truncation-path test? [Claude]
24. The message no longer carries the duration and `stalled_ms` sits in context, which Sentry cannot facet, alert, or sort on. How does anyone distinguish a 2s stutter from a 604s wedge in the issue list, and why is there no `hang.duration_bucket` tag? [Claude]
25. An explicit fingerprint with no `{{ default }}` and no release component makes each cause a permanent issue that can only regress, never close. Is that intended, and how does anyone then answer "did it recur on the next release"? [Claude]
26. Mangled c11 symbol names now leave the machine as searchable tags in a third-party index, leaking unreleased feature names. Has that been reviewed? [Claude]

### E. Coverage of the underlying defect
27. `attachStacktrace = true` still stands at `AppDelegate.swift:2615`, and `sentryCaptureError` at `TerminalController.swift:857` and `:1679` still group on the capturing thread. Do those have the same bug? If yes, why are they not in this PR? If no, why not? [Claude]
28. Which `NSHostingView` boundaries (sidebar, tab bar, toolbars, command palette) have actually been audited with Time Profiler to rule out deeply nested generic chains? The set is finite and enumerable. [Gemini]
29. What exact user interaction and app state reproduces the alleged generic-metadata stall, and what are the capture settings, duration, symbol filter, and before/after pass criteria? If no reproduction exists, say so explicitly and remove any implication that the performance issue is resolved. [Codex]

### F. Verification, rollout, and aftercare
30. **Which single event, on which real tagged build, has been observed arriving in Sentry with the new fingerprint, tags, and title rendered as intended?** If none: the change's entire behavior is remote, and the repo's own rule is that green tests are not a working product. [Claude, Codex]
31. Which CI job runs `MainThreadHangSignatureTests`, and what artifact-level check proves the project targets include the new source and tests? "swiftc compiled" is not an answer. [Codex]
32. What is the rollout and rollback plan, including the observation window, the named owner who reads the resulting Sentry issues, and the conditions (cardinality, privacy, misclassification rate) that trigger a revert? [Codex, Claude]
33. Post-#401, `reportedCurrentEpisode` sends at most one event per episode. What is `hang.recapture` for, given it will always be `"false"`? [Claude]
34. **With 1 event per episode, 3/hour, 15/day, what is the projected weekly event count per bucket, and at what count does a bucket's trend become actionable?** If the answer is "we do not know," the amended acceptance has no numerator. [Claude]
35. Does the one-event-per-episode budget deliberately discard a later, more diagnostic persist stack? What evidence says the first eligible sample suffices for cause and phase classification? [Codex]
36. What is the classifier's failure threshold? If `other` plus `unknown` is 40% of hang events after release, is that a bug or the accepted floor? Who decides, and when do they look? [Claude, Codex]
37. What happens to C11-30 and C11-31? Who closes them, who audits the alert rules and assignments pointed at them, and how is pre-change history reconciled with the post-change taxonomy? [Claude]
38. The plan names three follow-up classes and files zero tickets. Who files them, by when, and what happens to this PR if they are not filed? [Claude, Codex, Gemini]

---

## Appendix: Minimum Bar Before Merge

The three reviews propose overlapping merge gates. Consolidated and ordered by leverage:

1. Re-run the classification deduped by episode and weighted per user, and commit the script plus the event dump under `notes/`. If the table moves materially, both the follow-up sizing and the "premise does not hold" argument need rewriting. [Claude, Codex, Gemini all depend on this]
2. Answer the C11-191 contradiction in writing. If Sentry is a biased sensor, record it in the plan, the follow-up tickets, and CLAUDE.md. [Claude]
3. One real-artifact smoke: tagged build, forced stall, observe the event in Sentry with its fingerprint, tags, and title, and screenshot it. [Claude, Codex]
4. Bound the tags. Move `top_symbol` and free-form culprit to context, or define a finite vocabulary with a cardinality ceiling and a privacy note. [Codex, Claude]
5. Add `hang.duration_bucket` so severity is visible in the issue list. [Claude]
6. Write down the classifier contract (ordered rules, precedence, `unknown` behavior, fixture per rule) and pin the classifier version into the event. [Codex]
7. File the three follow-up tickets, or state in the PR why they are deliberately not being filed, with an owner and a date for the Sentry read. [Claude, Codex, Gemini]
8. Have someone other than the implementer write the acceptance criteria. [Claude, Codex, Gemini]
9. Optional and cheap: move `MainThreadHangSignatureTests` into its own file, and note in the PR that `c11Tests/MainThreadHangDetectorTests.swift` is a `c11LogicTests` member despite its directory, so the next reader does not re-derive C11-105 the hard way. [Claude]
