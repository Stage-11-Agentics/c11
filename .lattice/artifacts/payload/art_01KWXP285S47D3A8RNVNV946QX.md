# Plan Review: C11-161 — Public-surface truth (Wave 1)

Reviewer: Claude (plan review pass). All factual claims in the plan were checked against the working tree, not taken on trust.

## 1. Verdict

**PASS** — the plan is complete in approach, technically sound, and tightly aligned with SPEC WEB-1..5. The issues below are localized amendments (verification-command fixes and two unclassified hit categories), not structural gaps; they belong in the plan's own "Plan-review amendments" section, and the first two should be resolved before the WEB-1 sweep starts.

## 2. Summary

Reviewed the C11-161 plan against the Truth & Stability contract (SPEC.md WEB-1..5, EVALUATION.md) and against the actual repo state. The plan's load-bearing claims verify: the dispatch switch really has 231 unique dotted `case` entries, `docs/socket-api-reference.md` really is 288 lines with 56 cmux mentions, `ROADMAP.md` is missing while `PHILOSOPHY.md` line 3 references it, and the CONTRIBUTING.md ghostty section really instructs `git push manaflow`. The key concern: the WEB-1 verification grep as written cannot return zero — it sweeps gitignored `web/.next/` build artifacts (~1,500 hits, 420 in one file), and two categories of tracked hits (cmux.dev testimonials in all 19 locales + testimonials.tsx, and manaflow Twitter/LinkedIn social links) have no assigned treatment in the plan.

## 3. Issues

**[MAJOR] WEB-1 Verification — The stated grep command sweeps gitignored build artifacts and cannot return zero**
The verification is `grep -rinE "manaflow|cmux\.(com|dev)|…" web/ | grep -v node_modules`. Measured against the current tree, that returns ~1,588 hits, the overwhelming majority inside `web/.next/` (gitignored build output; `web/.next/server/app/sitemap.xml.body` alone has 420). Even after a perfect source sweep, the command as written stays red — inviting either a false "fail" or an ad-hoc loosening of the bar mid-implementation. The EVALUATION bar ("repo-wide grep") plainly means tracked files.
**Recommendation:** Use `git grep -inE '<pattern>' -- web/` (tracked files only), or add `--exclude-dir={node_modules,.next,out}`. State the exact final command in the plan so the recorded before/after counts are reproducible. Optionally note that stale `.next/` output will regenerate clean on next build.

**[MAJOR] WEB-1 scope — Two hit categories in tracked files have no assigned treatment: cmux.dev testimonials and manaflow social links**
(a) Every one of the 19 `web/messages/*.json` files has a second hit beyond the `© Manaflow` copyright: a testimonial string "Switched to cmux.dev" (e.g. `en.json:580`), plus `web/app/[locale]/testimonials.tsx:120` ("cmux.dev に乗り換えた"). These are product-prose *and* domain hits at once — they fall in the crack between the plan's "entity/domain/key pointers in scope" and "no product-name prose changes." The grep will not come clean unless they're edited, removed, or explicitly counted as justified survivors — and "user testimonial about cmux displayed on the c11 site" is a stretch as a lineage credit; it's arguably the exact truth problem P0.6 targets.
(b) `web/app/[locale]/community/page.tsx:89,113` and `site-footer.tsx:41` link to `twitter.com/manaflowai` and `linkedin.com/company/manaflow-ai` — manaflow pointers matched by the grep, but social handles are an operator-held value the plan's "Values I don't hold" section doesn't enumerate (no Stage 11 Twitter/LinkedIn is derivable from the repo).
**Recommendation:** Add both categories to the plan explicitly. For testimonials: either drop them (they endorse a different product) or park them behind the counted-and-justified clause with reasoning — pick one now, not mid-sweep. For social links: drop the entries or point them at the GitHub org, and add "social handles" to the operator-confirmation flag list alongside domain/inbox/legal contact.

