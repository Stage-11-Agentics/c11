# Action-Ready Synthesis: c11-190-plan

## Verdict

**rework-then-rereview**

No reviewer of the nine called the plan ready. The spread is narrow but real:

- Standard/Claude: "Needs revision." Standard/Codex: "Needs revision, then ready for a verification executor" (the most permissive of the nine). Standard/Gemini: "Needs rethinking."
- Adversarial/Claude: "concern level high... first action on this ticket is to rewrite the plan file, not to execute it." Adversarial/Codex: "do not execute this plan as written." Adversarial/Gemini: plan is "fundamentally disconnected from current reality."
- Evolutionary/Claude: "as a work contract, this plan is mostly spent." Evolutionary/Codex: "not current enough to execute as written. Amend it before work proceeds." Evolutionary/Gemini: reframes rather than validates.

Per the cautious-verdict rule, the more severe reading wins. The reason this lands at rework rather than revise is not the number of findings but their location: all three of the plan's numbered remaining items are obsolete, answered, or unrunnable, and the title encodes a date that no longer exists. What replaces them is a materially different contract (a release gate, a query specification, numeric thresholds, and a detector disposition), and several of those replacements depend on operator-level scope calls listed under "Surface to user." Re-review the rewritten plan rather than treating this as an in-place patch.

**Independently verified by this synthesizer** (so the downstream agent does not have to re-derive):

- `git merge-base --is-ancestor 42ce4c919 origin/release/v0.63.0` → **false**. `git grep -l SentryEventBudget origin/release/v0.63.0` → **no results**; on `origin/main` it hits `Sources/AppDelegate.swift`, `Sources/MainThreadHangMonitor.swift`, `Sources/SentryHelper.swift`. Latest tag is `v0.61.0`. The fix has no shipping vehicle.
- `Sources/AppDelegate.swift:2624-2626` — `beforeSend` classifies only `event.level == .fatal ? .crash : .other`. `SentryEventBudget.allow` (`Sources/SentryHelper.swift:153-177`) records into `globalHourly`/`globalDaily` for both `.hang` and `.other`. Hang double-charge and SDK-app-hang-bypass claims are correct as written.
- `platform/sentry.md` line 15 says Team/50,000/$49 while lines 192-193 and 241 still describe the Developer plan, `onDemandMaxSpend: 0`, and the "2026-07-25 → 2026-08-24" block as current. Self-contradiction confirmed.
- `platform/sentry.md:158` points at `scripts/telemetry/verify_sentry_arrival.py`. That file does not exist in acetate; the real files are `verify_real_arrival.py` and `verify_staged_arrival.py`. Broken pointer confirmed.
- `platform/sentry.md:90` credits project id `4511028453900288` to `c11`; line 97 gives c11's real id as `4511304571158528` and line 104 gives `4511028453900288` as `demo-project`. Confirmed wrong.
- `.github/workflows/release.yml:305` and `nightly.yml:465` set `SENTRY_PROJECT: stage11-c11`, while the project table says the slug is `c11`. Discrepancy confirmed (see S6).

---

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: The title and item 1 gate on 2026-08-24, a date that no longer exists**
  - Where in the plan: title line ("verify it resumes after the 2026-08-24 quota reset"); paragraph "WHAT REMAINS (this ticket)"; item 1 ("After 2026-08-24, confirm...").
  - Problem: the org upgraded to Team (`am3_team`) and the billing period reset on 2026-08-04 → 2026-09-03 with `usage: 0`, `usageExceeded: false`. The org is not blocked and there is nothing to wait for. The title is the highest-traffic surface of this ticket; a board reader sees only it and defers the ticket for weeks.
  - Revision: retitle to remove the date and reflect the real remaining work (e.g. "Sentry: verify c11 events are stored again and bounded once #401 ships"). Delete every reference to 2026-08-24, the Developer plan, the 5,000-error cap, and the "org stays blocked until then / c11 is still blind right now" claim. Replace with a one-paragraph current-state snapshot: Team plan, 50,000 errors/month org-wide, `onDemandMaxSpend` $20 shared, $49 hard ceiling, period reset 2026-08-04.
  - Sources: all nine. Standard/Claude (W1), Standard/Codex, Standard/Gemini, Adversarial/Claude (A1, blind spot 7), Adversarial/Codex, Adversarial/Gemini, Evolutionary/Claude (currency audit), Evolutionary/Codex, Evolutionary/Gemini.

