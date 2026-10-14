# Trident Synthesis — Standard/Analytical Reviews of C11-192

- **Plan:** `.lattice/plans/task_01KZ733HRN64WS7YSVCTT6WWRP.md`
- **Ticket:** C11-192 (c11), branch `c11-192-button-metadata`, PR #402 (open)
- **Reviews synthesized:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
- **Synthesized:** 2026-08-04

---

## 0. Executive Summary

1. **Unanimous on the core judgment.** All three models accept the plan's central finding as correct and high-value: Sentry issue C11-31 is not a `Button.body` generic-metadata bug, it is a *grouping artifact*. `attachStacktrace = true` makes the Cocoa SDK fingerprint message events on the *capturing* thread's stack, and the capturing thread is always `com.stage11.c11.hang-monitor`, whose stack is byte-identical every time. Every main-thread hang therefore collapses into one issue titled after whichever event was latest. All three call the pivot from view-tree surgery to cause-aware grouping the right move.

2. **Unanimous praise for invalidating the assigned premise.** Every reviewer independently flags the author's willingness to pull all 875 events, disprove the ticket, and refuse the unfalsifiable `AnyView` fix as the highest-value judgment in the document.

3. **Verdict splits 2–1 toward "needs revision."** Claude and Codex both land on *needs revision, not rethinking*: the engineering is sound, the evidentiary framing and the plan-as-document are not. Gemini lands on *ready to execute*. The split correlates strongly with review depth (Claude ~470 lines, Codex ~86, Gemini ~40) and with what each model noticed about the plan's status as a document.

4. **Three findings are raised independently by all three models** and should be treated as highest-confidence: (a) the `attachStacktrace = true` interaction with explicit fingerprinting is unverified and potentially load-bearing; (b) `hang.culprit` / `hang.top_symbol` are unbounded, high-cardinality strings pushed into indexed Sentry tags; (c) nothing in the verification proves the telemetry actually reaches Sentry as intended, only that the classifier is a pure function.

5. **The single most consequential unique finding is Claude's:** the distribution table that justifies the entire pivot is computed over the wrong unit. The 875 events are pre-#401 *recaptures*, one user contributed 816, and long episodes re-sent the same wedge every 5 seconds. "63.9% SwiftUI graph work / 5.7% generic metadata" is a distribution over duration-weighted samples on one machine, not over episodes. Post-#401 the monitor sends one event per episode, so the shipped classifier will produce a different, possibly inverted ranking. Neither Codex nor Gemini caught this.

6. **The second most consequential unique finding, also Claude's:** the classifier's output contradicts the sibling ticket. C11-192 puts `lock-wait` at 10 events (1.1%); C11-191 reports 9,433 local captures wedged on `__ulock_wait2` with `GhosttyNSView.attachSurface` at frame 1, one episode running 13h58m. Both cannot describe the same population. The reconciliations are all consequential, including the possibility that the *worst* hangs never flush to Sentry at all.

7. **Net recommendation:** hold PR #402 on a small, concrete set of evidence-and-durability fixes rather than a redesign. The classifier itself survives all three reviews largely intact.

---

## 1. Where the Models Agree (highest-confidence findings)

### 1.1 Agreed unanimously (3/3)

1. **The diagnosis is correct and the pivot is justified.** Fixing the broken instrument before chasing the reading is the right sequencing. No reviewer argues for keeping the original view-tree work.
   - Claude: "the single most valuable thing in this document."
   - Codex: "strong enough to reject the ticket's original premise."
   - Gemini: "exactly the right move."

2. **Coarse classifier grouping beats top-frame fingerprinting, and the plan defends it well.** The 645-groups / 607-singletons measurement over the real corpus is cited approvingly by all three as the correct way to foreclose the obvious objection.

3. **The pure-function decomposition is the right seam.** A classifier with no AppKit or SDK dependency is what makes both the offline 875-stack replay and `c11LogicTests` membership possible, and it keeps classification off the capture/suspend path. All three call this out as a strength.

4. **`hang.culprit` / `hang.top_symbol` as indexed Sentry tags is a problem.** All three flag it, with different framings:
   - Gemini: hard length limit (~200 chars); Swift mangled/demangled names exceed it; move them to event context/`extra`.
   - Codex: length *plus* cardinality *plus* sanitation; strip paths/newlines/addresses, use a sentinel for unknown, prefer context for unbounded detail.
   - Claude: notes the code already caps at 190 chars (a good catch not mentioned in the plan) but asks whether it has been verified end-to-end against real ingestion, since a rejected tag fails silently.

