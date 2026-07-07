# C11-161 — Public-surface truth (Wave 1) — Plan

Delegator: `agent:ts-web-delegator`. Worktree `web-public-surface`, branch `ts/web-public-surface`.
Contract: `docs/cycles/2026-07-truth-and-stability/{SPEC.md §WEB, EVALUATION.md WEB-1..5}`.
Source dialogue: audit `notes/c11-audit-merged-2026-06-09.md` P0.6/P0.7 + naming-residue.

## Scope decision (the load-bearing call)

The June audit filed P0.6 as an explicit fork: **"finish the rebrand or mark `web/` inherited/undeployed."** This ticket finishes the rebrand of **pointers** — the things that route users, telemetry, contributions, and legal identity back to manaflow. The eval bar for WEB-1 is literally *"repo-wide grep for manaflow domains/keys in web/; only lineage credits remain."*

**In scope (WEB-1):** manaflow domains, PostHog key/host, feedback routing/endpoints, repo links, canonical site domain, legal-entity identity (Manaflow → Stage 11 Agentics), copyright strings, nightly DMG links, `CMUX_*` env-var names in `web/`.

**Explicitly OUT of scope:** the product-name **"cmux" → "c11" prose rebrand** across the 19 locale message files and blog posts. The audit sequences this as a *separate* naming-residue item ("user-facing 'cmux' strings ... sequence AFTER P0.1"), not part of P0.6. It is a translation-scale effort (19 locales) and not a "domain/key" per the grep bar. Touching en.json product prose without the other 18 locales would half-rebrand worse than today. This plan changes only **entity/domain/key pointers** inside message files (e.g. the `© Manaflow` copyright), never product-name prose. **Flagged for the orchestrator** as a deliberate boundary.

## Values I don't hold → env-drive with non-manaflow defaults (deviate-with-flag)