- **B2: Item 2 rests on a premise the audit disproved, and states a wrong steady-state number**
  - Where in the plan: item 2, "Decide the budget question... the only fences are a paid plan or an on-demand budget. Billing = operator decision," and "c11 alone used ~1,466 accepted errors in 30d."
  - Problem: two defects. (a) The paid plan was purchased and delivered no fence: per-key rate limits are Business-gated, re-verified post-upgrade (`rateLimit: null` with the user token, 403 with the org token; spike protection 403). Anyone acting on the sentence as written buys the wrong thing and believes they are protected. (b) `1,466` was a *throttled* figure. The audit puts the attempted rate at ~1,343/day (~40k/month). The plan commits, inside itself, the exact accepted-vs-attempted confusion it exists to warn about.
  - Revision: mark item 2 closed with a decision record: Team plan purchased; per-key rate limits unavailable on Team and permanently unavailable at this price point; client-side budgets are the only fence. Correct the volume statement to distinguish attempted (~40k/month, ~1,343/day) from accepted (throttled, 1,466/30d), and adopt a convention that every event count in this ticket names its outcome.
  - Sources: Standard/Claude (drift table row 2, W-summary), Standard/Codex, Standard/Gemini, Adversarial/Claude (A3, A4), Adversarial/Codex (assumption table), Evolutionary/Claude (currency audit), Evolutionary/Codex, Evolutionary/Gemini.

- **B3: Item 3 is presented as an open investigation; it is answered, and the answer is larger than the question**
  - Where in the plan: item 3, "Consider whether any shipped c11 build still points at the retired DSN."
  - Problem: the audit answered it. `CLI/c11.swift` on `main` hard-coded demo-project's DSN and fired an event per shell prompt, per agent tool call, per hook, with `sendDefaultPii = true`. That was the 1,121,397 rejected events. The problem was in the repo, not only in the field. Leaving the item open sends a fresh agent to re-investigate.
  - Revision: mark item 3 closed with the finding (main-branch CLI DSN was the dominant source; #401 removed the compiled-in DSN, made it opt-in via `C11_CLI_SENTRY_DSN`, and turned off `sendDefaultPii`). Replace the residual open question with the narrower one that actually remains: which released artifact is the first with no compiled-in CLI DSN, and explicitly close the app-side half (app builds older than the 2026-04-29 project migration now report nowhere at all, which is accepted).
  - Sources: Standard/Claude (drift table row 3, W-list item 2), Standard/Codex, Standard/Gemini, Adversarial/Claude (A5), Adversarial/Codex, Evolutionary/Claude, Evolutionary/Codex (concrete suggestion 3).

- **B4: No release gate — the verification has no shipping vehicle and is currently unrunnable**
  - Where in the plan: item 1's premise, and the audit's "after PR #401 ships in a release."
  - Problem: verified above — `42ce4c919` is on `origin/main` only. `origin/release/v0.63.0` (already version-bumped) does not contain it, and `SentryEventBudget` does not appear on that branch. Latest tag is `v0.61.0`. No user has a build containing the budget, the hang throttle, or the CLI DSN removal, and nothing in the plan says who moves it there or when. Item 1 cannot be executed today or on any stated date.
  - Revision: add an explicit release-gate acceptance criterion before the verification criterion: either cherry-pick `42ce4c919` onto `origin/release/v0.63.0`, or record an explicit deferral to v0.64.0 with a date and an owner. Name the version/build that will carry the fix and require evidence that it has emitted at least one real production event (not a dev build, not an XCTest host, not an older release) before the verification runs.
  - Sources: Standard/Claude (executive summary, W2), Standard/Codex ("no release boundary"), Standard/Gemini ("missing deployment dependency"), Adversarial/Claude (A6), Adversarial/Codex (assumption table, blind spot 2), Adversarial/Gemini (adoption curves), Evolutionary/Claude (step 2), Evolutionary/Codex ("the plan also needs a release gate").

- **B5: The verification has no numeric pass condition and no query contract**
  - Where in the plan: item 1, "confirm c11 events are actually being STORED again — check outcome=accepted"; and the audit's "lands in the low thousands rather than ~40k."
  - Problem: "low thousands" is a vibe, not an acceptance criterion. There is no observation window, no project/release/environment filter, no `stats_v2` query shape, no threshold for `rate_limited`, no interpretation rule for `client_discard`, and no named evidence artifact. A verifier's judgment becomes the acceptance criterion, which is how tickets close on optimism. It also has no failure branch: nothing says who investigates or whether the ticket blocks versus the release rolls back.
  - Revision: specify the verification as an executable protocol. Name the `stats_v2` query (org, `project=c11`, `groupBy` outcome **and** release, daily interval, declared window and timezone). State numeric pass conditions, at minimum: `accepted > 0` attributable to the fixed release within a stated window of it reaching production; `rate_limited == 0` over the window while the org is under quota; and a stated 30-day projected accepted ceiling (Evolutionary/Claude proposes under 10,000; pick a number rather than inheriting one). Require the raw (credential-safe) response plus a one-paragraph interpretation to be recorded as the evidence artifact. Add a failure branch naming who investigates and what distinguishes "release did not adopt" from "quota problem returned" from "SDK/config regression."
  - Sources: Standard/Claude (W4, AC ladder), Standard/Codex ("no reproducible query contract", "no closure threshold"), Adversarial/Claude (hard question 3), Adversarial/Codex (blind spots 1 and 3, hard questions 2 and 3), Evolutionary/Claude (concrete suggestion 2), Evolutionary/Codex ("'Confirm accepted' is underspecified"), Evolutionary/Gemini (question 3).

### Important (revise before implementation starts)

- **I1: The measurement will be contaminated by un-upgraded installs unless it is release-filtered**
  - Where in the plan: item 1's implied fleet-total reading.
  - Problem: the audit's own data says 1,725 of 1,784 production events over 14 days came from `com.stage11.c11@0.58.0+116` alone, while tags already reach v0.61.0. A post-#401 aggregate will be dominated by installs without the fix for weeks. A fleet-total number read soon after ship reads as failure when the fix is correct; read later, it can read as success for reasons unrelated to the fix (Adversarial/Claude's stress-test scenario 1: a passing verification for the wrong reason, which is worse than failing because it retires the ticket).
  - Revision: state explicitly that the primary measurement is **version-filtered** — per-install-day accepted volume on the fixed release — and that the fleet-total is a secondary, later observation. Group the `stats_v2` query by release. If a fleet-total claim is required to close, say so and attach its own (longer) window.
  - Sources: Standard/Claude (W3), Standard/Gemini ("legacy footprint"/"mix of old and new clients"), Adversarial/Claude (A7, stress test 1), Adversarial/Codex (blind spot 3), Adversarial/Gemini (blind spot: legacy footprint).

