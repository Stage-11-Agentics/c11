# Trident Evolutionary Synthesis — C11-190

- **Plan under review:** `.lattice/plans/task_01KZ6YXZRV8SH2V7FJJKPM7QCJ.md` (C11-190, Sentry quota exhaustion incident, verify monitoring resumes)
- **Reviewers synthesized:** Claude, Codex, Gemini (Evolutionary/Exploratory lane)
- **Pack:** `notes/trident-review-C11-190-plan-pack-20260804-1559/`
- **Synthesized:** 2026-08-04

---

## Executive Summary

All three models independently reached the same verdict, with unusually little spread: **the plan is not executable as written, and its remaining value has moved.** Two of its three items were closed by events that happened after it was authored (the Team-plan upgrade with a $20 on-demand budget; PR #401's removal of the hard-coded CLI DSN), and the third, a verification step, is gated on a date (2026-08-24) that no longer exists. Anyone picking the ticket up cold will wait three weeks for a reset that already happened on 2026-08-04.

Beyond currency, the three converge on a sharper reframing. The plan treats the incident as a billing outage and proposes a one-time manual eyeball at `stats_v2`. All three argue the real defect is named in the ticket's own opening sentence: **nothing surfaced it.** A month of production blindness was found by a human working on a sibling repo. A manual check closes the outage; it does not close the class. The upgrade to Team with `allowOnDemand: true` arguably made detectability *worse*: the failure mode changed from "hard-blocks at 50,000" to "silently spends $20, then hard-blocks." Better ceiling, worse signal, until an alarm exists.

Where they diverge is in altitude, not direction. Codex stays tightest to the ticket and argues for a release-bound, outcome-based measurement contract. Gemini names PR #401 what it actually is, a client-side QoS/governor layer, and pushes toward remote-configurable budgets and degraded-mode local capture. Claude goes furthest, framing the org's single 50,000-error pool as a **shared commons with three tenants and no server-side partition** (c11 app, c11 CLI, acetate), and arguing that the durable deliverable is a tenancy protocol plus an executable verifier lifted to `platform/`, not another paragraph of prose.

One item is unanimous-adjacent and time-sensitive: **the `c11` Sentry project is live today with `scrubIPAddresses: false` and `relayPiiConfig: null`** while `acetate` on the same org has both set. Claude verified this against the live API; Codex flags it from the runbook; Gemini does not raise it. It is a one-call fix requiring no build and no release, and it is the only item in the pack that gets strictly worse the longer it waits.

---

## 1. Consensus Direction

Evolution paths identified by two or more models.

1. **Rewrite the ticket before working it. (3/3)** Title, premise, trigger date, item 2, and item 3's framing are all superseded. Claude produced a row-by-row currency audit against live API state; Codex declares the plan "not current enough to execute as written"; Gemini treats the mutation as already having happened via #401. Delete every reference to the Developer plan, the 5,000 cap, and 2026-08-24.

2. **The remaining check must be release-bound, not date-bound. (3/3, most explicit from Codex.)** A merged PR is not a deployed client. `usage: 6` on a period that reset today means there is currently nothing to observe, and no amount of staring changes that. The observation window must start when a signed build containing `42ce4c919` reaches production, and the ticket must name the version and channel.

3. **Verification needs numeric pass criteria and three outcomes, not one. (3/3.)** "Confirm events are accepted" is a vibe. Claude and Codex both independently arrive at the same three-outcome shape: `accepted > 0` (monitoring is alive), `rate_limited == 0` (nobody is blinding anyone), and `client_discard > 0` (the new budget is actually firing). Claude notes the third is the one a human eyeballing a dashboard would never think to check, and the only one that proves *the fix works* rather than proving *the outage ended*. Codex adds the same distinction from the opposite side: a drop in accepted events is good only when paired with expected client discards, not as an unexplained absence.

4. **Replace the manual check with something that runs forever. (3/3.)** Claude wants a checked-in `scripts/telemetry/verify-sentry-accepted.py` modeled on acetate's `verify_real_arrival.py`, wired into `release.yml` and a nightly schedule. Codex wants a "reusable, secret-safe verification helper" emitting only aggregates. Gemini wants a Sentry threshold alert to replace the ongoing need to check `stats_v2`. Same instinct, three implementations.

5. **Add the alarm; the missing alarm is the actual defect. (3/3.)** Claude calls it "the highest-value item in the whole ticket and it is not in the ticket," proposing org quota notifications at 50%/80% plus on-demand spend notifications to `projects@stage11.ai`. Gemini proposes a volume-threshold alert (>500 events/24h) plus a dedicated fatal-spike alert. Codex frames it as converting the successful query into a recurring health check.

6. **Instrument the governor: drop counts must escape the process. (3/3, three different channels.)** `SentryEventBudget` tracks `droppedTotal`/`droppedHangs` and the information dies in a local log. Claude proposes tagging surviving events with the counters (five lines in `beforeSend`), so each event that gets through reports how much was discarded to make room for it. Gemini proposes a PostHog ping so the governor's health is observable without spending Sentry quota. Codex proposes an observable discard counter as part of a shared admission contract. All three see the same hole; pick a channel.

7. **Fatal exemption is an unbounded liability. (2/3, Gemini and Claude.)** Fatals bypass the budget by design, which is correct for a single crash and unbounded for a crash-on-launch loop across a fleet. Gemini: a startup crash loop "could still blow through the $49/mo ceiling in hours." Claude proposes a generous daily fatal ceiling (~20/day), well above any honest crash rate and well below a loop.

8. **Generalize the fence into a shared contract. (3/3.)** Codex: turn `SentryEventBudget` into a telemetry-admission contract every Stage 11 client declares against. Claude: write `platform/telemetry-tenancy.md`, have each tenant check in a `telemetry-budget.json`, and add a shared script asserting declared shares sum below the pool. Gemini: cross-project fairness as an unlocked capability. This is the strongest cross-model signal that the ticket's durable output is org-level, not c11-local.

9. **The c11 IP/geo privacy exposure must be explicitly in or out. (2/3, Claude and Codex.)** Neither wants it silently omitted. Claude argues to fold it in now because it was discovered by this investigation and will be lost when the ticket closes; Codex is agnostic on placement but insists on an explicit decision or a linked follow-up.

10. **This ticket is separate from the hang fixes. (3/3.)** C11-191 and C11-192 own the actual hangs. C11-190 owns the fence and the proof. Claude adds the sequencing warning below.

---

## 2. Best Concrete Suggestions

Ranked by actionability × leverage, deduplicated across models.

1. **Do the privacy PUT today.** Set `scrubIPAddresses: true` and a leaf-selector `relayPiiConfig` on the `c11` project. The exact curl is already in `platform/sentry.md`, including the trap that `$user.geo` as a parent selector is accepted and silently does nothing while only leaf selectors work. Then **verify by reading back a stored event, not the setting** — this org's most expensively-learned lesson applied to its own fix. No build, no release, reversible, and it is the only item that degrades with delay. *(Claude, verified live; Codex concurs on urgency.)*

2. **Retitle and rewrite the ticket body.** From "verify it resumes after the quota reset" to something like *"Verify PR #401's telemetry fence bites in a production release, and make quota loss self-announcing."* Replace item 2 with a completed decision record (Team, 50,000 errors/month, $20 shared on-demand, $49 hard ceiling, client-side budgets as the only per-client fence, per-key limits confirmed Business-tier-only). Replace item 3 with the established root cause: `CLI/c11.swift` on main hard-coded the retired DSN and fired per shell prompt / per tool call / per hook with `sendDefaultPii = true`, producing the 1,121,397 rejected events; fixed in #401, now opt-in via `C11_CLI_SENTRY_DSN`. *(Codex, Claude.)*

3. **Give item 1 a numeric pass criterion and a window.** Consensus shape: over the N days following the first release containing #401 — on project `c11` — `sum(quantity)` where `outcome=accepted` is > 0; `outcome=rate_limited` == 0; `outcome=client_discard` > 0; projected 30-day accepted volume under ~10,000 (Claude's number) or "low thousands" (Codex's framing). Preserve a timestamped, redacted evidence artifact. *(Claude, Codex.)*

4. **Ship `scripts/telemetry/verify-sentry-accepted.py`, modeled on acetate's `verify_real_arrival.py`.** Non-zero exit on any assertion failure. Wire into `release.yml` post-publish and a nightly schedule. The ticket then closes on evidence that regenerates itself rather than on a screenshot. *(Claude; Codex's "reusable secret-safe helper" is the same object with a stricter output contract — aggregates only, never print auth tokens or DSNs.)*

