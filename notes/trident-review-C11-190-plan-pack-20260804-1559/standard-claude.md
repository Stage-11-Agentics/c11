# Standard Plan Review: C11-190 (Sentry quota incident, verification remainder)

- PLAN_ID: `c11-190-plan`
- MODEL: Claude
- Reviewed: 2026-08-04
- Plan file: `/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01KZ6YXZRV8SH2V7FJJKPM7QCJ.md`
- Context read: audit comment `ev_01KZ7351DG3WBXE5N4CDAA2HEF`, merged PR #401 (`42ce4c919`), `code/platform/sentry.md`, `Sources/SentryHelper.swift`, `Sources/AppDelegate.swift`, `Sources/MainThreadHangMonitor.swift`, `CLI/c11.swift`, git refs.

---

## Executive Summary

As an incident write-up, this document is excellent: it is specific, it names IDs, it distinguishes what was done from what remains, and it captures the one generalizable lesson (an HTTP 200 with an event id is not storage). As **the contract for what remains on this ticket**, it is now materially stale and, worse, actively misleading. Two of its three remaining items are answered, its title fixes on a date that no longer exists, and its item 2 rests on a premise the audit disproved (that a paid plan would provide a fence; Team does not).

The single most important thing in this review is not in the plan at all:

> **PR #401 is on `main` and is NOT on `origin/release/v0.63.0`, the in-flight release branch that has already been version-bumped and is dated 2026-07-31.** Verified: `git merge-base --is-ancestor 42ce4c919 origin/release/v0.63.0` returns false, and `git grep SentryEventBudget origin/release/v0.63.0` returns nothing. `v0.61.0` is likewise not an ancestor of `main`, confirming this repo's known pattern of a release line that diverges from `main`.

So the entire remaining verification premise, "after PR #401 ships in a release, confirm accepted volume drops," has no scheduled path to being true. If v0.63.0 cuts as staged, the fix ships in v0.64.0 at the earliest, and the fleet mix in the audit (1,725 of 1,784 production events from `0.58.0+116`, while tags already reach v0.61.0) says real installs trail releases by several versions. The verification this ticket exists to perform is therefore weeks to months out, gated on a step nobody has written down.