- **I2: No disposition for a recurrence detector, on a ticket whose defining fact is that nothing alerted**
  - Where in the plan: the "CONSEQUENCE FOR c11" paragraph names the failure mode ("quota exhaustion is silent to the sender... nothing surfaced it"); no item responds to it.
  - Problem: all three remaining items are backward-looking. The plan's response to "nothing alerted for a week" is one human looking once. Seven of nine reviewers independently flagged this as the single highest-value missing item. A grep confirms no `stats_v2`/`usageExceeded` check exists in any script, workflow, or source file; it exists only in prose.
  - Revision: add an explicit acceptance criterion that records a **disposition** for the detector — either it is in scope for C11-190 (name the mechanism: Sentry org-level quota/spend notifications, a scheduled `stats_v2` read failing on `rate_limited > 0` or `usageExceeded: true`, or both; name the recipient and the escalation action), or it is split into a named sibling ticket created **before C11-190 closes**. Do not leave it unstated. The in-scope-versus-split call itself is S1 below; the plan must not close without one of the two being written down.
  - Sources: Standard/Claude (W5, alternative A), Standard/Codex ("no ownership/cadence"), Adversarial/Claude (blind spot 1, hard question 5, "if exactly one thing gets done on this ticket, it should be the monitor"), Adversarial/Codex (blind spot 4, hindsight preview), Adversarial/Gemini (implied via server-side gap), Evolutionary/Claude (how-it-could-be-better 2, "the highest-value item in the whole ticket and it is not in the ticket"), Evolutionary/Codex (sequencing step 6), Evolutionary/Gemini (concrete suggestion 1).

- **I3: The c11 IP/geo privacy exposure has no disposition and will evaporate when this ticket closes**
  - Where in the plan: absent. `platform/sentry.md` records it as "worth a decision"; the org has `scrubIPAddresses: false` and `dataScrubber: false`, and only `acetate` was fixed.
  - Problem: it was discovered by this investigation, it is live on a shipped public product, it is on the same org and the same subsystem, and it currently exists as one paragraph with no ticket behind it. Evolutionary/Claude verified via live read-only GET that the `c11` project has `scrubIPAddresses: false` and `relayPiiConfig: null` while `acetate` has both set. Adversarial/Claude adds the aggravating context that `TelemetrySettings.defaultSendAnonymousTelemetry = true`, i.e. opt-out-by-default telemetry from a public product into an org storing client IP and derived city.
  - Revision: add an explicit in-or-out line to the plan. If in scope, note that the fix is a project-settings PUT needing no release, that the leaf-selector trap applies (`$user.geo` as a parent selector is accepted and silently does nothing), and that it must be verified by reading back a **stored event**, not by reading back the setting. If out of scope, name the sibling ticket and require it to exist before C11-190 closes. The fold-versus-split call is S2 below.
  - Sources: Standard/Claude (W7), Standard/Gemini (question 3), Adversarial/Claude (blind spot 2), Adversarial/Codex (blind spot 6, hard question 9), Evolutionary/Claude (how-it-could-be-better 3, step 0), Evolutionary/Codex (concrete suggestions).