5. **Turn on Sentry quota + on-demand spend notifications now.** 50% and 80% thresholds to `projects@stage11.ai`, plus an on-demand spend notification. Gemini's variant: a project-level alert at >500 events/24h, and a *separate* alert on fatal-event spikes since fatals bypass the budget. This is the single change that would have prevented the original incident. *(All three.)*

6. **Tag surviving events with the drop counters.** Five lines in `AppDelegate`'s `beforeSend`: merge `budget_dropped_total` and `budget_dropped_hangs` into `event.tags`. Converts a lossy sample into a self-describing one. An install reporting `budget_dropped_total: 400` on a single warning is a wedged machine, visible in the issue list, at zero extra event cost. Highest value-per-line in the pack. *(Claude.)*

7. **Fix the hang double-charge.** `MainThreadHangMonitor.shouldReportHangToSentry` calls `SentryEventBudgetGate.shared.allow(.hang)`, recording into the global hourly/daily counters. The event then reaches `beforeSend`, which classifies it as `.other` (the closure only ever produces `.crash` or `.other`, never `.hang`) and charges the global counters *again*. Each hang costs 2 of the 20 hourly slots, making the "20 events/hour" figure now asserted in `platform/sentry.md` inaccurate. Preferred fix: move the whole decision into `beforeSend` so there is one gate at one call site, and the hang sub-budget applies to any hang-shaped event rather than only monitor-originated ones. *(Claude.)*