**[MINOR] WEB-1 verification — Grep pattern doesn't cover the in-scope `CMUX_*` env-var renames**
The plan puts "`CMUX_*` env-var names in `web/`" in scope (the `web/app/env.ts` renames) but the verification regex checks only manaflow/cmux-domain/key patterns, so a missed `CMUX_FEEDBACK_*` reference would pass verification silently.
**Recommendation:** Add `CMUX_` to the verification pattern (or a second grep) for `web/`.

**[MINOR] WEB-1 table — `web/app/layout.tsx` is the wrong file; the cmux.com metadata lives in `web/app/[locale]/layout.tsx`**
`web/app/layout.tsx` exists but the three `https://cmux.com` hits (canonical URL, `metadataBase`, og `url`) are at `web/app/[locale]/layout.tsx:34,64,97`. Also unlisted in the table: `web/app/[locale]/page.tsx:212`, `community/page.tsx:77`, `blog/show-hn-launch/page.tsx:136` (all `manaflow-ai/cmux` repo links). The catch-all "grep-sweep all `web/app`" covers these, so this is a table accuracy nit, not a coverage gap — but the Show HN launch post is historical lineage content, so decide whether its repo link is a justified survivor or gets repointed.
**Recommendation:** Correct the layout.tsx path; classify the blog-post link explicitly (lineage-credit survivor is defensible there).

**[MINOR] WEB-5 — File count is 37, not 45**
`grep -rl "def _find_cli_binary" tests_v2/` returns 37 files (the audit said 35, the plan says 45). No effect on the approach — the shared-helper design is right regardless — but the recorded before/after numbers in the validation evidence should use the measured count.
**Recommendation:** Use 37 (or re-measure at implementation time) in the plan and evidence.

**[MINOR] WEB-1 — Env-var renames are a deploy-config break; say so in the PR flag**
Renaming `CMUX_FEEDBACK_FROM_EMAIL`/`CMUX_FEEDBACK_RATE_LIMIT_ID` and gating PostHog on `NEXT_PUBLIC_POSTHOG_KEY` changes the deployment environment contract. Almost certainly moot (the audit's premise is that `web/` is inherited/undeployed), but if any deployment of this site exists, feedback email and analytics silently stop until env is updated.
**Recommendation:** One line in the PR-body flag list: "env contract changed — set `C11_FEEDBACK_*` / `NEXT_PUBLIC_POSTHOG_*` / `NEXT_PUBLIC_SITE_URL` at deploy."

## 4. Positive Observations

- **The plan's factual claims verify against the repo.** 231 unique dotted case entries in `Sources/TerminalController.swift` (exact match to the plan's proposed generation command), 288 lines / 56 cmux mentions in the socket doc, ROADMAP.md genuinely missing with a live PHILOSOPHY.md reference, 19 locale files, and CONTRIBUTING.md's `git push manaflow` residue at exactly the cited section. A plan whose numbers survive independent measurement is rare and worth naming.
- **The scope decision is the right call, made explicitly.** Separating pointer rebrand (this ticket) from product-name prose rebrand (19-locale translation effort, sequenced separately by the audit) is correct, and flagging it for the orchestrator rather than deciding silently is exactly the deviate-with-flag discipline the contract asks for.
- **Operator-held values are handled honestly.** Rather than inventing a marketing domain or inbox, the plan makes each env-driven with defensible non-manaflow defaults and flags all four for operator confirmation. The PostHog no-op-when-unset guard also fixes the audit's telemetry-default concern as a side effect.
- **Verification is quantified per criterion** — grep counts for WEB-1, count-match for WEB-3, a real tagged-build discovery run for WEB-5 — matching EVALUATION.md's autonomous-check design rather than hand-waving "will verify."
- **Sensible risk register**: legal-copy edits flagged as needs-legal-review rather than shipped as final; `cmux` glob fallbacks kept in WEB-5 so mixed environments don't regress while the only-`c11` requirement is still the tested bar; build lock scoped to the one phase that needs it.