Second most important: the plan closes on a **one-time manual check** for an incident whose defining property was that **nothing alerted for a week**. Reducing the input (which #401 does well) is not the same as installing the detector. If this ticket closes with "I ran the curl and saw `accepted`," the org is one noisy neighbour away from a silent repeat, and the next repeat will again be found by accident, on a different project, by a different agent.

Verdict: **Needs revision.** The technical work behind it is strong; the document as a forward-looking contract needs a rewrite of its remaining scope.

---

## The Plan's Intent vs. Its Execution

**Intent, stated:** verify that error monitoring resumes.

**Intent, actual (reading between the lines):** make c11's production error monitoring trustworthy again, and make sure "trustworthy" is a property somebody can observe rather than assume.

The gap between those two is where the plan drifts. Item 1 verifies resumption **once**. It does not establish an ongoing signal. The lesson the plan itself articulates so well in its own consequence paragraph, that exhaustion is silent to the sender and only `stats_v2` can see it, implies a recurring reader, not a single reader. The plan states the lesson and then does not act on it.

Three concrete drifts from the audited reality:

| Plan text | Reality (audit, 2026-08-04) |
|---|---|
| Title and item 1: "after the 2026-08-24 quota reset" | Billing period already reset 2026-08-04 → 2026-09-03, usage 0, `usageExceeded: false`. Org is Team (`am3_team`), 50,000 errors, `allowOnDemand: true`. Nothing to wait for. |
| Item 2: "the only fences are a paid plan or an on-demand budget. Billing = operator decision." | The paid plan landed and **did not** deliver a fence. Per-key rate limits are Business-gated; re-verified after upgrade (`rateLimit: null` with user token, 403 with org token). Client-side is still the only fence. The decision is made; the premise under it was wrong. |
| Item 3: "Consider whether any shipped c11 build still points at the retired DSN" | Answered, and bigger than "old builds": `CLI/c11.swift` on `main` hard-coded demo-project's DSN with `sendDefaultPii = true`, firing per shell prompt / per tool call / per hook. That was the 1,121,397 rejected events. Fixed in #401. |

The harm from leaving this stale is not abstract. A fresh agent picking this ticket up cold will (a) wait until 2026-08-24 for a reset that already happened, (b) take a resolved billing question back to the operator, and (c) re-investigate the CLI DSN. This repo has already recorded exactly this failure mode once, in `platform/sentry.md`'s Secrets banner: a stale pointer "cost an ACE-801 agent a wrong ask to the operator." Same shape, same cost.

**One nuance the audit did not fully close, and the plan should keep open:** item 3 was answered for the **CLI**. It was not explicitly answered for the **app**. c11 migrated to its own project on 2026-04-29, so any app build older than that points at a now-deactivated key and reports **nowhere at all**. That is probably fine and probably nobody, but it is currently an unstated assumption rather than a closed line. State it and close it.

---

## Architectural Assessment

The remaining problem decomposes into four things, and the plan names one and a half of them.

1. **Did storage resume?** (plan item 1). Now trivially answerable and effectively already answered by the audit: quota reset, usage 0, `usageExceeded: false`. This should be closed today, not deferred.
2. **Did the fix reach the fleet?** (not in the plan). This is the real remaining work, and it is a release-engineering item, not a Sentry item.
3. **Will we know next time?** (not in the plan). Quota alerting / a recurring position check.
4. **Is the fence actually the right shape?** (not in the plan). #401's budget is per-process and in-memory; the quota is org-wide and fleet-scale.

The right structure for the remainder is a small, checkable ladder rather than a narrative:

```
AC1  Org position is healthy now              (one curl, closeable today)
AC2  #401 is on the shipping release branch   (cherry-pick onto release/v0.63.0, or explicit defer to v0.64.0 with a date)
AC3  Post-ship, c11 stats_v2 shows outcome=accepted, rate_limited=0,
     and a 30d projected accepted total under an explicit number (name it)
AC4  A quota-exhaustion signal exists that does not depend on a human running a curl
AC5  Open hygiene items closed or split out (org-wide IP/geo scrubbing; demo-project key
     final disposition; platform/sentry.md self-contradiction)
```

That is roughly the same content, but each line has a pass condition and an owner. The current three bullets have neither.

**On the "verify then close" framing more broadly.** The plan treats verification as the terminal state. I would argue the terminal state for an observability incident is *a working alarm*, and verification is just the evidence you collected on the way there. Framed that way, item 1 stops being the ticket's purpose and becomes its first line.

---

## Is This the Move?

Mostly yes on what was done, with two bets I would question.

**The right call, clearly:** deactivating the key rather than deleting the project (reversible, one PUT), and fixing the sender rather than chasing the quota. #401 attacks the actual cause: 98% of volume was one wedge re-reported every 5s while Sentry grouped it into a single issue anyway. Cutting worthless volume is strictly better than buying headroom for it.

**Bet I would question 1: a per-process, in-memory budget as *the* fence.** `SentryEventBudget` lives in `SentryEventBudgetGate.shared` with no persistence. It resets to a clean 50/day on every launch. c11 is a terminal multiplexer that its own maintainers relaunch constantly (`reload.sh`), and a crash-loop or a wedge-then-force-quit-then-relaunch cycle is precisely the pathological case the budget is meant to bound. The daily cap is therefore much softer than "50/day" reads. `platform/sentry.md` already concedes the fleet version of this for acetate ("bounds a single crash loop but not a fleet"); the same sentence applies to c11 and is not written down. Fleet arithmetic: 30 wedged installs × 50/day × 30 days = 45,000, i.e. the quota, from the throttled path. The fence bounds one process on one day, which is genuinely valuable, and is not the same as bounding the bill or the blindness.

Cheap hardening: persist the sliding-window stamps to `~/Library/Caches/<bundle-id>/` and rehydrate on launch. Ten lines against the exact scenario that started this incident.

**Bet I would question 2: closing without an alarm.** See above. The cost of the alarm is small (Sentry's org-level quota/spend notification settings, plus optionally a scheduled `stats_v2` read); the cost of not having it is a repeat of a week of blindness discovered by luck.

---

## Findings in the Landed Code (relevant because AC3's numbers depend on them)

The plan's remaining item is "confirm the volume actually dropped." Three things in #401 will move those numbers in ways the predicted "1,848 → under ~150" does not account for.

**1. Hang events are charged to the global budget twice.**

`MainThreadHangMonitor.shouldReportHangToSentry` calls `SentryEventBudgetGate.shared.allow(.hang)` (line 307), which records into `hangHourly`, `hangDaily`, **and** `globalHourly`/`globalDaily`. The resulting `SentrySDK.capture(message:)` then passes through `options.beforeSend` in `AppDelegate.swift:2623`, which classifies by level only (`event.level == .fatal ? .crash : .other`) and calls `allow(.other)`, recording into `globalHourly`/`globalDaily` **again**. Every hang report consumes two global slots.

Worse than the arithmetic: if the global budget is exhausted at the `beforeSend` stage, the hang budget has already been consumed **and** `reportedCurrentEpisode = true` has already been set (line 308). The episode is marked as reported, the event is discarded, and that episode is never reported at all. That is a silent hole in exactly the signal path this ticket cares about.

The clean fix is one consumption point: classify in `beforeSend` (the hang path is identifiable by the `category` tag it already sets, or by message prefix) and let the monitor's `reportedCurrentEpisode` be the only per-episode gate.

**2. The SDK's own app-hang tracker bypasses the hang sub-budget.**

`options.appHangTimeoutInterval = 8.0` is set and `enableAppHangTracking` is never disabled, so Sentry's native ANR tracker is live and emits its own "App Hanging" events (this is the same generator behind the stale `App Hanging ... 2000 ms` issues cited in the plan). Those events reach `beforeSend` at non-fatal level and are classified `.other`, so they face only the 20/hour and 50/day global caps and **never** the 3/hour, 15/day hang sub-cap. The claim in `platform/sentry.md`'s fence table and in #401's commit message, that at most 3 hang reports per hour may be sent, is not true as implemented. It also means the same wedge can produce two events: one from the custom watchdog at 5s and one from the SDK at 8s.

Decide one owner for hang reporting. If the custom watchdog is the owner (it should be; it captures a backtrace mid-wedge, which the SDK cannot), set `enableAppHangTracking = false`.

**3. `beforeSend` classification is level-based, so nothing is ever `.hang` at that layer.** Consequence of 1 and 2; noted separately because the enum has three cases and only two are reachable from `beforeSend`.

None of these are reasons to reopen #401 as a whole. They are reasons the "under ~150/day" prediction should be treated as a hypothesis to be measured, not a result, which is precisely what AC3 is for. Worth its own follow-up ticket so AC3 is measuring a known quantity.

---

## Key Strengths

- **It separates done from remaining, with reversibility spelled out.** "The project is intact, not deleted; one PUT reverses it," plus the exact key id, is the difference between an artifact a stranger can act on and one they have to re-derive. This is the strongest property of the document.
- **It names the actual epistemic trap.** "Check `outcome=accepted`, not just that the SDK returns an event id. The whole lesson here is that those two are not the same thing." That sentence is the ticket's real payload and it generalizes far past Sentry. It is the same lesson as this repo's "green tests are not a working product" and as `sentry.md`'s "verify against a stored event, never against the setting."
- **It quantifies.** 3,735 of 5,000, 1,121,397 rejected, 11,700 dropped, 1,466 accepted. Numbers make the follow-up falsifiable. Most incident notes do not do this.
- **It pushed the durable knowledge to `platform/sentry.md` rather than leaving it in the ticket.** Correct instinct: the ticket is ephemeral, the platform doc is where the next project reads it.
- **It correctly refuses to treat a billing change as an agent decision.** "Billing = operator decision" is the right boundary and matches `sentry.md`'s Dangerous list.

---

## Weaknesses and Gaps

**W1. The title is a lie now, and titles are what people read.** "verify it resumes after the 2026-08-24 quota reset" will be the only thing most readers see in a board view. It encodes an obsolete date and an obsolete blocked-state. Retitle to something like "Sentry: confirm c11 events are stored again and bounded after #401 ships."

**W2. No release gate.** The biggest one, detailed in the summary. The remaining verification cannot occur until #401 is in a shipped build, `release/v0.63.0` does not contain it, and nothing in the plan or the audit says who moves it there or when.

**W3. No fleet-adoption model.** Even once shipped, the audit's own data (1,725 of 1,784 events from `0.58.0+116`, against tags at v0.61.0) says the reporting population lags releases badly. AC3 measured a week after ship will be measuring mostly unfixed installs and will read as failure. The verification needs either a version-filtered stats query (measure the fixed version's per-install rate, not the fleet total) or an explicit "re-check at 30 days" schedule. Version-filtering is much better: it isolates the fix from adoption noise and is answerable in days rather than months.

**W4. No pass/fail numbers.** "In the low thousands rather than ~40k" is a vibe. Give AC3 a threshold: e.g. `rate_limited == 0` over 7d, `accepted > 0` within 24h of the first fixed build reporting, and per-install-day accepted events on the fixed version below some N. Without a number, the verifier's judgment is the acceptance criterion, which is how tickets close on optimism.

**W5. No recurrence detector.** Detailed above. This is the item I would most want added.

**W6. `platform/sentry.md` now contradicts itself, and the plan is why.** The top of the doc says Team, 50,000, `allowOnDemand: true`, $49 ceiling. The "quota incident" section further down still says the billing period runs "2026-07-25 → 2026-08-24 with `onDemandMaxSpend: 0` and `canTrial: false`. Everything the org sends is dropped until the reset," and its closing paragraph still reasons from the Developer plan ("the only real option is a paid plan", "`allowOnDemand: false`", "no small-dollar option between waiting for the reset and upgrading to Team"). The one-call position check still prints `reserved: 5000`. A reader who lands mid-document, which is how reference docs are read, gets the wrong plan, the wrong ceiling, and a nonexistent blocked-state. Reconciling that section is cheap and belongs in this ticket's remainder, since this ticket is the reason it drifted. (Two smaller doc bugs in the same file while you are in there: the Setup Checklist credits project id `4511028453900288` to `c11`, but that is demo-project's id; c11 is `4511304571158528`. And the CI section uses `SENTRY_PROJECT: stage11-c11` while the Active Projects table says the slug is `c11`. If the CI value is wrong, dSYM uploads are landing somewhere unexpected, which would show up as unsymbolicated crashes.)