8. **Persist the budget's sliding window across launches.** It is currently process-local and in-memory, so a wedged install that the user force-quits and reopens ten times gets ten fresh budgets — exactly the population the fence exists for. `LaunchSentinel` already owns a directory under `~/Library/Caches/<bundle-id>/`. Add a generous daily fatal ceiling (~20/day) in the same change. *(Claude; Gemini raises the crash-loop half independently.)*

9. **Smoke the fence in a real build before the load disappears.** `MainThreadHangDetectorTests.swift` covers the pure core; nothing exercises the `beforeSend` closure, which is the actual wiring. Drive a tagged build into a real beachball, confirm suppression counts climbing in the local hang log (`SentryEventBudgetGate.shared.dropped` is already read at `MainThreadHangMonitor.swift:212`), and confirm Sentry received exactly one event for the episode. *(Claude.)*

10. **Log dropped events locally instead of discarding into the void.** Gemini's version: on rejection, write a concise summary (timestamp, issue signature) to a local rolling file, so a user submitting a support ticket brings the suppressed context with them. This preserves per-user debuggability at zero quota cost and is the cheap half of the "local record, remote index" mutation below.

11. **Fix the broken pointer in `platform/sentry.md`.** It cites acetate's verifier as `scripts/telemetry/verify_sentry_arrival.py`; no such file exists. The real ones are `verify_real_arrival.py` and `verify_staged_arrival.py`. The doc that is supposed to carry this incident's lesson already has a dead link to the reusable asset. *(Claude.)*