- **I4: Known deviations in the landed #401 code are not recorded, so the verification measures an unknown quantity**
  - Where in the plan: absent; the audit asserts "1,848 events → under ~150" as an expected effect.
  - Problem: three verified deviations move those numbers in ways the prediction does not account for. (a) Hang events consume **two** global slots: `MainThreadHangMonitor.swift:307` calls `allow(.hang)`, which records into `globalHourly`/`globalDaily`; the resulting capture then passes `AppDelegate.swift:2624` `beforeSend`, which classifies by level only and calls `allow(.other)`, recording again. Worse, `reportedCurrentEpisode = true` is set at line 308 before `beforeSend` can drop the event, so an episode can be marked reported and never reported. (b) Sentry's native app-hang tracker is still live (`appHangTimeoutInterval = 8.0`, `enableAppHangTracking` never disabled); its events reach `beforeSend` non-fatal, are classified `.other`, and bypass the 3/hour, 15/day hang sub-cap entirely — so the fence table in `platform/sentry.md` and #401's commit message describe a budget the code does not implement. (c) The budget is process-local and in-memory, so it resets on every launch.
  - Revision: add a short "known deviations in the fence, measured not assumed" note to the plan recording (a), (b), (c), and restate the "under ~150" figure as a hypothesis under test rather than a result. File the code fixes as a follow-up ticket and link it, so the verification measures known behavior. Do not fold the code changes into C11-190 (see S3 for the disagreement on that point).
  - Sources: Standard/Claude (findings 1-3, question 9), Adversarial/Claude (D2, D3, D4), Evolutionary/Claude (how-it-could-be-better 4, question 8), Adversarial/Gemini and Evolutionary/Gemini raise the fatal-exemption half.

- **I5: No owner, no date, no named evidence artifact**
  - Where in the plan: "WHAT REMAINS (this ticket)" and all three numbered items.
  - Problem: the remaining items are unassigned, undated, and do not say what "done" looks like as a file or paste. On a ticket whose entire subject is that nobody noticed for a week, an unowned follow-up is a thematically exact failure.
  - Revision: assign an owner and a date to each remaining acceptance criterion, and name the artifact each one produces (e.g. the `stats_v2` response and interpretation appended as a Lattice comment on C11-190).
  - Sources: Standard/Claude (W10), Standard/Codex (weaknesses, question 6), Adversarial/Codex (blind spot 4, hard question 5).

### Straightforward mediums

- **M1: `client_discard` will undercount actual suppression, and the plan does not say so**
  - Where in the plan: item 1's `outcome=accepted` check.
  - Problem: post-#401 there are two distinct drop paths with different observability. `beforeSend` returning nil surfaces as `client_discard` in `stats_v2`. `MainThreadHangMonitor.shouldReportHangToSentry` returning false means the event never reaches the SDK at all, so it is invisible to Sentry entirely — the only record is a `sentrySuppressed=n/m` string in a local log on the user's machine. A careful reader seeing low `client_discard` will wrongly conclude the budget is barely firing.
  - Revision: add one sentence to the verification spec stating that `client_discard` is (a) an expected and *positive* signal that the budget is engaging, not evidence of monitoring loss, and (b) a lower bound on suppression, because monitor-side drops never reach Sentry.
  - Sources: Adversarial/Claude (blind spot 4), Standard/Codex (weakness on `client_discard`, question 5), Evolutionary/Claude (verifier assertion 3), Evolutionary/Codex ("distinguish accepted from `client_discard`, which is expected"), Evolutionary/Gemini (flywheel).

- **M2: The fleet-level arithmetic of the per-process budget is nowhere written down**
  - Where in the plan: absent; the plan describes the fence only implicitly through item 2.
  - Problem: `SentryEventBudget` defaults are 20/hour and 50/day **per process**. The org allowance is 50,000/month ≈ 1,666/day, shared with acetate. 50,000 / 30 / 50 ≈ 33, so roughly 34 simultaneously-noisy installs let c11's own fence permit consumption of the org's entire daily allowance. `platform/sentry.md` twice tells *other* projects to size against the whole 50,000; c11's own budget was sized the way that advice warns against, and nobody wrote the division down.
  - Revision: state the arithmetic explicitly in the plan and record c11's declared share of the 50,000 as a number. This item is about writing the division down, not about changing the numbers — the accept-versus-resize call is S4.
  - Sources: Adversarial/Claude (D1, hard question 6), Adversarial/Codex (executive summary, blind spot 5, hard question 6), Standard/Claude ("bet I would question 1"), Evolutionary/Claude ("what is c11's declared share", question 5).