Three replacement targets are operator-held facts, not derivable from the repo:
- **Canonical public domain** (currently `cmux.com`). No c11 marketing domain is referenced anywhere in-repo (README uses `stage11.dev` for videos, `stage11.ai` for the company link).
- **Feedback recipient inbox** (currently `feedback@manaflow.com`).
- **Legal contact** (currently `founders@manaflow.com`) and **PostHog project** (currently manaflow's key + `r.cmux.com`).

Approach: **remove every hardcoded manaflow value; make each env-driven with a defensible non-manaflow default**, so source greps clean and the operator overrides via env at deploy. Defaults chosen: site URL `https://c11.stage11.systems` (agents own `stage11.systems` prod per global CLAUDE.md), legal entity `Stage 11 Agentics`, legal contact `founders@stage11.ai` (company domain per README). PostHog: no-op when `NEXT_PUBLIC_POSTHOG_KEY` is unset (also fixes the audit's opt-out-default-ON telemetry concern). **All flagged in the plan-review amendment + PR body for operator confirmation.**

---

## WEB-1 — Pointer sweep (`web/`)

| File | Change |
|---|---|
| `web/app/[locale]/posthog.tsx` | Replace hardcoded key `phc_opOVu…` + `api_host: https://r.cmux.com` with `process.env.NEXT_PUBLIC_POSTHOG_KEY` / `NEXT_PUBLIC_POSTHOG_HOST`; guard init so PostHog is a no-op when key unset. |
| `web/app/env.ts` | Rename `CMUX_FEEDBACK_FROM_EMAIL` → `C11_FEEDBACK_FROM_EMAIL`, `CMUX_FEEDBACK_RATE_LIMIT_ID` → `C11_FEEDBACK_RATE_LIMIT_ID`; add `C11_FEEDBACK_TO_EMAIL`. |
| `web/app/api/feedback/route.ts` | `feedbackRecipient` `feedback@manaflow.com` → `env.C11_FEEDBACK_TO_EMAIL`; `from: "Manaflow <…>"` → `"c11 <…>"`; subject/`<h1>` `cmux feedback` → `c11 feedback`; env refs updated. |
| `web/app/api/github-stars/route.ts` | `api.github.com/repos/manaflow-ai/cmux` → `…/Stage-11-Agentics/c11`. |
| `web/app/[locale]/components/*` (github-stars/github-button/footer/header) | Any `manaflow-ai/cmux` repo link → `Stage-11-Agentics/c11` (grep-sweep all `web/app`). |
| `web/app/sitemap.ts`, `web/app/robots.ts` | `https://cmux.com` base → `process.env.NEXT_PUBLIC_SITE_URL ?? "https://c11.stage11.systems"` (single helper). |
| `web/app/layout.tsx` | metadataBase / canonical if it names cmux.com → same env helper. |
| `web/proxy.ts` | Remove the `cmux.dev`/`www.cmux.dev` → `cmux.com` manaflow apex-redirect block (c11 owns neither domain). |
| `web/app/[locale]/nightly/page.tsx` | DMG `github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg` → `Stage-11-Agentics/c11` nightly asset; issues link → `Stage-11-Agentics/c11/issues`; icon alt `cmux NIGHTLY` → `c11 NIGHTLY`. |
| `web/app/[locale]/(legal)/{eula,privacy-policy,terms-of-service}/page.tsx` | Entity `Manaflow` → `Stage 11 Agentics`; `founders@manaflow.com` → `founders@stage11.ai`. |
| `web/messages/*.json` (19 locales) | Entity-only: `© {year} Manaflow` → `© {year} Stage 11 Agentics` (mechanical, all locales). Any manaflow domain/email in messages → repoint. **No product-name prose changes.** |

Verification: `grep -rinE "manaflow|cmux\.(com|dev)|r\.cmux\.com|phc_opOVu|feedback@manaflow|founders@manaflow" web/ | grep -v node_modules` returns **zero** (any surviving hit must be intentional lineage-credit prose, counted + justified). Record before/after grep counts. Also confirm `web/` still builds/typechecks (`bun run build` or `tsc --noEmit` if practical).

## WEB-2 — CONTRIBUTING.md

Already clones from `Stage-11-Agentics/c11` (WEB-2 core satisfied). Fix the **P0.7 residue**: the ghostty submodule section (`CONTRIBUTING.md:~102-121`) tells contributors `git push manaflow my-ghostty-feature` / `manaflow/main` — wrong per policy (fork is `Stage-11-Agentics/ghostty`, remote `stage11`). Rewrite to the stage11-fork workflow to match CLAUDE.md §"Ghostty submodule workflow". Keep the deliberate lineage credit ("code that clearly came from upstream cmux — flag it") — that's allowed lineage talk.

Verification: read CONTRIBUTING.md; no contributor-facing push target points at a manaflow remote.

## WEB-3 — docs/socket-api-reference.md rewrite

Current file is 288 lines, 56 cmux mentions, pre-rename, documents nonexistent commands. Rewrite fully:
- **c11-branded**; source link → c11/stage11 docs URL or drop the stale `cmux.com/docs/api` line.
- **v2 JSON-RPC framing** documented from source (`Sources/TerminalController.swift`): newline-delimited JSON; request `{"id","method","params"}`; success `{"id","ok":true,"result":…}`; error `{"ok":false,"error":{"code","message"}}` (codes seen: `invalid_utf8`, `parse_error`, `invalid_request`, …).
- **Complete method index generated from source**: the dispatch switch has **231 dotted `case "domain.method"` entries** across 21 domains (browser 84, debug 35, workspace 25, surface 25, pane 13, theme 10, conversation 6, window 5, system 5, snapshot 5, notification 5, app 3, markdown 2, feedback 2, tab/sidebar/settings/session/mailbox/auth 1 each). Generate the index programmatically:
  `grep -oE 'case "[a-z_]+\.[a-z_.]+"' Sources/TerminalController.swift | sed -E 's/case "//;s/"$//' | sort -u`
  Emit **per-domain sections**, every method listed. Socket paths → `/tmp/c11.sock`, `/tmp/c11-debug.sock`, `/tmp/c11-debug-<tag>.sock`; env `C11_SOCKET_PATH`/`C11_SOCKET`; access-mode env `C11_SOCKET_MODE`.
- **Zero stale cmux naming** (except any deliberate `cmux` CLI compat-alias note).

Verification (EVALUATION WEB-3): index method count == unique dotted registrations in source (231); `grep -ci "cmux" docs/socket-api-reference.md` == 0 (or only the intentional compat-alias mention, counted and justified). Cross-check a sample against `c11 capabilities` on the tagged build during validation.

## WEB-4 — ROADMAP.md stub + PHILOSOPHY.md resolves

Create minimal `ROADMAP.md` at repo root — a "directions we care about" stub per operator (minimal placeholder, NOT a manifesto). `PHILOSOPHY.md:3` already references `ROADMAP.md`; creating the file makes the reference resolve. Use the standard-project-file header shape.

Verification: `test -f ROADMAP.md`; the PHILOSOPHY.md reference now resolves to a real file.

## WEB-5 — tests_v2 binary discovery (shared helper)

45 test files each define an identical `_find_cli_binary()` that globs `~/.../DerivedData/**/Build/Products/Debug/cmux`, `/tmp/cmux-*/Build/Products/Debug/cmux`, and honors `CMUXTERM_CLI`. The built binary is now **`c11`** (`PRODUCT_NAME = c11`, DerivedData `c11-<slug>/Build/Products/Debug/c11`), so discovery finds nothing.

Approach (shared helper, per prompt's "prefer one helper over 35 edits"):
1. Add `find_cli_binary()` to the shared `tests_v2/cmux.py`. It: honors `C11_CLI` then `CMUXTERM_CLI` (compat); globs `Build/Products/Debug/c11` under both `c11-*` and legacy `cmux-*` DerivedData dirs + `/tmp/c11-*` and `/tmp/cmux-*`; picks newest; raises `cmuxError` if none. Prefer `c11` product name, keep `cmux` globs as fallback so nothing regresses.
2. Replace the 45 per-file `_find_cli_binary()` definitions with `from cmux import find_cli_binary` (or a thin local shim delegating to it). Keep function name/call-sites stable to minimize churn.

Verification (EVALUATION WEB-5): with a tagged build present and **only a `c11` binary** discoverable (no `cmux` binary), a discovery smoke (import + `find_cli_binary()` resolves + one socket test connects) passes against `C11_SOCKET=/tmp/c11-debug-web-post.sock`. Capture the log.

---

## Phase execution

- **Implement** in reviewable commits: (1) WEB-4 ROADMAP, (2) WEB-2 CONTRIBUTING, (3) WEB-1 pointer sweep, (4) WEB-3 socket ref, (5) WEB-5 discovery helper.
- **Build lock** required only for WEB-5 validation (tagged build). Acquire `xcodebuild` resource, `reload.sh --tag web-post`, run discovery pass, release. Heartbeat every ~10 min.
- **No skills touched** → no `sync-installed-skills.sh` needed (confirm no `skills/` edits). Doc/web strings are not app strings → no localization pass.
- **Validation bar:** recorded grep proofs (WEB-1 zero manaflow, WEB-3 count match) + tagged-build discovery log (WEB-5) attached with `--role validation`.

## Risks / flags for plan-review

1. **Domain/feedback/PostHog/legal-contact defaults are assumptions** (env-overridable). Operator must confirm the real c11 public domain + feedback inbox + legal entity/contact before deploy. Prominent PR-body flag.
2. **Legal-page entity edits** (Manaflow → Stage 11 Agentics) touch binding legal copy — correct-but-needs-legal-review; flag, don't silently ship as final.
3. **Product-name "cmux" prose deliberately untouched** — confirm the orchestrator agrees this is out of C11-161 scope (separate naming-residue ticket).
4. **WEB-5 fallback globs** keep `cmux`-named paths so a mixed environment doesn't regress; the *requirement* (works with only `c11`) is still met.

## Plan-review amendments (authoritative — supersede conflicting text above)

Plan-review verdict: **PASS** (`art_01KWXP285S47D3A8RNVNV946QX`). All plan facts verified against the tree. Amendments folded in:

**A1 [MAJOR fix] Verification command → tracked files only.** The `grep -r web/` sweeps gitignored `web/.next/` build output (~1,588 hits) and can never return zero. **Authoritative verification command:**
`git grep -inE 'manaflow|cmux\.(com|dev)|r\.cmux\.com|phc_opOVu|CMUX_|feedback@manaflow|founders@manaflow' -- web/`
Run before and after; record both counts. Remaining post-sweep hits are acceptable ONLY if every one is a justified lineage credit (enumerated in A5).

**A2 [scope refinement — the clean line] Token vs. prose.** The grep bar targets **tokens/identifiers/domains/entity-names**, never bare product-name "cmux". Therefore:
- **In scope, swept across ALL surfaces incl. all 19 locale message files and docs pages (mechanical, non-translational):** `CMUX_*` env-var identifiers → `C11_*` (e.g. `CMUX_SURFACE_ID`→`C11_SURFACE_ID`, `CMUX_SOCKET_PATH`→`C11_SOCKET_PATH`, `CMUX_SOCKET_MODE`→`C11_SOCKET_MODE`, `CMUX_WORKSPACE_ID`→`C11_WORKSPACE_ID`); `cmux.com`/`cmux.dev`/`r.cmux.com` domains; `manaflow` entity/domain/email/repo/social; the PostHog key. These are literal tokens identical in every locale — same treatment as the `© Manaflow` copyright. (c11 binary dual-reads `C11_*`/`CMUX_*`, so `C11_*` docs are always correct; CLAUDE.md mandates authoring `C11_*`.)
- **Still OUT of scope (separate product-name translation pass):** bare English word "cmux" inside prose sentences across locales, blog narrative prose.

**A3 [MAJOR fix] Two newly-assigned hit categories.**
- **cmux.dev testimonials** — `web/messages/*.json` key `kataring` "Switched to cmux.dev" (all 19) + `web/app/[locale]/testimonials.tsx`. **Treatment: DROP** (both a `cmux.dev` domain hit and an endorsement of a different product/domain — the exact truth problem P0.6 targets; fabricating a "switched to c11" quote is dishonest). Flag to operator.
- **manaflow social links** — `community/page.tsx:89,113`, `site-footer.tsx:41` → `twitter.com/manaflowai`, `linkedin.com/company/manaflow-ai`. **Treatment:** drop the manaflow twitter/linkedin entries (or repoint the GitHub link to `github.com/Stage-11-Agentics`); add "Stage 11 social handles" to the operator-confirmation flag list (no Stage 11 handle is derivable from the repo).

**A4 [MINOR fixes]**
- Verification pattern already includes `CMUX_` (A1) — covers the env-var renames.
- Correct file path: canonical/metadataBase `cmux.com` hits are in **`web/app/[locale]/layout.tsx:34,64,97`** (not `web/app/layout.tsx`). Also sweep repo links at `page.tsx:212`, `community/page.tsx:77`.
- **Additional in-scope files the sweep surfaced** (git grep ground truth, 240 tracked hits): `web/app/[locale]/docs/api/page.tsx` (13 — on-site socket-API mirror; fix `CMUX_*`, `/tmp/cmux.sock`→`/tmp/c11.sock`, `cmux <verb>` CLI tokens, `cmux_cmd`→`c11_cmd` per WEB-3 "zero stale cmux naming"), `docs/notifications/page.tsx` (5), `docs/concepts/page.tsx` (3), `web/.env.example` (2 — `CMUX_FEEDBACK_*`→`C11_FEEDBACK_*`), `components/nav-links.tsx` (1). Message files carry the socket-docs env tokens too (en.json:245,297,377,384,388,436,441) — swept as tokens.
- **WEB-5 file count is 37**, not 45 (`grep -rl 'def _find_cli_binary' tests_v2/`). Use measured count in evidence.

**A5 [justified lineage survivors — expected non-zero grep tail]** The historical blog posts `blog/show-hn-launch/page.tsx` and `blog/zen-of-cmux/*` narrate the cmux-era Show HN launch; their `manaflow-ai/cmux` references are correct historical fact and qualify as CLAUDE.md lineage credits. **Treatment: keep, enumerate, justify** in validation evidence. The final `git grep` proof will show a small tail of hits, each mapped to a named lineage-credit location. If a hit is NOT one of these, it's a defect to fix.

**A6 [PR flag] Deploy-config break.** Env renames (`C11_FEEDBACK_*`, gated `NEXT_PUBLIC_POSTHOG_*`, `NEXT_PUBLIC_SITE_URL`) change the deployment env contract — if any deployment exists, feedback/analytics silently stop until env is set. One line in the PR flag list.

## Reset 2026-07-07 by agent:ts-web-delegator
