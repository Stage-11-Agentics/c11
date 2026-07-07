# Code Review: C11-161 — Public-surface truth (Wave 1)

## 0. Review-harness anomaly (read first)

**The diff embedded in the review prompt is the wrong diff.** It is commit `5d7689da8` ("C11-159: extract window.* socket handlers + dispatcher seam") — `GhosttyTabs.xcodeproj`, `Sources/SocketHandlers/WindowHandlers.swift`, `TerminalController.swift` visibility widening. None of that exists on this branch (`Sources/SocketHandlers/` is absent from the `ts/web-public-surface` worktree), and none of C11-161's actual changes appear in the prompt's diff.

I therefore reviewed the **actual branch diff**: `git diff main...HEAD` on `ts/web-public-surface` — five commits (`caa99eae8` WEB-4, `89d56b792` WEB-2, `6e18c01e8` WEB-1, `fcf5fb6d1` WEB-3, `543e6f900` WEB-5), 84 files, +793/−1180. This is a review of the real C11-161 implementation against the real C11-161 plan. Whoever assembled `review-23sg3xiy` should fix the diff-capture step — it appears to have grabbed a different ticket's commit. If a C11-159 review was also expected, that diff has not been reviewed here and needs its own pass.

## 1. Verdict

**FAIL (implementation-level)** — the plan is sound and almost everything is executed well, but one user-visible runtime bug (dangling i18n keys on the docs API page, all 19 locales) must be fixed before this passes. It is a two-line fix; the task should return to `in_progress` briefly, not to planning.

## 2. Summary

Reviewed the five WEB commits on `ts/web-public-surface` against the amended plan (A1–A6) and EVALUATION WEB-1..5. Overall quality is high: I independently re-ran every verification gate the plan defines and four of five pass exactly as claimed (grep tail of 6 justified survivors, doc method index identical to the 231 source dispatch cases, ROADMAP resolves, shared discovery helper with 37 delegating shims, `tsc --noEmit` clean, nightly DMG asset confirmed to exist on the live release). The key finding: the WEB-1 message-key rename `cmuxOnlyMode`/`cmuxOnlyEnable` → `c11OnlyMode`/`c11OnlyEnable` was applied to all 19 locale files but **not** to the component that consumes them, so the docs API access-modes table renders raw key paths at runtime — and typecheck cannot catch it (verified: `tsc --noEmit` passes with the bug present).

## 3. Issues

**[MAJOR] web/app/[locale]/docs/api/page.tsx:106-107 — Dangling i18n keys after locale-file rename**
The access-modes table calls `t("cmuxOnlyMode")` and `t("cmuxOnlyEnable")`, but the WEB-1 commit renamed those keys to `c11OnlyMode`/`c11OnlyEnable` in every one of the 19 `web/messages/*.json` files (verified: 0 old-key occurrences, 2 new-key occurrences per locale). At runtime next-intl fails the lookup and renders the raw key path in the table for every locale — a user-visible break on exactly the page this ticket was cleaning up. `tsc --noEmit` passes with the bug present (message keys are untyped), so the commit's "tsc clean" claim is true but does not cover this. These are the only two dangling references in `web/app` (verified by grep for `t("cmux…")` and the removed `kataring` key).
**Fix:** Change lines 106–107 to `t("c11OnlyMode")` / `t("c11OnlyEnable")`. Then render the page once (or run the web build and load `/docs/api`) to confirm the table shows prose, not key paths — this class of bug is invisible to typecheck, so the validation evidence should include a rendered-page check.

**[MINOR] web/public/avatars/kataring.jpg — Orphaned asset from the dropped testimonial**
The kataring testimonial was removed from `testimonials.tsx` and all 19 message files (correct per amendment A3), but its avatar image remains in `web/public/avatars/`. Harmless dead weight, and arguably the same "pointer to another product" residue class the ticket sweeps.
**Fix:** `git rm web/public/avatars/kataring.jpg` in the rework commit.