- **M3: `platform/sentry.md` now contradicts itself, and this incident is why**
  - Where in the plan: not in the plan; it is the doc this ticket's work updated.
  - Problem: verified. Line 15 and line 108 describe Team, 50,000, $20 on-demand, $49 ceiling. Lines 192-193 still say the period runs "2026-07-25 → 2026-08-24" with `onDemandMaxSpend: 0` and `canTrial: false` and that "everything the org sends is dropped until the reset"; line 241 still reasons from `allowOnDemand: false` on Developer. A reader landing mid-document — which is how reference docs are read — gets the wrong plan, wrong ceiling, and a nonexistent blocked state. Two adjacent verified doc bugs: line 90 credits project id `4511028453900288` to `c11` (that is `demo-project`; c11 is `4511304571158528`), and line 158 points at `scripts/telemetry/verify_sentry_arrival.py`, which does not exist in acetate — the real files are `verify_real_arrival.py` and `verify_staged_arrival.py`.
  - Revision: add an acceptance criterion to reconcile the quota-incident section of `platform/sentry.md` — either label it explicitly as historical narrative or update it to Team-plan reality — and fix the two pointer bugs in the same pass. Five-minute edit; this ticket is the reason the doc drifted.
  - Sources: Standard/Claude (W6), Standard/Codex (closing note, question 8), Adversarial/Codex (challenged decisions, hard question 10), Evolutionary/Claude (currency audit closing note, concrete suggestion 9).

- **M4: `demo-project`'s key has no final disposition and nothing watches it**
  - Where in the plan: "WHAT I DID, 2026-08-04" — "The project is intact, not deleted; one PUT reverses it."
  - Problem: good incident-time action, poor steady state. The plan advertises the one-PUT reversal without a corresponding "and here is why you must not." Every CLI already installed in the field still contains the compiled-in demo-project DSN and still fires on socket-connect failure; that population is harmless *conditionally, indefinitely*, on a mutable web-console setting with no guard and no alert.
  - Revision: add an acceptance criterion that records a final disposition for key `ce836c6e3462a139dcd469f5e4d3ceec` — and, whichever way it goes, add an explicit "deactivated permanently, do not re-enable" line to the Retired table in `platform/sentry.md`. Recording the decision is the deliverable here; delete-versus-deactivate is S5.
  - Sources: Standard/Claude (W8, question 7), Adversarial/Claude (A9, blind spot 5, D6, hard question 10).

### Evolutionary clear wins

*(None.)* Every evolutionary finding either expands the ticket's scope (a checked-in verifier, a platform-level tenancy contract, drop-counter tagging) or changes its direction. The two that come closest — the checked-in verifier and the sequencing constraint against C11-191/192 — are carried below as E1 and E2 rather than applied, because both are bets the plan author should weigh rather than edits they plausibly already wanted.

---

## Surface to user (do not apply silently)

- **S1: Should the recurrence detector live in C11-190 or a sibling ticket?**
  - Why deferred: disagreement + scope call.
  - Summary: seven of nine reviewers say the detector is the highest-value missing work, and Adversarial/Claude goes further: "if exactly one thing gets done on this ticket, it should be the monitor, not the verification." But Standard/Codex explicitly dissents on placement — "alerting on future quota pressure is valuable, but is a separate scope decision rather than an implicit addition to this recovery ticket." Both readings are defensible; what is not defensible is leaving it unwritten (that part is I2). The operator should choose: fold it in and let C11-190 stay open longer, or split it and accept the risk that a split ticket does not get written. Shapes proposed: Sentry org-level quota notifications at 50%/80% plus on-demand spend notifications to `projects@stage11.ai` (Evolutionary/Claude); a scheduled `stats_v2` read failing loudly on `rate_limited > 0` or `usageExceeded: true` (Adversarial/Claude, Adversarial/Codex); a Sentry volume-threshold alert on the c11 project (Evolutionary/Gemini). Note the anti-flywheel Evolutionary/Claude raises: `allowOnDemand: true` converts the old failure mode from "blocked at 50,000" into "spends $20 quietly, then blocks quietly" — a better ceiling but a *worse* signal until notifications exist.
  - Sources: Standard/Claude (W5, A), Standard/Codex (weaknesses, question 7 — the dissent), Adversarial/Claude (blind spot 1), Adversarial/Codex (blind spot 4), Evolutionary/Claude (2), Evolutionary/Codex (step 6), Evolutionary/Gemini (1).

