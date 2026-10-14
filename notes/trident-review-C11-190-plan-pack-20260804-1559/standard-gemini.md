# Standard Plan Review

### Executive Summary
This plan is fundamentally stale and out of sync with recent actions taken on the project. The core constraints the plan was built around—waiting until August 24th for a free-tier quota reset, investigating the CLI DSNs, and making a decision on budget limits—have already been resolved. The organization has been upgraded to the Team plan (which immediately reset the billing period on August 4th), and PR #401 has already landed the necessary client-side throttles and removed the hardcoded CLI DSN. 

The only surviving and valid intent of this plan is the final verification step. The plan must be rewritten to reflect the current reality before execution.

### The Plan's Intent vs. Its Execution
The underlying intent of the plan is spot-on: to ensure `c11` is no longer flying blind and that events are genuinely being stored, not just accepted at the edge and dropped silently.

However, the execution as written is obsolete:
- The plan directs the operator to wait until August 24, 2026. This is now actively incorrect; the org upgrade unblocked the quota on August 4.
- The plan dictates investigating "the budget question" and checking if "any shipped c11 build still points at the retired DSN". These were fully addressed in the audit and PR #401. 

If someone were to execute this plan today, they would be waiting 20 days for a date that no longer matters, to make decisions that are already shipped.

### Architectural Assessment
The original structure of the plan (Wait for reset -> Verify Storage -> Decide Budget/Fix DSNs) made sense before the audit. Today, the problem decomposition is entirely observational. 

An updated, correct framing would be:
1. **Wait for Deployment:** Ensure a new release containing PR #401 reaches the fleet.
2. **Verify Acceptance:** Confirm via `stats_v2` that incoming events have `outcome=accepted`.
3. **Verify Volume:** Confirm that the new client-side `SentryEventBudget` successfully drops the event volume to the low thousands per month, preventing the old ~40k/month run rate.

### Is This the Move?
As currently written, no. Sticking to the August 24th timeline would cause unnecessary delay. Given common patterns in incident response, the right move is to pivot immediately from "fix formulation" to "verification of the deployed fix." 

Furthermore, a common failure pattern when dealing with client-side fixes is forgetting the long tail of old clients. Older `c11` Cocoa clients (pre-PR #401) will continue to spam the active DSN with un-throttled hang reports. The verification phase must account for this mix of old and new clients consuming the new 50k quota.

### Key Strengths
The single strongest element of this plan is its explicit distinction between an SDK returning a success response and Sentry actually storing the event. The insistence on checking `outcome=accepted` (rather than just observing that the SDK doesn't throw an error) proves a deep understanding of Sentry's edge-discard behavior. This specific verification check is the most critical part of the ticket and must be preserved.

### Weaknesses and Gaps
- **Chronological Obsolescence:** The entire timeline is wrong post-upgrade.
- **Resolved Action Items:** Steps 2 and 3 are no longer actionable because they are already done.
- **Missing Deployment Dependency:** The plan forgets that client-side throttles don't exist until the user upgrades. Verification of the volume drop requires waiting for adoption of the release containing PR #401.

### Alternatives Considered
- **Alternative 1 (Close and replace):** Close C11-190 completely, noting that the audit and PR #401 resolved it, and open a new ticket strictly for "Verify PR #401 Sentry throttles in production". This might be cleaner than mutating a stale plan.
- **Alternative 2 (Rewrite in place):** Keep C11-190, but delete items 2 and 3, and rewrite item 1 to reflect the August 4th reset and the dependency on a new release deployment. This is the recommended path to maintain context.

### Readiness Verdict
**Needs rethinking.** The plan must be reduced to a pure verification checklist that accurately reflects the August 4th quota reset, the new 50k limit, and the landed PR #401.

### Questions for the Plan Author
1. When is the next release cut that includes PR #401? We cannot verify the volume drop until the fleet actually updates and the new client-side budget takes effect.
2. Since older Cocoa clients will continue to send un-throttled hang reports to the active `c11` project DSN, do we have an estimate of how fast those old versions will bleed out? Do we need to consider temporary server-side dropping of specific hang issues if they threaten the new 50k cap before adoption hits?
3. The Sentry audit noted that `c11` is currently storing user IP addresses and cities because `scrubIPAddresses` is false on the org (only `acetate` was fixed). Does this ticket need to include verifying that `c11` project settings are updated to scrub PII, or is that entirely out of scope for C11-190?