5. **The `attachStacktrace = true` interaction is unresolved.** All three raise it, and this is the finding where the three framings compose into something larger than any one of them (see §3.1).

6. **Offline replay + unit tests do not constitute validation of the telemetry integration.** All three note that `swiftc` compilation and parser unit tests prove the classifier is a function, not that Sentry honors `scope.setFingerprint`, that tags survive ingestion, or that new issues actually separate. Claude explicitly invokes the repo's own "green tests ≠ working product" hard rule.

7. **The generic-metadata question is deferred to a ticket that does not exist.** All three note the plan promises a future issue and files none. Gemini's Q3 and Claude's item 10 and Codex's "split the work" alternative are the same concern.

### 1.2 Agreed by two of three (2/3)

8. **The acceptance amendment needs a formal decision, not a paragraph.** (Claude, Codex.) Codex frames it as requiring *owner approval* to re-scope or split, and warns an agent could implement all four steps and still fail the ticket's stated acceptance. Claude frames it as an identity problem across three surfaces (ticket title, branch name, board searchability) and adds that the amended criterion is unfalsifiable as written: "an issue exists and has a trend" cannot come back red.

9. **The fingerprint array is a permanent, unversioned schema and needs a stability contract.** (Claude, Codex.) Codex asks for an explicit version component in the fingerprint. Claude works out the failure mode concretely: adding a seventh `phaseRule` next month silently migrates existing traffic from `["main-thread-hang", "swiftui-update"]` to `[..., "swiftui-update", "new-phase"]`, creating a new issue and stranding the old trend, which directly breaks an acceptance criterion that is *entirely* about trends being readable over time.

10. **The verification is not reproducible by anyone else.** (Claude, Codex.) No corpus path, no committed replay harness, no `swiftc` invocation, no redacted fixture set, no Sentry query. Codex wants checked-in redacted fixtures with expected signatures. Claude wants the replay harness committed so the 875-stack verification becomes a re-runnable regression gate rather than a one-time assertion.

11. **Post-release success is underspecified.** (Claude, Codex.) No observation window, no threshold, no named owner, no Sentry query. Claude proposes a concrete falsifiable replacement: after the next release, pull N days of hang events, require ≥90% classify into a named cause (not `other`/`unknown`), and require `generic-metadata` and `swiftui-update/*` to be distinct issues with independent counts.

---

## 2. Where the Models Diverge (the disagreement is signal)

### 2.1 The readiness verdict itself

| Model | Verdict | Framing |
|---|---|---|
| Claude | Needs revision | "Small, targeted revisions, not a rethink. The engineering is sound; the evidentiary framing and the plan-as-document are not." |
| Codex | Needs revision | "Retain the corrected diagnosis and observability goal, then make the telemetry contract, Sentry grouping semantics, target membership, and release-validation path specific." |
| Gemini | Ready to execute | "The shift in scope is fully justified by the data." |

**Reading the split:** Gemini's verdict rests entirely on the *decision* being right, which all three agree it is. Claude and Codex both go on to evaluate the *artifact* (as a document, as evidence, as a durable contract) and find it wanting on grounds Gemini never examines. This is not a genuine three-way disagreement about the change; it is a two-way agreement plus a shallower read. **Weight the 2/3 "needs revision" accordingly.**

### 2.2 Is this document even a plan?

Sharpest divergence in the pack, and it turns on a fact only one model surfaced.

1. **Claude:** "This is not a plan. It is a retrospective rationale written after the work landed." Evidence: the branch exists, both commits exist, PR #402 is open, the Verification section is past tense, and the code contains items the "Work" section omits (the 190-char tag cap, the `hang.recapture` tag). Consequence: a fresh implementer handed this cold would produce *a* classifier, not *this* classifier, and since the bucket names **are the Sentry fingerprint**, a different taxonomy is a different set of permanent issue groups.
2. **Codex:** treats it as a forward-looking plan and finds it under-specified for that job: no exact API signatures, no input grammar for `backtrace_symbols()` lines, no finite cause/phase enums, no ordered precedence table, no fingerprint array. "'SwiftUI graph work' and 'host phase' are too broad for two implementers to make the same classifier."
3. **Gemini:** treats it as complete and executable, and does not register that the work has already shipped.

