# C11-190-PLAN Evolutionary Review (Gemini)

### Executive Summary
The original plan was a reactive fix to a billing/quota outage. Thanks to the PR #401 audit, the infrastructure has already mutated from "hope the quota holds" into a "client-side telemetry governor." The opportunity here isn't just to verify that Sentry is accepting events again; it's to evolve c11's telemetry from a blind firehose into a highly tuned, self-regulating signal generator. This is the foundation for a fleet-wide health mesh that guarantees high-signal (crashes) never gets drowned out by high-noise (hangs, tests, old clients).

### What's Really Being Built
On paper, this is about fixing a Sentry quota incident and verifying the dashboard. Underneath, PR #401 just built a *Quality of Service (QoS) routing layer for telemetry*. By implementing `SentryEventBudget` and throttling hang reports, the system is no longer just reporting errors; it is making real-time, client-side economic decisions about what data is worth sending to the mothership. You are building an edge-based intelligence filter.

### How It Could Be Better
The current plan concludes with a manual chore: "confirm via stats_v2 that c11 events are accepted... and that the monthly accepted total lands in the low thousands."
Manual verification is brittle and reactive. This could be improved by automating the budget verification and feedback loops:
1. **Instrument the Governor:** The `SentryEventBudget` is purely client-side and silent when it drops an event. It should emit a lightweight analytic ping (e.g., to PostHog, bypassing Sentry) stating `sentry_budget_exhausted: true` or recording the number of dropped events. This allows you to monitor the *effectiveness* of the governor without spending Sentry quota.
2. **Automated Budget Fences:** Turn the manual "stats_v2 check" into an automated Sentry Alert that fires if c11's event volume exceeds an expected daily threshold (e.g., > 150/day). 

### Mutations and Wild Ideas
1. **Dynamic Server-Driven Budgets:** What if `SentryEventBudget` wasn't static? If a bad release causes an unexpected spike in a previously unseen error type, you could push a JSON config payload from the server to dial down the global budget to 1 per day per client instantly, mitigating quota bleed without waiting for an app update.
2. **Degraded Mode Local Telemetry:** When the Sentry budget is exhausted, instead of `outcome=client_discard` into the void, degrade to logging the Sentry payload to a local SQLite DB or rolling file. When the user eventually reports an issue via the UI, these "budget-dropped" events are attached to the manual feedback payload.
3. **Peer-to-Peer Telemetry Blackholing:** Clients that hit a specific fatal crash loop could report the signature to a cheap, lightweight backend sink, which then gossips that signature to other clients to suppress it, saving the expensive Sentry quota for novel issues.

### What It Unlocks
- **Guaranteed Signal-to-Noise:** Because fatal crashes are exempt from the throttle, engineering has unlocked a guarantee that real crashes will be seen. This allows for tighter SLAs on crash resolution.
- **Cross-Project Fairness:** Acetate and other apps on the org's shared Sentry quota are now insulated from c11's noise. c11 has essentially "fenced itself" to be a good neighbor.
- **Predictable OpEx:** The business can scale c11 users without scaling monitoring costs linearly.

### Sequencing and Compounding
The plan's final step needs a slight reordering to maximize value:
1. **Ship & Watch (Immediate):** Release PR #401 and watch for the baseline drop in volume.
2. **Alerting (Short-term):** Set up Sentry alerts for *anomalous volume spikes* to replace manual dashboard monitoring.
3. **Instrument Drops (Medium-term):** Add PostHog tracking for events dropped by `SentryEventBudget` so you know if your client-side limits are too tight.
4. **Remote Configuration (Long-term):** Build the remote-control capability for `SentryEventBudget`.

### The Flywheel
**The Signal-to-Noise Flywheel:** Tighter client-side budgets force developers to fix the root causes of frequent warnings (like the C11-191/192 hangs) because they crowd out other non-fatal insights. Fixing hangs reduces noise → Sentry budget opens up for more diverse, subtle errors → Developers see and fix those subtle errors → App quality improves → Telemetry volume drops further, unlocking even more budget for new features. 

### Concrete Suggestions
1. **Create an Automated Threshold Alert:** Go into Sentry right now and create an alert for the c11 project: if event count > 500 in 24 hours, alert the team. This replaces the ongoing need to "verify stats_v2".
2. **Log Dropped Events Locally:** Update `SentryEventBudget` so that when it rejects an event, it writes a concise summary (timestamp, issue signature) to a local rolling file. This preserves debuggability for individual users when they submit support tickets.
3. **Monitor the 'Exempt' Fatals:** Ensure there is a specific alert for a spike in *fatal* events. Since fatals bypass the budget, a startup crash loop in the wild could still blow through the $49/mo ceiling in hours.

### Questions for the Plan Author
1. Now that fatal crashes bypass the client-side budget, what is our defense mechanism if a new release introduces an infinite crash loop on startup? Will that blow through the $49 cap instantly?
2. How will we know if `SentryEventBudget` is too aggressive and blinding us to widespread issues? Should we send a daily heartbeat (via a cheaper channel like PostHog) with the count of events dropped by the client?
3. Since the verification is the only remaining task, what is the exact exit criteria? How many days after the PR #401 release ships do we consider the verification "complete" so we can close C11-190?