12. **Grep for the "accepted, then discarded" shape elsewhere,** starting with the dSYM upload steps in `release.yml` and `nightly.yml`. Does anything verify the symbols actually landed, or only that `sentry-cli` exited 0? An unverified dSYM upload produces unsymbolicated crashes — the same blindness wearing different clothes, degrading exactly the crash reports this ticket exists to protect. *(Claude.)*

---

## 3. Wildest Mutations

The most creative and ambitious ideas, including the risky ones.

1. **Invert the architecture: Sentry as index, not store. (Claude.)** c11 already writes richer diagnostics locally than it ever transmits — MetricKit payloads in `~/Library/Logs/c11/metrickit/`, the full hang log, `LaunchSentinel` unclean-exit markers. Send *one* deliberately minimal event per episode carrying a correlation id and a pointer to the local artifact; the operator asks the user for the file when an issue warrants it. Simultaneously a quota story (volume collapses), a privacy story (nothing leaves the machine until a human asks), and a product story (local artifacts are strictly better forensics than a Sentry stack trace). The observation that lands hardest: c11's existing local diagnostics are already ~80% of this design and nobody has named the architecture out loud. Gemini's "degraded mode local telemetry" — spill budget-dropped payloads to a local SQLite/rolling file and attach them to manual user feedback — is the same idea entering through the back door.

2. **Server-driven dynamic budgets. (Gemini.)** Make `SentryEventBudget` remotely configurable: when a bad release causes an unexpected spike in a previously unseen error class, push a JSON config that dials the global budget to 1/day/client instantly, mitigating quota bleed without shipping an app update. High leverage, real risk — it's a remote kill switch on your own observability, and the failure mode of a bad push is silence.

3. **Peer-to-peer telemetry blackholing. (Gemini.)** Clients hitting a specific fatal crash loop report the signature to a cheap lightweight sink, which gossips it to other clients to suppress the duplicate, reserving expensive Sentry quota for novel issues. The most speculative idea in the pack, and the most interesting: it treats crash-signature novelty as the scarce resource rather than event count.

4. **The telemetry canary release. (Codex.)** A controlled production build emits one benign, uniquely-tagged non-fatal event. `stats_v2` plus issue/event read-back then validates storage, project routing, release attribution, *and* privacy settings in a single end-to-end heartbeat — replacing inference with a monitoring path that proves itself. Codex correctly flags the risk of polluting production issues; needs careful design.

5. **Name the failure class and sweep for it. (Claude.)** Lesson 3 in `platform/sentry.md` is written as a Sentry fact. It is not — it is a general shape: *a system returns success at the edge and discards server-side, so the sender cannot distinguish success from loss.* Once named, it is greppable. Candidates in this codebase: PostHog's ingestion cap, the dSYM upload, Sparkle appcast generation, and — most interesting because it is *inside the product* — c11's own socket `report_*` telemetry commands. A `c11 report_*` call that succeeds and is silently coalesced away has the identical shape as a Sentry event accepted and dropped, in a product whose entire value proposition is that an agent's work stays legible to the operator.

6. **The adversarial-tenant thought experiment. (Claude.)** The org has no server-side fence and will not have one at this price. Every future Stage 11 project that wires telemetry is, on day one, capable of blinding every other project. The current onboarding control is a paragraph in a markdown file saying "decide the budget question first." A new agent onboarding tenant four will read it, agree, and size its budget against what feels polite — which is exactly what `platform/sentry.md` already warns against. **The only control that survives contact with an agent in a hurry is a script that fails.**

7. **Reframe #401 as a QoS routing layer. (Gemini.)** The client is no longer reporting errors; it is making real-time economic decisions about which data is worth sending upstream. Named that way, the natural next questions are the ones QoS systems ask: classes, priorities, guaranteed lanes (fatals), best-effort lanes (hangs), and admission control — a considerably richer design space than "throttle."

---

## 4. Flywheel Opportunities