**Synthesis:** Claude and Codex reach the same practical conclusion (a fresh agent cannot reproduce this from the document) by opposite routes: Claude because the document is a post-hoc rationale, Codex because it is an under-specified prospective spec. The reproducibility gap is real either way. Whether the fix is "write the spec" or "relabel this as a PR description" is Claude's Q16, and it is a process question worth answering explicitly.

### 2.3 Test-target membership: three different readings of the same fact

1. **Gemini:** a strength. "By extracting the signature logic into a pure type, it can be tested exhaustively in `c11LogicTests` ... perfectly matching the local development guidelines in `CLAUDE.md`."
2. **Codex:** unplanned risk. Existing `MainThreadHangDetectorTests.swift` lives in `c11Tests` while the plan specifies `c11LogicTests`; the agent needs explicit `pbxproj` membership instructions or the tests silently land in the wrong target.
3. **Claude:** already resolved in code, but with a caveat worth preserving. The code appends the new class to `c11Tests/MainThreadHangDetectorTests.swift` on disk while correctly making it a member of the `c11LogicTests` *target*. Claude notes this is exactly the on-disk/target split that caused the C11-105 socket-unlink incident, so it is substantively fine but worth a comment.

**Synthesis:** Codex's risk is real in the abstract and already discharged in the shipped code. Claude's C11-105 callback is the durable insight: the on-disk/target mismatch is a known local footgun in this repo and deserves a note so nobody "tidies" the file into the wrong target later.

### 2.4 Fixtures: strength or gap?

1. **Gemini:** listed under Key Strengths. "Utilizing verbatim frames from production reports ... ensures the parser actually handles edge cases (like `c11 DEV` module names)."
2. **Codex:** listed under Weaknesses. "Classifier fixtures are not reproducible from the plan ... needs a checked-in, redacted fixture set, the selected representative captures, and expected signatures."
3. **Claude:** effectively both. Praises the parser realism (keying on the `0x` load address rather than whitespace, because image names contain spaces, and stripping the `+ <offset>` suffix that would otherwise churn the grouping key every build) while flagging the *absence* of the one fixture that matters most (see §3.2).

**Synthesis:** Gemini is evaluating fixture *quality*, Codex fixture *provenance*. Both are right. The fixtures that exist are good; the corpus behind them is unreachable to anyone else.

### 2.5 How severe is deferring the generic-metadata fix?

1. **Gemini:** a real cost. "Discarding the original criteria means the 50 real generic metadata hangs are left untouched for now ... it relies on a future unknown ticket."
2. **Claude:** a bookkeeping failure rather than an engineering one. The deferral is correct; not filing the ticket is the defect. "Prose in a merged plan is where findings go to die."
3. **Codex:** a scoping failure. Wants the ticket formally split so acceptance criteria stay honest.

**Note:** Gemini's phrasing "the 50 real generic metadata hangs" inherits the number-discipline problem Claude identifies in §3.3. The 50 is a classifier-bucket count over recaptures, and the plan itself gives 24 as the count under a stricter definition.

---

## 3. Unique Insights (surfaced by exactly one model)

### 3.1 Claude only

1. **The fix stops one step short of the bug it diagnosed.** The change fixes *grouping* (explicit fingerprint) and *titling* (message names the cause) but leaves `attachStacktrace = true` untouched. The new `generic-metadata` issue will still render the watchdog's stack in Sentry's primary stack-trace panel, with the real 24-frame capture demoted to a context blob. The next person to open that issue walks into the identical trap that produced C11-192. `Sources/AppDelegate.swift:2623` already has an unused `beforeSend` hook: the seam to swap or strip the misleading thread stack is sitting there. Claude calls this "the cheapest high-value item in the change."
   - *This composes with Gemini's independent worry (§2, item 5) that an explicit fingerprint may not fully override grouping while `attachStacktrace` is on, and with Codex's demand for a real ingestion check. Together they are one blocker with three faces: display, grouping, and verification.*