**W7. An open privacy item adjacent to this ticket has no home.** `sentry.md` states plainly: "`organizations/stage-11-kl` has `scrubIPAddresses: false` and `dataScrubber: false`. Only the `acetate` project was changed. **c11 reports to this org and is presumably storing its users' IPs and cities right now.** Worth a decision." That is arguably higher-stakes than the remaining verification, it is on the c11 project specifically, and it is currently a sentence in a doc rather than a ticket. Either fold it into C11-190 or split it into C11-193 in the same breath, but do not let it stay a footnote. Note also that `acetate`'s fix required the leaf-selector trap workaround, so c11's fix is not a copy of the setting name, it is a copy of the verified config plus a read-back.

**W8. Final disposition of `demo-project` is undecided.** Its key is deactivated, its issues are intact, its project exists. That is a good incident-time action and a bad steady state: the next person to look at the org sees a project that could be re-enabled by one PUT and an alert rule nobody owns. Decide: delete the key outright, or document "deactivated permanently, do not re-enable" in the Retired table. One line either way.

**W9. No regression guard on the two things most likely to silently regress**: a compiled-in DSN reappearing in the CLI, and `beforeSend` losing its budget wiring. Note that this repo's test policy explicitly forbids grep/source-text tests, so a naive "assert no DSN string in `c11.swift`" test is not allowed here and should not be added. The policy-compliant options are a behavioral test (CLI run with `C11_CLI_SENTRY_DSN` unset produces no Sentry transport) or an explicit decision to accept the risk. Either is fine; silently having neither is what I would flag.