- **S2: Fold the IP/geo privacy fix into C11-190, or split it, and is it org-level or project-level?**
  - Why deferred: design-needed + author-intent-needed.
  - Summary: six reviewers agree it must not stay a footnote (that part is I3), but split on where it goes. Evolutionary/Claude wants it as step 0, today, no release required, and raises a sharper sub-question: `platform/sentry.md` records `scrubIPAddresses: false` and `dataScrubber: false` at the **org** level, and org settings are on that doc's "Dangerous, confirm with human" list — setting them org-wide once is strictly better than fixing each project forever, but needs an explicit yes. Adversarial/Claude escalates the framing: opt-out-by-default telemetry (`TelemetrySettings.defaultSendAnonymousTelemetry = true`) from a public open-source desktop product into an org that stores IP and derived city, with "anonymous" in the settings key. Evolutionary/Claude also asks the broader question of whether c11 wants a stated collection policy at all (acetate generates a privacy page from its manifest and gates deploys on the page matching reality; c11 has no equivalent and, on current settings, could not truthfully write one).
  - Sources: Standard/Claude (W7, question 6), Standard/Gemini (question 3), Adversarial/Claude (blind spot 2, hard question 9), Adversarial/Codex (blind spot 6, hard question 9), Evolutionary/Claude (3, questions 2, 3, 10), Evolutionary/Codex.

- **S3: Fix the #401 code deviations now, or file them?**
  - Why deferred: disagreement.
  - Summary: the deviations themselves are verified and recorded as I4, but reviewers split on timing. Standard/Claude: "file separately so AC3 is not chasing a moving target." Adversarial/Claude: "if this ticket is the verification ticket for #401, this is squarely in scope." Evolutionary/Claude: "neither is urgent... fix now or file?" The specific decisions bundled here are: whether to unify the budget gate into a single `beforeSend` call site (which would fix the double-charge and make the hang sub-budget apply to SDK-originated hangs too); whether to set `enableAppHangTracking = false` so the custom watchdog is the single owner of hang reporting; and whether to persist the sliding window across launches into the cache directory `LaunchSentinel` already uses.
  - Sources: Standard/Claude (findings 1-3, questions 8-10), Adversarial/Claude (D2, D3, D4, hard questions 7-8), Evolutionary/Claude (4, question 8).

