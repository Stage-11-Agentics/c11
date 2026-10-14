# Adversarial Plan Review: c11-190-plan (Claude)

**Plan:** `.lattice/plans/task_01KZ6YXZRV8SH2V7FJJKPM7QCJ.md` (C11-190)
**Reviewed:** 2026-08-04
**Posture:** designated adversary. Not balanced by design.

---

## Executive Summary

**Concern level: high, but not for the reason the plan thinks.**

The plan is not wrong so much as it is *expired*, and expired in a way that is worse than being wrong: it reads as authoritative. Every one of its three open items has been answered by the 2026-08-04 audit, and the answers contradict the plan's text in load-bearing ways. The plan says the org is blocked until 2026-08-24; the org is on Team, unblocked, with a billing period that already reset on 2026-08-04. The plan says the fence choices are "a paid plan or an on-demand budget"; the paid plan was bought and it did **not** deliver a fence (per-key rate limits are Business-gated). The plan asks whether any shipped build still points at the retired DSN; the answer was "yes, and worse: `main` itself did, generating 1.12M events."

None of that is captured in the plan file. The audit lives in the Lattice event log; the plan on `HEAD` is the pre-audit text, and the ticket **title** still hardcodes `2026-08-24`. Anyone reading the board (a human sweeping tickets, a future orchestrator, the ticket's own delegator after a context reset) will read the title, conclude "not actionable for 20 days," and defer. This ticket has been engineered, accidentally, into a zombie: it is `in_progress`, unassigned, and gated on a date that does not exist.

**The single biggest issue** is not the staleness, though. It is that what remains of this ticket is scoped as *a one-shot manual eyeball check*, and contains **no item that would detect a recurrence**. The entire incident's headline is "quota exhaustion is silent to the sender, and nothing surfaced it for a week." The plan's response to that is for a human to go look, once, at a date. That is the same posture that produced the incident. If C11-190 closes with items 1 through 3 checked and nothing else, the org will be blind again within a quarter and will again find out by accident, from a different project's rollout.

Secondary but serious: the fix this plan is meant to verify (#401) is **on `main` only, not on any release branch**, and the production fleet is dominated by 0.58.0 while `main` is at 0.61.0. There is currently no build in any user's hands that contains the budget, the hang throttle, or the CLI DSN removal. Item 1's verification is unrunnable and will remain unrunnable for weeks; when it becomes runnable, the number it reads will be uninterpretable, because it will be a blend of upgraded and un-upgraded installs.

---

## How Plans Like This Fail

This is an **incident follow-up plan**. That genre fails in five well-worn ways, and this plan is exposed to four of them.

**1. The plan is written at peak knowledge and then never re-baselined.** Incident follow-ups are authored in the adrenaline window, when the facts feel permanent. Facts move: this one moved within hours. The plan is the artifact everyone will read in three weeks and nobody will re-read against reality. **This has already happened here** and is the plan's dominant defect. Note the mechanism: PR #401 *committed* the plan file and *separately* appended the audit as an event-log comment. The commit made the stale text look fresh (recent `git log` touch) while the correction went somewhere the plan reader never looks.

**2. Remediation gets confused with prevention, and the ticket closes on remediation.** The blast crater gets filled (key deactivated, budget added, CLI DSN dropped) and everyone feels the loop is closed. It isn't: the *detector* was never built. This plan has three items and all three are backward-looking (verify the past fix, decide a past budget question, audit past builds). Zero are forward-looking. The one sentence in the incident write-up that generalizes ("nothing alerted") produced no work item at all.

**3. "Verify later" items decay into never-verified items.** An item whose trigger is a calendar date, with no owner, no automation, and no reminder, is a coin flip. This one is worse than a coin flip because the date is now wrong, so even a diligent human executing the plan faithfully executes it at the wrong time.

**4. The fix is validated against the *sender*, not the *system*.** The entire lesson of this incident is "the sender cannot tell." Item 1 correctly names this ("check outcome=accepted, not just that the SDK returns an event id") and then still specifies a *negative* observation: look at an aggregate and see if it looks healthy. A low `accepted` count is consistent with "the fix worked," "the quota blew again," "telemetry consent got flipped," "the DSN is wrong," "the SDK failed to start," and "the budget is eating real signal." The plan has no positive control that distinguishes these. Which is galling, because `platform/sentry.md` **already documents the right pattern** and calls it out as the pattern to copy: acetate's `verify_sentry_arrival.py --live` sends through the real frozen binary and asserts on what the server *stored*. The plan's own knowledge base solved this and the plan did not adopt it.

**5. (Where this plan is genuinely fine.)** The classic "we'll fix the root cause with process discipline" trap is mostly avoided: #401 shipped a real mechanical fence rather than a "remember to check the quota" convention. Credit where due. But see the Challenged Decisions section: the fence has arithmetic problems the plan does not know about, and the plan is now the artifact responsible for verifying a fence it has never examined.

---

## Assumption Audit

### Load-bearing, and currently FALSE

| # | Assumption | Status |
|---|---|---|
| A1 | The org is blocked until 2026-08-24 and c11 is blind right now. | **False.** Team plan, period reset 2026-08-04, `usage: 0`, `usageExceeded: false`. |
| A2 | The org cap is 5,000 errors/month on Developer. | **False.** 50,000 on Team, `allowOnDemand: true`, $49 hard ceiling. |
| A3 | "The only fences are a paid plan or an on-demand budget." | **False, and the more dangerous half.** The paid plan was purchased and delivered no fence. Per-key rate limits are Business-gated; re-verified post-upgrade (`rateLimit: null` / 403). Anyone acting on this sentence buys the wrong thing and believes they are safe. |
| A4 | c11's steady-state is ~1,466 accepted errors/30d. | **False.** Attempted rate was ~1,343/day (~40k/month) against 50k, shared with acetate. The 1,466 was a *throttled* figure and the plan mistook a suppressed number for a natural one. This is the same accepted-vs-attempted confusion the plan exists to warn about, committed inside the plan. |
| A5 | Old builds in the wild were the demo-project traffic source. | **Materially false.** `CLI/c11.swift` on `main` carried the DSN. The problem was in the repo, not only in the field. |

### Load-bearing and unexamined

- **A6: A release containing #401 will exist and reach users before verification runs.** Unverified and currently false. `42ce4c919` is on `origin/main` only; `origin/release/v0.63.0` does not contain it. Latest tag is v0.61.0. The plan's verification has no shipping vehicle.
- **A7: Fleet adoption is fast enough that a post-fix aggregate reflects the fix.** Almost certainly false. The audit's own data: 1,725 of 1,784 production events over 14d came from `0.58.0+116` alone, three releases behind `main`. c11 users lag. A post-#401 `accepted` count will be dominated by installs that do not have the fix, for weeks. **The plan's success criterion is not attributable to the plan's fix.**
- **A8: A per-process client-side budget bounds org-wide consumption.** False as arithmetic. See Challenged Decisions.
- **A9: The deactivated `demo-project` key stays deactivated.** Unguarded. Nothing enforces it, nothing alerts on reactivation, and the plan itself advertises "one PUT reverses it" without a corresponding "and here is why you must not."
- **A10: The error category is the only category that matters.** Unexamined. `tracesSampleRate = 0.1` is still live and transactions/spans bill separately against the shared `$20` on-demand pool. Nobody is watching that category. The $49 ceiling protects the wallet, not the visibility.
- **A11: Verification is only about volume.** The plan never asks whether the *right* events still arrive. A fence that drops 40k events is indistinguishable, by volume, from a fence that drops the one crash that mattered.

### Invisible assumptions

- **A12:** That whoever executes this ticket will read the event log, not just the plan. There is no reason to expect this, and the plan file gives no pointer to the audit.
- **A13:** That "budget question" (item 2) is purely a billing decision for the operator. It is not: it is now primarily an *engineering sizing* decision, since billing has been settled and did not fence anything.
- **A14:** That c11 and acetate are the only clients. Any future Stage 11 project wiring Sentry inherits the same shared cap with no server-side fence. There is no gate, checklist entry, or CI check that forces a new client to declare a budget.

---

## Blind Spots

### 1. No detector. This is the gap that matters most.

The incident's defining property is silence. The remediation is entirely client-side and one-shot. There is **no** work item for:

- a scheduled check of `customers/stage-11-kl` → `categories.errors.usageExceeded`;
- an alert when `outcome=rate_limited` is nonzero for any project;
- an alert on the *absence* of events (a project that suddenly reports nothing is either healthy or dead, and the two are worth distinguishing);
- a Sentry-native alert rule (`Safe (autonomous)` per the platform doc, so no human gate needed).

I grepped the repo: there is no `stats_v2`/`usageExceeded` check in any script, workflow, or source file. It exists only in prose. **The plan proposes to check by hand the exact thing that needs to be checked by machine.** Cheapest possible version: a `cron`/GitHub Action running the two curls already documented in `platform/sentry.md`, failing loudly on `usageExceeded: true` or `rate_limited > 0`. That is under an hour of work and it is the only item on this ticket with permanent value.

### 2. Privacy, flagged on the same day, in the same document, and not carried by this ticket

`platform/sentry.md` says, plainly: org-wide `scrubIPAddresses: false` and `dataScrubber: false`; **"c11 reports to this org and is presumably storing its users' IPs and cities right now. Worth a decision."**

Add the context the doc does not: `TelemetrySettings.defaultSendAnonymousTelemetry = true`. Telemetry is **opt-out**, on by default, in a **public, open-source, distributed desktop product**, feeding an org that stores client IP and derived city. The word "anonymous" appears in the settings key. It is not anonymous.

The `sendDefaultPii = true` leak in the CLI (another user's absolute home path in an issue title) was the visible tip of this. #401 fixed the CLI flag. It did not touch the org-level setting, which is where IP and geo are attached server-side and where no client-side change can reach.

This is not scope creep on a quota ticket. It is the same subsystem, the same org, discovered in the same audit, and it is a materially larger exposure than the quota was. If C11-190 does not carry it, it needs a sibling ticket **created before this one closes**, or it evaporates: it currently exists as one paragraph in a platform doc with no ticket behind it.

### 3. The verification has no positive control

Item 1 as written cannot distinguish "healthy and quiet" from "broken and silent." What it needs, and what the org already has a template for:

1. Assert the pre-flight config (project settings read back, not assumed).
2. Send a canary event from the **real signed build**, with a planted unique token.
3. Read it back through the issues API and assert it was **stored**, with the planted token present and PII absent.
4. Only then read the aggregate.

Steps 1 through 3 turn a vibe into an oracle. Acetate's `verify_sentry_arrival.py --live` is the reference implementation and the platform doc explicitly says "that is the pattern to copy." The plan ignores it.

### 4. Suppression is not observable where the plan will look

Post-#401 there are two distinct drop paths:

- `beforeSend` returns nil → surfaces in client reports as `client_discard`, visible in `stats_v2`.
- `MainThreadHangMonitor.shouldReportHangToSentry` returns false → the event **never reaches the SDK at all**, so it is invisible to Sentry entirely. The only record is a `sentrySuppressed=n/m` string appended to a local log file on the user's machine.

Consequence: after the fix, `client_discard` will *undercount* actual suppression, possibly by a lot. An agent reading "client_discard is low, we're barely throttling" would be wrong. The plan should name this explicitly or it will be misread by exactly the kind of careful reader it is written for.

### 5. Old CLI installs are permanently pointed at a key that is one PUT from re-arming

Every c11 CLI already installed in the field still contains the compiled-in demo-project DSN and still fires on every socket-connect failure. Today that is harmless because the key is inactive. It is harmless *conditionally*, forever, on a mutable web-console setting with no guard and no alert, against a population that only shrinks as users upgrade. The plan treats this as informational (item 3, "worth knowing"). It is a live, indefinite liability. Options the plan never considers: delete the key outright rather than deactivate; delete `demo-project`; add the key's `isActive` to whatever monitoring gets built in blind spot #1.

### 6. No gate on the next client

Acetate is the second client. There will be a third. Nothing in CI, in `new-project-checklist.md`, or in this plan requires a new Sentry client to declare and implement an outbound budget sized against the org's 50,000. The lesson is currently prose in one service doc. Prose is not a gate.

### 7. The ticket title is itself a defect

`"...verify it resumes after the 2026-08-24 quota reset"` is now false and is the highest-traffic surface of this ticket. Board sweeps read titles. Retitling costs nothing and it is not in the plan.

---

## Challenged Decisions

### D1. The per-process budget does not bound the fleet, and the arithmetic says so

`SentryEventBudget` defaults: 20/hour, 50/day, **per process**. The org's allowance is 50,000/month, which is **~1,666/day**, shared with acetate.

50,000 / 30 / 50 = **33.3**. At roughly **34 simultaneously-noisy installs**, c11's own client-side fence permits the fleet to exceed the entire org's daily allowance. The fence bounds one install. It does not bound c11.

`platform/sentry.md` says this in two places and both times about somebody else:

> "Size a new client's budget against the whole org's 50,000, not against what feels polite."

> "[acetate's 30/hour] bounds a single crash loop but not a fleet."

c11's own budget was sized the way the doc warns against. The correct counterargument to my point is that 50/day/process is a *worst case* and typical installs will send far less, so 34 concurrently-saturated installs is unrealistic. That is probably true today. It is exactly the assumption that fails on the day something ships a bug that fires on every launch, which is the scenario the fence exists for. A fence whose capacity assumption is "most installs will be well behaved" is not a fence, it is an average.

Not proposing a specific number here. Proposing that the ticket **state the fleet-level arithmetic explicitly** and either accept it with eyes open or size for it. Right now nobody has written the division down.

### D2. Hang events are charged twice, so the documented budget is not the real budget

Trace one hang event:

1. `MainThreadHangMonitor.shouldReportHangToSentry` calls `SentryEventBudgetGate.shared.allow(.hang)`. On success this records into `hangHourly`, `hangDaily`, **and** `globalHourly`/`globalDaily`.
2. The event is handed to `sentryCaptureWarning` → `SentrySDK.capture`.
3. `options.beforeSend` fires and runs `allow(kind)` with `kind = event.level == .fatal ? .crash : .other`. The event is `.warning`, so it is classified `.other`, and **consumes a second global slot**.

Each hang report therefore costs **two** of the 20 hourly / 50 daily global slots. `platform/sentry.md` documents "20 events/hour and 50/day per process, of which at most 3/hour and 15/day may be hang reports." That is not what the code does. Three hangs consume six global slots, squeezing genuine errors harder than the design intends.

Non-fatal, arguably conservative, but it is undocumented drift between the doc and the mechanism, discovered on day one. If this ticket is the verification ticket for #401, this is squarely in scope.

### D3. `beforeSend` never produces `.hang`, so Sentry's *own* hang tracking bypasses the hang sub-budget

`options.appHangTimeoutInterval = 8.0` is still set and Sentry Cocoa's built-in app-hang tracking is still enabled. Those events originate inside the SDK, so they never touch `MainThreadHangMonitor` and never see `allow(.hang)`. They reach `beforeSend`, are not `.fatal`, and are classified **`.other`**.

So the `Kind.hang` case is only ever reachable from c11's own watchdog. The `App Hanging ...` issue class named in this very ticket's problem statement is fenced only by the global budget. The taxonomy in the code implies a coverage that does not exist. Either classify SDK app-hang events as `.hang` in `beforeSend` (inspect the event's exception type or mechanism), or document that the hang sub-budget covers the custom monitor only.

### D4. The budget resets on every process launch

Both windows live in a process-local struct. A crash-and-relaunch loop, or a user who quits and reopens c11 several times a day, resets the daily cap each time. "50/day" is "50 per process lifetime, capped at 50/day." For a long-running app that is usually the same thing; for the pathological case the fence is built for, it is not. Whether that matters depends on D1's fleet arithmetic, which is why D1 should be written down first.

(Minor, and in the safe direction: `ProcessInfo.systemUptime` excludes system sleep, so the windows run long in wall-clock terms on a laptop. Throttles slightly more than advertised. Not a problem, worth knowing.)

### D5. Item 2 is presented as a billing decision. It is now an engineering decision.

The plan frames item 2 as "Billing = operator decision," and billing has been decided. What remains is: how much of the org's 50,000 does c11 get, how is that enforced given no server-side fence exists, and what happens when client three arrives. That question has no owner in the current plan because the plan believes it was answered by a purchase.

### D6. Deactivate rather than delete: right at the time, worth revisiting now

Deactivation was correct in the moment (reversible, preserves history, and per the platform doc a disabled key is indistinguishable from a live one at the edge while the org is over quota, so reversibility was genuinely valuable). Now that the org is unblocked and the CLI's DSN is gone from `main`, the reversibility is pure downside: a mutable setting, no guard, no alert, protecting against a population of installs that will keep shrinking but never reach zero. Revisit.

---

## Hindsight Preview

Two years out, the "we should have known" list:

1. **"We had the data the whole time."** `stats_v2` existed, the curls were one line each, and nobody ran them on a schedule. The gap between "we know how to check" and "something checks" is the entire incident. If this ticket closes without automating the check, the retrospective writes itself.

2. **"We shipped a fence and never measured it in the field."** The budget's parameters were chosen from one day of data (2026-07-25) on one dominant release. Nobody built a way to see, post-deploy, how often it fires or what it eats. `sentrySuppressed=` in a local log file on a user's machine is not a measurement.

3. **"We confused accepted with attempted, twice."** Once in the incident, once *inside the plan written about the incident* (A4). The vocabulary needs to be forced. Any doc or ticket citing a Sentry event count should be required to say which outcome it means.

4. **"The privacy issue was in the doc on day one."** The IP and geo paragraph was written the same day and had no ticket. Two years later that is either a non-event or a very bad day, and which one it turns out to be will have nothing to do with how careful anyone was.

5. **"The plan file and the truth diverged the moment the audit landed."** The mechanism is generalizable and worth fixing at the workflow level: a Lattice comment does not amend a plan, and the plan is what gets read.

**Early-warning signals this plan has no mechanism to detect:**

- `rate_limited > 0` on any project for any interval.
- `accepted` dropping to near-zero for c11 while installs are demonstrably running (dead-man's switch; the current design would read this as success).
- `client_discard` climbing, which means the budget is eating volume that a human should be looking at.
- `demo-project` key flipping back to `isActive: true`.
- On-demand spend accruing at all, in any category.
- A new Stage 11 project appearing in `stats_v2` `groupBy=project` that nobody declared a budget for.

Every one is a one-line assertion on data already reachable with the two curls in the platform doc.

---

## Reality Stress Test

**Three most likely disruptions, applied together.**

**(1) The ticket is executed on the plan's own timeline.** Someone picks it up around 2026-08-24 because that is what the title says. By then #401 has shipped in some release; adoption is partial. They run the `stats_v2` query, see a number in the low thousands, mark it verified, close the ticket. **They are reading a number that is mostly un-upgraded 0.58.0 installs plus whatever the reset gave back.** The verification passes for the wrong reason, and passing is worse than failing because it retires the ticket.

**(2) Acetate's rollout ramps in the same window.** Acetate is a shipping desktop app with a 30/hour/process budget on the same shared 50,000. It has just been wired and its real-world volume is unmeasured. If its first real production week is noisy, the org tightens again. The current plan has no monitor, so the first anyone knows is when c11 misses a crash, which is unobservable by definition.

**(3) A c11 release ships a hang regression.** C11-191 and C11-192 exist precisely because c11 has two dominant hang paths under active work. A regression in that area, on a fleet of upgraded installs, hits the fence: 3 hangs/hour/process (costing 6 global slots each hour, per D2), across N installs. Per D1's arithmetic, N does not need to be large.

**All three at once:** the ticket is closed as verified on a misread aggregate; acetate's ramp and a c11 hang regression push the org toward the cap; there is no monitor; the next real c11 crash is dropped silently; and the ticket that would have caught it is in the `done` column with a green check. That is not a tail scenario. It is the modal outcome of executing this plan exactly as written.

---

## The Uncomfortable Truths

**The plan is currently a liability, not an asset.** Its most cited facts are false, its date is wrong, its title propagates the wrong date to every board reader, and the correction lives somewhere the reader will not look. A blank ticket saying "verify Sentry works" would mislead less. First action on this ticket is to rewrite the plan file, not to execute it.

**This ticket cannot succeed as scoped.** Item 1 requires a release that does not exist and attribution that will not be possible for weeks. Items 2 and 3 are answered. If you executed the plan literally today you would do nothing useful; if you executed it on 2026-08-24 you would produce a false pass. The remaining honest content of C11-190 is roughly: retitle, rewrite the plan from the audit, build the monitor, decide the privacy question, fix the budget-accounting drift, and verify with a real read-back once a release actually carries #401. That is a different ticket than the one on the board.

**The fence was shipped and its arithmetic was never checked against the fleet.** 50/day/process against 1,666/day org-wide means ~34 installs. That division takes ten seconds and nobody did it, including the doc that twice tells other people to do it. #401 is a large improvement over unbounded, and it is not a bound.

**A budget that eats 98% of your events is not only a quota fix; it is a decision to stop looking.** The 1,816 hang events were low-information *in aggregate*, but the throttle now hard-caps hang visibility at 3/hour/process before any judgment about whether the current hang is new, worse, or spreading. The right answer is probably still "throttle, and rely on the local hang log," but the plan should say out loud that c11 has traded away hang volume as a signal, and name what replaces it. Right now the replacement is a string in a log file that never leaves the user's machine.

**"Nothing alerted" is still true.** Every fix in #401 reduces what c11 sends. Not one of them tells anyone when the org goes blind again. If exactly one thing gets done on this ticket, it should be the monitor, not the verification.

**The privacy finding is being carried by a paragraph.** Opt-out-by-default telemetry from a public product into an org with `scrubIPAddresses: false` and `dataScrubber: false` is a larger exposure than a blown quota, it was found in the same audit, and it has no ticket. It will be forgotten unless it gets one before this ticket closes.

---

## Hard Questions for the Plan Author

1. **Why was the plan file left stale after the audit?** The audit went into the event log and #401 committed the pre-audit plan text. What is the rule for amending a Lattice plan when reality moves, and does it exist? (Currently the honest answer is: there is no rule, and this is the second Sentry artifact in a week to mislead a reader by being confidently out of date. The first was the `op://` pointer in `platform/sentry.md`.)

2. **What release will carry #401, and when?** `42ce4c919` is on `origin/main` only; `origin/release/v0.63.0` does not contain it. Item 1 is unrunnable until this is answered. Answer with a version number.

3. **How do you attribute the post-fix number when the fleet is on 0.58.0?** Production events over 14d were 1,725 of 1,784 from `0.58.0+116` alone. What release-tag breakdown, at what adoption threshold, constitutes a pass? Without this, item 1 has no pass criterion, only a vibe.

4. **What is the positive control?** Will you adopt the read-back canary (acetate's `verify_sentry_arrival.py --live` pattern, already named in `platform/sentry.md` as the pattern to copy), or is item 1 staying as an aggregate glance? If staying, how do you distinguish "healthy and quiet" from "silently broken"?

5. **What monitors the quota from here?** Name the mechanism, the cadence, and where it alerts. If the answer is "a human will check," say so explicitly, and then explain why that is different from what produced the incident. **I believe the current answer is "nothing," and that is the most important gap on this ticket.**

6. **Do you accept the fleet arithmetic?** 50/day/process, ~34 installs, and c11 alone can consume the org's entire daily allowance. Accept, resize, or add a second-order fence. This needs a written answer, not an implied one.

7. **Was the double-charge in D2 intended?** A hang consumes a global slot at `allow(.hang)` and a second at `beforeSend`. `platform/sentry.md` documents a budget the code does not implement. Fix the code, or fix the doc.

8. **Should SDK app-hang events (`appHangTimeoutInterval = 8.0`) be classified `.hang`?** Today they are `.other` and bypass the hang sub-budget entirely, which means the `App Hanging ...` issue class named in this ticket's own problem statement is unfenced except by the global cap.

9. **Who owns the org-wide privacy setting?** `scrubIPAddresses: false` and `dataScrubber: false`, with telemetry defaulting to ON in a public product. Does C11-190 carry it or does a sibling ticket get created before C11-190 closes? "Worth a decision" in a doc is not an owner.

10. **Delete the `demo-project` key rather than deactivate it?** If it stays deactivated, what watches `isActive`? Right now the answer is nothing, and the plan text advertises the one-PUT reversal without a warning attached.

11. **What stops client number three?** No CI check, no checklist entry, and no gate requires a new Sentry client to declare an outbound budget sized against the shared 50,000. What makes the acetate lesson binding rather than advisory?

12. **Is anyone watching the non-error categories?** `tracesSampleRate = 0.1` is live and transactions/spans draw on the same $20 shared on-demand pool. The $49 ceiling caps the bill; nothing caps the surprise.

13. **What is the ticket's actual definition of done, restated post-audit?** The current three items are answered, obsolete, or unrunnable. Write the new list, or close C11-190 and open the ticket that reflects what remains. Leaving it `in_progress`, unassigned, with a date-stamped false title is the worst of the three options.

14. **Will you retitle the ticket today?** It costs nothing and it is currently telling every board reader to wait 20 days for an event that already happened.
