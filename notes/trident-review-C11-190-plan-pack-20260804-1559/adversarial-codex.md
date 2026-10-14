# Adversarial Review — C11-190 Plan

## Executive Summary

**Verdict: do not execute this plan as written.** Its single remaining operational goal is sound—prove that an event is *stored*, not merely accepted by the ingest edge—but its stated timeline, capacity model, and remediation choices were overtaken by the 2026-08-04 audit and merged PR #401. It would send a worker to wait for a reset that has already occurred and to reopen billing/rate-limit questions that already have materially different answers.

The replacement contract should be narrow and executable: after a release containing `42ce4c919d8015b3a2d4fbf59517e220771571f7` is deployed to real production installs, query `stats_v2` for the **c11 project**, grouped by outcome, and demonstrate post-release `accepted` storage with the release/environment dimensions needed to attribute it. Then observe a declared window and decide whether actual accepted volume remains within the org budget. Anything else in the old three-item list is either completed or needs a separately framed policy decision.

The largest unresolved risk is hidden by the reassuring phrase “client-side budget”: the new cap is per process, not org-wide. A fleet of healthy app processes can still collectively consume the shared 50,000-event allocation. It prevents a single wedged process from replaying hundreds of reports per hour; it is not a quota guarantee.

## How Plans Like This Fail

- **A date becomes the plan.** The plan makes 2026-08-24 its trigger. The billing period was reset early on 2026-08-04 under a Team plan, so that trigger is stale and causes needless blindness.
- **Transport success is mistaken for storage.** The plan correctly identifies this failure mode, but does not name a reproducible query, time range, project filter, expected minimum, or durable evidence artifact. A reviewer can still mistake an SDK event ID or an aggregate org counter for proof.
- **Remediation is treated as shipped merely because it merged.** PR #401 is on `main`, but the plan has no release/version gate. Verification before a production build containing that commit has meaningful traffic cannot establish that the new budget and hang throttle are protecting users.
- **A local throttle is mistaken for a fleet budget.** `SentryEventBudget` is process-local. The old daily rate was a population outcome; comparing it to 50/day without a release/install denominator creates a false sense of safety.
- **Old incident narrative survives as operating truth.** `platform/sentry.md` still contains the old 5,000-error/2026-08-24/no-on-demand narrative in its quota-incident section while its account and fence sections say Team/50,000/$49. A new operator can choose the wrong instructions depending on which section they read.

## Assumption Audit

| Assumption | Status | Why it matters |
|---|---|---|
| The org remains blocked until 2026-08-24. | **False.** Reset was 2026-08-04; usage was zero. | The ticket's principal wait condition is obsolete. |
| The org is a 5,000-event Developer account with no on-demand capacity. | **False.** It is Team: 50,000 reserved errors, $20 shared on-demand, $49 hard ceiling. | The budget decision and urgency are materially different. |
| A paid plan or on-demand spend can provide the needed per-key fence. | **False as framed.** Per-key limits remain Business-only; Team still has none. | Paying alone does not isolate c11 from another client. |
| The retired DSN is only in old builds. | **False.** The main CLI had the hard-coded DSN and was the 1.12M-event source. | The plan misses the actual dominant producer. |
| The PR #401 controls are active in production. | **Unproven.** The commit is merged, but no released build/version or install uptake is specified. | The remaining verification cannot be attributed to the fix otherwise. |
| Low thousands per month is inherently safe. | **Load-bearing but unquantified.** The caps are per process and fatal events are exempt. | A fleet-wide ceiling and an alert threshold are still absent. |
| `stats_v2` remains the storage oracle. | Likely, but the exact supported query/result semantics must be captured in the runbook. | The ticket needs an evidence-producing procedure, not only the endpoint name. |

## Blind Spots

1. **No acceptance criteria.** “Confirm accepted” lacks an observation window, query parameters, project/environment/release filters, a success threshold, and a saved sanitized result. It also has no failure branch: who investigates, and what determines whether this ticket is blocked versus the release is rolled back?
2. **No production-release boundary.** Require a tagged/released artifact containing #401, identify its version/build, and wait for a nontrivial number of real production sessions before drawing a rate conclusion. Internal/debug/test traffic must not satisfy the proof.
3. **No baseline or denominator.** “Low thousands” is not measurable without a cohort: unique installed versions, active users/processes, days observed, and the counts by outcome. One quiet day does not establish monthly safety; one noisy day does not prove regression after a budgeted release.
4. **No ongoing detection mechanism.** The incident was silent because only a server-side outcome query exposes exhaustion. A one-time manual check recreates the same failure mode. Assign an owner/cadence and an alert or scheduled report for `accepted`, `rate_limited`, and client-discarded volume before the quota is threatened.
5. **No cross-client budget contract.** c11 and Acetate share the org. Their independent per-process caps do not compose into an org cap. The plan needs a written allocation, review trigger for new reporting clients, and a rule for what is sacrificed first when usage rises.
6. **No privacy closure.** The audit found a CLI with `sendDefaultPii = true`; #401 disables it, but the platform document says c11 may still store IP and derived city because its project/org server-side scrub settings have not been decided. This is not proof-of-resumption work, but it is an explicit adjacent risk that must be assigned or recorded as out of scope.
7. **No test of the actual silent-failure detector.** The plan should say whether validation may deliberately emit a bounded synthetic event, how it will be marked and removed/ignored, and whether that action needs operator approval. Querying ambient traffic alone cannot prove the full event-to-storage path at a chosen moment.

