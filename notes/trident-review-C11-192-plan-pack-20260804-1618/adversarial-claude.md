# Adversarial Plan Review: c11-192-plan (Claude)

**Plan:** `.lattice/plans/task_01KZ733HRN64WS7YSVCTT6WWRP.md` (C11-192)
**Branch:** `c11-192-button-metadata` (2 commits, PR #402 open)
**Reviewed:** 2026-08-04 16:18
**Role:** designated adversary. Not balanced by design.

---

### Executive Summary

The diagnosis in this plan is good and probably correct. The plan built on it is not a plan, and the evidence under it is weaker than the plan says.

Three things should worry you, in order:

**1. This is not an executable implementation plan; it is a retrospective.** The work is already committed on `origin/c11-192-button-metadata` (`93e655929`, `9caf9c72e`) with PR #402 open. The Verification section is written in the past tense ("The new code compiled standalone... and run over all 875 production stacks produces 13 issues from 1"). There are no numbered steps, no file paths with anchors, no ordering, no rollback, no branch/PR mechanics, no "stop here if X." An implementation agent handed this document on that branch has nothing to execute or will duplicate what exists. If the ask was "review the completed work," this should be a code review, not a plan review, and the distinction matters because a plan review has no mechanism to catch the plan/implementation drift that has *already occurred* (see #17 below: the plan promises a file `MainThreadHangSignatureTests`; the branch appended a second class to `MainThreadHangDetectorTests.swift`).

**2. The evidentiary base was invalidated by a commit that is already on `main`.** All 875 events predate #401 (`42ce4c919`, current HEAD), which added `reportedCurrentEpisode` (at most one Sentry event per hang episode) plus a 3/hour, 15/day hang budget. #401's own comment says re-sending the same wedge every 5s was "~98% of c11's entire event volume." So the 875-event population is a distribution over *captures*, dominated by recaptures of a small number of episodes, and it can never occur again. The plan's headline table (63.9% / 15.2% / 11.0% / 5.7% / ...) is therefore not the distribution of *hangs*; it is the distribution of *samples of hangs under a reporting regime that no longer exists*. The plan has the `recapture` flag in hand and never dedupes by it. Compounding: the plan itself notes 816 of 875 events came from one user, then proceeds to reason from the un-reweighted table anyway.

**3. The plan and its sibling C11-191 make contradictory claims about the same watchdog's data, and neither notices.** C11-191: 9433 of 20778 local captures wedged with leaf `__ulock_wait2`, one pid wedged 13h58m with 9412 consecutive persist captures. C11-192: `lock-wait` is 10 of 875 events, 1.1%. Same watchdog, same era, same fleet. The most likely reconciliation is that Sentry systematically under-samples the worst wedges (a 14-hour wedged main cannot flush its transport; and post-#401 a 14-hour episode sends exactly one event). If that is right, the new taxonomy's trends inherit the same survivorship bias, and the amended acceptance criterion ("that trend is what a future ticket acts on") is built on a sensor that is blindest exactly where the damage is worst. The plan never mentions the sibling ticket's data even though both were reviewed in the same session.

Net: I would not reject the change. I would reject the *plan document* as a plan, reject the self-authored acceptance criteria, and require the analysis be reproducible and re-run per-episode before any of its follow-up ticket sizing is trusted.

---

### How Plans Like This Fail

Common failure patterns for "instrumentation / observability refactor discovered mid-ticket," and where this one sits on each:

**a. The scope swap that nobody signs off on.** An agent opens a ticket, finds the premise wrong, and writes a different ticket inside the same ID. That is often the right *engineering* call and almost always the wrong *bookkeeping* call. Here the branch is literally named `c11-192-button-metadata` and contains no button and no metadata work. Six months from now the archaeology is: ticket says "fix a Button," branch says "button metadata," PR says "fingerprint hangs." Vulnerability: high, and already realized.

**b. Self-graded acceptance.** The agent that discovers the original AC is unmeetable also proposes its replacement, and the replacement is one the agent cannot fail. "Hang reports group by cause" is satisfied by the code compiling. "`generic-metadata` exists as its own Sentry issue with its own trend" requires a shipped release and days of production data that nobody is assigned to look at. Vulnerability: high.

**c. Instrumentation that ships and is never read.** This is the modal failure for taxonomy work. The classifier lands, the buckets appear, and eighteen months later `other` and `unknown` are the new C11-31: unactionable piles nobody triages. The plan explicitly stakes its entire value on "which this change makes possible" and then exits without filing a single follow-up ticket, while naming three that should exist. Vulnerability: highest of all. This is the way this specific change most likely dies.

**d. Client-side taxonomy calcification.** Grouping rules compiled into the binary can only be improved by shipping. Worse, they fork the historical record: 0.58 events grouped one way, 0.59+ grouped another, so the trend line the AC depends on has a discontinuity at exactly the moment the instrument is installed. Vulnerability: high, unmentioned.

**e. Fixing the symptom of a general bug at one call site.** The diagnosis ("`attachStacktrace = true` makes Sentry fingerprint message events on the capturing thread's stack") is a statement about *every* message event in the app. The fix is applied to one. `attachStacktrace = true` is untouched at `Sources/AppDelegate.swift:2615`, and `sentryCaptureError` at `Sources/TerminalController.swift:857` and `:1679` still have the original defect. Vulnerability: certain, already true on the branch.

**f. Analysis by uncommitted script.** The load-bearing numbers exist only in the agent's dead context window. Vulnerability: certain.

---

### Assumption Audit

Load-bearing (plan collapses or misleads without them):

| # | Assumption | Stated? | Holds? |
|---|---|---|---|
| A1 | The 875-event sample represents the fleet's hang population | implicit | **No.** 816/875 from one user; recapture-dominated; pre-#401 regime. |
| A2 | Sentry's received events are an unbiased sample of hangs | invisible | **Probably not.** Contradicted by C11-191's local log. Worst wedges likely never transmit. |
| A3 | Post-change, enough hang events will arrive to form actionable per-cause trends | invisible | **Doubtful.** #401 caps at 1/episode, 3/hour, 15/day/user. Thin data per bucket. |
| A4 | 13 buckets is the right coarseness | argued (645-vs-13 comparison) | Plausible, but the comparison is against a strawman (top-5-frame). No middle option evaluated. |
| A5 | The cause taxonomy belongs in the client binary | invisible | **Contestable.** Sentry server-side fingerprint rules do the same job, adjustable without a release. |
| A6 | `ProcessInfo.processInfo.processName` equals the `backtrace_symbols` image name | invisible | Probably true for `c11` / `c11 DEV`. Untested at runtime; tests inject `"c11"`. Silent fleet-wide `hang.culprit` loss if it ever diverges. |
| A7 | Sentry rejects (not truncates) tag values over the limit, and 190 is safe | asserted in a code comment | Unverified, untested. |
| A8 | Someone will read the new buckets and file the follow-up tickets | invisible | **The single most fragile assumption in the document.** No owner, no date, no mechanism. |
| A9 | The original AC's Time Profiler trace is genuinely unmeetable | argued | I accept this. It is the plan's strongest section. |

Cosmetic assumptions: exact bucket names, `causeWindow = 16` / `moduleWindow = 8` (sensible, arbitrary, undefended, and no test pins the boundary behavior).

Note on A9: the plan's refutation of the ticket is actually over-argued. It leans hardest on the distribution table (the weakest evidence), when the two robust arguments stand alone: the `attachStacktrace` grouping mechanism explains the misattribution completely, and "no metadata-stack event names a `Button` c11 owns" kills the ticket outright. If the table is challenged, the plan looks shakier than it is. That is a self-inflicted wound.

---

### Blind Spots

**1. The sibling ticket.** Reviewed in the same pack, same watchdog, flatly contradictory lock-wait numbers. Never referenced.

**2. #401's effect on the plan's own data.** The plan quotes #401 in the *ticket* section ("judge recurrence by issue presence and user count") and then never applies that reasoning to its own 875-event table. `hang.recapture` is added as a tag that, post-#401, is always `"false"` because `reportedCurrentEpisode` guarantees one event per episode. Dead tag on arrival. Direct evidence the change was not reconciled against HEAD.

**3. Severity is now invisible in the Sentry issue list.** The message drops the duration by design, and `stalled_ms` moves to context, which Sentry cannot facet, alert, or sort on. A 2.0s stutter and a 604s wedge are now the same row with no way to tell them apart from the issue list. In a change whose entire purpose is making Sentry legible, this is a regression. A `hang.duration_bucket` tag is one line.

**4. The Sentry UI still shows the wrong stack.** `attachStacktrace = true` remains. The event's Stack Trace panel is the watchdog's loop; the real stack is a 24-frame string blob in the `hang` context. No symbolication, no frame navigation, no suspect commits, no in-app frame highlighting. The plan fixed grouping and left the display broken. The alternative it never considers or rejects: `SentrySDK.capture(event:)` with a synthesized `threads` payload marking the wedged main as `current: true`, which fixes grouping *and* display *and* hands Sentry's own grouper the correct input, making the hand-rolled classifier optional rather than load-bearing.

**5. Tag cardinality.** `hang.top_symbol` is unbounded: when `backtrace_symbols` cannot resolve a symbol it prints an address, so `parse` yields a per-launch `0x...` "symbol." `hang.culprit` is already at 114 distinct values by the plan's own count. Nothing caps, buckets, or monitors this.

**6. Migration and comms for the existing issues.** C11-30 and C11-31 go silent. Any alert rule, assignment, saved search, or dashboard keyed to them stops firing, and nobody is named as owner of the Sentry-side cleanup. Historical continuity across the taxonomy change is simply lost.

**7. No real-artifact smoke test.** Global CLAUDE.md is explicit: green tests are not a working product. This change is *entirely* about what a remote service receives and how it groups. Nothing verifies Sentry accepts `hang.cause`/`hang.phase`/`hang.culprit`/`hang.top_symbol` as tags, accepts the 3-element fingerprint, or renders the message as intended. This is trivially testable (tagged build, dev DSN, forced synthetic stall, open the event) and it is exactly the class of thing that fails only in the shipped bundle.

**8. Privacy / consent.** Mangled c11 symbol names now leave the machine as searchable tags. The `TelemetrySettings.enabledForCurrentLaunch` guard covers it legally, but symbol names leak unreleased feature names into a third-party index. Worth one sentence; gets none.

**9. Failure detection for the classifier itself.** If `hang.culprit` coverage silently drops from 20% to 0% (A6 breaks), or if `other`/`unknown` swells to 60%, nothing notices. No coverage metric, no threshold at which the classifier is judged to have failed.

**10. No rollback.** If the new fingerprints turn out worse than one big issue (plausible if buckets fragment across releases), there is no stated path back and no server-side override, because the taxonomy is compiled in.

---

### Challenged Decisions

**Client-side classifier over server-side fingerprint rules.** The plan never presents this as a choice. Sentry's server-side fingerprinting and grouping enhancements operate on the same event data, are editable in minutes rather than a release cycle, and can be re-applied retroactively to already-received events, which would let them reclassify the existing 875 and prove the taxonomy before shipping anything. The counterargument for client-side (the wedged stack is a context string, not a structured stacktrace, so server rules cannot see it) is real, but it is an argument for fixing the *event shape* (blind spot 4), not for compiling the taxonomy into the binary. This is the plan's biggest unexamined default.

**Explicit fingerprint with no `{{ default }}` and no release component.** All events across all releases now collapse into one permanent issue per cause. Consequence the plan does not state: the issue can only be resolved-and-regressed, never closed. The ticket's own AC language ("does not recur on the next release") is structurally unsatisfiable under the fix the plan ships. Whether permanence or per-release issues is right is a genuine design call. It should have been made explicitly.

**Coarse over medium.** The 645-groups-at-top-5-frames figure is a strawman. Nobody proposed top-5-frame fingerprinting. `cause + phase + module-of-culprit` is the obvious middle and is not evaluated. The 13-bucket answer may be right; it is not shown to be right, only better than a bad alternative.

**Dropping the duration from the message.** Correct instinct (duration is not a grouping key), wrong execution (it went to context, which is queryable by nothing). Should have gone to a bucketed tag.

**Repurposing the ticket and branch.** The honest move is to close C11-192 as invalid with the diagnosis attached, and open a new ticket for the fingerprinting work with its own AC written by someone other than the implementer. Repurposing saves an ID and costs traceability plus the independence of the acceptance criteria.

**Adding `fingerprint:`/`tags:` to the shared helpers but using them at one of three call sites.** Either the socket-error call sites have the same grouping bug and should be fixed in the same PR, or someone should state why they do not.

---

### Repo-Specific Landmines the Plan Walks Past

**Test file placement re-creates the C11-105 footgun.** The new `MainThreadHangSignatureTests` was appended to `c11Tests/MainThreadHangDetectorTests.swift`. That file lives in `c11Tests/` on disk but is a member of the **`c11LogicTests`** target (pbxproj Sources phase `37DDE3B0A6A70E75A7B2BEDF`, owned by the target named `c11LogicTests`). CLAUDE.md documents this exact disk/target mismatch as the root cause of C11-105, where a `c11Tests/`-resident file that was secretly a `c11LogicTests` member unlinked the operator's production socket. Nothing here touches sockets, so it is not dangerous today. It re-establishes the pattern the repo already got burned by, in a file whose name now lies about two of its three classes. The plan says "`MainThreadHangSignatureTests` in `c11LogicTests`," which is true of the target and misleading about the file.

**Verification leans entirely on CI.** Correct per CLAUDE.md's no-local-`xcodebuild` rule, and the plan is right to say so. But CI's `build` job is a compile-plus-logic-test gate; it cannot observe a Sentry event. The plan treats "CI green" as the end of verification for a change whose entire behavior is remote.

**Not a typing-latency path, and the plan should say so.** `describe()` runs on the watchdog thread inside `reportTelemetry`, off main, consistent with the socket/telemetry threading policy. That is correct and worth one explicit line, because a reviewer scanning "new string parsing added to the hang path" will ask.

---

### Hindsight Preview

Two years out, the likely retrospective lines:

- *"We should have known the 875 events were one user's beachball recaptured 800 times, because #401 landed the same week and said exactly that."*
- *"We should have deduped by episode before quoting percentages, and we had the flag to do it."*
- *"Why didn't we just put the wedged stack in the event's threads payload? Then Sentry grouped it for free and the UI showed the right thing."*
- *"Why didn't we just write the fingerprint rules server-side and reclassify the events we already had, instead of waiting a release to find out?"*
- *"The taxonomy shipped and nobody ever opened the `xpc-sync-wait` bucket."*
- *"The trend we were going to act on never accumulated, because the throttle we shipped one commit earlier meant three events an hour."*

Early warning signs the plan has no mechanism to detect:

1. `hang.culprit` present on a much smaller fraction of reports than the 172/875 the offline run predicted (A6 broke, or production stacks differ from the sample).
2. `other` + `unknown` exceeding ~25% of hang events.
3. Total hang events per day post-release collapsing below the level at which any bucket can trend.
4. `generic-metadata` count going to zero, which would confirm it was one user's artifact rather than a class.
5. Nobody having opened a Sentry hang issue thirty days after release. This is the one that actually predicts the failure, and it is the easiest to instrument: put a calendar reminder in the follow-up ticket.

---

### Reality Stress Test

Three likely disruptions, hitting together:

**1. #401's throttle bites harder than expected.** One event per episode, 3/hour, 15/day. Post-release volume drops by ~98% by design. Each of the 13 buckets now receives a trickle. `generic-metadata` at 5.7% of a 98%-smaller stream is a handful of events per week fleet-wide, indistinguishable from noise. The amended AC ("its own user count and trend") is technically satisfied by the issue existing with 2 users, and materially satisfied by nothing.

**2. C11-191's fix lands and removes the dominant wedge.** If the `attachSurface` mailbox deadlock really is the fleet's main hang, then post-fix the distribution shifts wildly. Because 0.58 events are grouped by watchdog stack and 0.59+ by cause, there is no way to attribute the shift to the fix versus the taxonomy change. Both tickets lose their measurement at the same moment, and each will be tempted to claim the other's improvement.

**3. The one heavy user's machine changes.** 816 of 875 events came from one install. That user upgrades, reboots, changes hardware, or stops hitting their bug. Fleet hang volume falls off a cliff for reasons unrelated to any code change, and every trend in the new taxonomy inverts. Nobody can tell.

All three together: the release ships, hang events become rare, the new issues each hold a dozen events, the pre-change history is not comparable, and the rational conclusion available to a future reader is "hangs got better," which may or may not be true and cannot be checked. The instrument installed to make hangs actionable arrives at the moment the data goes quiet.

---

### The Uncomfortable Truths

**The plan is right, and that is what makes it dangerous.** The diagnosis is genuinely good work: the `attachStacktrace` grouping mechanism is a real and non-obvious finding, and killing the Time Profiler AC is the correct call. A correct diagnosis is being used to license three things that would not survive on their own: a scope swap inside someone else's ticket ID, acceptance criteria written by the implementer, and a distribution table that does not support the weight put on it. Reviewers who nod at the diagnosis will nod at the rest.

**The document is a PR description wearing a plan's clothes.** PR #402 is open. The commits exist. "Judge whether this is an executable implementation plan" has one honest answer: it is not one, and it was never going to be, because the work was done first. If the workflow produced a plan artifact after the implementation, the workflow has a hole, and reviewing this document as a plan launders that hole.

**Nobody is going to look at these buckets.** The plan lists three follow-ups, files zero tickets, and names no owner or date. The entire justification for the change is "which this change makes possible." Possibility is not a deliverable. The single highest-leverage edit to this plan is one line: "file C11-19x for `xpc-sync-wait` and C11-19y for `runloop-idle` before this PR merges."

**Five point seven percent is doing a lot of work.** The plan uses 50/875 (or 24/875 for the demangler symbols specifically) to declare the ticket's premise dead. If that sample is biased, and there is direct evidence from the sibling ticket that it is, then the refutation is weaker than presented. The refutation does not need the table at all. Leading with it was a choice, and it is the one a hostile reviewer attacks first.

**"No claim that a metadata hang was fixed" is honest, and it means C11-192 closes without fixing a hang.** That may be entirely correct. It should be said out loud to whoever tracks the board, rather than absorbed into an amended AC that reads as if the ticket succeeded.

---

### Hard Questions for the Plan Author

1. The work is committed and PR #402 is open. What, precisely, is an implementation agent on `c11-192-button-metadata` supposed to do with this document? If the answer is "nothing, it is a write-up," say so and route it to code review instead.
2. Re-run the classification with recaptures collapsed to one row per episode, and per-user rather than per-event. What does the table look like? Does `generic-metadata` survive as a distinct class, or was it one user's one afternoon? **Currently unknown, and this is the number the whole plan rests on.**
3. Why does C11-191 find `__ulock_wait2` in 45% of 20778 local captures while this plan finds `lock-wait` in 1.1% of 875 Sentry events? Pick one: Sentry is a biased sensor, or one of the two classifications is wrong. **"We do not know" is the current answer and it is a problem**, because if it is bias then the amended AC's trend is measured through the same bias.
4. Where is the classifier script and the 875-event dump? Neither is committed. How does a reviewer reproduce "13 issues from 1," "172 reports naming 114 distinct symbols," or any row of the table?
5. Why is the taxonomy compiled into the client instead of expressed as Sentry server-side fingerprint rules, which would have let you reclassify the 875 events you already have and validate the buckets before shipping anything?
6. Why not fix the event shape (synthesize a `threads` payload with the wedged main as `current: true`) so Sentry groups correctly on its own and the UI displays the right stack? Was this considered and rejected, or not considered?
7. `attachStacktrace = true` still stands at `AppDelegate.swift:2615`, and `sentryCaptureError` at `TerminalController.swift:857` and `:1679` still group by the capturing thread. Do those have the same bug? If yes, why are they not in this PR? If no, why not?
8. The message no longer carries the duration and `stalled_ms` sits in context, which Sentry cannot facet, alert, or sort on. How does anyone distinguish a 2s stutter from a 604s wedge in the issue list? Why is there no `hang.duration_bucket` tag?
9. Post-#401, `reportedCurrentEpisode` sends at most one event per episode. What is `hang.recapture` for now, given it will always be `"false"`?
10. With 1 event per episode, 3/hour, 15/day, what is the projected weekly event count per bucket? At what count does a bucket's trend become actionable, and do you expect to reach it? **If the answer is "we do not know," the amended AC has no numerator.**
11. An explicit fingerprint with no `{{ default }}` and no release component makes each cause a permanent issue that can only regress, never close. Is that intended? How does anyone answer "did it recur on the next release" against a permanent issue?
12. What happens to C11-30 and C11-31? Who closes them, who audits the alert rules and assignments pointed at them, and how is the pre-change history reconciled with the post-change taxonomy?
13. `ownModule` is `ProcessInfo.processInfo.processName`, matched against a `backtrace_symbols` image name. What verifies these are equal in a signed release build? What alarms if `hang.culprit` coverage drops to zero fleet-wide?
14. `hang.top_symbol` is unbounded: unresolvable frames yield a per-launch `0x...` string. What caps this tag's cardinality?
15. The 190-character tag cap rests on a code comment asserting Sentry rejects rather than truncates. What verifies that, and where is the test for the truncation path?
16. `causeWindow = 16` and `moduleWindow = 8`. Where did those numbers come from, and what test pins the behavior at the boundary?
17. What is the failure threshold for the classifier? If `other` plus `unknown` is 40% of hang events after release, is that a bug to fix or the accepted floor? Who decides, and when do they look?
18. Which single event, on which real tagged build, has been observed arriving in Sentry with the new fingerprint and tags rendered as intended? If none: this change's entire behavior is remote, and the repo's own rule is that green tests are not a working product.
19. The plan names three follow-up classes and files zero tickets. Who files them, by when, and what happens to this PR if they are not filed?
20. Should C11-192 be closed as invalid with a new ticket opened for the fingerprinting work, so the acceptance criteria are not written by the agent that will be graded against them, and so the branch name stops lying?

---

### Verdict

**Approve the code direction. Reject the document as a plan. Reject the self-authored acceptance criteria.**

Minimum bar before merge, in priority order:

1. Re-run the classification deduped by episode and weighted per user, and commit the script plus the event dump as artifacts under `notes/`. If the table changes materially, the follow-up sizing and the "premise does not hold" argument both need rewriting.
2. Add a `hang.duration_bucket` tag. Severity must be visible in the issue list.
3. File the three follow-up tickets, or state in the PR why they are deliberately not being filed.
4. One real-artifact smoke: tagged build, forced stall, observe the event in Sentry with its fingerprint, tags, and title. Screenshot it.
5. Have someone other than the implementer write the acceptance criteria, with a named owner and a date for the Sentry read.
6. Answer question 3 (the C11-191 contradiction) in writing. If Sentry is a biased sensor, that belongs in the plan, in the follow-up tickets, and in CLAUDE.md, because every future hang ticket will be reasoned from this same biased stream.

Optional but cheap and high-value: move `MainThreadHangSignatureTests` into its own file so `c11Tests/MainThreadHangDetectorTests.swift` stops accumulating classes it is not named for, and note in the PR that the file is a `c11LogicTests` member despite its directory, so the next reader does not re-derive C11-105 the hard way.
