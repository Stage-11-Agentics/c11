# Evolutionary review — C11-190

## Executive Summary

The useful remaining ticket is no longer a quota-reset wait or a billing decision. It is the first production proof that c11 has become a *bounded, observable participant* in a shared telemetry budget: a PR #401 release must arrive in real installs, its events must be stored (not merely accepted at ingest), and the resulting rate must remain small enough that distinct failures are visible. The present plan is materially stale and therefore not executable as that contract: its title, premise, date, remaining work item 2, and explanation of the retired-DSN source contradict the audit and the merged fix.

## What's Really Being Built

This ticket can establish an operational control loop for shared Sentry capacity:

1. a released client enforces a local outbound budget and suppresses low-value repeat hangs;
2. Sentry `stats_v2` verifies the server-side outcome independently of the SDK's HTTP/event-id response; and
3. a bounded monthly trend detects a return to blindness before it hides a real crash.

That is more durable than a one-time “did quota reset?” check. It is the reusable contract every Stage11 reporting client needs while server-side per-key limits remain unavailable.

## How It Could Be Better

Replace the historical narrative with a short current-state snapshot. The plan should explicitly record that the org is Team, the period reset on 2026-08-04 with zero usage, the hard ceiling is $49/month, and per-key limits remain unavailable on Team. Remove the obsolete claim that the only fences are a paid plan or an on-demand budget: both are already decided, and neither creates a per-key fence.

The plan also needs a release gate. PR #401 being merged is not evidence that production clients run it. Name the release/version and distribution channel that contains commit `42ce4c919d8015b3a2d4fbf59517e220771571f7`, then define the observation window relative to that release reaching production—not the superseded 2026-08-24 reset.

“Confirm accepted” is underspecified. Define the exact `stats_v2` query shape, a time window after rollout, the project/outcome filters, the expected accepted count range, and the minimum evidence artifact (timestamped response or a redacted summary). The plan should also distinguish accepted server-side outcomes from `client_discard`, which is an expected result of the new local budget and useful proof the budget is engaging.

## Mutations and Wild Ideas

Turn `SentryEventBudget` into a small telemetry-admission contract shared by every Stage11 client rather than a c11-only repair. Each client would declare its event classes, fatal exemption policy, hourly/daily bounds, and an observable discard counter. A common dashboard or periodic read-only report could then compare the summed client budgets with the 50,000 org budget before a new integration ships.

A more ambitious variant is a “telemetry canary release”: one controlled production build emits a benign, uniquely tagged non-fatal event once. `stats_v2` and issue/event read-back validate storage, project routing, release attribution, and privacy settings. This must be designed carefully to avoid polluting production issues, but it replaces inference with an end-to-end monitoring heartbeat.

## What It Unlocks

Once verification is release-bound and outcome-based, c11 can safely claim that Sentry is a production diagnostic channel again. The same evidence pattern can gate Acetate and future projects, prevent SDK success responses from being mistaken for storage, and make client-side discards a capacity signal instead of an invisible loss. It also separates this ticket from the actual hang fixes, correctly owned by C11-191 and C11-192.

## Sequencing and Compounding

1. Amend C11-190 to retire the reset/billing investigation and state the post-audit baseline.
2. Identify and ship a release containing PR #401; record its version/build and rollout start.
3. After a defined settling window, query `stats_v2` by `project=c11` and outcome; preserve a redacted evidence artifact.
4. Compare accepted events against a low-thousands/month projection and check that client discards are compatible with the configured budget rather than evidence of an org block.
5. If stored outcomes are absent, first isolate release adoption/routing/configuration from quota state; do not reopen the old billing hypothesis.
6. Convert the successful query and thresholds into a recurring lightweight health check, or explicitly decide that this is a one-time release verification.

The needed early investment is the measurement contract. Without it, a future reset, plan change, or client regression recreates the same silent-blindness failure mode.

## The Flywheel

Bounded clients produce fewer duplicate events; reduced noise preserves shared quota; preserved quota means real failures are stored; stored failures reveal the next noisy source or actual product defect; those findings tighten client admission rules and improve the next release. Accelerate the loop by treating `accepted`, `rate_limited`, and `client_discard` as three first-class outcomes in one recurring report. A drop in accepted events is good only when it is paired with expected client discards—not when it is an unexplained absence.

## Concrete Suggestions

- Retitle/rewrite the ticket around “verify PR #401 telemetry protection in a production release,” removing the now-false 2026-08-24 wait condition.
- Replace item 2 with a completed decision record: Team plan, 50,000 errors/month, $20 shared on-demand cap, $49 ceiling, and client-side budgets as the only per-client fence.
- Replace item 3 with the established root cause and mitigation: the main-branch CLI DSN was the 1.12M-event source; it is removed and only opt-in through `C11_CLI_SENTRY_DSN` now. The remaining question is release adoption, not speculative legacy-build routing.
- Add explicit acceptance criteria: production release includes #401; `stats_v2` reports stored/accepted c11 events after rollout; no `error_usage_exceeded`/rate-limited org condition; accepted-rate projection is low thousands rather than roughly 40k/month; and the evidence records the query timestamp and release under observation.
- Add a privacy decision or linked follow-up: the platform runbook says c11 is presumably still storing IP/city because only Acetate has project-level scrubbing. This is adjacent but operationally important; it should be explicitly in or out of C11-190 rather than silently omitted.
- Create a reusable, secret-safe verification helper or documented command that reads existing credentials locally, emits only aggregate outcomes, and never prints auth tokens or DSNs.

## Questions for the Plan Author

1. Which released version/build contains PR #401, and what production-adoption signal establishes that the verification window is meaningful?
2. What exact post-release observation interval and outcome thresholds constitute success, including expected `client_discard` volume?
3. Is this ticket a one-time release check, or should it install a recurring aggregate outcome check so the original silent-failure class is detected promptly?
4. Should C11-190 include the c11 IP/geo storage decision, or should it create a separately owned, explicitly linked privacy follow-up?
5. What is the intended response if the release proves stored events but the accepted trend exceeds the low-thousands projection: adjust budgets, investigate a new emitter, or block additional reporting clients?

## Verdict

The plan is not current enough to execute as written. Amend it before work proceeds; then the narrowed verification task is concrete and valuable.