- **S4: Accept the fleet arithmetic, resize the budget, or add a second-order fence?**
  - Why deferred: design-needed + operator sizing call.
  - Summary: once M2 writes the division down (≈34 noisy installs consume the org's entire daily allowance), a decision follows. Adversarial/Claude deliberately declines to propose a number and asks only that the arithmetic be accepted with eyes open or sized for; he also states the strongest counterargument himself ("50/day/process is a worst case and typical installs send far less — probably true today, and exactly the assumption that fails the day something ships a bug that fires on every launch"). Adversarial/Codex wants a written cross-client allocation between c11, acetate, and future tenants, plus a rule for what is sacrificed first when usage rises. Standard/Claude raises the adjacent per-fingerprint alternative: #401 spends its 20/hour first-come-first-served, so a chatty warning class can crowd out a rarer, more interesting error; budgeting by fingerprint (what acetate does via `DedupeIntegration`) spends quota on *distinct* issues, which is what quota is for.
  - Sources: Adversarial/Claude (D1, hard question 6), Adversarial/Codex (blind spot 5, hard questions 6-7), Standard/Claude (alternative B), Evolutionary/Claude (question 5).

- **S5: Delete the `demo-project` key rather than deactivate it — and delete the project?**
  - Why deferred: operator call on an irreversible action.
  - Summary: Adversarial/Claude argues the reversibility that made deactivation correct on 2026-08-04 is now pure downside — a mutable setting, no guard, no alert, protecting against a population that only shrinks but never reaches zero. Standard/Claude offers the cheaper alternative: leave it deactivated but document "do not re-enable" in the Retired table, and add `isActive` to whatever monitoring gets built. Deletion is irreversible and destroys the issue history; that is the operator's call. (Recording *a* decision is M4; choosing which one is this.)
  - Sources: Standard/Claude (W8, question 7), Adversarial/Claude (D6, blind spot 5, hard question 10).

- **S6: The dSYM upload target project slug may be wrong**
  - Why deferred: single-reviewer, adjacent scope, needs an API check before any edit.
  - Summary: Standard/Claude noticed and this synthesizer verified that `.github/workflows/release.yml:305` and `nightly.yml:465` set `SENTRY_PROJECT: stage11-c11`, while `platform/sentry.md`'s Active Projects table gives the c11 slug as `c11`. If the workflow value is wrong, dSYMs are landing somewhere unexpected and crashes are arriving unsymbolicated — a quieter version of exactly the blindness this ticket exists to fix, and it would degrade the crash reports the verification is meant to protect. One API call settles which value is right. Not folded into the apply-list because it is outside the plan's stated scope and the correct fix depends on what the check returns.
  - Sources: Standard/Claude (W6 tail, question 12). Verified independently by this synthesizer.

- **S7: Server-side inbound data filters were never considered as an option**
  - Why deferred: single-reviewer, unverified availability on Team.
  - Summary: Adversarial/Gemini points out that the plan (and the audit) concluded "no server-side fence exists" on the basis of per-key rate limits and spike protection alone, and never asked about Sentry's **inbound data filters** — server-side rules that can drop events by release version, by message pattern, or by other criteria before they count against quota. If available on Team, that would let old un-upgraded releases be dropped at the edge during the adoption window, which is precisely the gap I1 describes and which no client-side fix can reach. Nobody verified whether these are available on Team; that check is cheap and would either open a real option or close it explicitly.
  - Sources: Adversarial/Gemini (blind spots, challenged decisions, hard question 1).

- **S8: Was "stop reporting the CLI errors" the right response to 1.12M CLI failures?**
  - Why deferred: single-reviewer, and it questions a decision the operator already made.
  - Summary: Adversarial/Gemini's sharpest point, and the one no other reviewer made: 1,121,397 socket-connect and hook-dispatch failures per month is not only a telemetry problem, it is a claim about the CLI's actual reliability. #401 removed the reporter; nobody asked why the CLI is failing to reach its socket that often. The counter-reading, implied by the rest of the pack, is that the CLI fires on every shell prompt and every hook, so a high absolute count may reflect frequency of invocation rather than a broken user experience. Worth one look before accepting the counter-reading, since the repo already documents a real socket-unreachable failure mode (`CLAUDE.md`, C11-105).
  - Sources: Adversarial/Gemini (how-plans-fail, challenged decisions, hard question 3).

- **S9: Should verification use a deliberate canary event, or only passive production traffic?**
  - Why deferred: disagreement + needs approval.
  - Summary: Adversarial/Claude argues item 1 as written cannot distinguish "healthy and quiet" from "broken and silent," and wants the acetate pattern: assert config by read-back, send a canary from the real signed build with a planted token, read it back through the issues API, then read the aggregate. Standard/Codex and Adversarial/Codex both prefer passive evidence by default — a deliberately generated production event creates production telemetry, needs explicit privacy approval, a distinguishing marker, and a cleanup/triage policy. Evolutionary/Codex proposes it as a designed "telemetry canary release." The disagreement is real and the approval question is the operator's.
  - Sources: Adversarial/Claude (blind spot 3, hard question 4), Standard/Codex (alternatives, architectural assessment), Adversarial/Codex (blind spot 7, hard question 4), Evolutionary/Codex (mutations).

- **S10: Does C11-190 stay open until a shipped build is measured, or close now and hand off?**
  - Why deferred: author-intent-needed.
  - Summary: Standard/Claude prefers closing C11-190 on the immediately-answerable org-position check and opening a new ticket for post-ship verification, rather than leaving this one open for weeks against an external dependency. Standard/Gemini offers the same fork as its "Alternative 1 (close and replace)" versus "Alternative 2 (rewrite in place)," and recommends rewriting in place to preserve context. Standard/Codex frames it as a two-stage question: close on immediate post-release acceptance proof, or only after a 7-14-day (or full billing-period) rate observation. These are three defensible answers to one question and the plan author should pick.
  - Sources: Standard/Claude (question 2), Standard/Gemini (alternatives 1 and 2), Standard/Codex (question 2).

- **S11: Regression guard against a compiled-in CLI DSN returning**
  - Why deferred: single-reviewer, and the repo's test policy constrains the options.
  - Summary: Standard/Claude notes there is no guard against the two things most likely to silently regress — a compiled-in DSN reappearing in the CLI, and `beforeSend` losing its budget wiring. He also correctly notes that this repo's test policy forbids source-text/grep tests, so the naive assertion is not allowed. The policy-compliant options are a behavioral test (CLI run with `C11_CLI_SENTRY_DSN` unset produces no Sentry transport) or an explicit accepted-risk note. His flag is specifically against silently having neither.
  - Sources: Standard/Claude (W9, question 15).

- **S12: What stops the fourth telemetry tenant?**
  - Why deferred: scope-creep beyond c11, platform-level decision.
  - Summary: acetate is the second client on a shared 50,000 with no server-side fence; there will be a third. Nothing in CI, in `new-project-checklist.md`, or in this plan requires a new Sentry client to declare and implement an outbound budget sized against the pool. Adversarial/Claude's framing: "the only control that survives contact with an agent in a hurry is a script that fails." Standard/Claude adds an adjacent unconsidered option worth an explicit sentence of rejection rather than silence: **one Sentry org per project**, which restores blast-radius isolation without a Business plan at the cost of a second $29/mo and split administration — his read is not worth it at two projects, worth revisiting at four, and the trigger should be written down now while the reasoning is fresh.
  - Sources: Adversarial/Claude (blind spot 6, A14, hard question 11), Adversarial/Codex (blind spot 5), Standard/Claude (alternative C, questions 13-14), Evolutionary/Claude (adversarial-tenant thought experiment).

- **S13: Nobody is watching the non-error categories**
  - Why deferred: single-reviewer, unquantified.
  - Summary: `tracesSampleRate = 0.1` is live and transactions/spans bill separately against the same $20 shared on-demand pool. The $49 ceiling caps the bill; nothing caps the surprise, and no reviewer or audit measured this category. One `stats_v2` call grouped by category would size it.
  - Sources: Adversarial/Claude (A10, hard question 12).

---

## Evolutionary worth considering (do not apply silently)

- **E1: Replace the one-time manual check with a checked-in verifier, and lift it to `platform/`**
  - Summary: item 1 as written is "a human looks at `stats_v2` once," an artifact that evaporates the moment it is performed. The same effort spent on `scripts/telemetry/verify-sentry-accepted.py`, modeled on acetate's `verify_real_arrival.py`, produces something that runs on every release forever and asserts four things: `accepted > 0`, `rate_limited == 0`, `client_discard > 0` (the *positive* proof that the fence is firing, which a human eyeballing a dashboard would never think to assert), and projected monthly volume under c11's declared share. The larger version writes `platform/telemetry-tenancy.md` plus a per-tenant `telemetry-budget.json` whose shares a shared script asserts sum below the pool.
  - Why worth a look: this is the third independent rediscovery of "verify against stored reality" across two repos, and the lesson has so far only ever transferred as prose — evidenced by `platform/sentry.md`'s pointer to the acetate verifier being broken (verified: the file it names does not exist). One shared script converts a documentation habit into a compounding one.
  - Sources: Evolutionary/Claude (1, concrete suggestions 4 and 11, "the flywheel"), Evolutionary/Codex (mutations, concrete suggestions), Evolutionary/Gemini (concrete suggestion 1).

- **E2: Sequencing trap — C11-191 and C11-192 will remove the load before the fence is ever tested**
  - Summary: C11-191 (tab bar preference pass, 2.3s) and C11-192 (SwiftUI Button generic metadata, 10s) exist to fix the two hangs that were 98% of c11's volume. If they land before anyone observes the budget biting in a real shipped build, the load disappears for reasons unrelated to the fence, the fence never fires in production, and its first real exercise will be during the next incident. The proposed constraint: verify the fence under real load first, or — if schedule pressure forces 191/192 ahead — make an induced-beachball smoke on a tagged build a **hard** exit gate rather than a nice-to-have, since it becomes the only remaining evidence path. Related and cheap: the `beforeSend` wiring is the untested part (`MainThreadHangDetectorTests.swift` covers only the pure core, and the closure only ever emits two of the three `Kind` cases).
  - Why worth a look: it is a scheduling constraint that costs nothing to honor now and cannot be recovered later, and it is a textbook instance of this repo's own "green tests are not a working product" rule.
  - Sources: Evolutionary/Claude (executive summary 3, step 4, 5, concrete suggestion 10, question 6).

- **E3: Tag surviving events with the budget's drop counters**
  - Summary: `SentryEventBudget` already tracks `droppedTotal` and `droppedHangs`, and that information currently dies in a local log file on the user's machine. Attaching both as tags on every event that *does* get through (about five lines in `beforeSend`) converts a lossy sample into a self-describing one: an install reporting `budget_dropped_total: 400` alongside a single warning is a visibly wedged machine, surfaced in the issue list at zero extra event cost. Evolutionary/Gemini proposes the same signal routed through PostHog instead, to avoid spending Sentry quota on it.
  - Why worth a look: it is the difference between a fence and an instrumented fence, and it is the only cheap answer to "how would we know if the budget is too aggressive and blinding us" — a question three reviewers asked and nothing currently answers.
  - Sources: Evolutionary/Claude (mutations, concrete suggestion 6), Evolutionary/Gemini (how-it-could-be-better 1, question 2).