2. **The corpus is the wrong unit of analysis.** #401 (merged, `42ce4c919`) added a per-episode Sentry throttle. The 875 events predate it and are dominated by 5-second recaptures of long episodes. The percentages therefore measure *seconds spent wedged, sampled, weighted by one machine*, not how often each cause fires. A single 14-hour SwiftUI-graph beachball on one Mac would produce ~10,000 recaptures and single-handedly manufacture the "63.9%" headline. The plan states the 816/875 fact and then reasons from the uncorrected table anyway. Recomputing per-episode is minutes of work over a corpus already in hand and may reorder the entire follow-up backlog.

3. **Unreconciled evidence conflict with C11-191.** `lock-wait` at 1.1% (10 events) versus C11-191's 9,413 captures wedged on `attachSurface` / `__ulock_wait2` with a 13h58m episode. Three possible reconciliations, all consequential: the 816-event user swamps everything; the deadlock never flushed to Sentry (meaning **the worst hangs are systematically invisible to Sentry**, a finding bigger than either ticket); or the classifier mis-buckets those stacks. Claude's proposed hard requirement: add a test fixture from a verbatim C11-191 capture out of the operator's 151 MB `~/Library/Logs/c11/hang.log` and assert it classifies as `lock-wait`. "The single most load-bearing test missing from this change."

4. **Number discipline slipped.** The generic-metadata share appears as **50 (5.7%)** in the table, **24 (2.7%)** two lines later, and **58** in the commit message for `93e655929`. The 50/24 gap is explained (classifier bucket vs literal symbol presence); the 58 matches neither and is now in the permanent git record. When the entire justification for amending acceptance is "here are the counts," the counts must be consistent.

5. **`culprit` scans all 96 captured frames but only 24 ship in the event context.** `hang.culprit` can therefore name a symbol appearing nowhere in the visible stack, leaving an operator unable to verify the classification. Conversely, Claude credits an unstated property of the implementation: `causeWindow = 16` and `moduleWindow = 8` both sit inside the shipped `prefix(24)`, making classification auditable from the event. That property should be written down before someone "optimizes" the context to 10 frames.

6. **Server-side Sentry grouping rules were never considered.** Fingerprint rules / stack-trace rules would require zero client code, apply **retroactively to the existing 875 events**, and be tunable without a release. Claude still leans client-side (versioned with the binary, testable in CI, works on `extra.stack`) but flags that a real advantage was silently forgone.

7. **Sequencing against C11-191.** If `attachSurface` deadlocks main for 14 hours at a stretch, fixing it first removes the largest source of recapture volume and makes the remaining distribution far more legible. Claude concludes it probably does not change the answer, but notes the two plans were clearly written without reading each other, and the unreconciled `lock-wait` numbers are the visible evidence.

8. **`other` (15.2%) will become the second-largest issue and carries no actionable signal.** No phase, no refinement path, no stated triage plan. Risks becoming the bucket everyone learns to ignore.

9. **`runloop-idle` ships reporting on a thread that is idle.** The plan raises the question and the code answers it by shipping. Ten events is negligible, but under the #401 per-episode budget these consume the same quota as real wedges.

10. **Ticket identity is wrong in three places** (title, branch `c11-192-button-metadata`, board searchability) and the 604-second XPC wedge, described in the plan as a "real wedge class, no ticket," still has no ticket despite arguably being more severe than the ticket this plan is attached to.

### 3.2 Codex only

11. **Privacy and consent policy for symbol-derived telemetry.** Before forwarding symbol-derived fields as indexed tags, the plan needs a bounded field policy: are symbol names permitted telemetry under the existing consent policy, especially when a frame embeds a local path or a non-c11 image name? No other reviewer raises privacy at all.

12. **Input grammar for degenerate frames.** The parser contract must specify handling for unsymbolicated addresses, truncation, and non-c11 frames, not only the `c11 DEV` space-in-image-name case the plan cites.

13. **Explicit ownership gate on the acceptance amendment.** Codex is alone in framing re-scoping as requiring *owner approval* rather than being the plan author's call to make unilaterally. "If C11-192 must retain its current acceptance, this plan should be a prerequisite ticket rather than its implementation plan."

14. **Does the outbound event budget survive the refactor?** Is it still one event per hang episode after the change, and is the full stack still retained locally while only the first 24 frames are sent?

15. **Sentinel values for unknown.** Tag policy should define an explicit unknown sentinel rather than letting absent tags mean two different things.