1. **Signal-to-noise → quality → headroom. (Gemini and Codex, near-identical.)** Tighter client budgets crowd out low-value events, which forces developers to fix the root causes of frequent warnings (the C11-191/192 hangs) because they are eating the shared lane. Fixed hangs reduce volume → budget opens for more diverse, subtle errors → those get seen and fixed → quality rises → volume falls further. Codex's accelerant: treat `accepted`, `rate_limited`, and `client_discard` as three first-class outcomes in one recurring report, so the loop has a gauge.

2. **Drop-rate → wedged installs → hang fixes. (Claude.)** Tag events with drop counters → rising drop rates surface wedged installs in the ordinary issue list → wedged installs generate hang tickets → fixed hangs reduce volume → headroom funds finer instrumentation → which surfaces the next tier of problems. Each turn makes the next cheaper and the telemetry more informative. **Currently open at the first link,** because the counters never leave the process. This is the cheapest flywheel to close in the pack.

3. **Cross-tenant learning — the one that exists and is not spinning. (Claude.)** Acetate learned "read back the stored artifact, not the config" on ACE-334, and "a green check against a stale manifest is worse than no check" on ACE-678. c11 then learned both again, from scratch, at the cost of a month of production blindness. The lessons transferred as prose in `platform/sentry.md`, and prose does not transfer — evidenced by that doc's pointer to acetate's verifier being broken. The loop wants to be: *incident → lesson → checked-in gate → inherited by next tenant → next tenant's incidents are novel rather than repeats.* Steps one and two happen reliably at Stage 11. **Step three is where it breaks,** because the gate lives inside one project's `scripts/` where the next project cannot see it. One shared script in `platform/`, invoked by both repos, converts a documentation habit into a compounding one.

4. **Tenant onboarding gets cheaper. (Claude, Codex.)** Once the verifier and a machine-readable budget declaration exist, adding a project stops being an incident-generating event. The declared shares are asserted to sum below the pool by a shared script; tenant four costs less than tenant three.

5. **Accepted-vs-attempted as a fleet health signal. (Claude.)** The ratio is currently visible only during a post-mortem. Made continuous, a rising `client_discard` rate across the fleet is an early warning that something is wedging installs — available days before anyone files a bug. Given that C11-191 and C11-192 both trace to user-visible beachballs, this is a product signal, not just an ops signal.

6. **The anti-flywheel to watch. (Claude.)** On-demand spend is enabled. The failure mode has changed shape from "blocked at 50,000" to "silently spends up to $20, *then* blocks." For a system with no alarm, that is a *worse* signal than before, because the first symptom is now a line item on an invoice rather than an outage. The alarm is what keeps the plan upgrade from being a net negative on detectability.

7. **The sequencing trap that would quietly waste PR #401. (Claude, unique and load-bearing.)** C11-191 and C11-192 exist to fix the two hangs that were ~98% of c11's volume. If they land *before* anyone proves the budget bites in a real build, the load disappears, the fence never fires in production, and the next volume spike from some future source meets untested safety code whose first real exercise is the next incident. Prove the fence bites while the load still exists. If schedule pressure forces 191/192 first, the induced-beachball smoke becomes a **hard gate**, because it is the only remaining evidence path.

---

## 5. Strategic Questions for the Plan Author

Deduplicated and merged across all three reviews, ordered roughly by how much downstream work each answer unblocks.

1. **Should this ticket close on the verification, or on the alarm?** Closing on a one-time check means the next occurrence is again found by accident. Expand scope to the detection mechanism, or split the alarm into its own ticket and accept the risk it never gets written? *(Claude Q1, Codex Q3, Gemini Q2.)*

2. **Which released version/build contains PR #401, and what production-adoption signal makes the verification window meaningful?** A merged PR is not a deployed client; without this, the observation window has no start. *(Codex Q1.)*

3. **What are the exact exit criteria — observation interval, outcome thresholds, and expected `client_discard` volume — and how many days after the release ships do we call C11-190 done?** *(Codex Q2, Gemini Q3, Claude concrete-suggestion 2.)*

