# Action-Ready Synthesis: c11-192-plan

## Verdict

**revise-then-proceed**

Reviewer verdicts diverge sharply, and the divergence is documented here rather than averaged away:

| Review | Verdict |
|---|---|
| standard-claude | needs revision (small, targeted) |
| standard-codex | needs revision |
| standard-gemini | **ready to execute** |
| adversarial-claude | approve code direction; **reject the document as a plan**; reject the self-authored acceptance |
| adversarial-codex | **do not implement as C11-192 yet** |
| adversarial-gemini | **reject** — "a won't-fix disguised as an observability improvement" |
| evolutionary-claude | correct pivot; fold five items in before merge |
| evolutionary-codex | not yet an executable plan |
| evolutionary-gemini | **brilliant, ship as planned** |

Seven of nine say the plan needs revision or worse; two say ship. Per the cautious-bias rule the verdict follows the majority. It is *not* `rework-then-rereview` because the engineering direction (fix the instrument before chasing the reading) draws explicit support from six of the nine, including two of three adversaries. Only adversarial-gemini wants a full rethink, and its central premise — that the metadata hang is a real unfixed 10s beachball being dodged — is directly contested by standard-claude, standard-codex, standard-gemini, evolutionary-claude and evolutionary-codex, all of whom accept the refutation as sound. That dissent is preserved verbatim under **S2**.

The revisions below target the `# PLAN (agent:c11-192, 2026-08-04)` section only.

---

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: The scope change is unrecorded and unauthorized, and the ticket/branch identity now contradicts the work**
  - Where in the plan: `## Amended acceptance` ("The original acceptance ... cannot be met ... Proposed instead"), plus the ticket title carried at the top of the file and the branch name `c11-192-button-metadata`.
  - Problem: The plan converts C11-192 from "remove a proven generic-metadata layout stall, evidenced by a Time Profiler trace" into "make hang reports separable by cause," and rewrites its own acceptance criteria from inside its own plan. No decision record, no owner sign-off, no disposition for the original question. The ticket title, the branch name, and the PR now describe three different things; a future search for "did we ever fix the Button hang" lands on a ticket that did not fix it.
  - Revision: Add an explicit `## Scope change` section immediately before `## Amended acceptance` stating (a) that C11-192's original acceptance is being superseded, (b) the evidence for that (the `attachStacktrace` grouping mechanism and the absence of any c11-owned `Button` in a metadata-stack event — the two arguments that stand without the distribution table), (c) that this requires ticket-owner approval, and (d) which disposition is proposed: retitle C11-192, close-as-invalid and re-open under a new ID, or split into a prerequisite diagnostic ticket. Flag the disposition choice for the operator (see **S1**) rather than picking it silently.
  - Sources: standard-claude ("ticket identity is now wrong in three places"), standard-codex ("must explicitly state whether C11-192 is being retitled/re-scoped"), adversarial-claude ("the scope swap that nobody signs off on... vulnerability: high, and already realized"), adversarial-codex ("requires ticket-owner approval"), adversarial-gemini ("deserves massive pushback"), evolutionary-codex ("a plan cannot unilaterally declare its own acceptance unreachable"), evolutionary-claude (Q10).

