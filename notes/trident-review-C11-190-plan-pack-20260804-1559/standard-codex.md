# C11-190 plan review — Codex

## Executive Summary

**Needs revision before execution.** The plan correctly identifies the real failure mode—ingest success is not storage success—but it is no longer the contract for the ticket. Its date gate, quota facts, remediation choices, and “open” investigation are superseded by the 2026-08-04 audit and merged PR #401. The remaining job is narrow: after a release containing `42ce4c919d8015b3a2d4fbf59517e220771571f7` has reached a real production client, use Sentry `stats_v2` to prove accepted c11 events and measure the post-fix rate.

The single most important correction is to turn that into a reproducible, time-bounded observation protocol. A successful SDK response, a green build, or an event visible in a local debug session is not evidence that production telemetry is stored.

## The Plan’s Intent vs. Its Execution

The intent is sound: recover trustworthy c11 error monitoring after an org-wide quota incident, and avoid confusing HTTP 200/event IDs with retained events. But the written execution describes a blocked Developer-plan org that must wait until 2026-08-24 and then resolve a budget decision and discover whether builds still use the retired DSN.

Those are no longer outstanding:

- The org is Team, with a 50,000-error allocation, a $20 shared on-demand cap, and a $49/month hard ceiling; the period reset on 2026-08-04 with zero use.
- Team still has no per-key or spike-protection rate limit. A paid plan was not the missing server-side fence.
- PR #401 removed the CLI’s compiled-in retired DSN, made it opt-in, disabled default PII, excluded XCTest, installed the app-side event budget, and made hang reports one-per-episode at at least five seconds.
- The apparent “old builds” source was materially the CLI on `main`, not merely unknown legacy application releases.

Keeping the three original numbered items would waste effort and, worse, postpone a verification that can now happen as soon as a fixed release is in use.

## Architectural Assessment

The right decomposition now has two explicit phases:

1. **Release eligibility.** Record the public production release/version/build containing #401 and evidence that it has actually emitted at least one production event. Do not let a development build, XCTest host, or an event from an older release satisfy this phase.
2. **Server-side outcome verification.** Query `stats_v2` grouped by project, outcome, release, and daily interval over a declared observation window. Demonstrate `outcome=accepted` for the c11 project and report accepted, rate-limited, and client-discard counts separately. Compare the observed accepted pace with a named pre-fix baseline (about 40k/month attempted, 1,848 accepted on 2026-07-25) and the intended low-thousands/month outcome.

This preserves the core lesson: only Sentry’s outcome data proves storage. It also separates deployment truth from implementation truth. The current plan has neither a release predicate nor a query/result artifact, so a future executor could check too early or report a misleading aggregate.

The verification should be observability work, not a synthetic production error injection by default. A controlled live event would require an explicit privacy and production-data decision; naturally occurring production telemetry, queried after a stated minimum window, is sufficient for this ticket.

## Is This the Move?

Yes—the revised, verification-only move is right. The landed controls address the proven high-volume sources locally, where a shared-quota org actually has leverage. Reopening the earlier billing/rate-limit investigation would be churn: the Team upgrade has already happened and was empirically shown not to offer the assumed per-key fence.

However, “monthly accepted total lands in the low thousands” is not yet an executable acceptance criterion. It needs a concrete observation period and calculation. A few post-release hours can prove *resumption* but cannot prove the monthly rate; a 7- or 14-day sample can support a normalized projection, while a full billing period establishes it conclusively. The ticket should state which claim is required to close it, and defer the longer-horizon confirmation to a follow-up if timely closure is necessary.

## Key Strengths

- The plan centers `outcome=accepted`, the only signal that distinguishes retained telemetry from silent quota discard.
- The audit correctly identified the shared-org blast radius and rejected a false server-side rate-limit solution.
- #401 attacks the demonstrated sources rather than guessing: the CLI’s dead DSN flood, repeated hang captures, and XCTest-host fatal noise.
- The controls retain diagnostic fidelity where it matters: fatal events are exempt, and local hang logging remains available even when remote reporting is constrained.

## Weaknesses and Gaps

- **Obsolete prerequisites.** Waiting for 2026-08-24 is actively incorrect; the new billing period began 2026-08-04 and is not blocked.
- **Resolved work is still presented as open.** The budget decision and retired-DSN investigation have conclusions and landed code, but the plan does not say they are closed or point to the corresponding release requirement.
- **No release boundary.** “After PR #401 ships in a release” needs an exact release/build identifier and an evidence source. Otherwise pre-fix production events can contaminate the reading.
- **No reproducible query contract.** Specify the authenticated `stats_v2` query, groupings, timezone/window, project filter, and raw result artifact. The documented endpoint’s daily interval requirement should be retained.
- **No closure threshold.** “Low thousands” is directionally correct but too elastic. State a normalized target, a maximum allowed `rate_limited` count (normally zero while under quota), and how `client_discard` is interpreted rather than mistaking intentional budget drops for Sentry loss.
- **No ownership/cadence.** A one-off query proves recovery only at that instant. The plan should name who runs the release-adjacent check and whether a second, longer-window check is required. Alerting on future quota pressure is valuable, but is a separate scope decision rather than an implicit addition to this recovery ticket.

`platform/sentry.md` itself contains stale Developer-plan/reset language inside the historical incident section while its account and fence sections reflect Team. The revised plan should cite the audit/updated operational facts rather than propagate the historical block as current state.

## Alternatives Considered

- **Wait for a full billing month, then close.** Strongest rate evidence, but unnecessarily delays the immediate proof that storage resumed. Prefer a two-stage result: post-release acceptance proof now, then a scheduled 7–14-day normalized-rate check (or full-period confirmation) if the ticket is intended to establish the low-thousands claim.
- **Send a deliberately generated production event.** Fast and deterministic, but creates production telemetry and needs explicit approval plus a privacy-safe marker and cleanup/triage policy. Prefer passive production evidence unless that approval is granted.
- **Rely on client logs or the SDK event ID.** Fast but invalid for this incident, because server-side quota rejection occurs after acceptance at the edge. Reject this as closure evidence.
- **Add server-side per-key limits.** Not available on Team. The client-side budgets in #401 are the applicable fence; any future plan upgrade should be a separate operator decision.

## Readiness Verdict

**Needs revision, then ready for a verification executor.** Replace the original three remaining items with a release-gated `stats_v2` runbook and explicit success criteria. No new implementation work is justified by this ticket based on the supplied audit and current `main` code. Do not close merely because the org reset or #401 merged: closure requires post-release server-side accepted outcomes.

## Questions for the Plan Author

1. Which released c11 version/build first contains #401, and what evidence will establish that it is running in a real production client?
2. Is C11-190 meant to close after immediate post-release acceptance proof, or only after a 7–14-day (or full billing-period) rate observation supports the low-thousands/month claim?
3. What exact observation window and timezone should the executor use, and should the query group by release as well as project and outcome to exclude pre-fix clients?
4. What numeric closure threshold defines “low thousands” after normalizing the window, and is zero `rate_limited` required while the organization remains below quota?
5. Should intentional `client_discard` counts be reported as a health signal for the client budget rather than treated as monitoring failure? What level would trigger follow-up?
6. Who owns the post-release query and where should the raw `stats_v2` response plus a concise interpretation be recorded?
7. Is a separate quota-pressure alert/check desired to prevent a recurrence, or is this ticket deliberately limited to recovery verification?
8. Should the stale historical Developer-plan/reset language in `platform/sentry.md` be corrected in a dedicated documentation follow-up, so future responders do not mistake it for live operational state?