16. **Framing the deliverable difference cleanly:** "grouping reports is a different deliverable from fixing the existing performance issue." The cleanest one-line statement of the scoping problem in the pack.

### 3.3 Gemini only

17. **The concrete tags-vs-contexts split.** Gemini is the only reviewer to propose the specific remedy: keep bounded categories (`hang.cause`, `hang.phase`) as indexed tags, move unbounded strings (`hang.top_symbol`, `hang.culprit`) into event context/`extra`. Claude's 190-char cap and Codex's sanitation policy both address symptoms; Gemini addresses the structure. **This is the most actionable single suggestion in the shallowest review.**

18. **The "one PR" alternative, explicitly rejected.** Fixing telemetry grouping *and* the 50 generic-metadata hangs together would bloat the PR, complicate review, and mix infrastructure changes with speculative view-tree optimization. Gemini is the only reviewer to consider and dismiss this, and the reasoning is sound.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews. Attribution in brackets: **[C]** Claude, **[X]** Codex, **[G]** Gemini.

### A. Evidence and statistics

1. **Are the 875 events deduplicated by episode?** #401 throttles to one event per episode, but this corpus predates it and one user contributed 816. Does the 63.9% / 5.7% ranking survive a per-episode recount (dedupe by user + episode, or drop `recapture == true`)? Have you run that recount? **[C]**
2. **How do you reconcile `lock-wait` at 1.1% with C11-191's 9,413 captures on `attachSurface` / `__ulock_wait2`?** Is the deadlock absent from Sentry (never recovered, never flushed), swamped by the 816-event user, or mis-bucketed by the classifier? **[C]**
3. **Has a verbatim C11-191 stack been run through `describe()`?** Reading the rules it should land on `lock-wait`, and that is the one classification we can independently prove correct, but there is no fixture for it. **[C]**
4. **Which number is right: 50, 24, or 58?** The plan gives 50 (classifier bucket) and 24 (literal demangler symbols); commit `93e655929` says 58. Where does 58 come from? **[C]**
5. **Where does the 875-event corpus live, and is the replay reproducible?** Can a future agent re-run the classifier over a fresh 30-day pull, or does that mean rebuilding the pipeline from scratch? **[C, X]**
6. **What are the representative redacted `0.58.0+116` fixtures and expected signatures for each classifier rule**, including malformed and unsymbolicated frames? **[X]**

### B. Sentry semantics and the `attachStacktrace` question

7. **Why leave `attachStacktrace = true`?** Was swapping or stripping the displayed stack in the existing `beforeSend` at `Sources/AppDelegate.swift:2623` considered and rejected, or not considered? New titles name the cause, but the stack panel will still show the watchdog: the exact thing that produced this ticket. **[C]**
8. **Has it been verified that an explicit fingerprint fully overrides the Cocoa SDK's default grouping when `attachStacktrace = true`?** Or might the native layer still fold the capturing thread's stack into its grouping heuristic? **[G, C]**
9. **How will CI or release staging assert that `scope.setFingerprint` and the tags actually reach Sentry**, rather than only testing the pure parser? **[X, C, G]**
10. **Was server-side Sentry fingerprint / stack-trace rule configuration considered?** It requires no client code, applies retroactively to the existing 875 events, and is tunable without a release. What made client-side the better call? **[C]**

### C. Telemetry contract and schema durability

11. **Which of `cause`, `phase`, `culprit`, `top_symbol` should be indexed tags versus event-context fields?** Given Sentry's tag length limit and the cardinality of 114 distinct culprit symbols, should the unbounded ones move to `extra` while bounded categories stay as tags? **[G, X, C]**
12. **What are the exact max length, normalization, path/newline stripping, and unknown-sentinel rules for each field?** **[X]**
13. **What is the fingerprint's stability contract?** When someone adds a seventh `phaseRule` next month, events that grouped as `swiftui-update` start grouping as `swiftui-update/new-phase`: new issue, orphaned trend, against an acceptance criterion that is entirely about trends. Acceptable, or should the fingerprint carry a version segment? **[C, X]**
14. **What are the exact `MainThreadHangSignature` enums, parsing rules, and precedence ordering?** A compact decision table would let two implementers produce the same classifier. **[X]**
15. **Has `hang.culprit` been checked end-to-end against Sentry's tag-value rules?** The 190-char cap is in, but mangled Swift symbols can contain characters Sentry treats specially, and a rejected tag fails silently. **[C]**
16. **Are symbol names permitted telemetry under the existing consent/privacy policy**, especially where a frame embeds a local path or non-c11 image name? **[X]**
17. **Does the outbound Sentry budget remain one event per hang episode after the refactor**, and is the full local stack still retained while only the first 24 frames are sent? **[X]**
18. **`culprit` scans all 96 captured frames but only 24 ship in the context.** How does an operator verify a `hang.culprit` naming a frame they cannot see? **[C]**