**[MINOR] web/app/[locale]/posthog.tsx:12 — `api_host` silently undefined when only the key is set**
With `NEXT_PUBLIC_POSTHOG_KEY` set but `NEXT_PUBLIC_POSTHOG_HOST` unset, `api_host: undefined` makes posthog-js fall back to its own default ingestion host. Functional, but an operator setting the key at deploy could unknowingly ship events to the default US host rather than a reverse proxy.
**Fix:** Either default explicitly (`api_host: posthogHost ?? "https://us.i.posthog.com"`) or add one comment line in `web/.env.example` stating the fallback. Not blocking.

**[MINOR] Validation evidence not yet attached — plan's recorded-proof bar**
The plan's validation bar is recorded grep proofs plus a tagged-build WEB-5 discovery log (`--role validation`), and the ticket's bar is "tagged build + recorded scenario proof." The commit messages carry the grep counts (240 → 6), but I found no attached discovery-log artifact in the branch. I verified the helper resolves the design correctly by inspection, but the plan's own evidence obligation (run against `C11_SOCKET=/tmp/c11-debug-web-post.sock` with only a `c11` binary discoverable) still needs to be produced during the rework pass.
**Fix:** Attach the WEB-5 discovery log and the before/after grep transcript as validation evidence when returning the fixed branch.

**Accepted deviation (no action, record it):** the 5 surviving `CMUX_NOTIFICATION_*` hits in `docs/notifications/page.tsx` deviate from amendment A4's in-scope listing, but the commit message justifies them with source evidence — `TerminalNotificationStore.swift:503-505` emits only the `CMUX_` variants, so renaming the docs would make them lie. I verified that source claim and endorse the call; it is exactly the truth-over-mechanical-sweep judgment this cycle is about. It should be enumerated in the final validation evidence alongside the show-hn lineage credit so the grep tail (6 hits) is fully accounted for. The durable fix (emit `C11_NOTIFICATION_*` alongside, then update docs) belongs to the naming-residue ticket.

## 4. Positive Observations

- **Every plan verification gate I re-ran independently passed.** WEB-1: the authoritative A1 grep returns exactly 6 hits, each mapped to a justified survivor. WEB-3: I diffed the doc's method set against `grep 'case "…"' | sort -u` from `TerminalController.swift` — **identical, all 231 methods**, and the doc's only 2 "cmux" occurrences are the deliberate compat-alias notes the plan pre-authorized. WEB-4: `ROADMAP.md` exists and `PHILOSOPHY.md:3` resolves. WEB-5: 37 files (matching A4's measured count) each carry a 3-line shim delegating to the single `tests_v2/cmux.py:find_cli_binary()`.
- **The WEB-5 helper is better than the plan asked for**: env override (`C11_CLI` then legacy `CMUXTERM_CLI`), a fast-path via the `reload.sh` marker files that skips the slow recursive DerivedData glob, c11-first candidates with legacy `cmux` fallback, newest-by-mtime, and a clear `cmuxError` with remediation. Function names at call sites kept stable — churn minimized exactly as planned.
- **Truth-checking went beyond grep.** The nightly DMG link was repointed to `Stage-11-Agentics/c11/releases/download/nightly/c11-nightly-macos.dmg` — I confirmed that exact stable asset exists on the live nightly release, so the link is real, not aspirational. Likewise CONTRIBUTING's "after a `--recursive` clone, origin is the Stage 11 fork" claim checks out against `.gitmodules`.
- **The kataring testimonial drop (A3) is the right integrity call** — deleting a real person's endorsement of a different product rather than doctoring the quote — and it was executed consistently across the component and all 19 locales.
- **The PostHog change fixes two problems at once**: removes manaflow's hardcoded key and converts telemetry from on-by-default to no-op-unless-configured, addressing the audit's opt-out concern.
- **Commit hygiene is exemplary.** Five reviewable commits in the planned order; the WEB-1 message enumerates every pointer class touched, records before/after grep counts, justifies each survivor with a source citation, and carries the A6 deploy-contract flag (env renames, operator confirmations for domain/inbox/social handles). A reviewer can audit the whole sweep from the log alone.
- Scope discipline held: entity/domain/key tokens swept across all locales mechanically; product-name prose left for the separate translation-scale pass, exactly on the A2 line.
