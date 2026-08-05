# C11-190: Sentry — verify c11 events are stored again and bounded once #401 ships

Reworked 2026-08-04 after trident plan review (pack: `notes/trident-review-C11-190-plan-pack-20260804-1559/`, verdict: rework-then-rereview). The original plan's three items were respectively obsolete, answered, and unrunnable; this version replaces them with an executable verification contract. Origin: found while finishing Acetate's ACE-801 (Sentry rollout on the same org). Full incident write-up: `platform/sentry.md` § "The quota incident (2026-08-04)".

## Current state (2026-08-04, supersedes all earlier quota narrative)

- Org `stage-11-kl` is on **Team** (`am3_team`): 50,000 errors/month org-wide, `onDemandMaxSpend` $20 shared, hard monthly ceiling $49, `allowOnDemand: true`. Billing period reset 2026-08-04 → 2026-09-03 with `usage: 0`, `usageExceeded: false`. **The org is not blocked and there is nothing to wait for.** Every reference to 2026-08-24, the Developer plan, or the 5,000-error cap in earlier versions of this ticket is obsolete.
- PR #401 (`42ce4c919`) landed on `main`: `SentryEventBudget` in `beforeSend` (20/hr, 50/day per process; hang sub-cap 3/hr, 15/day; fatal exempt), one hang report per episode ≥5s, CLI compiled-in DSN removed (opt-in via `C11_CLI_SENTRY_DSN`, `sendDefaultPii` off), Sentry no longer starts under XCTest hosts.

## Closed items (decision records — do not reopen)

1. **Budget/billing (old item 2): CLOSED.** Team plan purchased. Per-key rate limits are **Business-gated and remain unavailable** — re-verified post-upgrade (`rateLimit: null` with user token, 403 with org token; spike protection 403). The old premise "a paid plan provides a fence" is disproved; client-side budgets are the only fence at this price point. Volume convention for this ticket: every event count names its outcome. c11's **attempted** rate pre-fix was ~1,343/day (~40k/month); the oft-quoted 1,466/30d was the **accepted** (throttled) figure, not a steady state.
2. **Retired DSN in shipped builds (old item 3): CLOSED, and the answer was larger than the question.** `CLI/c11.swift` on `main` itself hard-coded demo-project's DSN and fired per shell prompt / agent tool call / hook with `sendDefaultPii = true` — that was the 1,121,397 rejected events. #401 removed it. App builds older than the 2026-04-29 project migration now report nowhere at all; this is accepted. Residual question folded into AC1: name the first released artifact with no compiled-in CLI DSN.

## Known deviations in the landed fence (measure, don't assume)

The audit's "1,848 → under ~150" projection is a **hypothesis under test**, not a result. Three verified deviations move the numbers:

- (a) Hang events consume **two** global budget slots (`MainThreadHangMonitor.swift:307` `allow(.hang)`, then `AppDelegate.swift:2624` `beforeSend` re-classifies as `.other` and charges again), and `reportedCurrentEpisode = true` is set before `beforeSend` can drop the event — an episode can be marked reported yet never reported.
- (b) Sentry's native app-hang tracker is still live (`appHangTimeoutInterval = 8.0`); its events classify as `.other` and **bypass the hang sub-cap**, so "at most 3 hang reports/hour" is not what the code does.
- (c) The budget is in-memory per process — resets on every relaunch, weakest in the crash-loop case.

These are candidate follow-up code fixes (fix-now vs file-separately is an open operator call, see needs-human). Until decided, verification interprets results against the code as it actually is.

## Fleet arithmetic (written down so nobody re-derives it wrong)

50,000/month ≈ 1,666/day org-wide, shared with acetate (and future tenants). c11's fence permits 50/day **per process**: ~34 simultaneously-noisy installs can consume the entire org daily allowance. c11's declared share of the org pool: **25,000/month (half)** pending the operator's sizing call (accept/resize/second-order fence — see needs-human).

## Acceptance criteria

**AC1 — Release gate (blocking; verification is unrunnable without it).**
`42ce4c919` is on `main` only: it is NOT on `origin/release/v0.63.0` (already version-bumped, dated 2026-07-31) and the latest tag is v0.61.0. Either cherry-pick #401 onto `release/v0.63.0`, or record an explicit deferral to v0.64.0 with a date. Deliverable: the named version/build that carries the fix, plus evidence it has emitted ≥1 real production event (not a dev build, not an XCTest host, not an older release). Owner: agent:c11-190 (routing the cherry-pick-vs-defer call to operator via needs-human). Evidence: Lattice comment on C11-190.