- **B2: The amended acceptance cannot come back red**
  - Where in the plan: `## Amended acceptance` — "hang reports group by cause, `generic-metadata` exists as its own Sentry issue with its own user count and trend, and that trend is what a future ticket acts on."
  - Problem: Every clause is satisfied by the code compiling and the release shipping. There is no observation window, no threshold, no named owner, and no failure condition. It replaces a falsifiable criterion (a symbol absent from a trace) with an unfalsifiable one. Six reviewers independently landed on this.
  - Revision: Replace with concrete, checkable gates. Merge gates: (a) the committed corpus replay test is green with an asserted distribution (see I2); (b) a tagged build with an induced hang produces a Sentry event whose title names the cause and whose `hang.cause`/`hang.phase` tags are present and faceted, screenshotted (see B3). Post-release gate, with a named owner and a date: after N days on the next release, ≥90% of hang events classify into a named cause (not `other`/`unknown`), and `generic-metadata` and the `swiftui-update/*` causes are distinct Sentry issues with independent distinct-user counts. State N, state the owner.
  - Sources: standard-claude (weakness 3b, required item; "as written it will be marked done by whoever notices the deploy went out"), standard-codex (#5 "production success is underspecified"), adversarial-claude ("self-graded acceptance... vulnerability: high"), adversarial-codex (blind spot 5), evolutionary-claude (concrete suggestion 9), evolutionary-codex (Q7).

- **B3: Verification is entirely offline; nothing proves Sentry honors the fingerprint or the tags**
  - Where in the plan: `## Verification` — "The new code compiled standalone (`swiftc`) ... Unit tests cover parsing ... CI's `build` job is the compile + logic-test gate."
  - Problem: The entire behavior of this change is remote. `swiftc` proves neither Xcode target membership nor Sentry SDK behavior; unit tests prove the classifier is a function. Nothing verifies that `scope.setFingerprint` overrides grouping on a *message* event while `attachStacktrace = true` is set, that dotted tag keys are accepted, that the 190-char cap is the right cap, or that the message renders as the issue title. This is squarely the repo's own hard rule ("green tests ≠ working product; smoke-launch the real artifact").
  - Revision: Add a `Real-artifact validation` subsection to `## Verification` specifying: tagged build, induce or force a main-thread stall past the 5000ms Sentry threshold, then confirm in the Sentry UI that the event carries the explicit fingerprint, that all four `hang.*` tags survived ingestion, that the title names the cause, and that a second hang with a different cause lands in a *different* issue. Screenshot it and attach to the PR. Name how the hang is induced (see **E2** for a reusable debug hook).
  - Sources: standard-claude (weakness 4, required item 5), standard-codex ("the plan should not claim that CI alone validates the telemetry integration", Q9), standard-gemini (weakness "Sentry Cocoa SDK quirks", Q2), adversarial-claude (blind spot 7, Q18, minimum bar 4), adversarial-codex (blind spot 5, Q8), evolutionary-claude (G), evolutionary-codex (sequencing step 6, suggestion 3).

- **B4: The headline distribution table is a per-capture, pre-#401, one-user-dominated sample, and the plan prioritizes from it anyway**
  - Where in the plan: the seven-row table under `## Finding`, and `## Follow-ups exposed` which orders work by those percentages.
  - Problem: All 875 events predate #401 (`42ce4c919`, now on main), which added `reportedCurrentEpisode` — at most one Sentry event per hang episode. The 875 are therefore recaptures of a smaller number of episodes, duration-weighted, and the plan itself notes 816 of 875 came from one user before reasoning from the uncorrected table. "63.9% SwiftUI graph work / 5.7% generic metadata" is a distribution over *samples of episodes under a reporting regime that no longer exists*, not over hangs. The plan has the `recapture` flag in hand and never dedupes by it.
  - Revision: Recompute the table per episode (dedupe by user + episode, or exclude `recapture == true`) **and** per distinct user, and report distinct-user counts alongside event counts for every row — including specifically for the `generic-metadata` row, whose per-user spread is currently unknown and is adversarial-gemini's strongest point. Correct the table and re-order `## Follow-ups exposed` to whatever the corrected numbers say. If the corpus is no longer reachable, label the table explicitly as a per-capture distribution under a superseded reporting regime and remove it as the basis for prioritization, leaning the refutation on the two arguments that do not need it (the grouping mechanism; no c11-owned `Button`).
  - Sources: standard-claude (weakness 2, required item 2, Q1), adversarial-claude (headline #2, Q2, minimum bar 1), adversarial-gemini (assumption audit: "what if the other 6 users generated the 50 metadata hangs?", Q1), adversarial-codex (reality stress test 2), evolutionary-claude (B, Q7), evolutionary-codex (Q7).

- **B5: The `## Work` section is four declarative sentences, not an implementable specification**
  - Where in the plan: `## Work`, items 1–4.
  - Problem: The plan never lists the cause vocabulary, the phase vocabulary, the ordered precedence rules, the exact fingerprint array, or the file paths and API signatures. "Classify what main is blocked on" and "narrow SwiftUI graph work by host phase" are not implementable — two implementers produce two different taxonomies, and because the bucket names *are* the permanent Sentry fingerprint, a different taxonomy is a different permanent set of issue groups. Item 4 promises coverage of "every cause rule and its precedence" against rules the plan never states.
  - Revision: Expand `## Work` into a specification. Include: the exact file paths touched (`Sources/MainThreadHangMonitor.swift`, `Sources/SentryHelper.swift`, and the actual test file — see M2); the new `sentryCaptureWarning`/`sentryCaptureError` signatures with their default-nil behavior for existing callers; the finite list of `cause` values and `phase` values as a compact decision table with match tokens and precedence order; the exact fingerprint array; the exact tag keys; what stays in context; and the fallback behavior for empty frames, unsymbolicated address-only frames, and a stack with contradictory signals (must route to a stable `unknown`, never a per-frame minted fingerprint). Also state explicitly that no `ContentView.swift` / view-tree work is in scope.
  - Sources: standard-codex (weakness 2 and architectural section, Q3, Q5), adversarial-codex (blind spot 1 "'every cause rule' cannot be implemented from this plan because the rules are never listed", Q3), evolutionary-codex (#2, #4, suggestion 1), standard-claude (exec summary: "a fresh implementer would produce *a* classifier, but not *this* classifier"), adversarial-claude (headline #1).

### Important (revise before implementation starts)

- **I1: The fingerprint is a permanent, unversioned wire format**
  - Where in the plan: `## Work` item 3, and the "Grouping is deliberately coarse" paragraph.
  - Problem: `["main-thread-hang", cause, phase]` is the grouping key forever. Adding a phase rule silently migrates existing traffic into a brand-new issue and strands the old one's history; renaming a cause orphans its trend; reordering rules reclassifies retroactively. This directly breaks the amended acceptance, which is entirely about trends being readable over time. The rule lists are explicitly most-specific-first and invite extension, so this *will* happen.
  - Revision: Add a schema version segment to the fingerprint (e.g. `main-thread-hang.v1` or a discrete `"v1"` element) and a matching `hang.signature_version` tag; state in the plan that these strings are a wire format, that adding a phase splits an existing issue, that taxonomy changes are deliberate version bumps, and that Sentry issue merging is the migration tool. Put the same note as a comment above the cause/phase rule tables in source.
  - Sources: standard-claude (weakness 5, required item 4, Q8), standard-codex (architectural: "a stable schema/version component", Q4), adversarial-claude ("client-side taxonomy calcification"), adversarial-codex (challenged decisions: "only if the stable classifier version is included"), evolutionary-claude (D), evolutionary-codex (#3, mutation "treat taxonomy changes as data migrations").

- **I2: The load-bearing verification is not reproducible by anyone else**
  - Where in the plan: `## Verification` — "run over all 875 production stacks produces 13 issues from 1; `hang.culprit` lands on 172 reports naming 114 distinct c11 symbols."
  - Problem: No corpus path, no replay script, no `swiftc` invocation, no Sentry query is committed. No reviewer can check these numbers and no future agent can re-run the classifier against a new corpus or after a rule change. The claim exists only in the authoring agent's dead context.
  - Revision: Commit a redacted fixture corpus (e.g. `c11Tests/Fixtures/hang-stacks.jsonl`) plus the replay harness, and add a test that asserts a *distribution* rather than individual labels: no stack with frames classifies `unknown`; `swiftui-update` within a stated band; total distinct fingerprints within a stated band (guards both collapse-to-one and explosion-into-singletons). State the redaction rule and provenance in the plan. Note in the plan which CI job runs it.
  - Sources: standard-claude (weakness 6, recommendation 7, Q7), standard-codex (weakness 4, Q7), adversarial-claude ("analysis by uncommitted script — vulnerability: certain", Q4, minimum bar 1), adversarial-codex (blind spot 2, Q4), evolutionary-claude (C: "highest-leverage single addition in this review"), evolutionary-codex (suggestion 5).

- **I3: The C11-191 contradiction is unreconciled and untested**
  - Where in the plan: the `lock / semaphore wait | 10 | 1.1%` row, and `## Follow-ups exposed` ("C11-191 is in this family").
  - Problem: The sibling plan reports 9,433 of 20,778 local captures wedged on `__ulock_wait2`, 9,413 with `GhosttyNSView.attachSurface` at frame 1, one episode running 13h58m. This plan puts `lock-wait` at 10 events, 1.1%. Same watchdog, same era, same fleet. Both readings cannot be right. The most consequential reconciliation — that Sentry systematically under-samples the worst wedges because a permanently wedged process never flushes — would mean the amended acceptance's trend is measured through a sensor that is blindest exactly where the damage is worst.
  - Revision: Add a paragraph reconciling the two, or stating explicitly that it is unknown and why that matters for the amended acceptance. Separately, add a `lock-wait` test fixture built from a verbatim C11-191 `attachSurface` / `__ulock_wait2` capture out of the operator's `~/Library/Logs/c11/hang.log` and assert it classifies as `lock-wait` with `culprit` naming `attachSurface`. This is the one classification with independently proven ground truth; if it does not come out `lock-wait`, that is a classifier bug, not a fixture problem.
  - Sources: standard-claude (weakness 3, required item 1, Q2/Q3: "the single most load-bearing test missing from this change"), adversarial-claude (headline #3, blind spot 1, Q3, minimum bar 6), adversarial-gemini (blind spots: the sibling ticket), adversarial-codex (Q7, reality stress test 3), evolutionary-claude (C: "the C11-191 ground truth is the crown jewel here").

- **I4: `attachStacktrace = true` is untouched, so the misleading display that caused this ticket survives — and the same defect exists at other call sites**
  - Where in the plan: `## Finding` diagnoses `attachStacktrace = true` as the root cause of the misattribution; `## Work` fixes only grouping and titling.
  - Problem: Verified on the branch — `Sources/AppDelegate.swift:2615` still sets `attachStacktrace = true`, and the unused `beforeSend` hook sits at `:2623`. The new `generic-metadata` issue will still render the watchdog's loop in Sentry's primary stack-trace panel, with the real capture demoted to a 24-frame context string. The next audit reads the watchdog stack again and files C11-2xx against another phantom. The diagnosis is also a statement about *every* message event captured from a fixed-shape worker thread; the fix is applied to one call site.
  - Revision: Add to the plan an explicit statement that `attachStacktrace = true` is unchanged and the stack panel will continue showing the watchdog, with a decision: either scope a `beforeSend` fix for `category: "hang"` events into this change, or file it as a named follow-up ticket referenced by ID in the plan. Also state whether the other `sentryCaptureError` call sites reported from fixed-shape worker threads have the same grouping defect, and if so whether they are in scope. The *mechanism* for fixing the display (strip in `beforeSend` vs synthesize a `threads` payload) is a design call — see **S4**.
  - Sources: standard-claude (weakness 1 "the highest-value missing item", alternative A, Q5), standard-gemini (weakness: SDK quirks, Q2), adversarial-claude ("fixing the symptom of a general bug at one call site — vulnerability: certain", blind spot 4, Q6, Q7), adversarial-gemini (challenged decisions), evolutionary-claude ("the plan fixes one instance of a class", mutation 4).

- **I5: Tag cardinality, length and privacy policy is undefined**
  - Where in the plan: `## Work` item 3 — "tags `hang.cause` / `hang.phase` / `hang.culprit` / `hang.top_symbol`."
  - Problem: `hang.culprit` already has 114 distinct values by the plan's own count and `hang.top_symbol` is unbounded — when `backtrace_symbols` cannot resolve a frame it prints an address, minting a per-launch tag value. Sentry tags are indexed dimensions, not an evidence store. Separately, a 190-char prefix of a mangled Swift symbol will not demangle, so the truncated tag is unreadable on exactly the field that points at c11's own code. And mangled c11 symbol names now leave the machine as searchable third-party-indexed strings; the plan says nothing about that under the existing consent policy.
  - Revision: Add a tag policy to the plan: which fields are tags versus context; maximum length and normalization for each; a sentinel value for unknown; a rule that unresolved address-only frames must not become tag values; and a statement that the full untruncated `culprit` is preserved in the event context `data` alongside the bounded tag. Add one sentence on privacy: symbol names are covered by `TelemetrySettings.enabledForCurrentLaunch`, and note the residual exposure of unreleased-feature symbol names.
  - Sources: standard-gemini (weakness "Sentry Tag Limits", Q1), standard-codex (architectural bullet 4, weakness 6, Q5, Q6), adversarial-codex (challenged: "using tags for per-report detail", Q5, Q6), adversarial-claude (blind spot 5, blind spot 8, Q14, Q15), evolutionary-claude (F), evolutionary-codex (#2, suggestion 2).

- **I6: "Follow-ups exposed (separate tickets)" names zero tickets**
  - Where in the plan: `## Follow-ups exposed (separate tickets)` — three bullets, including "96 events are main blocking on a synchronous XPC round trip ... up to 604s. Real wedge class, **no ticket**."
  - Problem: The plan's entire justification is "which this change makes possible." Possibility is not a deliverable. The 604-second XPC wedge is plausibly more severe than the ticket this plan is attached to and exists only as a bullet in a plan file. The plan also promises that "whether generic-metadata instantiation is worth attacking needs its own issue" and does not file it. This is the modal death of taxonomy work: buckets ship, nobody triages, `other` becomes the new C11-31.
  - Revision: File Lattice tickets for (a) the synchronous XPC/AppleEvents wedge class, (b) the `hosting-begin-transaction` vs `hosting-layout` split, (c) the `runloop-idle` report-or-not decision, and (d) "is generic-metadata a real class" gated on the new trend. Replace the prose bullets with the ticket IDs. If any is deliberately not being filed, say so and why in the plan.
  - Sources: standard-claude (weakness 10, recommendation 8, Q14), adversarial-claude ("instrumentation that ships and is never read — vulnerability: highest of all"; "the single highest-leverage edit to this plan is one line"; Q19, minimum bar 3), adversarial-codex (blind spot 6), standard-gemini (Q3), evolutionary-claude (Q6: "the most alarming number in the plan and has no ticket").

- **I7: No alternatives-considered section; the coarseness argument is defended against a strawman**
  - Where in the plan: "Grouping is deliberately coarse: ... a top-5-frame fingerprint gives 645 groups ... The classifier gives 13."
  - Problem: 645-vs-13 is the two endpoints of a spectrum; nobody proposed top-5-frame fingerprinting. The obvious middle — fingerprinting on `[cause, phase, culprit-module]` — is never evaluated. More importantly, the plan never mentions that Sentry supports **server-side fingerprint rules**, which operate on the same data, are editable without a release, and could have reclassified the existing 875 events to validate the taxonomy *before* shipping anything. Compiling the taxonomy into the binary also means it can only be improved by shipping, and there is no rollback path. This is the plan's biggest unexamined default.
  - Revision: Add an `## Alternatives considered` section covering at minimum: (a) server-side Sentry fingerprint/stack-trace rules, with the reason client-side was chosen (likely: the wedged stack is a context string, not a structured stacktrace, so server rules cannot reach it — which is itself an argument for fixing the event shape, see S4); (b) medium-granularity fingerprinting on `[cause, phase, culprit-module]` and why culprit-as-facetable-tag beats culprit-as-group; (c) no-op on grouping and fix only `attachStacktrace`, and why 645 groups / 607 singletons rules that out.
  - Sources: standard-claude (alternatives A/B/C, Q6), adversarial-claude ("the plan never presents this as a choice... this is the plan's biggest unexamined default", "coarse over medium — the 645 figure is a strawman", Q5, blind spot 10), adversarial-gemini (Q4), standard-codex (alternatives section).

### Straightforward mediums

- **M1: Three different numbers for one quantity**
  - Where in the plan: the table row `Swift generic metadata instantiation | 50 | 5.7%`, then "Strictly the demangler symbols appear in 24 of 875 (2.7%)" — and commit `93e655929` says "accounts for **58** of its 875 events."
  - Problem: Verified. 50 (classifier bucket) and 24 (literal demangler symbols) are explainable and the plan explains them; 58 matches neither and is now permanent in the git record. When the entire justification for amending acceptance is "here are the counts," the counts must be consistent everywhere.
  - Revision: Establish which number is correct for which definition, make the plan state both definitions unambiguously, and correct the commit message (amend or add a correcting commit / PR-description note).
  - Sources: standard-claude (weakness under "number discipline slipped", required item 3, Q4). Single reviewer, but self-validating on inspection of the plan and commit.

- **M2: `## Work` item 4 names a file that does not exist, and understates a repo landmine**
  - Where in the plan: `## Work` item 4 — "`MainThreadHangSignatureTests` in `c11LogicTests`."
  - Problem: Verified. The branch appends the class to `c11Tests/MainThreadHangDetectorTests.swift`. The statement is true of the *target* and misleading about the *file*: the file lives in `c11Tests/` on disk while being a member of the `c11LogicTests` target — the exact disk/target mismatch CLAUDE.md documents as the root cause of C11-105. Nothing here touches sockets so it is not dangerous today, but it re-establishes the pattern, in a file whose name now lies about its contents.
  - Revision: Correct item 4 to name the actual file and target, and add a sentence noting the disk-location/target-membership mismatch so the next reader does not re-derive it from the pbxproj. Optionally move the class to its own file. The plan's `## Work` bullets also omit two things the code does (the 190-char tag cap, the `hang.recapture` tag) — add them.
  - Sources: standard-claude (weakness 7), standard-codex (weakness 3, Q8), adversarial-claude (repo-specific landmines), evolutionary-claude (executability note), evolutionary-codex (suggestion 1).

- **M3: The classifier has no health metric and no failure threshold**
  - Where in the plan: the `other compute | 133 | 15.2%` row; nothing in `## Work` or `## Amended acceptance` addresses classifier rot.
  - Problem: The phase rules match Apple private-symbol fragments. When macOS rotates them, `phase` silently goes nil, the fingerprint changes, the issue forks, and the trend resets — which reads as "the fix worked." Likewise if `hang.culprit` coverage drops fleet-wide (the `ownModule` match is `ProcessInfo.processName` against a `backtrace_symbols` image name, untested at runtime), nothing notices. And `other` at 15.2% is on track to be the second-largest issue with no refinement path.
  - Revision: State a classifier-health contract in the plan: emit `hang.phase = "none"` explicitly rather than omitting the tag, so the no-phase rate is a measurable metric; name the health metrics to watch (rate of `unknown` + `other`; rate of `swiftui-update` with `phase = none`; `hang.culprit` coverage vs the 172/875 the offline run predicts); and state the threshold at which the classifier is judged to have rotted and who looks.
  - Sources: standard-claude (weakness 8, Q9), adversarial-claude (blind spot 9, A6, Q13, Q17), adversarial-codex (early-warning metrics list), adversarial-gemini (hindsight preview: "a macOS security update slightly renamed a frame"), evolutionary-claude (E), evolutionary-codex (early-warning metrics).

- **M4: Landing this forks Sentry issue C11-31 and nobody owns the migration**
  - Where in the plan: nothing addresses the transition.
  - Problem: The old issues (C11-30, C11-31) go quiet and new ones appear. Anyone watching the dashboard without that context reads it as "hangs stopped." Alert rules, assignments, saved searches and dashboards keyed to the old issues stop firing, and pre-change history is not comparable to post-change history — a discontinuity at exactly the moment the instrument is installed.
  - Revision: Add a short `## Rollout` note to the plan stating that landing this forks C11-31, that the old issue will go quiet and this is expected, who closes/annotates the old issues and audits any alert rules pointed at them, and that trend comparisons across the taxonomy boundary are invalid.
  - Sources: adversarial-claude (blind spot 6, Q12), evolutionary-claude (D, "related operational note that belongs in the PR description"), evolutionary-codex (mutation: data migrations).

- **M5: The reported sample is systematically the persist capture, and the plan does not say so**
  - Where in the plan: the `## Finding` table is presented as the distribution of hangs.
  - Problem: Verified in source — detection threshold 2000ms, recapture interval 5000ms, Sentry threshold 5000ms. The first capture (2s) is below the Sentry threshold, so the capture that actually reaches Sentry is the persist capture roughly 7s into the wedge. (Hence the original issue title's "(persist)".) The taxonomy therefore measures *what stays wedged*, not *what wedges* — a fast AttributeGraph storm and a permanent futex deadlock are wildly over/under-represented relative to each other. Relatedly, `hang.recapture` is a near-constant tag under this regime and its purpose is unstated.
  - Revision: Add one paragraph to `## Finding` naming the persist-capture bias and what it means for reading the table and the future trends. State the intended purpose of the `hang.recapture` tag, or drop it.
  - Sources: evolutionary-claude (B), adversarial-claude (blind spot 2, Q9 — note his claim that `hang.recapture` will always be `"false"` is inverted; the threshold arithmetic makes it near-always `"true"`, but the underlying point that it is degenerate holds).

- **M6: State that classification runs off the main thread**
  - Where in the plan: `## Work` item 3 wires `describe()` into `reportTelemetry`; the plan never says where it runs.
  - Problem: A reviewer scanning "new string parsing added to the hang path" will ask whether this touches a latency-sensitive path. It does not — `describe()` runs on the watchdog thread inside `reportTelemetry`, consistent with the repo's socket/telemetry threading policy — but the plan should say so rather than leaving it to be re-derived.
  - Revision: One sentence in `## Work` item 3 stating that classification is bounded string work over ≤96 frames on the watchdog thread, off main, per the socket-command threading policy.
  - Sources: adversarial-claude (repo-specific landmines: "not a typing-latency path, and the plan should say so"), adversarial-codex (failure mode: "a hot diagnostic path grows parsing... the plan does not establish a bounded cost").

### Evolutionary clear wins

- **EW1: Classify every capture into the local hang log, not only the Sentry-bound one**
  - Where in the plan: `## Work` item 3 places `describe()` inside the Sentry reporting path.
  - Problem: Verified on the branch — `describe()` is called only inside the `shouldReportHangToSentry` branch, so it runs at most once per episode, only past 5000ms, only when the budget gate allows, and only with telemetry consent on. Every other capture, including the entire local hang log, stays unclassified. The local log header (`=== c11 hang.persist <ts> stalledMs=... pid=... ===`) carries no cause. Meanwhile the operator's machine holds ~151 MB of untruncated, locally-symbolicated hang records that C11-191 had to mine by hand.
  - Revision: Move `describe()` up into `handleHang` and append `cause=`/`phase=`/`culprit=` to the local log header line. Roughly three lines. It makes `grep 'cause=lock-wait' ~/Library/Logs/c11/hang.log` a real triage command with full untruncated frames and no consent gate, turns the existing 151 MB corpus into a far better validation set than the 24-frame Sentry payloads, and gives the implementing agent an acceptance gate it can execute today rather than one that waits on a release.
  - Sources: evolutionary-claude (A, concrete suggestion 1 — "largest value multiplier in the change"), evolutionary-gemini (concrete suggestion 1 — "local `hang.log` was the oracle that actually solved C11-191; the classifier must also annotate the local log"). Independently raised by two evolutionary reviewers and verified against the branch.

---

## Surface to user (do not apply silently)

- **S1: Which disposition for C11-192 — retitle, close-as-invalid, or split?**
  - Why deferred: author-intent-needed / operator call
  - Summary: Every reviewer who flagged the scope swap proposed a different remedy. standard-claude: "either retitle C11-192 to what it became, or close it as invalid and move the work under a new ID." standard-codex and adversarial-codex: split — keep C11-192 as the performance ticket and make this a separate telemetry ticket, "the cleanest option because it keeps acceptance criteria honest." adversarial-claude: close as invalid and open a new ticket "so the acceptance criteria are not written by the agent that will be graded against them, and so the branch name stops lying." B1 requires the plan to *record* the scope change; the choice among the three is yours.
  - Sources: standard-claude (recommendation 9, Q15), standard-codex (alternatives, readiness item 1, Q1), adversarial-claude (challenged decisions, Q20), adversarial-codex (challenged decisions, Q1), evolutionary-codex (#1).

- **S2: Adversarial-gemini's dissent — "this is a won't-fix disguised as an observability improvement"**
  - Why deferred: disagreement (5 reviewers reject the premise, 1 holds it strongly)
  - Summary: adversarial-gemini argues the plan abandons a real 10-second beachball; that "no `Button` c11 owns appears in the stack" is a cop-out because SwiftUI type erasure routinely obscures c11 view names and `NSHostingView` is the boundary (sidebar, tab bar, command palette, toolbars are all known hosts); that if C11-191 removes the 64% AttributeGraph family, generic-metadata immediately becomes the dominant unresolved class; and that after this ships the user experience is unchanged. It asks which `NSHostingView` boundaries have actually been audited with Time Profiler. adversarial-codex makes the narrower version of the same point: "the plan may be right that C11-31 is a bad grouping, but that does not prove there is no view-tree defect — a 24- or 50-event class can still be a severe, reproducible user failure." Counterweight: standard-claude, standard-codex, standard-gemini, evolutionary-claude and evolutionary-codex all accept the refutation, and the repo's own guidance is against speculative `AnyView` surgery without a profile. Note that B4 (per-user recount of the generic-metadata bucket) is the cheap test that would settle gemini's strongest sub-claim.
  - Sources: adversarial-gemini (whole review, esp. assumption audit and Q1/Q2/Q5/Q6), adversarial-codex ("the uncomfortable truths").

- **S3: Client-side classifier versus Sentry server-side fingerprint rules**
  - Why deferred: design-needed / reviewers disagree on the answer
  - Summary: Three reviewers flag that server-side fingerprint rules would do the same job, be editable in minutes rather than a release cycle, and could be applied retroactively to the 875 events already received — validating the taxonomy before shipping any code. adversarial-claude calls it "the plan's biggest unexamined default." standard-claude, having considered it, still leans client-side (versioned with the binary, testable in CI, and it can read `extra.stack` which server rules cannot easily reach). I7 asks the plan to *document* the choice; whether to actually change it is yours.
  - Sources: standard-claude (alternative C, Q6), adversarial-claude (challenged decisions, Q5, hindsight preview), adversarial-gemini (Q4).

- **S4: Fix the event shape instead — synthesize a `threads` payload with the wedged main marked `current: true`**
  - Why deferred: design-needed / would change the plan's direction
  - Summary: adversarial-claude's alternative to the whole approach: use `SentrySDK.capture(event:)` with a synthesized threads payload so Sentry receives the real wedged stack as a structured stacktrace. That fixes grouping *and* display *and* hands Sentry's own grouper the correct input, making the hand-rolled classifier optional rather than load-bearing — and it also unblocks server-side rules (S3). adversarial-gemini reaches the same place from a different angle ("configure the SDK to treat the main thread as the crashed thread"). This is materially larger than the I4 revision and could obsolete parts of the current design, so it needs your call rather than a silent edit.
  - Sources: adversarial-claude (blind spot 4, Q6, hindsight preview), adversarial-gemini (challenged decisions, Q4), standard-claude (alternative A, partial).

- **S5: Severity is now invisible in the Sentry issue list**
  - Why deferred: single-reviewer, adds a new field
  - Summary: The message drops the duration by design and `stalled_ms` moves to context, which Sentry cannot facet, alert on, or sort by. A 2.0s stutter and a 604s wedge become the same row with no way to distinguish them from the issue list — a regression in a change whose entire purpose is making Sentry legible. Proposed fix is a `hang.duration_bucket` tag, one line. evolutionary-codex independently agrees duration must not be in the message or fingerprint, but does not propose the bucket tag.
  - Sources: adversarial-claude (blind spot 3, Q8, minimum bar 2), evolutionary-codex (suggestion 2, partial).

- **S6: An explicit fingerprint with no `{{ default }}` and no release component makes each cause a permanent issue**
  - Why deferred: design-needed
  - Summary: Under the shipped fingerprint, every cause becomes one permanent issue across all releases: it can only be resolved-and-regressed, never closed. The ticket's own original acceptance language ("does not recur on the next release") is structurally unsatisfiable against a permanent issue. Whether permanence or per-release issues is right is a genuine design call that should be made explicitly rather than defaulted into.
  - Sources: adversarial-claude (challenged decisions, Q11).

- **S7: Post-#401 throttling may starve every bucket of an actionable trend**
  - Why deferred: ambiguous — nobody has run the projection
  - Summary: #401 caps at one event per episode, 3/hour, 15/day per user, and its own commit notes the pre-throttle recapture stream was "~98% of c11's entire event volume." `generic-metadata` at 5.7% of a stream 98% smaller is a handful of events per week fleet-wide. The amended acceptance ("its own user count and trend") would then be technically satisfied by an issue existing with two users, and materially satisfied by nothing. The projected weekly event count per bucket, and the count at which a bucket's trend becomes actionable, are both currently unknown. This bears directly on whether B2's post-release gate is achievable at all.
  - Sources: adversarial-claude (reality stress test 1, A3, Q10), evolutionary-claude (sequencing/flywheel latency argument).

- **S8: This is a retrospective, not a plan — is the workflow producing plan artifacts after implementation?**
  - Why deferred: process question for the operator, not a plan edit
  - Summary: The work is committed on `c11-192-button-metadata` (`93e655929`, `9caf9c72e`) with PR #402 open, and `## Verification` is written in the past tense. Two reviewers argue that reviewing this document as a plan launders a hole in the workflow, and that it should have been routed to code review instead. adversarial-claude: "a plan review has no mechanism to catch the plan/implementation drift that has *already occurred*." Worth deciding whether the trident-plan-review stage should run before implementation on this workflow, or whether these should be routed to trident-code-review when the branch already exists.
  - Sources: standard-claude (exec summary, Q16), adversarial-claude (headline #1, "the uncomfortable truths", Q1).

---

## Evolutionary worth considering (do not apply silently)

- **E1: `c11 hang-report` — turn the local hang log into a triage command**
  - Summary: The classifier plus the operator's existing ~151 MB local hang log equals a ranked table of what actually wedges this machine, computed in seconds, with no telemetry, no consent gate, no 24-frame truncation, and no release cycle. Ship it as a CLI subcommand or fold it into `c11 health`. Builds directly on EW1.
  - Why worth a look: It collapses the hang-investigation feedback loop from a release cycle to minutes, on a corpus that already exists today.
  - Sources: evolutionary-claude (mutation 1, flywheel section), evolutionary-gemini (offline/persistent hang logs).

- **E2: A debug-only "simulate main-thread hang (N seconds)" command (Debug menu + socket)**
  - Summary: There is currently no way to induce a hang on demand, which is exactly what B3's real-artifact smoke test needs. A debug hook makes that gate repeatable and agent-drivable, and it is reusable for C11-186 (you cannot test hang survivability without inducing a hang) and for every future hang ticket.
  - Why worth a look: Small build that turns B3 from a one-off favor into a repeatable gate, with compounding reuse.
  - Sources: evolutionary-claude (G, concrete suggestion 7), evolutionary-codex (sequencing step 6), evolutionary-gemini (automated regression testing).

- **E3: Frame C11-192 as the sensor half of C11-186, and design the taxonomy against a response policy**
  - Summary: "Make main-thread hangs survivable" cannot have a policy until something can say *what kind* of hang this is: a thread parked in `__ulock_wait2` for 14 hours is a deadlock and deserves a different response from a 6-second AttributeGraph pass, and `xpc-sync-wait` deserves "we are waiting on the system, not hung." If the taxonomy is designed against Sentry's grouping needs alone, it may not be the right taxonomy for C11-186's response policy — and the fingerprint ossifies on merge.
  - Why worth a look: Reconciling the two requirement sets is much cheaper before the taxonomy becomes a permanent wire format than after.
  - Sources: evolutionary-claude (exec summary #2, mutation 2 "sensor becomes actuator", Q2), evolutionary-gemini (proactive auto-recovery, deferred).