**W10. No owner, no date, no evidence artifact named.** The remaining items have no assignee and no "done looks like this file/paste." For a ticket whose whole subject is "nobody noticed," leaving the follow-up unowned is a thematically perfect mistake.

---

## Alternatives Considered

**A. One-time verification (plan's choice) vs. a standing quota alarm.**
The plan verifies once. The alternative installs a signal: Sentry's org-level quota and spend notification emails to `projects@stage11.ai`, and/or a scheduled `stats_v2` read that fails loudly on `rate_limited > 0`. Cost differential is small; the alarm strictly dominates, because the incident's defining property was the absence of one. The alarm does not replace the one-time check, it replaces the *need to remember* the one-time check. **Alternative is better. Adopt both.**

**B. Per-process sliding-window budget (#401's choice) vs. per-fingerprint dedupe plus a global cap.**
#401 spends its 20/hour first-come-first-served, so a chatty non-hang warning class can crowd out a rarer, more interesting error inside the same hour. Hangs are protected against this by their sub-cap; nothing else is. The alternative, which is what acetate does via `DedupeIntegration`, is to budget by fingerprint: allow the first N occurrences of each distinct issue per window, then cap globally. That spends quota on *distinct* issues, which is what quota is actually for, and it matches the observation driving the whole fix (Sentry groups repeats into one issue anyway, so repeats buy nothing). #401's choice is simpler and was the right first move under time pressure; per-fingerprint is the better steady state. **Worth a follow-up, not a blocker.** It also makes AC3's "every distinct issue still represented" claim structurally true rather than probabilistically true.

**C. Client-side fence (forced) vs. server-side per-key limits (unavailable) vs. separate orgs per project.**
The audit closed the middle option: Business-gated, verified twice. The unconsidered third option is **one Sentry org per project**, which restores blast-radius isolation without a Business plan, at the cost of a second $29/mo and split administration. Given that the entire incident is "shared quota, no fence, neighbours can blind each other," and that acetate is now a live neighbour, this deserves at least a sentence of explicit rejection rather than silence. My read: not worth it yet at two projects, worth revisiting at four, and the trigger to revisit should be written down now while the reasoning is fresh.

**D. Deactivate the retired key (plan's choice) vs. repoint it at the live project.**
The plan chose deactivation. The audit retroactively proved this was the only safe choice: repointing would have moved ~1.12M events/month onto the real quota and burned 50,000 in about 1.3 days. Worth keeping in the write-up as a near-miss, because "just repoint the DSN" is the intuitive move and it would have been catastrophic.

**E. Custom watchdog plus SDK app-hang tracking (current state, apparently by accident) vs. one owner.**
See code finding 2. Two hang reporters with different thresholds, only one of which is budget-classified, is not a choice anyone made. Pick the watchdog and turn the SDK's off.

---

## Readiness Verdict

**Needs revision.** Not "needs rethinking": the analysis is right, the fix is right, the direction is right. The document just no longer describes the work.

What flips it to **Ready to execute**:

1. Retitle; drop 2026-08-24 everywhere.
2. Mark items 2 and 3 resolved inline with a one-line answer each (Team plan bought, no fence either way; CLI DSN was the source, fixed in #401), and explicitly close the app-side half of item 3 (pre-2026-04-29 builds now report nowhere; accepted).
3. Add the release gate as an explicit AC: cherry-pick `42ce4c919` onto `origin/release/v0.63.0`, or state the deferral to v0.64.0 with a date. **This is the blocking one.** Without it the ticket cannot complete.
4. Rewrite item 1 as two checks with numbers: an immediate org-position check (closeable today), and a post-ship, version-filtered `stats_v2` check with a stated pass threshold.
5. Add the recurrence detector as an AC.
6. Add the `platform/sentry.md` reconciliation as an AC (it is a five-minute edit and the doc is currently self-contradictory because of this incident).
7. Split or fold the org-wide IP/geo scrubbing decision so it stops being a footnote.
8. File the code findings (double-charge, `reportedCurrentEpisode` set on a dropped event, SDK app-hang bypass, non-durable budget) as a follow-up ticket, so AC3 measures known behavior.

---

## Questions for the Plan Author

1. **Release gate.** `origin/release/v0.63.0` (bumped 2026-07-31) does not contain `42ce4c919`. Do you cherry-pick #401 onto it, or accept that the Sentry fix first ships in v0.64.0? Either is defensible; the ticket cannot be verified until one is chosen. Which?
2. **Does this ticket stay open until the fix ships and is measured, or does it close on the org-position check with a new ticket tracking post-ship verification?** I would prefer the latter, since the current ticket would otherwise sit open for weeks against an external dependency.
3. **What is the numeric pass condition for AC3?** Proposal: over any 7-day window after the fixed build has meaningful adoption, `rate_limited == 0` for the c11 project, `accepted > 0`, and accepted events attributable to the fixed release below X per install-day. What is your X?
4. **Do you want the verification version-filtered** (measure only the fixed release's per-install rate, answerable in days) **or fleet-total** (answerable only after adoption, weeks to months)? Given the audit's version mix, fleet-total will read as failure long after the fix is correct.
5. **Recurrence detector: which shape?** Sentry's built-in quota/spend notification emails to `projects@stage11.ai`, a scheduled `stats_v2` check, or both? Who receives it, and what do they do when it fires?
6. **Org-wide IP and geo.** `sentry.md` says c11 is presumably storing users' IPs and cities right now, and only `acetate` was fixed. Is that in scope for C11-190, a new ticket, or an accepted risk? Note the fix needs the leaf-selector workaround and a stored-event read-back, not just the setting.
7. **`demo-project` final disposition.** Leave the key deactivated indefinitely, or delete it? Should the Retired table carry an explicit "do not re-enable" so a future agent does not helpfully turn it back on?
8. **Hang reporting owner.** Sentry's native app-hang tracking is still on at 8s alongside the custom watchdog at 5s, and its events bypass the hang sub-budget entirely. Should `enableAppHangTracking` be set to false so the watchdog is the single owner?
9. **Budget double-charge.** Hang events consume two global slots (`allow(.hang)` in the monitor, then `allow(.other)` in `beforeSend`), and an episode can be marked reported while its event is dropped. Fold the fix into this ticket, or file separately? I would file separately so AC3 is not chasing a moving target.
10. **Should the budget persist across launches?** It currently resets on every process start, which is weak precisely in the crash-loop and force-quit-relaunch cases. Worth ten lines in the cache directory, or deliberately out of scope?
11. **`platform/sentry.md` reconciliation.** Confirmed in scope for this ticket, or a separate doc pass? The quota-incident section still reasons entirely from the Developer plan and the 2026-08-24 block.
12. **CI project slug.** The doc's CI snippet uses `SENTRY_PROJECT: stage11-c11` while the project table says the slug is `c11`. Are dSYMs currently uploading to the right project? If not, crashes are arriving unsymbolicated and nobody would necessarily notice.
13. **Acetate's share of the shared 50,000.** Now that both are neighbours, is anyone tracking the split, and is there a stated per-project expectation, even an informal one?
14. **At what point does one-org-per-project become the answer?** Two projects on a shared quota with no server-side fence is workable; four is a recurring incident generator. Is there a trigger worth writing down now?
15. **Regression guard.** Given the repo's ban on source-text tests, do you want a behavioral guard against a compiled-in CLI DSN returning, or an explicit accepted-risk note? Silently neither is the option I would avoid.
16. **Owner and date for the remaining items?** Currently unassigned, on a ticket whose subject is that nobody noticed for a week.
