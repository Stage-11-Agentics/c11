# Trident Standard Review Synthesis: C11-190

- **Track:** Standard / Analytical
- **Plan:** C11-190, Sentry quota exhaustion incident, verify monitoring resumes
- **Plan file:** `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01KZ6YXZRV8SH2V7FJJKPM7QCJ.md`
- **Reviewers:** Claude, Codex, Gemini
- **Synthesized:** 2026-08-04
- **Sources:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`

---

## Executive Summary

1. **Unanimous verdict: the plan is not executable as written.** Two reviewers say "Needs revision," one says "Needs rethinking." No reviewer says "Ready." The disagreement is only about how much of the document survives the rewrite, not about whether a rewrite is required.

2. **The failure is staleness, not error.** All three reviewers praise the underlying analysis and the fix. The document has simply stopped describing the work: its title fixes on a quota-reset date (2026-08-24) that was overtaken by the 2026-08-04 Team-plan reset, and two of its three remaining items were answered by the 2026-08-04 audit and merged PR #401.

3. **The plan's one genuinely valuable idea must survive the rewrite.** All three reviewers independently isolated the same sentence as the ticket's real payload: an HTTP 200 with an event id is not storage; only `outcome=accepted` in `stats_v2` proves retention. Claude calls it "the actual epistemic trap," Codex calls it "the only signal that distinguishes retained telemetry from silent quota discard," Gemini calls it "the most critical part of the ticket."

4. **The largest structural gap is one all three found and none of them found in the plan: there is no release gate.** The remaining verification is premised on "#401 ships in a release," and nothing states which release, who moves it there, or when. Claude alone did the git work and found the harder version of this: `42ce4c919` is on `main` but is **not** an ancestor of `origin/release/v0.63.0`, the in-flight release branch already version-bumped on 2026-07-31. If v0.63.0 cuts as staged, the fix first ships in v0.64.0. This is the single blocking item.

5. **The most consequential divergence is about when this ticket closes.** Codex holds a hard line: no closure without post-release server-side accepted outcomes. Claude prefers closing on the immediate org-position check and tracking post-ship verification on a new ticket. Gemini raises close-and-replace as a hygiene option. This needs an operator decision; it is not resolvable by more analysis.

6. **Claude's review is the deepest and carries the most net-new information**, including four defects in the landed #401 code that would distort exactly the numbers the remaining verification is supposed to measure. Codex's review is the most operationally precise about the verification protocol itself. Gemini's is the shortest but independently confirms the staleness diagnosis and contributes one option the others missed.

7. **Adoption lag is the sleeper risk.** Two reviewers flagged that the reporting fleet trails releases badly (Claude cites the audit: 1,725 of 1,784 production events from `0.58.0+116` while tags already reach v0.61.0). A naive fleet-total measurement taken a week after ship will be measuring mostly unfixed installs and will read as failure long after the fix is correct. All three converge on release-filtered measurement as the answer.

---

## 1. Where the Models Agree (Highest Confidence)

These findings were reached independently by multiple reviewers and should be treated as settled.

### 1.1 Unanimous (3 of 3)

1. **The plan is stale and would actively mislead a fresh executor.** Claude: "materially stale and, worse, actively misleading." Codex: "no longer the contract for the ticket." Gemini: "fundamentally stale and out of sync." Confidence: highest.

2. **The 2026-08-24 wait is now wrong.** The billing period reset on 2026-08-04 with zero usage under the Team plan. Anyone following the plan literally waits 20 days for nothing. Gemini states the cost most bluntly.

3. **Items 2 (budget decision) and 3 (retired DSN in shipped builds) are resolved and should be marked closed inline, not left presented as open.** The Team upgrade happened; the retired-DSN question was answered by finding the CLI's compiled-in DSN on `main`, fixed in #401.

4. **The `outcome=accepted` insight is the plan's strongest element and must be preserved verbatim through any rewrite.** See executive summary item 3.

5. **The remaining work is purely observational verification, gated on deployment.** All three arrive at essentially the same two-or-three phase decomposition: get a fixed release into the fleet, prove acceptance, prove the volume drop.

6. **There is a missing deployment dependency the plan never names.** Client-side throttles do not exist until users run a build containing them. Gemini: "the plan forgets that client-side throttles don't exist until the user upgrades."

### 1.2 Two of Three

7. **"Low thousands per month" is not an acceptance criterion** (Claude, Codex). Claude: "a vibe." Codex: "directionally correct but too elastic." Both demand a number, a normalization window, and an explicit `rate_limited` expectation (both propose zero while under quota). Gemini repeats the phrase without challenging it.

8. **`platform/sentry.md` now contradicts itself and this ticket caused it** (Claude, Codex). The header reflects Team / 50,000 / `allowOnDemand: true`; the quota-incident section further down still reasons entirely from the Developer plan, `onDemandMaxSpend: 0`, and the 2026-08-24 block. Both note that a reference doc read mid-document hands the next responder a wrong plan and a nonexistent blocked state. Claude scopes the reconciliation into this ticket; Codex prefers a dedicated doc follow-up.

9. **No owner, no cadence, no named evidence artifact** (Claude, Codex). Codex asks where the raw `stats_v2` response plus interpretation gets recorded. Claude notes the irony directly: leaving the follow-up unowned on a ticket whose whole subject is "nobody noticed for a week."

10. **Org-wide IP and geo scrubbing on `stage-11-kl` is an open, adjacent, arguably higher-stakes item with no home** (Claude, Gemini). Only `acetate` was fixed; c11 is presumably storing user IPs and cities right now. Both ask whether it belongs in C11-190 or a new ticket. Claude adds that the fix is not a copy of the setting name: acetate's required the leaf-selector trap workaround plus a stored-event read-back.

11. **The old-client long tail will contaminate or delay the reading** (Claude, Gemini; Codex handles it structurally via group-by-release without framing it as a risk). Claude quantifies the version skew from the audit; Gemini frames it as "a common failure pattern when dealing with client-side fixes."

12. **A paid plan did not buy a server-side fence, and that premise under item 2 was wrong** (Claude, Codex). Per-key rate limits are Business-gated, re-verified after the upgrade. Client-side remains the only fence. Reopening the billing/rate-limit investigation would be churn.

---

## 2. Where the Models Diverge (The Disagreement Is Signal)

### 2.1 Ticket disposition: does C11-190 close now or stay open for weeks?

1. **Codex (hard line):** "Do not close merely because the org reset or #401 merged: closure requires post-release server-side accepted outcomes." The ticket stays open against an external dependency.
2. **Claude (prefers split):** close on the org-position check, which is answerable today, and open a new ticket for post-ship verification, "since the current ticket would otherwise sit open for weeks against an external dependency."
3. **Gemini (raises both):** Alternative 1 is close-and-replace ("this might be cleaner than mutating a stale plan"); Alternative 2 is rewrite-in-place, which it recommends for context continuity.

**Reading of the disagreement:** this is a real tradeoff between evidentiary rigor and board hygiene, not a factual dispute. Codex is right that an unproven fix is unproven. Claude and Gemini are right that a ticket blocked for weeks on a release train is a board-rot generator. The synthesis position: split it. Close C11-190 on what is provable today (org position healthy, items 2 and 3 answered, doc reconciled) and open a successor ticket carrying the release gate plus the numeric post-ship criteria. That satisfies Codex's substance while avoiding the open-for-weeks failure mode. **Operator decision required.**

### 2.2 Is a recurrence alarm in scope?

1. **Claude (in scope, near-blocking):** "the item I would most want added." Argues the incident's defining property was that nothing alerted for a week, so a one-time manual check is the wrong terminal state. "The terminal state for an observability incident is a working alarm; verification is just the evidence you collected on the way there." Proposes Sentry org-level quota/spend notifications plus optionally a scheduled `stats_v2` read.
2. **Codex (explicitly out of scope):** "Alerting on future quota pressure is valuable, but is a separate scope decision rather than an implicit addition to this recovery ticket." Asks it as a question rather than asserting it.
3. **Gemini:** silent.

**Reading:** Claude has the stronger argument on substance; Codex has the stronger argument on ticket discipline. These are compatible: file the alarm as a named sibling ticket in the same breath, so it is neither smuggled into a recovery ticket nor lost. What both would reject is closing the incident with no detector anywhere.

### 2.3 Does this ticket authorize any new code?

1. **Codex:** "No new implementation work is justified by this ticket based on the supplied audit and current `main` code." Explicit.
2. **Claude:** found four defects in the landed #401 (see section 3.1) and argues they materially move the numbers AC3 will measure, so they should be filed as a follow-up "so AC3 is measuring a known quantity." Notably, Claude also does not want them in this ticket, so the two positions converge on "not here, but file them."
3. **Gemini:** proposes a possible temporary server-side inbound filter for hang issues during the adoption window, which is operational config rather than code, but is the only reviewer suggesting any new mitigation at all.

**Reading:** near-agreement once Claude's "file separately" is read carefully. The genuine open question is Gemini's: does the org need an interim protective measure while old clients bleed out, or is 50,000 enough headroom to ride it out?

### 2.4 How to defeat adoption lag in the measurement

1. **Claude:** version-filtered stats, "measure only the fixed release's per-install rate, answerable in days rather than months." Argues explicitly that fleet-total "will read as failure long after the fix is correct."
2. **Codex:** group `stats_v2` by project, outcome, **release**, and daily interval, primarily to exclude pre-fix clients from contaminating the reading.
3. **Gemini:** account for the mixed population and consider temporary server-side dropping of specific hang issues if old clients threaten the 50,000 cap before adoption lands.

**Reading:** Claude and Codex propose the same mechanism for slightly different reasons (Claude to accelerate the answer, Codex to keep it clean). Gemini's is the only proposal that protects the quota during the window rather than just measuring around it. All three are compatible and should be adopted together.

### 2.5 Severity framing

1. **Claude and Codex:** "Needs revision," explicitly framing the analysis and fix as correct and only the forward-looking contract as broken.
2. **Gemini:** "Needs rethinking," on the grounds that the plan must be "reduced to a pure verification checklist."

**Reading:** the gap is mostly rhetorical. Gemini's own prescription (reduce to a verification checklist) is a revision, not a rethink, and it explicitly recommends rewrite-in-place. Treat the consensus as "Needs revision," with Gemini's label reflecting how little of the original text survives.

---

## 3. Unique Insights (Single-Reviewer Findings)

### 3.1 Claude only

1. **The release-branch divergence, git-verified.** `git merge-base --is-ancestor 42ce4c919 origin/release/v0.63.0` returns false, and `git grep SentryEventBudget origin/release/v0.63.0` returns nothing. This converts "which release?" from an open question into a known problem with a known cost. Highest-value single finding in the pack.

2. **Hang events are charged to the global budget twice.** `MainThreadHangMonitor.shouldReportHangToSentry` calls `allow(.hang)` (recording into `hangHourly`, `hangDaily`, `globalHourly`, `globalDaily`), then the resulting capture passes through `beforeSend` in `AppDelegate.swift:2623`, which classifies by level only and calls `allow(.other)`, recording into the globals again.

3. **A silent hole in the hang signal path.** If the global budget is exhausted at the `beforeSend` stage, the hang budget has already been consumed **and** `reportedCurrentEpisode = true` has already been set. The episode is marked reported, the event is discarded, and that episode is never reported at all. This is a defect in exactly the signal this incident is about.

4. **The documented "3 hang reports per hour" fence is not true as implemented.** `options.appHangTimeoutInterval = 8.0` is set and `enableAppHangTracking` is never disabled, so Sentry's native ANR tracker is live. Its events reach `beforeSend` at non-fatal level, get classified `.other`, and face only the 20/hour and 50/day global caps, never the 3/hour, 15/day hang sub-cap. The same wedge can also produce two events, one from the custom watchdog at 5s and one from the SDK at 8s. This contradicts both `platform/sentry.md`'s fence table and #401's own commit message.

5. **The budget does not persist across launches.** `SentryEventBudgetGate.shared` is in-memory, so it resets to a clean 50/day on every process start, which is weakest in precisely the crash-loop and wedge-then-force-quit-then-relaunch cases the budget exists to bound. Proposed fix is ten lines writing sliding-window stamps to `~/Library/Caches/<bundle-id>/`.

6. **Fleet arithmetic on the throttled path.** 30 wedged installs x 50/day x 30 days = 45,000, which is the entire quota, from the *throttled* path. The fence bounds one process on one day; it does not bound the bill or the blindness.

7. **Per-fingerprint budgeting as the better steady state.** #401 spends its 20/hour first-come-first-served, so a chatty warning class can crowd out a rarer, more interesting error. Acetate already does the alternative via `DedupeIntegration`: allow the first N occurrences of each distinct issue per window, then cap globally. Matches the observation driving the whole fix (Sentry groups repeats into one issue anyway, so repeats buy nothing).

8. **One-org-per-project as an unconsidered structural option.** Restores blast-radius isolation without a Business plan, at the cost of a second $29/mo and split administration. Claude's read: not worth it at two projects, worth revisiting at four, and the trigger should be written down now while the reasoning is fresh.

9. **The near-miss worth preserving.** Repointing the retired DSN at the live project (the intuitive move) would have moved roughly 1.12M events/month onto the real quota and burned 50,000 in about 1.3 days. Deactivation was the only safe choice.

10. **Item 3 was answered for the CLI but never for the app.** Any app build older than the 2026-04-29 project migration points at a now-deactivated key and reports nowhere at all. Probably fine, but currently an unstated assumption rather than a closed line.

11. **Two additional doc bugs in `platform/sentry.md`.** The Setup Checklist credits project id `4511028453900288` to `c11`, but that is demo-project's id (c11 is `4511304571158528`). And the CI section uses `SENTRY_PROJECT: stage11-c11` while the Active Projects table says the slug is `c11`. If the CI value is wrong, dSYMs are uploading somewhere unexpected and crashes are arriving unsymbolicated with nobody necessarily noticing.

12. **`demo-project`'s final disposition is undecided.** Key deactivated, issues intact, project alive. Good incident-time action, bad steady state: one PUT re-enables it, and an unowned alert rule remains. Decide delete-outright or document "deactivated permanently, do not re-enable."

13. **Regression-guard design must respect this repo's test policy.** A naive "assert no DSN string in `c11.swift`" test is forbidden by the source-text test ban. The compliant options are a behavioral test (CLI run with `C11_CLI_SENTRY_DSN` unset produces no Sentry transport) or an explicit accepted-risk note. Silently having neither is the thing to flag.

14. **Titles are what people read.** The board view shows only "verify it resumes after the 2026-08-24 quota reset," which encodes both an obsolete date and an obsolete blocked state.

15. **This repo has already paid this exact cost once.** `platform/sentry.md`'s Secrets banner records a stale pointer that "cost an ACE-801 agent a wrong ask to the operator." Same shape, same failure mode, recurring.

### 3.2 Codex only

16. **A reproducible query contract is missing, not just a threshold.** Codex asks for the authenticated `stats_v2` query itself: groupings, timezone, window boundaries, project filter, and a raw result artifact, noting the endpoint's daily-interval requirement. Without it, "a future executor could check too early or report a misleading aggregate."

17. **`client_discard` needs an interpretation rule.** Intentional budget drops from #401 will appear in the outcome data. They are a health signal for the client fence, not evidence of Sentry loss, and conflating the two would misread the result in either direction. Codex asks what level of `client_discard` should itself trigger follow-up.

18. **Release eligibility needs a positive predicate, not just a version number.** Record the public production release/version/build containing #401 **and** evidence it has actually emitted at least one production event. Explicitly exclude development builds, XCTest hosts, and events from older releases from satisfying the phase.

19. **Synthetic event injection is rejected as the default verification method, with reasons.** It would create production telemetry and requires explicit approval plus a privacy-safe marker and a cleanup/triage policy. Passive production evidence after a stated minimum window is sufficient.

20. **Client logs and SDK event ids are explicitly named as invalid closure evidence**, "because server-side quota rejection occurs after acceptance at the edge." Worth stating in the runbook so a future executor cannot accidentally satisfy the criterion the wrong way.

21. **A staged two-claim structure.** A few post-release hours can prove *resumption* but cannot prove a *monthly rate*; 7 to 14 days supports a normalized projection; a full billing period establishes it conclusively. The ticket should declare which claim it requires to close.

### 3.3 Gemini only

22. **Close-and-replace as a first-class alternative.** "Close C11-190 completely, noting that the audit and PR #401 resolved it, and open a new ticket strictly for 'Verify PR #401 Sentry throttles in production.' This might be cleaner than mutating a stale plan." The only reviewer to raise ticket hygiene as a distinct consideration from evidentiary rigor.

23. **Interim server-side protection during the adoption window.** "Do we need to consider temporary server-side dropping of specific hang issues if they threaten the new 50k cap before adoption hits?" The only proposal that protects the quota during the bleed-out rather than merely measuring around it.

24. **Old-client bleed-out rate as an explicit unknown.** Asks for an estimate of how fast pre-#401 Cocoa clients age out. Nobody has this number, and it gates both the interim-protection decision and the fleet-total measurement timeline.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews and ordered by decision weight. Attribution in brackets: **[C]** Claude, **[X]** Codex, **[G]** Gemini.

### Blocking

1. **Release gate.** `origin/release/v0.63.0` (bumped 2026-07-31) does not contain `42ce4c919`. Do you cherry-pick #401 onto it, or accept that the Sentry fix first ships in v0.64.0? Either is defensible; the ticket cannot be verified until one is chosen. Which, and by when? **[C, X, G]**

2. **Ticket disposition.** Does C11-190 stay open until post-release accepted outcomes are proven (Codex's position), or close on the org-position check with a successor ticket carrying the post-ship verification (Claude's preference, Gemini's Alternative 1)? **[C, X, G]**

3. **Numeric closure threshold.** What exactly replaces "low thousands per month"? Proposed shape: over a declared window, `rate_limited == 0` for the c11 project while under quota, `accepted > 0` within 24h of the first fixed build reporting, and accepted events attributable to the fixed release below X per install-day. What is your X, and over what normalization window? **[C, X]**

### Verification protocol

4. **Release-filtered or fleet-total measurement?** Version-filtered isolates the fix from adoption noise and is answerable in days; fleet-total is answerable only after adoption, weeks to months out, and will read as failure long before it reads as truth. Which does the ticket require? **[C, X, G]**

5. **What is the exact `stats_v2` query contract?** Groupings (project, outcome, release), timezone, window boundaries, daily interval, project filter, and where the raw response plus a concise interpretation gets recorded as the evidence artifact. **[X]**

6. **Release-eligibility evidence.** What specific evidence establishes that a fixed release is running in a real production client, as distinct from a dev build, XCTest host, or an older release still reporting? **[X]**

7. **How is `client_discard` interpreted?** Intentional budget drops are a health signal for the #401 fence, not monitoring failure. What `client_discard` level would itself trigger follow-up? **[X]**

8. **Which claim closes the ticket:** resumption proven (hours), a normalized rate projection (7 to 14 days), or a full billing period? **[X]**

9. **Who owns the post-release check, and on what date?** The remaining items are currently unassigned on a ticket whose subject is that nobody noticed for a week. **[C, X]**

### Scope boundaries

10. **Recurrence detector: in scope, sibling ticket, or deliberately deferred?** If adopted, which shape: Sentry's org-level quota and spend notifications to `projects@stage11.ai`, a scheduled `stats_v2` read that fails loudly on `rate_limited > 0`, or both? Who receives it and what do they do when it fires? **[C, X]**

11. **Org-wide IP and geo scrubbing.** `stage-11-kl` has `scrubIPAddresses: false` and `dataScrubber: false`; only `acetate` was fixed, so c11 is presumably storing users' IPs and cities right now. In scope for C11-190, a new ticket, or an accepted risk? Note the fix needs the leaf-selector workaround plus a stored-event read-back, not just the setting name. **[C, G]**

12. **`platform/sentry.md` reconciliation: this ticket or a dedicated doc pass?** The quota-incident section still reasons entirely from the Developer plan and the 2026-08-24 block while the header says Team. **[C, X]**

13. **Interim quota protection.** Pre-#401 clients will keep sending un-throttled hang reports at the active c11 DSN through the adoption window. Do you have an estimate of the bleed-out rate, and is temporary server-side inbound filtering of specific hang issues warranted to protect the 50,000 cap? **[G]**

### Code and hygiene follow-ups (all agreed as "file, not fix here")

14. **Hang reporting owner.** Sentry's native app-hang tracking is still on at 8s alongside the custom watchdog at 5s, and its events bypass the hang sub-budget entirely, which makes the documented 3/hour fence untrue. Set `enableAppHangTracking = false` so the watchdog is the single owner? **[C]**

15. **Budget double-charge and the dropped-episode hole.** Hang events consume two global slots (`allow(.hang)` in the monitor, then `allow(.other)` in `beforeSend`), and an episode can be marked `reportedCurrentEpisode = true` while its event is dropped, so it is never reported at all. Fold into this ticket or file separately? Filing separately keeps AC3 from chasing a moving target. **[C]**

16. **Should the event budget persist across launches?** It currently resets on every process start, weakest in exactly the crash-loop and force-quit-relaunch cases. Ten lines in the cache directory, or deliberately out of scope? **[C]**

17. **Per-fingerprint budgeting as the steady state?** #401's first-come-first-served 20/hour lets a chatty warning class crowd out rarer errors. Acetate's `DedupeIntegration` pattern budgets by fingerprint. Follow-up ticket or accepted as-is? **[C]**

18. **Regression guard against a compiled-in CLI DSN returning.** Given the repo's ban on source-text tests, do you want a behavioral guard (CLI with `C11_CLI_SENTRY_DSN` unset produces no Sentry transport) or an explicit accepted-risk note? **[C]**

19. **`demo-project` final disposition.** Leave the key deactivated indefinitely or delete it outright? Should the Retired table carry an explicit "do not re-enable" so a future agent does not helpfully turn it back on? **[C]**

20. **CI project slug.** The doc's CI snippet uses `SENTRY_PROJECT: stage11-c11` while the project table says the slug is `c11`, and the Setup Checklist credits demo-project's id (`4511028453900288`) to c11 (actual: `4511304571158528`). Are dSYMs currently uploading to the right project? **[C]**

21. **Close the app-side half of item 3.** Any app build older than the 2026-04-29 project migration points at a deactivated key and reports nowhere. State and close it rather than leaving it an unstated assumption. **[C]**

22. **Acetate's share of the shared 50,000.** With two live neighbours on one quota, is anyone tracking the split, and is there a stated per-project expectation, even informal? **[C]**

23. **When does one-org-per-project become the answer?** Two projects on a shared quota with no server-side fence is workable; four is a recurring incident generator. Worth writing the revisit trigger down now while the reasoning is fresh? **[C]**

---

## 5. Consolidated Readiness Verdict

### 5.1 Verdict

| Reviewer | Verdict |
|---|---|
| Claude | Needs revision |
| Codex | Needs revision, then ready for a verification executor |
| Gemini | Needs rethinking |

**Synthesized: NEEDS REVISION.** Unanimous that the plan is not executable as written. The one-step-harsher label from Gemini reflects how little of the original text survives rather than a dispute about the underlying analysis, and Gemini's own prescription is a rewrite-in-place. No reviewer questions the incident analysis, the diagnosis, or #401 as the right fix.

### 5.2 What flips it to Ready

Synthesized from Claude's eight-item list, Codex's runbook demands, and Gemini's two alternatives. Ordered by dependency.

1. **Resolve the release gate.** Cherry-pick `42ce4c919` onto `origin/release/v0.63.0`, or state the deferral to v0.64.0 with a date. This is the blocking item; without it the ticket cannot complete regardless of how well the rest is written. *(Blocking.)*
2. **Decide the ticket's disposition** (close-and-successor vs stay-open) and restructure accordingly. *(Blocking on operator input.)*
3. **Retitle and purge 2026-08-24 everywhere.** The board view is what most readers see.
4. **Mark items 2 and 3 resolved inline with one-line answers each,** and explicitly close the app-side half of item 3.
5. **Replace the three narrative bullets with a checkable ladder,** each line carrying a pass condition and an owner. Claude's proposed shape: AC1 org position healthy now (closeable today); AC2 #401 on the shipping release branch; AC3 post-ship release-filtered `stats_v2` showing `accepted > 0` and `rate_limited == 0` against a named numeric threshold; AC4 a quota-exhaustion signal that does not depend on a human running a curl; AC5 open hygiene items closed or split out.
6. **Write the `stats_v2` runbook,** including query, groupings, timezone, window, release predicate, `client_discard` interpretation, and the named evidence artifact. Explicitly state that SDK event ids and client logs do not satisfy the criterion.
7. **State the numeric threshold** for the volume claim and the normalization window.
8. **Reconcile `platform/sentry.md`** (here or as a named follow-up), including the two additional doc bugs.
9. **File the recurrence detector** as a named AC or a named sibling ticket. Do not close the incident with no detector anywhere.
10. **Split or fold the org-wide IP and geo scrubbing decision** so it stops being a footnote in a reference doc.
11. **File the four #401 code findings** as a follow-up so AC3 measures known behavior rather than a moving target.
12. **Decide on interim quota protection** during the old-client bleed-out window.

### 5.3 Risk if shipped as-is

Named by at least two reviewers: a fresh agent picking this ticket up cold waits 20 days for a reset that already happened, takes a resolved billing question back to the operator, and re-investigates a DSN that was already fixed. Claude notes the repo has already recorded this exact failure mode once, in `platform/sentry.md`'s Secrets banner, where a stale pointer "cost an ACE-801 agent a wrong ask to the operator."

The deeper risk, raised most forcefully by Claude and echoed by Codex's question 7: this ticket closes on a one-time manual check for an incident whose defining property was that nothing alerted for a week. Reducing the input is not the same as installing the detector. Absent an alarm, the org is one noisy neighbour away from a silent repeat, and the next repeat is again found by accident, on a different project, by a different agent.