### D. Scope, acceptance, and bookkeeping

19. **Has the ticket owner approved changing C11-192 from a performance fix to telemetry regrouping**, or should this be split into a new diagnostic ticket with C11-192 left open? **[X, C]**
20. **What is the concrete pass/fail for the amended acceptance?** "Groups by cause and has a trend" cannot come back red. What observation window, what Sentry query, what threshold, who checks? **[C, X]**
21. **Should C11-192 be retitled or closed-as-invalid?** Its current title describes a bug the plan argues does not exist, and `c11-192-button-metadata` compounds it. **[C]**
22. **Will you file the generic-metadata ticket now, or wait for the new telemetry to prove a sustained trend?** **[G, C, X]**
23. **Should the three follow-ups be filed now as real Lattice tickets?** The 604-second synchronous XPC wedge in particular sounds more severe than the ticket this plan is attached to, and currently exists only as a bullet. **[C]**
24. **If the original Time Profiler acceptance stands, what exact user flow reproduces the generic-metadata hang and who captures the before/after trace?** **[X]**

### E. Design decisions and process

25. **What happens to `other` (15.2%)?** It will be the second-largest issue on the project and carries no actionable signal. Triage plan, or accepted dumping ground? **[C]**
26. **Should `runloop-idle` report at all?** The plan raises the question; the code ships it reporting. Under the #401 budget these consume the same quota as real wedges. **[C]**
27. **Why does `[cause, phase]` beat `[cause, phase, culprit]` as the fingerprint?** Culprit is the highest-signal field (114 distinct values over 172 reports) and it never drives grouping. The trade is probably right, but it should be stated rather than implied. **[C]**
28. **Which target will the new tests join, and what exact `pbxproj` membership change is required?** Note the existing on-disk/target split (`c11Tests/` on disk, `c11LogicTests` target) is the same pattern behind the C11-105 socket-unlink incident. **[X, C]**
29. **Was this document written before or after the implementation?** It reads as retrospective: past-tense verification, PR link at the bottom, code containing items the "Work" section omits. If the review process expects a pre-implementation plan, that difference should be named rather than blurred. **[C]**

---

## 5. Consolidated Readiness Verdict

### 5.1 Synthesized position

**NEEDS REVISION.** Small, targeted, evidence-and-durability work. Not a rethink, and not a redesign of the classifier.

Two of three reviewers land here independently; the third's "ready" verdict rests on the decision being right, which is not in dispute, and does not survive contact with the findings the other two surfaced. The classifier's *design* passes all three reviews. What fails is the *evidence* it was calibrated on, the *durability* of the fingerprint schema, and the *absence of any proof it works against real Sentry*.

### 5.2 Blockers before merging PR #402

Ranked by how much damage each does if shipped as-is.