**AC2 — Verification protocol (the ticket's core).**
Run after AC1's build has ≥7 days of production exposure. Query: `stats_v2` for org `stage-11-kl`, `project=c11` (id 4511304571158528), `groupBy` outcome **and** release, daily interval, UTC, window = release-availability date → query date. Pass conditions:
  - `accepted > 0` attributable to the fixed release (primary measurement is **version-filtered**; fleet totals are dominated by 0.58.0+116 for weeks and are a secondary, later observation);
  - `rate_limited == 0` across the window while the org is under quota;
  - projected 30-day accepted volume for the fixed release **< 10,000** (versus ~40k/month attempted pre-fix);
  - `client_discard > 0` is an **expected, positive** signal (the fence firing), and a **lower bound** on suppression — monitor-side drops never reach the SDK and are invisible to Sentry.
Failure branch: `accepted == 0` → distinguish "release not adopted" (check release dimension present at all) from "SDK/config regression" (check a dev-build canary against a scratch DSN) from "quota returned" (`usageExceeded`, `rate_limited > 0`). Owner: agent:c11-190. Evidence: raw credential-safe `stats_v2` response + one-paragraph interpretation as a Lattice comment, `--role validation`.

**AC3 — Recurrence detector disposition (the incident's actual lesson).**
Nothing alerted during a week of blindness; no `stats_v2`/`usageExceeded` check exists anywhere in the repo. Before this ticket closes, one of the following must be true: (a) a detector is in scope here and implemented (org-level quota/spend notifications at 50%/80%, and/or a scheduled `stats_v2` read failing loudly on `rate_limited > 0` or `usageExceeded: true`), or (b) a named sibling ticket exists. In-scope-vs-split is an operator call (needs-human); **this AC is satisfied only by a written disposition, not by silence.**

**AC4 — Privacy disposition.**
The `c11` Sentry project has `scrubIPAddresses: false`, `relayPiiConfig: null` (verified live; `acetate` on the same org has both set) while `TelemetrySettings.defaultSendAnonymousTelemetry = true` on a shipped public product. In-or-out decision required before close: if in scope, it's a project-settings PUT needing no release (beware the leaf-selector trap: `$user.geo` as a parent selector silently no-ops) verified by reading back a **stored event**, not the setting; if out, name the sibling ticket. Fold-vs-split and org-vs-project level are operator calls (needs-human).

**AC5 — Reconcile `platform/sentry.md`.**
The doc now contradicts itself: line 15 says Team/50,000/$49 while lines ~192-193 and ~241 still present the Developer block ("2026-07-25 → 2026-08-24", `onDemandMaxSpend: 0`) as current. Label the quota-incident section as historical narrative or update it to Team reality. Same pass fixes two verified pointer bugs: line ~90 credits demo-project's id `4511028453900288` to c11 (c11 is `4511304571158528`), and line ~158 points at `verify_sentry_arrival.py`, which does not exist (real files: `verify_real_arrival.py`, `verify_staged_arrival.py`). Owner: agent:c11-190. Evidence: commit to platform repo referenced in a Lattice comment.

**AC6 — Final disposition for demo-project's key.**
Key `ce836c6e3462a139dcd469f5e4d3ceec` is deactivated but one PUT reverses it, with no guard and no alert, while every fielded CLI still contains its DSN. Record a final disposition — at minimum add an explicit "deactivated permanently, do not re-enable" line to the Retired table in `platform/sentry.md`; delete-vs-deactivate is the operator's irreversible-action call (needs-human).

## Open operator decisions

Routed via `lattice needs-human` (see ticket flag): release vehicle for #401 (AC1); detector in-scope-vs-split (AC3); privacy fold-vs-split and org-vs-project (AC4); #401 code deviations fix-now-vs-file (Known deviations); fleet-share sizing (arithmetic above); demo-project delete-vs-deactivate (AC6); plus lower-priority surfaced items S6–S13 in `synthesis-action.md` (dSYM `SENTRY_PROJECT` slug mismatch in release.yml/nightly.yml is the sharpest of them).

## Reset 2026-08-04 by agent:trident-pane-C11-190
