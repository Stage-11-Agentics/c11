# Adversarial Review Synthesis: C11-190 Plan

**Ticket:** C11-190 (Sentry quota exhaustion incident, verify monitoring resumes)
**Plan:** `.lattice/plans/task_01KZ6YXZRV8SH2V7FJJKPM7QCJ.md`
**Reviewers synthesized:** Claude, Codex, Gemini (adversarial posture, same plan, independent passes)
**Synthesized:** 2026-08-04
**Nature of this document:** read-only synthesis. No code, plan, or ticket state was modified.

---

## Executive Summary

1. **All three reviewers reach the same verdict: do not execute this plan as written.** Not because the plan is careless, but because it is *expired*. Every one of its three open items was overtaken by the 2026-08-04 audit and by merged PR #401. Executing it literally today produces nothing; executing it on its own stated date (2026-08-24) produces a **false pass** that retires the ticket.

2. **The unanimous top structural finding is that "client-side budget" is being read as a quota guarantee, and it is not.** `SentryEventBudget` is per process. The org allowance (50,000 errors/month, shared with Acetate) is per organization. All three models independently identified this gap; Claude wrote the arithmetic down (50,000 / 30 days / 50 per process ≈ **34 simultaneously-noisy installs** to consume the org's entire daily allowance).

3. **Two of three reviewers name the same single highest-value missing item: a durable server-side detector.** The incident's defining property was silence, and the plan's answer to silence is one human looking once at one number. Claude grepped the repo and confirmed no `stats_v2` / `usageExceeded` check exists in any script, workflow, or source file. It exists only in prose.

4. **The verification is unrunnable and, when it becomes runnable, uninterpretable.** #401 (`42ce4c919`) is on `origin/main` only; `origin/release/v0.63.0` does not contain it; the latest tag is v0.61.0. Meanwhile production traffic is dominated by 0.58.0+116 (1,725 of 1,784 events over 14 days). All three reviewers flag the adoption-curve problem; the post-fix aggregate will be dominated by installs that lack the fix, for weeks.

5. **One genuine disagreement exists and needs an operator decision:** the deliberate exemption of fatal events from the client-side budget. Gemini calls it the single most dangerous design choice in #401 (a crash-on-launch bug is the fastest possible quota kill). Codex calls it correct-but-unbounded and demands a monitoring and response plan. Claude does not address it. See section 6.

6. **A materially larger, adjacent exposure was found in the same audit and has no ticket:** org-wide `scrubIPAddresses: false` and `dataScrubber: false`, against opt-out-by-default telemetry (`defaultSendAnonymousTelemetry = true`) in a public, distributed desktop product. Claude and Codex both insist this must be assigned or explicitly scoped out **before C11-190 closes**, or it evaporates.

7. **Net recommendation implied by all three:** C11-190 as scoped cannot succeed. Rewrite the plan file from the audit, retitle the ticket (the false date is its highest-traffic surface), and re-scope to: release gate → attributable verification with a positive control → durable monitor → written fleet allocation → privacy decision.

---

## 1. Consensus Risks (flagged by multiple models, highest priority)

### 1.1 The plan is stale in load-bearing ways, and reads as authoritative (3/3)

1. **The 2026-08-24 trigger is dead.** Org is on Team, billing period reset 2026-08-04, `usage: 0`, `usageExceeded: false`. All three models lead with this.
2. **The ticket title still hardcodes 2026-08-24.** Board sweeps read titles. Claude calls this a defect in itself: the ticket has been accidentally engineered into a zombie (`in_progress`, unassigned, gated on a date that does not exist).
3. **The correction lives where the reader will not look.** PR #401 committed the *pre-audit* plan text while the audit went into the Lattice event log as a comment. The commit made stale text look fresh. Claude and Codex both treat this as a workflow-level defect, not a one-off: a Lattice comment does not amend a plan, and the plan is what gets read.
4. **`platform/sentry.md` now contains contradictory instructions side by side** (Codex): the quota-incident section still carries the 5,000-error / 2026-08-24 / no-on-demand narrative while the account and fence sections say Team / 50,000 / $49. A new operator can execute the wrong instructions depending on which section they open.

### 1.2 Per-process budget is not an org budget (3/3, and the strongest technical consensus)

5. **The arithmetic nobody wrote down** (Claude): 50,000/month ÷ 30 days ÷ 50 per process ≈ 33.3. At roughly **34 simultaneously-noisy installs**, c11's own fence permits the fleet to exceed the entire org's daily allowance.
6. **`platform/sentry.md` twice tells other people to do this division** ("size a new client's budget against the whole org's 50,000"; "[acetate's 30/hour] bounds a single crash loop but not a fleet") and c11's own budget was sized the way the doc warns against.
7. **The fence bounds one wedged process; it is not a quota guarantee** (Codex). It prevents a single process replaying hundreds of reports per hour. It does not compose into an org cap across clients.
8. **No written cross-client allocation exists** (3/3). c11 and Acetate share 50,000 with independent per-process caps and no rule for what is sacrificed first when usage rises. Gemini models the failure: legacy c11 (~40k) + Acetate (~15k) alone = 55k > 50k, before any crashloop.

### 1.3 No detector: the incident's actual root cause is unaddressed (2/3 strong, 3/3 implied)

9. **Every fix in #401 reduces what c11 *sends*. Not one of them tells anyone when the org goes blind again.** Claude's formulation; Codex's blind spot #4 is the same finding.
10. **There is no scheduled check** of `customers/stage-11-kl` → `categories.errors.usageExceeded`, no alert on nonzero `outcome=rate_limited`, no dead-man's-switch on event *absence*, no Sentry-native alert rule.
11. **Verified by grep** (Claude): no `stats_v2` / `usageExceeded` check in any script, workflow, or source file in the repo.
12. **The cheapest viable version is under an hour of work**: a cron or GitHub Action running the two curls already documented in `platform/sentry.md`, failing loudly on `usageExceeded: true` or `rate_limited > 0`. Both Claude and Codex identify this as the only item on the ticket with permanent value.
13. **A one-time manual check recreates the exact failure mode of the incident** (Codex). The plan proposes to check by hand precisely the thing that needs to be checked by machine.

### 1.4 No release gate and no attribution model (3/3)

14. **#401 has no shipping vehicle.** `42ce4c919` is on `origin/main` only. `origin/release/v0.63.0` does not contain it. Latest tag is v0.61.0. There is currently no build in any user's hands containing the budget, the hang throttle, or the CLI DSN removal.
15. **Adoption lag makes the number uninterpretable** (3/3). 1,725 of 1,784 production events over 14 days came from `0.58.0+116` alone, three releases behind `main`. A post-#401 aggregate will be dominated by un-upgraded installs for weeks. Gemini: legacy clients keep sending ~40k/month until users naturally upgrade, "which could take months."
16. **The success criterion is therefore not attributable to the fix** (Claude A7, Codex "unproven"). The plan has no release-tag breakdown, no adoption threshold, no environment filter.

### 1.5 The verification has no acceptance criteria and no positive control (2/3 strong)

17. **"Confirm accepted" is not a test.** No observation window, query parameters, project/environment/release filters, success threshold, saved sanitized artifact, or failure branch (Codex).
18. **A low `accepted` count is consistent with at least six different world-states** (Claude): the fix worked, the quota blew again, telemetry consent got flipped, the DSN is wrong, the SDK failed to start, or the budget is eating real signal. The plan cannot distinguish them.
19. **The org already owns the correct pattern and the plan ignored it.** Acetate's `verify_sentry_arrival.py --live` sends through the real frozen binary and asserts on what the server *stored*. `platform/sentry.md` explicitly names it "the pattern to copy."
20. **The recommended shape** (Claude, mirrored by Codex's Q4): (a) assert pre-flight config by reading it back, (b) send a canary from the **real signed build** with a planted unique token, (c) read it back through the issues API and assert stored, token present, PII absent, (d) *only then* read the aggregate.
21. **Low volume is not health** (Claude + Codex). Health should be issue diversity, fatal delivery, release-tagged accepted outcomes, user impact, and rate-limit absence. The budget was specifically designed to make raw event count a weak proxy.

### 1.6 The privacy finding, found in the same audit, has no owner (2/3)

22. Org-wide `scrubIPAddresses: false` and `dataScrubber: false`. `platform/sentry.md` says plainly that c11 "is presumably storing its users' IPs and cities right now. Worth a decision."
23. **Context the doc omits** (Claude): `TelemetrySettings.defaultSendAnonymousTelemetry = true`. Telemetry is opt-out, on by default, in a public open-source distributed desktop product, feeding an org that stores client IP and derived city. The word "anonymous" is in the settings key and is not accurate.
24. **#401 fixed the CLI's `sendDefaultPii = true`** (the visible tip: another user's absolute home path in an issue title). It did not touch the **org-level** setting, which is where IP and geo attach server-side and where no client-side change can reach.
25. **Both models demand disposition before close**: C11-190 carries it, or a sibling ticket is created before C11-190 closes, or it is explicitly recorded as out of scope. "Worth a decision" in a doc is not an owner.

---

## 2. Unique Concerns (single-model, worth investigating)

### 2.1 Gemini only

26. **Server-side Inbound Data Filters were never considered.** The plan correctly notes per-key rate limits are Business-gated, then stops. Sentry's server-side inbound filtering (by release version, custom drop rules) is a different mechanism on a different gate. **Can legacy releases be dropped server-side before they count against the quota?** The plan never asks. This is the single most actionable unique finding: it is the only proposed mechanism that would actually address the un-upgradeable legacy fleet.
27. **The 1.12M CLI errors are being treated as a telemetry nuisance, not an engineering failure.** 1.12 million socket/hook failures per month is evidence of a severely broken CLI user experience. "We deactivated the key" silences the reporter; it does not investigate why the CLI cannot connect to its socket. Gemini calls this "a massive abdication of engineering responsibility." Neither Claude nor Codex raises root cause at all; both accept the DSN removal as the fix.
28. **Crashloop as the modal quota-kill scenario.** A crash-on-launch bug generating 60,000 fatal events in hours, with fatals exempt from the budget, hits the $49 ceiling and blacks out Sentry for *every* Stage 11 project for the rest of the cycle.
29. **The $49 hard cap protects finance and harms observability.** True for the wallet, false for visibility: hitting it early in a month shuts down monitoring org-wide, including Acetate.

### 2.2 Claude only

30. **Hang events are charged twice** (D2). `MainThreadHangMonitor.shouldReportHangToSentry` calls `allow(.hang)`, which records into `hangHourly`/`hangDaily` **and** `globalHourly`/`globalDaily`. The event then reaches `beforeSend`, which runs `allow(kind)` again; being `.warning`, it classifies as `.other` and consumes a **second** global slot. `platform/sentry.md` documents a budget the code does not implement. Three hangs consume six global slots.
31. **Sentry's own app-hang tracking bypasses the hang sub-budget entirely** (D3). `appHangTimeoutInterval = 8.0` is still set; SDK-originated hang events never touch `MainThreadHangMonitor`, reach `beforeSend`, are not `.fatal`, and classify as `.other`. The `Kind.hang` case is reachable **only** from c11's own watchdog. The `App Hanging ...` issue class named in this ticket's own problem statement is fenced only by the global budget.
32. **The budget resets on every process launch** (D4). Both windows live in a process-local struct; a crash-and-relaunch loop or a user who quits and reopens several times a day resets the daily cap each time. "50/day" is really "50 per process lifetime."
33. **Suppression is invisible where the plan will look.** Two distinct drop paths post-#401: `beforeSend` returning nil surfaces as `client_discard` in `stats_v2`; `shouldReportHangToSentry` returning false means the event **never reaches the SDK**, so it is invisible to Sentry entirely, recorded only as a `sentrySuppressed=n/m` string in a local log on the user's machine. `client_discard` will therefore undercount actual suppression, possibly by a lot.
34. **Deactivate-vs-delete has flipped** (D6). Deactivation was right in the moment (reversible, preserves history). Now that the org is unblocked and the CLI DSN is off `main`, reversibility is pure downside: a mutable web-console setting, no guard, no alert, protecting against a population that shrinks but never reaches zero. The plan advertises "one PUT reverses it" with no warning attached.
35. **Nothing gates client number three.** No CI check, no `new-project-checklist.md` entry, no requirement that a new Sentry client declare a budget sized against the shared 50,000. The Acetate lesson is prose, and prose is not a gate.
36. **Non-error categories are unwatched.** `tracesSampleRate = 0.1` is live; transactions and spans bill separately against the same shared $20 on-demand pool. The $49 ceiling caps the bill, not the surprise.
37. **The plan commits the very error it exists to warn against** (A4). It cites ~1,466 accepted errors/30d as c11's steady state. That was a *throttled* figure. Attempted rate was ~1,343/day (~40k/month). Accepted-vs-attempted confusion, committed inside the plan written about accepted-vs-attempted confusion.
38. **Item 2 has silently changed genre.** Framed as "Billing = operator decision." Billing is settled and delivered no fence. What remains (how much of the 50,000 does c11 get, how is it enforced, what happens at client three) is an **engineering sizing** decision with no owner, because the plan believes a purchase answered it.

### 2.3 Codex only

39. **The synthetic-event question is unresolved as policy.** May the verifier deliberately emit one bounded, clearly tagged production-path event? If so, who authorizes it, how is it distinguished from a real incident, and how is it removed or ignored afterward? Querying ambient traffic alone cannot prove the full event-to-storage path at a chosen moment.
40. **"Under ~150 events on the historic worst day" is a model, not evidence.** The audit's projected reduction must not be presented as achieved until a fixed release has observed real production traffic.
41. **The failure branch is undefined.** If verification fails, who investigates, and does that block the ticket or roll back the release?
42. **The durable artifact should be a specified runbook**, recording: query timestamp and range, org plan and remaining capacity, per-project outcome totals, release/environment filters, threshold, owner, escalation action.
43. **Item 3 should be reframed, not deleted.** Discovery is done (the live `main` CLI was the source). What remains is: "verify no supported released artifact retains the retired CLI DSN, and record the first fixed version."

---

## 3. Merged Assumption Audit

### 3.1 Load-bearing and currently FALSE

| # | Assumption | Status | Raised by |
|---|---|---|---|
| A1 | Org is blocked until 2026-08-24; c11 is blind right now. | **False.** Team plan, period reset 2026-08-04, `usage: 0`, `usageExceeded: false`. | All 3 |
| A2 | Org cap is 5,000 errors/month on Developer, no on-demand. | **False.** 50,000 on Team, `allowOnDemand: true`, $20 shared on-demand, $49 hard ceiling. | All 3 |
| A3 | The only fences are a paid plan or an on-demand budget. | **False, and the dangerous half.** The paid plan was purchased and delivered **no fence**. Per-key rate limits are Business-gated; re-verified post-upgrade (`rateLimit: null` / 403). Anyone acting on this sentence buys the wrong thing and believes they are safe. | Claude, Codex |
| A4 | c11's steady state is ~1,466 accepted errors/30d. | **False.** That was a *throttled* figure. Attempted was ~1,343/day (~40k/month) against 50k shared with Acetate. | Claude |
| A5 | The retired DSN only exists in old builds in the wild. | **False.** `CLI/c11.swift` on `main` carried it, and was the 1.12M-event source. The problem was in the repo, not only in the field. | Claude, Codex |
| A6 | PR #401's controls are active in production. | **False today.** `42ce4c919` is on `origin/main` only; not on `origin/release/v0.63.0`; latest tag v0.61.0. No shipping vehicle exists. | All 3 |
| A7 | The client-side throttle protects the org quota. | **False as framed.** Per-process, not org-wide; fatals exempt; legacy clients bypass entirely. Gemini rates likelihood-to-hold as **zero**. | All 3 |

### 3.2 Load-bearing and unexamined

| # | Assumption | Why it matters | Raised by |
|---|---|---|---|
| A8 | Fleet adoption is fast enough that a post-fix aggregate reflects the fix. | Almost certainly false; 1,725/1,784 events from 0.58.0+116. Verification will read mostly un-upgraded installs. | All 3 |
| A9 | A per-process budget bounds org-wide consumption. | False as arithmetic: ~34 noisy installs consume the org's daily allowance. | Claude, Codex |
| A10 | The deactivated `demo-project` key stays deactivated. | Unguarded. Nothing enforces it, nothing alerts on reactivation, and the plan advertises the one-PUT reversal without a warning. | Claude |
| A11 | Errors are the only billing category that matters. | `tracesSampleRate = 0.1` is live; transactions/spans draw on the same $20 pool. Unwatched. | Claude |
| A12 | Verification is only about volume. | A fence that drops 40k events is indistinguishable, by volume, from a fence that drops the one crash that mattered. | Claude, Codex |
| A13 | "Low thousands per month" is inherently safe. | Unquantified without a denominator: unique versions, active installs, days observed, counts by outcome. | Codex |
| A14 | `stats_v2` remains the storage oracle. | Probably true, but exact supported query and result semantics must be captured in a runbook, not left as an endpoint name. | Codex |
| A15 | The CLI socket/hook errors were just noise. | 1.12M failures/month is evidence of a badly broken CLI UX, not noisy telemetry. Root cause unexamined. | Gemini |
| A16 | A $49 hard cap protects the business. | True for finance, false for observability: hitting it early blacks out Sentry for **all** Stage 11 projects. | Gemini |
| A17 | Fatal exemption is safe because crashes matter most. | Deliberate unbounded path. Thousands of identical crashloop fatals add zero debugging value and destroy org observability. | Codex, Gemini |

### 3.3 Invisible assumptions

| # | Assumption | Raised by |
|---|---|---|
| A18 | Whoever executes this ticket will read the Lattice event log, not just the plan file. There is no reason to expect this, and the plan gives no pointer to the audit. | Claude |
| A19 | Item 2 ("budget question") is purely a billing decision for the operator. It is now primarily an engineering sizing decision. | Claude |
| A20 | c11 and Acetate are the only clients. Any future Stage 11 project inherits the same shared cap with no server-side fence and no gate forcing it to declare a budget. | Claude, Codex |
| A21 | Client-side is the only available defense given Team-tier limits. Sentry's server-side inbound data filters were never evaluated. | Gemini |
| A22 | The documented budget matches the implemented budget. It does not: hangs double-charge, and SDK app-hangs bypass the hang sub-budget. | Claude |

---

## 4. The Uncomfortable Truths (recurring hard messages)

1. **"Nothing alerted" is still true.** Every fix in #401 reduces what c11 sends. Not one of them tells anyone when the org goes blind again. If exactly one thing gets done on this ticket, it should be the monitor, not the verification. *(Claude, echoed by Codex)*

2. **The plan is currently a liability, not an asset.** Its most-cited facts are false, its date is wrong, its title propagates the wrong date to every board reader, and the correction lives where the reader will not look. A blank ticket saying "verify Sentry works" would mislead less. **First action is to rewrite the plan file, not to execute it.** *(Claude; Codex: "an incident note, not a usable implementation contract")*

3. **This ticket cannot succeed as scoped.** Item 1 requires a release that does not exist. Items 2 and 3 are answered or reframed. Executed today: nothing useful. Executed on 2026-08-24: a false pass, which is worse than a failure because it retires the ticket. *(All 3)*

4. **"Client-side-only fence" is a mitigation, not isolation.** The org has no server-side per-key guardrail, so every client, present and future, is *trusted* not to collectively overrun the quota. Our observability is at the mercy of our clients' behavior. *(Codex, Gemini)*

5. **The fence shipped and its arithmetic was never checked against the fleet.** 50/day/process against ~1,666/day org-wide is ~34 installs. That division takes ten seconds and nobody did it, including the doc that twice tells other people to do it. #401 is a large improvement over unbounded, and it is **not a bound**. *(Claude)*

6. **A budget that eats ~98% of your events is not only a quota fix; it is a decision to stop looking.** Hang visibility is now hard-capped at 3/hour/process before any judgment about whether the current hang is new, worse, or spreading. c11 has traded away hang volume as a signal, and the replacement is a string in a local log file that never leaves the user's machine. *(Claude)*

7. **We silenced the reporter instead of fixing the reported thing.** 1.12M CLI socket/hook failures were treated as a quota nuisance. The application is still failing; we just stopped looking at it. We are paying Sentry to accommodate our own architectural inefficiencies rather than fixing them at the root. *(Gemini)*

8. **We confused accepted with attempted, twice.** Once in the incident, and once *inside the plan written about the incident*. Any doc or ticket citing a Sentry event count should be required to state which outcome it means. *(Claude)*

9. **The privacy finding is being carried by a paragraph.** Opt-out-by-default telemetry from a public product into an org with `scrubIPAddresses: false` and `dataScrubber: false` is a larger exposure than a blown quota, was found in the same audit, and has no ticket. Two years out it is either a non-event or a very bad day, and which one has nothing to do with how careful anyone was. *(Claude, Codex)*

10. **The plan file and the truth diverged the moment the audit landed, and the mechanism is generalizable.** A Lattice comment does not amend a plan, and the plan is what gets read. This is a workflow defect worth fixing beyond this ticket. Compounding it: `platform/sentry.md` now holds obsolete and current quota instructions adjacent, unlabeled. *(Claude, Codex)*

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews. Grouped by theme; numbering is continuous.

### A. Plan integrity and ticket hygiene

1. **Will you retitle the ticket today?** `"...verify it resumes after the 2026-08-24 quota reset"` is false, costs nothing to fix, and is the highest-traffic surface of this ticket. *(Claude)*
2. **Why was the plan file left stale after the audit, and what is the rule for amending a Lattice plan when reality moves?** #401 committed the pre-audit text while the correction went to the event log. Does such a rule exist? *(Claude)*
3. **What is the ticket's actual definition of done, restated post-audit?** Write the new list, or close C11-190 and open the ticket that reflects what remains. Leaving it `in_progress`, unassigned, with a date-stamped false title is the worst of the three options. *(Claude, Codex)*
4. **When will `platform/sentry.md`'s historical incident text be reconciled or clearly labeled** so the obsolete 5,000-error / 2026-08-24 instructions cannot be executed as current operations? *(Codex)*
5. **Now that the org is unblocked, why does the plan still mandate waiting to verify rather than verifying as soon as a fixed release exists?** *(Gemini)*

### B. Release gate and attribution

6. **What exact released version/build will carry #401, and when?** `42ce4c919` is on `origin/main` only. Item 1 is unrunnable until this is answered with a version number. *(All 3)*
7. **What production uptake threshold makes the `stats_v2` result representative?** Given 1,725 of 1,784 events came from 0.58.0+116, what release-tag breakdown at what adoption level constitutes a pass? Without this, item 1 has no pass criterion, only a vibe. *(Claude, Codex)*
8. **Which supported release is the first with no compiled-in retired CLI DSN, and how will you verify no remaining supported distribution artifact retains it?** *(Codex)*

### C. Verification method

9. **What exact `stats_v2` query, project filter, outcome set, release/environment dimensions, interval, and observation window constitute proof that events were *stored*?** *(Codex)*
10. **What minimum accepted count proves delivery without treating a coincidentally quiet period as success, and what nonzero `rate_limited` count fails the ticket?** *(Codex)*
11. **What is the positive control?** Will you adopt the read-back canary (Acetate's `verify_sentry_arrival.py --live`, already named in `platform/sentry.md` as the pattern to copy), or is item 1 staying an aggregate glance? If staying, how do you distinguish "healthy and quiet" from "silently broken"? *(Claude, Codex)*
12. **May the verifier emit one bounded, clearly tagged synthetic production-path event?** If yes: who authorizes it, how is it distinguished from a real incident, and what read-back proves storage? *(Codex)*
13. **What is the failure branch?** If verification fails, who investigates, and does it block the ticket or roll back the release? *(Codex)*

### D. Monitoring and detection (the consensus priority)

14. **What monitors the quota from here?** Name the mechanism, the cadence, the owner, the escalation threshold, and where it alerts. If the answer is "a human will check," say so explicitly and then explain why that differs from what produced the incident. *(Claude, Codex; both rate this the most important gap on the ticket)*
15. **Will the durable artifact be a credential-safe runbook or scheduled check** recording query timestamp/range, org plan and remaining capacity, per-project outcome totals, release/environment filters, threshold, owner, and escalation action? *(Codex)*
16. **Which early-warning signals will actually be watched?** The candidate set, all one-line assertions on data reachable with the two curls already in `platform/sentry.md`:
    - `rate_limited > 0` on any project, any interval
    - `accepted` near zero for c11 while installs are demonstrably running (dead-man's switch; the current design reads this as *success*)
    - `client_discard` climbing (the budget eating volume a human should see)
    - `demo-project` key flipping back to `isActive: true`
    - on-demand spend accruing at all, in any category
    - a new project appearing in `stats_v2 groupBy=project` with no declared budget
    *(Claude, Codex)*

### E. Capacity, allocation, and the fleet

17. **Do you accept the fleet arithmetic?** 50/day/process, ~34 installs, and c11 alone can consume the org's entire daily allowance. Accept with eyes open, resize, or add a second-order fence. This needs a written answer, not an implied one. *(Claude, Codex)*
18. **What monthly allocation belongs to c11, Acetate, and future projects,** and what is sacrificed first when usage rises? *(Claude, Codex)*
19. **Have you modeled Acetate's projected monthly volume,** and does it leave headroom for c11's baseline plus the legacy footprint? *(Gemini, Codex)*
20. **What stops client number three?** No CI check, no `new-project-checklist.md` entry, no gate requires a new Sentry client to declare a budget sized against the shared 50,000. What makes the Acetate lesson binding rather than advisory? *(Claude, Codex)*
21. **Is anyone watching the non-error categories?** `tracesSampleRate = 0.1` is live and transactions/spans draw on the same $20 shared on-demand pool. The $49 ceiling caps the bill, not the surprise. *(Claude)*

### F. Fence design and correctness

22. **Why were fatal errors exempted from the client-side budget,** given that a crash-on-launch loop is the single fastest way to exhaust an unprotected quota? What is the response if fatal volume accelerates, and what emergency action is pre-authorized? *(Gemini, Codex)*
23. **What server-side mechanism will prevent legacy clients (v0.58.0 and earlier, lacking the throttle) from consuming most of the 50,000?** Specifically: have Sentry's **server-side Inbound Data Filters** (drop by release version, custom rules) been evaluated? The plan never asks. *(Gemini)*
24. **Was the double-charge intended?** A hang consumes a global slot at `allow(.hang)` and a second at `beforeSend` (classified `.other` because it is `.warning`, not `.fatal`). `platform/sentry.md` documents a budget the code does not implement. Fix the code or fix the doc. *(Claude)*
25. **Should SDK app-hang events (`appHangTimeoutInterval = 8.0`) be classified `.hang` in `beforeSend`?** Today they are `.other` and bypass the hang sub-budget entirely, so the `App Hanging ...` issue class named in this ticket's own problem statement is unfenced except by the global cap. *(Claude)*
26. **Is the per-process-lifetime reset acceptable?** Both budget windows live in a process-local struct; a crash-and-relaunch loop resets the daily cap each time. *(Claude)*
27. **How will suppression be measured in the field?** `shouldReportHangToSentry` rejections never reach the SDK, so they are invisible to Sentry; only `beforeSend` nils show as `client_discard`. `client_discard` will undercount real suppression. `sentrySuppressed=n/m` in a local log on a user's machine is not a measurement. *(Claude)*
28. **Delete the `demo-project` key rather than deactivate it?** If it stays deactivated, what watches `isActive`? Right now the answer is nothing, and the plan advertises the one-PUT reversal without a warning attached. *(Claude)*

### G. Root cause and scope

29. **What is the root cause of the 1.12 million CLI socket/hook errors, and why is "stop reporting them" an acceptable engineering response to that volume of failure?** *(Gemini; not raised by the other two, and unrebutted)*
30. **Who owns the org-wide privacy setting?** `scrubIPAddresses: false`, `dataScrubber: false`, with `defaultSendAnonymousTelemetry = true` in a public product. Does C11-190 carry it, or is a sibling ticket created before C11-190 closes, or is it explicitly recorded as out of scope? "Worth a decision" in a doc is not an owner. *(Claude, Codex)*

---

## 6. Where the Reviewers Disagree (operator decision required)

1. **Fatal-event exemption.** Gemini treats it as the plan's most dangerous flaw and its central hindsight scenario (60,000 fatals in hours, $49 ceiling, org-wide blackout). Codex calls it "correctly protects real crashes, but a deliberate unbounded path" and asks only for monitoring plus a pre-authorized emergency response. Claude does not address it at all. **These are not reconcilable by synthesis: someone must decide whether crashloop fatals get a cap, a circuit breaker, or a monitored exemption.**

2. **Root-cause obligation for the 1.12M CLI errors.** Gemini treats silencing them as an abdication. Claude and Codex both accept the DSN removal as the appropriate remediation and never ask why the CLI fails to connect. **Unrebutted rather than contested, which usually means it deserves a look.**

3. **Server-side inbound filters.** Only Gemini raises them. Claude and Codex both accept "no server-side fence exists on Team" as settled fact. If inbound data filters can drop by release version, that premise is at least partly wrong, and it is the only mechanism proposed by any reviewer that addresses the un-upgradeable legacy fleet. **Worth a 15-minute check before any further capacity planning.**

---

## 7. Minimum Viable Re-Scope (implied by all three, in priority order)

1. **Rewrite the plan file from the audit; retitle the ticket.** Cost: minutes. Currently the plan misleads every reader.
2. **Build the monitor.** A scheduled check on `usageExceeded`, `rate_limited`, `client_discard`, and event-absence, with an owner and an escalation path. Cost: under an hour using the curls already documented. **The only item on the ticket with permanent value.**
3. **Write down the fleet arithmetic and the cross-client allocation.** Accept, resize, or add a second fence, in writing.
4. **Decide the fatal-exemption question and check server-side inbound filters.**
5. **Assign or explicitly scope out the privacy finding, before C11-190 closes.**
6. **Reconcile the budget-accounting drift** (double-charge, SDK app-hang classification) between code and `platform/sentry.md`.
7. **Verify last**, once a release actually carries #401, with a read-back positive control and a stated attribution threshold, not an aggregate glance.
