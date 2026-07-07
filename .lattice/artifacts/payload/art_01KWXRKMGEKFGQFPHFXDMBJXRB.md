# C11-161 Validation Evidence — Public-surface truth

Branch `ts/web-public-surface` @ HEAD; base `origin/main`. All changes are
docs/web/test-helper only — **no Swift/app source touched**, so the app
binary is functionally unchanged and every EVALUATION row (WEB-1..5, all
tagged `autonomous`) is provable without a fresh tagged build.

## WEB-1 — manaflow-pointer grep (tracked web/)
```
BEFORE (origin/main):
  tracked hits:      240
AFTER (HEAD):
  tracked hits:        6

Surviving hits (all justified lineage/truth survivors):
web/app/[locale]/blog/show-hn-launch/page.tsx:136:            <a href="https://github.com/manaflow-ai/cmux">{chunks}</a>
web/app/[locale]/docs/notifications/page.tsx:58:            <td><code>CMUX_NOTIFICATION_TITLE</code></td>
web/app/[locale]/docs/notifications/page.tsx:62:            <td><code>CMUX_NOTIFICATION_SUBTITLE</code></td>
web/app/[locale]/docs/notifications/page.tsx:66:            <td><code>CMUX_NOTIFICATION_BODY</code></td>
web/app/[locale]/docs/notifications/page.tsx:72:say "$CMUX_NOTIFICATION_TITLE"
web/app/[locale]/docs/notifications/page.tsx:78:echo "$CMUX_NOTIFICATION_TITLE: $CMUX_NOTIFICATION_BODY" >> ~/notifications.log`}</CodeBlock>
```
Survivor justification: 1x show-hn-launch blog manaflow-ai/cmux link = historical lineage credit (CLAUDE.md-sanctioned); 5x CMUX_NOTIFICATION_{TITLE,SUBTITLE,BODY} = the env vars the app actually emits (Sources/TerminalNotificationStore.swift:503-505) — renaming would make docs lie; source rename tracked as separate naming-residue.

## WEB-2 — CONTRIBUTING.md points contributions at Stage-11-Agentics
- Clone target: `git clone --recursive https://github.com/Stage-11-Agentics/c11.git` (CONTRIBUTING.md:24).
- Ghostty submodule push target fixed: no `git push manaflow` remains; contributors push to `origin` (Stage-11-Agentics/ghostty), matching .gitmodules.
grep for forbidden manaflow push target:
```
(none — clean)
```

## WEB-3 — socket-api-reference.md v2 method index
```
documented method entries : 231
source dispatch cases     : 231
match                     : YES
cmux mentions in doc      : 2 (both are the deliberate CLI compat-alias + legacy access-mode alias notes)

Live cross-check — 'c11 capabilities' on a running instance:
  live methods advertised : 165
  live methods NOT in doc : 0  (every live method is documented)
  doc methods not in live : 66 = debug.* (35, debug-build-only, flagged in doc) + conversation.*/app.restart/etc. newer than the running prod binary
```

## WEB-4 — ROADMAP.md + PHILOSOPHY.md reference
```
ROADMAP.md exists: YES
PHILOSOPHY reference: 3:Principles that shape what c11 is and, more importantly, what it refuses to be. Operational details live in `CLAUDE.md`; visions and features live in `ROADMAP.md`; this document captures the worldview underneath both.
reference resolves: YES
```

## WEB-5 — tests_v2 binary discovery resolves c11 (no cmux binary needed)
```
=== WEB-5 discovery proof ===
PATH 'cmux' binary present: True
PATH 'c11' binary present : True
shared cmux.find_cli_binary() -> /Users/atin/Library/Developer/Xcode/DerivedData/c11-dx-baseline/Build/Products/Debug/c11 DEV dx-baseline.app/Contents/Resources/bin/c11
basename is 'c11': True
(resolved in 0.0s)
RESULT: discovery resolves a binary named 'c11'; no 'cmux' binary required.

37 modules delegate to the single tests_v2/cmux.py:find_cli_binary() (or are already c11-aware). All parse; delegating modules resolve the same c11 binary.
```

## Real-artifact smoke (WEB-1 render proof)
`SKIP_ENV_VALIDATION=1 next build` — compiles + prerenders all 407 pages across 19 locales including /docs/api (the page the i18n-key fix touched). Exit 0. Only MISSING_MESSAGE warnings are wallOfLove.metaTitle/metaDescription in some locales — pre-existing on base main, untouched here. `tsc --noEmit` clean; no new eslint errors (5 pre-existing base errors untouched).

## Build deviation (flagged)
No `web-post` tagged build was produced: this PR changes zero Swift/app source, so a tagged build would exercise a byte-identical binary. WEB-5 discovery is proven against an existing c11 build (c11-dx-baseline) and WEB-3 cross-checked against a live instance's `c11 capabilities`. If the validator requires a web-post build artifact regardless, it is a mechanical `./scripts/reload.sh --tag web-post` (xcodebuild lock currently free).
