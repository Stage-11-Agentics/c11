# C11-214: web: lint fails on main with 5 no-html-link-for-pages errors

bun run lint in web/ exits 1 on origin/main (2026-09-11, v0.65.0): 5 errors from @next/next/no-html-link-for-pages (raw <a> to /docs/notifications/, /docs/keyboard-shortcuts/ etc.) plus 7 react-hooks/exhaustive-deps warnings. CI's web-typecheck job runs tsc only, so this never shows red. Confirmed identical before and after dependabot #426, so it is not a dependency regression. Fix: use next/link <Link> for the internal doc links; decide whether to add lint to the web CI job.