## Challenged Decisions

- **“Wait until the quota reset.”** Superseded. Run the verification now, but only after a production release carrying #401 is available. Keeping the old date turns a resolved incident into an avoidable delay.
- **“Decide paid plan or on-demand budget.”** Superseded as the ticket's decision. The Team upgrade and $49 ceiling already happened; neither gives per-key limits. The real decision is an org-wide client budget/allocation and a monitoring policy, not a binary billing choice.
- **“Consider whether any shipped build uses the retired DSN.”** Completed in substance: the live `main` CLI did, and #401 removes its compiled-in DSN. What remains is release adoption, not discovery. Replace this with “verify no supported released artifact retains the retired CLI DSN and record the first fixed version.”
- **“Low event volume means health.”** Dangerous default. The budget intentionally makes raw event count a weak proxy, particularly for hang reports. Health should be issue diversity, fatal delivery, release-tagged accepted outcomes, user impact, and rate-limit absence—not simply fewer events.
- **Fatal exemption.** Correctly protects real crashes, but it is a deliberate unbounded path. The test-host exclusion removes one known source; the plan must state how fatal volume is monitored and what emergency action applies if a production fatal loop appears.

## Hindsight Preview

In two years the likely regret is not that this plan failed to add another quota number; it is that it closed after one green query and never created a durable server-side outcome monitor. The early warnings are: any nonzero `rate_limited` outcome after the release, accepted-volume acceleration relative to active installs, a new reporting client without a bounded sender, unexpected fatal concentration, and a release/version missing from the expected Sentry dimensions.

The durable artifact should be a small, credential-safe runbook or scheduled check that records: query timestamp and range, org plan/remaining capacity, per-project outcome totals, release/environment filters, threshold, owner, and escalation action. Without that, the next quota exhaustion will again be discovered only after an unrelated incident.

## Reality Stress Test

Assume simultaneously: (1) #401 ships but old builds remain common, (2) an Acetate release begins reporting, and (3) a new c11 fatal loop occurs. The CLI fix prevents the known 1.12M dead-DSN storm, and the per-process hang cap suppresses one common loop, but neither limits the aggregate fleet or Acetate. Fatal events bypass c11's cap. A one-time `stats_v2` check may be green at release time and still miss a rapid shared-quota burn days later. Under this plausible combination, the plan has neither fleet allocation nor a monitoring cadence nor a pre-authorized response.

## The Uncomfortable Truths

- The existing plan is now an incident note, not a usable implementation contract. Its three “remaining” items are respectively obsolete, answered differently, and completed/reframed by #401.
- “Client-side-only fence” is a mitigation, not isolation. The organization still has no server-side per-key guardrail, so every new client is trusted not to collectively overrun the quota.
- The audit's expected reduction to under roughly 150 events on the historic worst day is a model, not evidence from production. The plan must not present it as achieved until a fixed release has observed traffic.
- Documentation already contains conflicting historical and current quota instructions. Leaving them adjacent without an explicit historical label invites a repeat of the incident through operator error.

## Hard Questions for the Plan Author

1. What exact released version/build contains #401, when was it made available, and what production uptake threshold makes its `stats_v2` result representative?
2. What exact `stats_v2` query, project filter, outcome set, release/environment dimensions, interval, and observation window constitute proof that events were **stored** after the fixed release?
3. What minimum accepted count proves delivery without treating a coincidentally quiet period as success, and what nonzero `rate_limited` count fails the ticket?
4. Can the verifier emit one bounded, clearly tagged synthetic production-path event? If yes, who authorizes it, how is it distinguished from a real incident, and what read-back proves storage?
5. Who owns the recurring outcome check, how often does it run, and what is the escalation threshold before the shared quota threatens observability?
6. What fleet-level monthly allocation belongs to c11, Acetate, and future projects, given that 20/hour and 50/day are per process rather than per organization?
7. What is the response if fatal events—deliberately exempt from the budget—accelerate? “Fatal exempt” is not an answer to quota exhaustion.
8. Which supported release is the first one with no compiled-in retired CLI DSN, and how will the project verify there is no remaining supported distribution artifact with it?
9. Is c11's server-side IP/geo retention deliberately accepted, or should a separate approved privacy task configure and read back project-level scrubbing? **We do not know; leaving it implicit is a policy gap.**
10. When will `platform/sentry.md`'s historical incident text be reconciled or clearly labeled so the obsolete 5,000-error/2026-08-24 instructions cannot be executed as current operations?
