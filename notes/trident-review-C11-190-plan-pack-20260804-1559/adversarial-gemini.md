# Adversarial Plan Review

### Executive Summary
The plan is fundamentally disconnected from current reality and highly vulnerable in its proposed mitigations. The billing and quota blockages it anchors on are already resolved via a plan upgrade (Team tier), rendering the 2026-08-24 timeline obsolete. More concerningly, the "fix" (PR #401) relies entirely on a client-side throttle that fundamentally fails to protect the organization's shared quota. By exempting fatal errors from the client-side budget and leaving older, unthrottled clients in the wild without server-side filtering, this plan ensures the next crashlooping release or lingering legacy footprint will instantly exhaust the new $49/50,000-event quota, blinding all Stage 11 projects once again. Furthermore, the plan treats 1.12 million rejected CLI errors merely as a quota nuisance, completely ignoring the massive underlying engineering failure they represent.

### How Plans Like This Fail
- **Fixing the symptom, ignoring the disease:** The plan silences the Sentry reporter but doesn't fix the 1.12M underlying socket and hook failures in the CLI. The application is still failing; we just stopped looking at it.
- **Ignoring adoption curves:** The plan assumes PR #401 will immediately drop the run rate to the "low thousands". Old versions (like `0.58.0`) without the throttle will continue sending ~40,000 events/month until users naturally upgrade, which could take months.
- **Trusting the client for billing protection:** Client-side rate limiting for a shared organizational billing quota is fundamentally insecure and brittle. It cannot protect against old versions, malicious actors, or the client's own catastrophic failure modes.

### Assumption Audit
- **Assumption (Stale):** We are blocked until 2026-08-24. *Reality:* The org was upgraded to Team, billing reset on 2026-08-04, and the org is unblocked right now.
- **Assumption (Load-bearing):** PR #401's client-side throttle protects the quota. *Likelihood to hold:* Zero. Fatal errors are explicitly exempt, meaning a startup crashloop will instantly exhaust the quota. Old versions lacking the throttle will also bypass this entirely.
- **Assumption:** The CLI socket/hook errors were just noise. *Likelihood to hold:* Low. 1.12 million failures per month strongly suggests a severely broken CLI user experience, not just noisy telemetry.
- **Assumption:** A $49 hard cap protects the business. *Likelihood to hold:* True for finance, false for observability. If a noisy issue hits the $49 cap early in the month, Sentry shuts down for *all* Stage 11 projects, including Acetate.

### Blind Spots
- **The Legacy Footprint:** What happens to the 40k/month GUI hang events from users who do not immediately update their clients? They will eat 80% of the newly upgraded 50,000 quota before the new budget logic even applies to them.
- **The Crashloop Vulnerability:** By exempting fatal events from the client-side budget, PR #401 leaves the system wide open to the most dangerous quota-exhaustion scenario: a crash-on-launch bug. A crashlooping client will generate thousands of fatal events in minutes, destroying the quota.
- **Server-Side Inbound Filters:** The plan acknowledges that per-key rate limits don't exist on the Team plan, but completely ignores Sentry's server-side *Inbound Data Filters* (e.g., filtering by release version, legacy browser filters, or custom event dropping rules). Can we drop older releases at the server before they count against the quota? The plan never asks.
- **Acetate's Usage Model:** The plan acknowledges Acetate shares the quota but doesn't model their expected traffic. What happens if Acetate naturally consumes 30k/month, leaving no room for the legacy c11 footprint?

### Challenged Decisions
- **Exempting Fatal Errors from the Budget:** This is a deliberate choice in PR #401, justified by "losing a crash to a noisy neighbour is the thing being fixed." But it is completely backwards for quota protection. A crashloop is the fastest way to exhaust a quota. Thousands of identical fatal crashes from a single user provide zero extra debugging value while destroying observability for everything else.
- **Deactivating the CLI Key Instead of Fixing the Bug:** The decision to simply stop reporting 1.12 million errors rather than investigating why the CLI is failing to connect to its socket is a massive abdication of engineering responsibility.
- **Relying Solely on Client-Side Defenses:** Knowing that the Sentry plan lacks server-side rate limits, settling for a client-side-only defense without exploring Sentry's inbound data filtering rules is a dangerous default.

### Hindsight Preview
Six months from now, we will push a bad update that crashes on launch. It will generate 60,000 fatal events in a few hours. Because fatal events are exempt from the client-side budget, we will immediately hit the $49 cap. Sentry will black out, and we will be completely blind to *other* critical errors across all Stage 11 products until the next billing cycle. We will look back and ask, "Why didn't we cap fatal events?" and "Why didn't we configure server-side rules to drop legacy clients?"

### Reality Stress Test
Imagine these three things happen simultaneously:
1. A new c11 version ships with a crash-on-launch bug.
2. A stubborn subset of users remain on v0.58.0, continuing to generate legacy hang reports at a rate of 40k/month.
3. Acetate launches successfully and consumes 15k/month.
*Result:* The legacy users and Acetate alone exceed the 50,000 quota (55k/month). Add the crashloop, which generates 100k fatal events because they are exempt from throttling. The organization's entire Sentry quota is destroyed on day 1 of the billing cycle, leaving every Stage 11 project blind for 29 days.

### The Uncomfortable Truths
- We didn't fix the broken CLI; we just put duct tape over its mouth so we don't have to look at the million errors it generates.
- We are paying Sentry money (upgrading to the Team plan) primarily to accommodate our own architectural inefficiencies (unbounded hang reports) rather than fixing them at the root.
- Our observability infrastructure is entirely at the mercy of our clients' behavior, meaning any client can maliciously or accidentally turn off our monitoring system at any time.

### Hard Questions for the Plan Author
1. Since old clients (like v0.58.0) lack the PR #401 throttle, what is the specific server-side mechanism we will use to prevent them from consuming 80% of the new 50,000 quota?
2. Why were fatal errors explicitly exempted from the client-side budget, given that a crashloop is the most likely scenario to instantly exhaust an unprotected quota?
3. What is the root cause of the 1.12 million CLI socket/hook errors, and why is "stop reporting them" considered an acceptable engineering response to that volume of failures?
4. Now that the org is unblocked (as of 2026-08-04) due to the Team upgrade, why does the plan still mandate waiting to verify, rather than verifying today?
5. Have we modeled the projected monthly Sentry volume for the Acetate project, and does it leave enough headroom in the 50,000 quota for c11's baseline?