1. **Recompute the cause distribution per episode** (dedupe by user + episode, or exclude `recapture == true`) and correct the table. The follow-up backlog ordering, the "64% is SwiftUI graph work" headline, and the implicit deprioritization of `lock-wait` all rest on a duration-weighted sample from one machine. Minutes of work over a corpus already in hand. **[C]**
2. **Add a `lock-wait` fixture from a verbatim C11-191 `attachSurface` / `__ulock_wait2` capture** out of the operator's `hang.log` and assert the classification. If it does not come out `lock-wait`, that is a bug, not a fixture problem. This is the only classification we can independently prove correct, and the classifier is about to become the input to future prioritization. **[C]**
3. **Real-artifact verification against production Sentry.** Tagged build, force a hang, confirm in the Sentry UI that the event carries the explicit fingerprint, that all four tags survive ingestion, and that a second hang with a different cause lands in a *different* issue. Screenshot it. This is the repo's own "green tests ≠ working product" hard rule, and it simultaneously answers the `attachStacktrace` override question. **[C, X, G]**
4. **Resolve the tags-vs-context split** for `hang.culprit` / `hang.top_symbol`, with a stated length/normalization/sentinel policy. All three reviewers flagged this; Gemini's structural fix (bounded categories as tags, unbounded strings in context) is the cleanest remedy. **[G, X, C]**
5. **Add a fingerprint-stability note in source above `causeRules` / `phaseRules`:** these strings are a wire format, adding a phase splits an existing issue, Sentry issue merging is the migration tool. Consider a `main-thread-hang.v1` version segment. **[C, X]**
6. **Reconcile the 50 / 24 / 58 discrepancy** and correct the record. **[C]**
7. **Get an explicit decision on the acceptance amendment** (re-scope, retitle, or split into a prerequisite ticket), and replace the unfalsifiable criterion with a checkable one: after the next release, pull N days of hang events, require ≥90% to classify into a named cause, and require `generic-metadata` and `swiftui-update/*` to be distinct issues with independent counts. **[X, C]**

### 5.3 Strongly recommended, same change or immediate follow-up

8. **Use the existing `beforeSend` at `Sources/AppDelegate.swift:2623`** to stop shipping the watchdog's stack as the displayed stack on `category: "hang"` events. Cheapest high-value item in the change, and without it the next audit reads the watchdog stack again and files C11-2xx against another phantom. **[C]**
9. **Commit the offline replay harness** plus a redacted fixture set so the 875-stack verification becomes a re-runnable regression gate. **[C, X]**
10. **File the follow-ups as real Lattice tickets:** the 604s synchronous XPC wedge, the `hosting-begin-transaction` vs `hosting-layout` split, `runloop-idle`, and the "is generic-metadata real" ticket the plan promises. **[C, X, G]**
11. **Decide `runloop-idle` reporting in this change** rather than shipping the open question. **[C]**
12. **Retitle C11-192** (or close-as-invalid and re-open under a new ID) so the board reflects what shipped. **[C]**
13. **Confirm the per-episode event budget survives the refactor.** **[X]**

### 5.4 Explicitly not blockers

14. Branch name (`c11-192-button-metadata`). Cosmetic, though it is the string future searches will hit.
15. Plan/implementation drift (the omitted 190-char cap and `hang.recapture` tag). Substantively fine.
16. `other` bucket refinement. Worth a stated position, not worth holding the PR.
17. Test-file on-disk location. Correct as shipped; worth a comment given C11-105.

### 5.5 What the pack agrees is genuinely good, and should not be lost in revision

18. The root-cause finding is first-rate and mechanistically complete, including the verification that every event's `current: true` thread is the watchdog.
19. The willingness to invalidate the assigned premise rather than ship an unfalsifiable `AnyView` fix is the highest-value judgment in the document.
20. The 645-groups-vs-13 argument is empirically grounded on the real corpus and forecloses the obvious objection before anyone raises it.
21. The pure-function decomposition and the offline 875-stack replay are a validation technique worth reusing on future telemetry work.
22. The parser realism (keying on the `0x` load address because image names contain spaces; stripping the `+ <offset>` suffix that would otherwise churn the grouping key every build) is the kind of detail that only comes from having run the thing over real input.
23. Keeping `causeWindow = 16` and `moduleWindow = 8` inside the shipped `prefix(24)` makes every classification auditable from the event as displayed. Write this property down before someone optimizes the context to 10 frames.

---

## 6. Meta-observation on the Trident

1. Review depth varied by roughly an order of magnitude (Claude ~470 lines, Codex ~86, Gemini ~40), and verdict severity tracked it exactly. The deepest review found the two most consequential problems (wrong unit of analysis, C11-191 contradiction); neither of the other two came close to them.
2. Depth was not the whole story. The shallowest review produced the single most actionable structural fix in the pack (tags-vs-contexts). Breadth of *perspective* still paid, even at low depth.
3. Codex was the only reviewer to raise privacy/consent for symbol-derived telemetry and the only one to frame re-scoping as requiring owner approval rather than author discretion. Both are governance concerns the other two models never entered.
4. The one fact that most changed a verdict was whether the reviewer noticed PR #402 was already open. Claude did and reframed the entire document as retrospective. Gemini did not and evaluated it as a forward plan ready to execute.
