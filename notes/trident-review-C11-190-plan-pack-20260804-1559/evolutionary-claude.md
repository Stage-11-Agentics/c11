# Evolutionary Plan Review: C11-190

- **Plan ID:** c11-190-plan
- **Model:** Claude
- **Reviewed:** 2026-08-04 15:59
- **Document under review:** `.lattice/plans/task_01KZ6YXZRV8SH2V7FJJKPM7QCJ.md`
- **Context consumed:** the sentry-audit comment (`ev_01KZ7351DG3WBXE5N4CDAA2HEF`), merged PR #401 (`42ce4c919`), `platform/sentry.md`, `Sources/SentryHelper.swift`, `Sources/AppDelegate.swift` Sentry wiring, `Sources/MainThreadHangMonitor.swift`, and Acetate's `scripts/telemetry/` tooling.
- **Live verification performed (read-only GETs against the Sentry API):** org billing state, c11 project privacy settings, acetate project privacy settings, plan feature list.

---

## Executive Summary

As a work contract, this plan is mostly spent. Two of its three items are closed by events that happened after it was written, and the third was answered so thoroughly that it produced a different piece of software than the plan imagined. What is left is a single verification step whose trigger date is wrong and whose pass criterion is undefined.

That is the small finding. The larger one is that the ticket is aimed at the wrong target. Its own opening sentence names the real defect: *"nothing surfaced it."* An entire month of production error monitoring went dark and the discovery mechanism was a human working on an unrelated project on a sibling repo noticing something odd. The remaining plan responds to that with a one-time manual eyeball at a stats endpoint. That closes the outage. It does not close the class.

Three concrete openings the plan does not name:

1. **A live privacy exposure on a shipped product, confirmed just now.** The `c11` Sentry project has `scrubIPAddresses: false` and `relayPiiConfig: null`. `acetate`, on the same org, has both set. c11 is storing its users' IP addresses and Sentry's derived city/country on every event today. `platform/sentry.md` flags this as "worth a decision" and no ticket carries it. This is a one-call fix that needs no release and no build.
2. **No alarm exists, and the plan does not add one.** The org is now on Team with a $20 shared on-demand budget and `allowOnDemand: true`, so the next exhaustion will not block silently at 50,000; it will spend money first and *then* block silently. The failure mode did not go away, it acquired a bill.
3. **A sequencing trap that will quietly waste PR #401.** C11-191 and C11-192 exist to fix the two hangs that were 98% of c11's volume. If they land before anyone proves the budget actually bites in a real build, the load disappears and the fence is never tested. The next time volume spikes, from some future source, the fence is untested code that has never fired in production.

The best version of this ticket is not "confirm events resume." It is: **make silent telemetry loss impossible to discover by accident again**, and do it in a way the next Stage 11 tenant inherits for free.

---

## Currency Audit: What in the Plan Is Now False

The caller asked for staleness to be flagged explicitly. Every row below was verified against live API state or the merged commit.

| Plan text | Reality as of 2026-08-04 15:59 | Verdict |
|---|---|---|
| "`stage-11-kl` is on the free Developer plan, 5,000 errors/month" | `planDetails.id = am3_team`, `reserved: 50000` | **Stale.** Superseded by the upgrade. |
| "the billing period runs to 2026-08-24 ... the org stays blocked until then and c11 is still blind right now" | Period is `2026-08-04 -> 2026-09-03`. `usage: 6`, `usageExceeded: false` | **Stale and load-bearing.** The ticket's title, its trigger condition, and item 1's gating date are all built on a date that no longer exists. Anyone picking this ticket up cold will wait 20 days for nothing. |
| Item 2, "Decide the budget question ... the only fences are a paid plan or an on-demand budget. Billing = operator decision." | Both were taken. Team plan plus `onDemandMaxSpend: 2000` cents, `budgetMode: shared`, `enabled: true`, `allowOnDemand: true`. Hard ceiling $49/mo. | **Closed.** But see below: the plan's premise that a paid plan constitutes a *fence* was wrong, and the audit correctly caught that. Paying raised the ceiling; it did not add a fence. |
| Item 2's implicit assumption that a paid plan buys per-key rate limits | Re-verified post-upgrade. `PUT .../keys/<id>/` returns `rateLimit: null`; the org's feature list contains `crash-rate-alerts` and no `rate-limits` or spike-protection entry. Business tier only. | **Confirmed unavailable.** Client-side is the only fence, permanently, at this price point. |
| Item 3, "Consider whether any shipped c11 build still points at the retired DSN" | Answered, and the answer was worse than the question. It was not only old builds: `CLI/c11.swift` on `main` hard-coded the retired DSN and fired an event per shell prompt, per agent tool call, per hook, with `sendDefaultPii = true`. That is the 1,121,397 rejected events. Fixed in #401: no compiled-in DSN, opt-in via `C11_CLI_SENTRY_DSN`, PII off. | **Closed, and the finding is more valuable than the item.** |
| Item 1, "After 2026-08-24, confirm c11 events are actually being STORED again" | The date is wrong. The check is still the right check. There is currently nothing to observe: `usage: 6` on a period that reset today, and #401 has not shipped in a release. | **Partially valid, needs rewriting.** This is the only remaining work, and as written it has no trigger, no pass criterion, and no observation window. |

