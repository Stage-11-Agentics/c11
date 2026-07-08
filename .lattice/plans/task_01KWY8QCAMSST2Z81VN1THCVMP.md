# C11-168 — web/ naming residue: cmuxterm_* event names + safe cmux branding → c11

## Scope (per follow-up prompt + operator decision)

Mechanical tokens/event-names pass. **NOT** the 19-locale prose translation effort
(`web/messages/*.json`, 1737 occurrences — explicitly out of scope).

Operator decisions (AskUserQuestion, 2026-07-08):
- **PostHog event names → rename to `c11_*`** (accepting funnel-history rebuild; historical `cmuxterm_*` events stay queryable in PostHog).
- **Prose scope → safe branding strings only.**

## In scope (done)

1. Event tokens (4): `cmuxterm_download_clicked` → `c11_download_clicked`,
   `cmuxterm_github_clicked` → `c11_github_clicked` (download-button, nav-links,
   github-stars, github-button).
2. Safe English product-name branding: siteName metadata (layout/docs/blog),
   homepage `<h1>` + logo/screenshot alt, site-header logo alt + wordmark,
   changelog image alt + changelog prose, legal-doc product name
   (privacy/EULA/terms), current-product blog titles/summaries.

## Deliberately excluded (kept as-is)

- `web/messages/**` locale JSON (the 19-locale effort).
- URL slugs / redirects / sitemap (`zen-of-cmux`, `introducing-cmux` redirect source) — breaks links/SEO.
- i18n message keys (`introducingCmux`, `zenOfCmux`, `automationCmux`, `detectingCmux`) — coupled across all 19 locales.
- Testimonial quotes — renaming falsifies verbatim user quotes.
- `CMUX_NOTIFICATION_*` env-var docs — must match what the app actually emits.
- Historical Show-HN claims ("Launching cmux on Show HN", "cmux hit #2 on Hacker News…") — historically true of cmux; renaming would be false.
- browser-automation code examples / internal component fn names — not product branding.

## Proof

15 files, 32/32 (net-neutral pure token renames). `cmuxterm_` count 4→0.
`bun tsc --noEmit` exit 0; `bun run build` ✓ Compiled successfully (exit 0). CI web
gate is tsc-only; `next build` isn't a web CI gate but was run locally and passes.