4. **Does the c11 IP/geo exposure get folded into this ticket, or a separately owned and explicitly linked one?** It is live on a shipped public product right now, `platform/sentry.md` leaves it as "worth a decision," and it will be lost if this ticket closes without it. *(Claude Q2, Codex Q4.)*

5. **Related: is there a broader position on what c11 collects?** Acetate generates a privacy page from its manifest and gates deploys on the page matching reality. c11 has no equivalent statement and, on current settings, could not truthfully write one. Gap to close, or is c11's audience different enough that it doesn't apply? *(Claude Q3.)*

6. **Who owns the org-level settings decision?** `platform/sentry.md` records `scrubIPAddresses: false` and `dataScrubber: false` at the *org* level, and org settings sit on the "Dangerous, confirm with human" list. If the answer is "set them org-wide once," that is strictly better than doing it per-project forever — and needs an explicit yes. *(Claude Q10.)*

7. **What is c11's declared share of the 50,000?** Post-#401 the estimate is "low thousands," but nothing is written down. Without a number, tenant four sizes its budget against nothing. *(Claude Q5, Codex Q5.)*

8. **How much of acetate's telemetry machinery should be lifted to `platform/`?** The alternative is c11 writes its own verifier, they drift, and the third tenant writes a third one. The lift has real cost and is not obviously c11's ticket to pay. *(Claude Q4, Codex's shared-contract mutation.)*

9. **How do you feel about the sequencing risk with C11-191 and C11-192?** Hold them until the fence is observed working under real load, or make the induced-beachball smoke a hard gate instead? *(Claude Q6.)*

10. **Is `allowOnDemand: true` the posture you want with no alarm in place?** It converts a hard stop into a soft $20 spend followed by a hard stop: better ceiling, worse signal, until notifications exist. *(Claude Q7.)*

11. **Now that fatals bypass the client budget, what is the defense against an infinite crash loop on startup in a new release?** Could it burn the $49 ceiling in hours, and should there be a daily fatal ceiling plus a dedicated fatal-spike alert? *(Gemini Q1, Claude concrete-suggestion 8.)*

12. **How will we know if `SentryEventBudget` is too aggressive and blinding us to a widespread issue?** Daily heartbeat of drop counts via a cheaper channel (PostHog), or tags on surviving events, or both? *(Gemini Q2, Claude's drop-counter mutation, Codex's observable discard counter.)*

13. **The hang double-charge and the per-process budget reset: fix now or file?** Neither is urgent; both make the numbers currently asserted in `platform/sentry.md` inaccurate, and that doc is now the org's reference for how a tenant fences itself. *(Claude Q8.)*

14. **What is the intended response if the release proves stored events but the accepted trend exceeds the low-thousands projection** — adjust budgets, investigate a new emitter, or block additional reporting clients? *(Codex Q5.)*

15. **Is the "local record, remote index" architecture worth exploring?** Larger than this ticket wants, but it collapses quota, improves privacy, and improves forensics simultaneously — and this is the moment when the reasoning is fresh. *(Claude Q9, Gemini's degraded-mode variant.)*

---

## Reviewer Divergence Notes

- **Claude** is the only reviewer that performed live read-only API verification, producing a row-by-row currency audit and confirming the c11 privacy exposure, the absence of per-key rate limits on Team, and the hang double-charge in landed code. It also uniquely surfaces the C11-191/192 sequencing trap and the cross-tenant-learning flywheel.
- **Codex** is the most disciplined about scope: it treats the deliverable as a *measurement contract* bound to a release, and it is the only reviewer to insist explicitly on secret-safe output (aggregates only, never print auth tokens or DSNs) for any verification helper.
- **Gemini** is the only reviewer to name #401 as a QoS layer, and it owns the most speculative end of the mutation space (server-driven budgets, P2P signature blackholing). It does not raise the privacy exposure or the currency staleness of the plan's dates.
- **No material contradictions** were found between the three. The differences are altitude and coverage, not disagreement — which raises confidence in the consensus items above.