**One more drift worth fixing while you are in here:** `platform/sentry.md` cites `acetate`'s verifier as `scripts/telemetry/verify_sentry_arrival.py --live`. No such file exists. The real ones are `verify_real_arrival.py` and `verify_staged_arrival.py`. That doc is the thing this incident is supposed to have taught, and its pointer to the reusable asset is already broken.

---

## What's Really Being Built

The stated deliverable is "confirm monitoring resumed." The actual thing that came out of this investigation is **c11's first piece of telemetry governance**, and beneath that, Stage 11's first encounter with a shared-quota commons.

Three tenants now sit on one 50,000-error pool with no server-side partition: the c11 app, the c11 CLI, and acetate. There is no mechanism, at any price Stage 11 is willing to pay, that stops one from consuming the others' visibility. The `SentryEventBudget` in `SentryHelper.swift` is not a bug fix. It is the first line of a governance protocol for a commons, and it is written as if it were a local concern.

That reframing changes what "done" looks like. As a local concern, done is "c11 sends less." As a commons protocol, done is: **every tenant carries a declared share, the shares sum to less than the pool, and a violation is observable by someone other than the violator.** c11 currently has the first, has not declared it anywhere machine-readable, and has none of the third.

Acetate is further along on exactly this. Look at what already exists in `Gregorovich/projects/acetate/scripts/telemetry/`:

- `budget.json`: a checked-in, per-family monthly event budget with caps sized explicitly against the tier's ceiling, and notes on which families are session-aggregated versus one-per-occurrence.
- `provision.py`: idempotent config provisioning where **read-back, not the HTTP 200, is the success criterion** (their ACE-334 lesson, which is verbatim this incident's lesson 3).
- `privacy_deploy_canary.py`: a two-gate canary that compares deployed reality against checked-in claims, written because "a page can be perfectly in sync with a manifest that has been wrong for months, and every check was green" (their ACE-678).
- `verify_real_arrival.py` / `verify_staged_arrival.py`: assertions on what the server *stored*.

Acetate has independently derived every lesson in `platform/sentry.md` and then built machinery for them. c11 has derived the lessons and written prose. **The gap between those two states is the entire evolutionary opportunity in this ticket.**

---

## How It Could Be Better

### 1. Replace the manual verification with a checked-in verifier

Item 1 as written is "a human looks at stats_v2 once." That artifact evaporates the moment it is performed. The same effort, spent on a script, produces something that runs every release forever.

Concretely: `scripts/telemetry/verify-sentry-accepted.py`, modeled on acetate's `verify_real_arrival.py`, that takes the org and project and asserts:

- `outcome=accepted` count over the window is greater than zero (monitoring is alive),
- `outcome=rate_limited` count is zero (nobody is blinding anyone),
- `outcome=client_discard` is present and non-zero (the budget is actually firing, which is the *positive* signal that #401 works),
- projected monthly accepted volume is under c11's declared share.

Exit non-zero on any. Run it in `release.yml` post-deploy and on a schedule. The ticket then closes on evidence that regenerates itself rather than on a screenshot.

Note the third assertion. It is the one a human eyeballing a dashboard would never think to make, and it is the only one that proves the fix works rather than proving the outage ended.

### 2. Add the alarm, because the alarm is the actual defect

Nothing in the plan makes the next occurrence self-announcing. The org has spend notifications and quota-threshold notifications available; neither is mentioned. At minimum:

- Sentry org-level quota notification at 50% and 80% of the 50,000, to `projects@stage11.ai`.
- On-demand spend notification, because `allowOnDemand: true` means the new failure mode is "spends $20 quietly, then blinds quietly."
- A scheduled run of the verifier from item 1, so a non-zero `rate_limited` count anywhere on the org fails loudly within a day rather than within a month.

This is the highest-value item in the whole ticket and it is not in the ticket.

### 3. Close the confirmed privacy gap

`c11` project: `scrubIPAddresses: false`, `relayPiiConfig: null`. `acetate`: both set. The exact curl is already written in `platform/sentry.md`, including the trap that `$user.geo` as a parent selector is accepted and silently does nothing while only the leaf selectors work. One call, no release, no build, reversible.

Two reasons this belongs here and not in a someday ticket. First, it was discovered by this investigation and will be lost if this ticket closes without it. Second, c11 is a shipped public product with real users, and the same investigation established that `sendDefaultPii = true` in the CLI had already put another user's absolute home path into an issue title. The IP and city are the same class of leak, still live, on the app rather than the CLI.

And then verify it by reading back a stored event, not by reading back the setting. That is this org's most expensively-learned lesson and it applies to its own fix.

### 4. Fix two real wrinkles in the landed budget code

Both are minor individually and both undermine the numbers `platform/sentry.md` now states as fact.

**Hang events consume global budget twice.** `MainThreadHangMonitor.shouldReportHangToSentry` calls `SentryEventBudgetGate.shared.allow(.hang)`, which records into `globalHourly`/`globalDaily`. The event then reaches `AppDelegate`'s `beforeSend`, which classifies it as `.other` (the closure only ever produces `.crash` or `.other`, never `.hang`) and records into the global counters again. So each hang costs 2 of the 20 hourly global slots, and the documented "20 events/hour" is really 20 minus the hang double-count. Either have `beforeSend` recognise hang events and skip re-charging them, or move the entire decision into `beforeSend`. The latter is cleaner: one gate, one call site, and the hang sub-budget becomes enforceable against *any* hang event rather than only ones originating in the monitor.

**The budget is process-local and in-memory, so it resets on relaunch.** A wedged install that the user force-quits and reopens ten times gets ten fresh budgets. That is the exact population the fence exists for. Persisting the sliding window to the app's cache directory (`LaunchSentinel` already owns a perfectly good directory under `~/Library/Caches/<bundle-id>/`) makes the fence survive the restart loop. Related: fatal events are exempt by design, which is correct for a single crash and unbounded for a crash-on-launch loop across a fleet. Worth at least a generous daily fatal ceiling, say 20/day, well above any honest crash rate and well below a loop.

### 5. Smoke the fence in a real build before removing its load

`MainThreadHangDetectorTests.swift` proves the pure core. Green tests are not a working product, and this is a textbook instance: the budget's *wiring* is an `options.beforeSend` closure that only ever emits two of the three `Kind` cases, and no test exercises that closure. Before this ticket closes, drive a real tagged build into a real beachball, confirm the local hang log shows suppression counts climbing (`SentryEventBudgetGate.shared.dropped` is already read at `MainThreadHangMonitor.swift:212`), and confirm Sentry received exactly one event for the episode.

---

## Mutations and Wild Ideas

### The drop counters are the highest-leverage five lines in the file

`SentryEventBudget` tracks `droppedTotal` and `droppedHangs`. Right now that information goes into a local log file and dies there. Attach it as a tag on every event that *does* get through:

```swift
options.beforeSend = { event in
    let kind: SentryEventBudget.Kind = event.level == .fatal ? .crash : .other
    guard SentryEventBudgetGate.shared.allow(kind) else { return nil }
    let d = SentryEventBudgetGate.shared.dropped
    event.tags = (event.tags ?? [:]).merging([
        "budget_dropped_total": String(d.total),
        "budget_dropped_hangs": String(d.hangs),
    ]) { _, new in new }
    return event
}
```

That converts a lossy sample into a self-describing one. Every surviving event now reports how much was thrown away to make room for it. Suddenly the sample tells you about the population: an install reporting `budget_dropped_total: 400` on a single warning is a wedged machine, visible in the issue list, with zero extra events sent. It also makes the fence's own health observable in the same dashboard as everything else, which removes the need to trust it blindly.

This is small, cheap, and it is the difference between a fence and an instrumented fence.

### Invert the architecture: local record, remote index

c11 already writes richer diagnostics locally than it ever sends: MetricKit payloads in `~/Library/Logs/c11/metrickit/`, the full hang log, `LaunchSentinel` unclean-exit markers. The incident happened because c11 tried to push volume to a remote service with a hard shared ceiling.

The mutation: **treat Sentry as an index, not a store.** One event per episode carrying a correlation id and a pointer to the local artifact, deliberately minimal, with the operator able to ask a user for the local file when an issue warrants it. This is simultaneously a quota story (volume collapses), a privacy story (nothing leaves the machine until a human asks), and a product story, because the local artifacts are strictly better forensics than a Sentry stack trace. c11's existing local diagnostics are already 80% of this design; nobody has named the architecture out loud.

### Name the class: "accepted, then discarded"

Lesson 3 in `platform/sentry.md` is stated as a Sentry fact. It is not. It is a general shape: *a system returns success at the edge and discards server-side, so the sender cannot distinguish success from loss.* Once you have the name, you can sweep for it. Candidates in this codebase alone: PostHog's ingestion cap, the dSYM upload in `release.yml` and `nightly.yml` (does anything verify the symbols actually landed, or only that `sentry-cli` exited 0? an unverified dSYM upload produces unsymbolicated crashes, which is a quieter version of the same blindness), Sparkle appcast generation, and the c11 socket's own `report_*` telemetry commands.

That last one is the interesting one, because it is inside the product. c11's whole value proposition is that an agent's work stays legible to the operator. A `c11 report_*` call that succeeds and is silently coalesced away has the identical shape as a Sentry event accepted and dropped. Worth one grep.

### Promote the incident into a platform capability

Write `platform/telemetry-tenancy.md` once, describing the commons: the pool, the tenants, each tenant's declared share, the required client-side fence, and the required verifier. Then have both c11 and acetate check in a `telemetry-budget.json` whose shares are asserted to sum below the pool by a shared script. This is the third independent rediscovery of "verify against stored reality" across two repos. The lesson is clearly durable enough to deserve executable form.

### The adversarial-tenant thought experiment

The org has no server-side fence and will not have one at this price. That means every future Stage 11 project that wires telemetry is, on day one, capable of blinding every other project. The current onboarding control for that is a paragraph in a markdown file that says "decide the budget question first." A new agent onboarding a fourth project will read it, agree, and size its budget against what feels polite, which is exactly what `platform/sentry.md` already warns against. The only control that survives contact with an agent in a hurry is a script that fails.

---

## What It Unlocks

- **A repeatable onboarding path for tenant four.** Once the verifier and the budget declaration exist, adding a project stops being an incident-generating event.
- **Accepted-versus-attempted as a fleet health signal.** The ratio is currently only visible during a post-mortem. Made continuous, a rising `client_discard` rate across the fleet is an early warning that something is wedging installs, available days before anyone files a bug. Given that C11-191 and C11-192 both trace to real user-visible beachballs, this is a product signal, not just an ops signal.
- **Honest telemetry claims.** With `scrubIPAddresses` and `relayPiiConfig` set and verified by read-back, c11 can make a specific, defensible statement about what it collects. Acetate is already generating a privacy page from its manifest (`gen_privacy_page.py`) and gating deploys on the page matching reality. c11 has no equivalent and, on current settings, could not truthfully write one.
- **Headroom to instrument more.** The current attempted rate was ~40k/month against a 50k pool shared with acetate. Post-#401 that should fall to low thousands. That reclaimed headroom is the budget for telemetry c11 does not have yet and would benefit from.

---

## Sequencing and Compounding

The plan's implicit order is: wait for a date, then look. Both halves are wrong. Here is the ordering that makes each step useful to the next.

**Step 0, today, no release required.** Set `scrubIPAddresses` and the leaf-selector `relayPiiConfig` on the `c11` project, then verify by reading back a stored event. Zero dependencies, closes a live exposure, and it is the only item that gets *worse* the longer it waits, because every day adds stored IPs.

**Step 1, before the release.** Stand up the alarm and the verifier. This ordering is the whole point: if the verifier exists before #401 ships, the release is the first thing it observes, and its output is a genuine before/after measurement rather than an assertion that things look fine now. Build the instrument before the experiment.

**Step 2. Ship #401 in a release.** Nothing in #401 is live for users until it is in a signed build in the wild. `usage: 6` today means there is currently nothing to verify and no amount of staring will change that.

**Step 3. Verify with the script, and verify the fence, not just the outcome.** Confirm `accepted > 0`, `rate_limited == 0`, and `client_discard > 0`. Plus one real-artifact smoke: tagged build, induced beachball, one Sentry event, suppression counters climbing in the local log.

**Step 4, and this is the sequencing trap. Only then land C11-191 and C11-192.** Those tickets remove the load that the fence exists to hold. If they land first, hang volume collapses for reasons unrelated to the budget, the budget never fires in production, and you have shipped an untested safety mechanism whose first real exercise will be during the next incident. Prove the fence bites while the load still exists. If schedule pressure forces 191/192 first, then step 3's induced-beachball smoke becomes mandatory rather than nice to have, because it is the only remaining evidence path.

**Step 5. Generalize.** Lift the verifier to `platform/`, write the tenancy doc, have acetate adopt the shared script. Each tenant onboarded after this point costs less than the one before, which is the only version of this work that compounds.

---

## The Flywheel

**The one that exists and is not spinning: cross-tenant learning.**

Acetate learned "read back the stored artifact, not the config" on ACE-334. It learned "a green check against a stale manifest is worse than no check" on ACE-678. c11 then learned both again, from scratch, at the cost of a month of production blindness. The lessons transferred as prose in `platform/sentry.md` and prose does not transfer, as evidenced by that doc's pointer to the acetate verifier being broken.

The loop wants to be: *incident produces lesson, lesson produces a checked-in gate, gate is inherited by the next tenant, next tenant's incidents are novel rather than repeats.* Steps one and two happen reliably at Stage 11. Step three is where it breaks, because the gate is written inside one project's `scripts/` and the next project cannot see it. One shared script in `platform/`, invoked by both repos, converts a documentation habit into a compounding one. That is a small change with an unusually good slope.

**The one you can engineer cheaply: drop-rate to hang-fix.**

Tag events with the drop counters (see Mutations). Rising drop rates surface wedged installs. Wedged installs generate hang tickets like C11-191 and C11-192. Fixed hangs reduce volume. Reduced volume creates headroom for finer instrumentation, which surfaces the next tier of problems. Each turn makes the next turn cheaper and the telemetry more informative. Currently this loop is open at the first link, because the drop counters never leave the process.

**The anti-flywheel to watch.** On-demand spend is now enabled. The failure mode has changed shape from "blocked at 50,000" to "silently spends up to $20, then blocks." That is a *worse* signal than the old one for a system with no alarm, because the first symptom is now a line item rather than an outage. The alarm in step 1 is what keeps the plan upgrade from being a net negative on detectability.

---

## Concrete Suggestions

1. **Rewrite the ticket body.** Delete every reference to the Developer plan, the 5,000 cap, and 2026-08-24. Retitle from "verify it resumes after the quota reset" to something like "make Sentry quota loss self-announcing, and verify #401's fence bites." The current title will actively mislead whoever picks this up.

2. **Give item 1 a numeric pass criterion and a window.** Suggested: over the 7 days following the first release containing #401, `sum(quantity)` for `outcome=accepted` on project `c11` is greater than zero, `outcome=rate_limited` equals zero, `outcome=client_discard` is greater than zero, and projected 30-day accepted volume is under 10,000. Without numbers this item closes on a vibe.

3. **Do the privacy PUT today.** Use the curl in `platform/sentry.md`, leaf selectors only, then read back a stored event to confirm `user.ip_address` and `user.geo` are gone. Update the Active Projects table for `c11` to record it, matching the `acetate` row.

4. **Ship `scripts/telemetry/verify-sentry-accepted.py`.** Model on acetate's `verify_real_arrival.py`. Wire into `release.yml` post-publish and a nightly schedule. Non-zero exit on any assertion failure.

5. **Turn on Sentry quota and on-demand spend notifications.** 50% and 80% thresholds, to `projects@stage11.ai`. This is the item that would have prevented the whole incident.

6. **Tag surviving events with the drop counters.** Five lines in `AppDelegate`'s `beforeSend`, sketched above. Highest value-per-line in this entire ticket.

7. **Unify the budget gate.** Have `beforeSend` classify hang events and be the single call site, so hangs stop double-charging the global window and the hang sub-budget applies to any hang-shaped event rather than only monitor-originated ones.

8. **Persist the sliding window across launches**, into the cache directory `LaunchSentinel` already uses. Add a generous daily fatal ceiling so a crash-on-launch loop is bounded without ever threatening a single genuine crash report.

9. **Fix the broken pointer in `platform/sentry.md`** to `verify_sentry_arrival.py`, which does not exist. Real names: `verify_real_arrival.py`, `verify_staged_arrival.py`.

10. **Add a real-artifact smoke to the ticket's exit criteria.** Tagged build, induced beachball, assert exactly one Sentry event for the episode and non-zero suppression counts in the local hang log. The `beforeSend` wiring is the untested part and unit tests cover only the pure core.

11. **Write `platform/telemetry-tenancy.md`** and a checked-in per-tenant budget declaration, with a shared script asserting the declared shares sum below the pool. This is what makes tenant four cheap.

12. **Do one grep for the "accepted then discarded" shape elsewhere**, starting with the dSYM upload steps in `release.yml` and `nightly.yml`. An unverified symbol upload is the same failure wearing different clothes, and it would degrade exactly the crash reports this whole ticket is trying to protect.

---

## Questions for the Plan Author

1. **Should this ticket close on the verification, or should it close on the alarm?** My read is that closing it on a one-time verification means the next occurrence is again found by accident. Is there an appetite for expanding scope to the detection mechanism, or would you rather split the alarm into its own ticket and accept the risk of it not getting written?

2. **Does the c11 IP and geo exposure get folded in here, or does it get its own ticket?** It was discovered by this investigation, `platform/sentry.md` leaves it as "worth a decision," and it is live on a shipped public product right now. I would rather it move than be tidy, but it is genuinely a different concern from quota.

3. **Related: is there a broader position on what c11 collects?** Acetate generates a privacy page from its manifest and gates deploys on the page matching reality. c11 has no equivalent statement. Is that a gap you want closed, or is c11's audience different enough that it does not apply?

4. **How much of Acetate's telemetry machinery should be lifted to `platform/`?** The alternative is that c11 writes its own verifier, they drift, and the third tenant writes a third one. The lift has a real cost and it is not obviously c11's ticket to pay.

5. **What is c11's declared share of the 50,000?** Post-#401 the estimate is low thousands, but nothing is written down. Without a number, the fourth tenant sizes its budget against nothing.

6. **How do you feel about the sequencing risk with C11-191 and C11-192?** If those land first, the budget never fires under real load. Are you willing to hold them until the fence is observed working, or should the induced-beachball smoke become a hard gate instead?

7. **Is `allowOnDemand: true` the posture you want with no alarm in place?** It converts a hard stop into a soft $20 spend followed by a hard stop. Better ceiling, worse signal, until notifications exist.

8. **The hang double-charge and the per-process budget reset: fix now or file?** Neither is urgent. Both make the numbers currently asserted in `platform/sentry.md` inaccurate, and that doc is now the org's reference for how a tenant fences itself.

9. **Is the "local record, remote index" architecture worth exploring?** c11 already writes better diagnostics locally than it sends. Inverting the relationship would collapse quota, improve privacy, and improve forensics simultaneously. It is a larger change than this ticket wants, but it may be the right long-run shape and this is the moment when the reasoning is fresh.

10. **Who owns the org-level settings decision?** `platform/sentry.md` records `scrubIPAddresses: false` and `dataScrubber: false` at the org level, and org settings are on the "Dangerous, confirm with human" list. If the answer is "set them org-wide once," that is a strictly better fix than doing it per project forever, and it needs an explicit yes.
