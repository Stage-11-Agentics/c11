# C11-142: Project infrastructure: web rebrand, CI/release gates, test de-rot, docs/skills, repo hygiene, god-file refactor

## Project infrastructure: branding, CI/release, tests, docs, repo, refactor

Source: `notes/c11-audit-merged-2026-06-09.md` P0.6, P0.7, P1.7, P1.8, P1.9, P2.1, P2.2, P2.5, P2.6, and the P3 grab-bag. Validated against HEAD `b3dfc10bc`. Theme: everything that isn't app-runtime behavior — branding leaks, CI/release gates, the test suite, docs/skills, repo hygiene, and the enabling refactor. This is the largest ticket and is itself sub-dividable if a delegator wants to split it; the pieces are mostly independent.

### A. `web/` half-rebranded, leaks to manaflow if deployed (P0.6) — CONFIRMED (privacy/brand risk)
- PostHog manaflow key+host: `web/app/[locale]/posthog.tsx:9` (key), `:10` (`api_host:"https://r.cmux.com"`).
- Feedback → manaflow: `web/app/api/feedback/route.ts:11` (`feedback@manaflow.com`), `:118`, `:254`.
- Nightly serves upstream cmux DMG: `web/app/[locale]/nightly/page.tsx:55,77` (+ `:33` alt text).
- Legal pages name Manaflow as the Company: `(legal)/privacy-policy/page.tsx:17`, `terms-of-service/page.tsx:19,184`, `eula/page.tsx:35`; all `founders@manaflow.com`.
- Canonical domain `cmux.com`: `layout.tsx:34,64,97`, `robots.ts:6`, `sitemap.ts:5`, **`web/proxy.ts:10,13`** (corrected — not under `app/`).
- **Decision required:** finish the rebrand or mark `web/` inherited/undeployed. If deployed it ships manaflow telemetry/legal/email.

### B. CONTRIBUTING pushes to manaflow (P0.7) — CONFIRMED, worse than stated
`CONTRIBUTING.md:110` `git push manaflow my-ghostty-feature`; `:121` "push to `manaflow/main`". No `manaflow` remote exists in the `ghostty` submodule (`origin`=manaflow-ai/ghostty, `stage11`=Stage-11-Agentics/ghostty); the command fails outright, and the only manaflow-named target (`origin`) is the **forbidden** upstream. **Fix:** rewrite to the `stage11` remote workflow (matches CLAUDE.md).

### C. CI / release / build gates (P1.7) — all 11 CONFIRMED
- Release/nightly build with no `test` action and no `set -euo pipefail`: `release.yml:155-164`, `nightly.yml:209-218` — logic regressions ship unguarded before sign/notarize/publish.
- `workflow_dispatch`-from-branch burns ~1h then can mint a malformed `refs/heads/main` release: `release.yml:7,17-18,33` (`context.ref.replace('refs/tags/','')` → `refs/heads/main`), `:329`.
- `update-homebrew.yml:33,37` — `inputs.version` / `workflow_run.head_branch` interpolated directly into `run:` (script injection). **Fix:** pass via `env:`.
- `SPARKLE_PRIVATE_KEY` as a positional CLI arg (visible in `ps`): `release.yml:151`, `nightly.yml:205`.
- `reload.sh:301-302` — `PIPESTATUS[0]` captured after `|| true` clobbers it; a killed xcodebuild reads as success and a stale build launches.
- No CI lint for ungated `dlog(` (the documented Release-breaking footgun). Add a pre-merge grep guard.
- `ci.yml:215` host-bound test step is `continue-on-error: true` — those classes never block merges.
- `drawbridge-sweep.yml:64` — digest never posts when 1-10 items exist (`set -e` + trailing `&&` group, `MAX_DISPATCH=10`).
- `scripts/run-e2e.sh:11` dispatches `manaflow-ai/cmux` (forbidden) and the target `test-e2e.yml` doesn't exist (CLAUDE.md/AGENTS.md document it anyway).
- `scripts/sync-upstream.sh:120,167` uses `mapfile` — dies on macOS bash 3.2.
- `scripts/setup.sh:34` `LOCK_TIMEOUT=300` < the ~10min zig build it protects → concurrent setup corrupts the cache.

### D. Wrappers / packaging (P1.9) — CONFIRMED
- `Resources/bin/claude:197` — guard reads `$cmux_set_agent_bin` (lowercase, never set) instead of `$C11_SET_AGENT_BIN` (set at `:174`) — the C11-24 conversation-claim rail is silently dead for Claude sessions. (The `set_agent` path at `:175` is fine.)
- Info.plist `CMUXCommit` vs `C11Commit`: readers `SkillInstaller.swift:506`, `c11App.swift:3178`, `ContentView.swift:8916` read `CMUXCommit`; the build phase (`project.pbxproj:1365`) writes only `C11Commit` (installed v0.51.0 bundle has `C11Commit`, no `CMUXCommit`) → empty provenance. Nuance: `nightly.yml:307-309` redundantly writes both (masks it for nightly only); `SentryHelper.swift:152` already reads `C11Commit`. **Fix:** point the three readers at `C11Commit`.
- Telemetry opt-out default-ON, no first-run disclosure: `c11App.swift:4255` (`defaultSendAnonymousTelemetry=true`), Sentry `AppDelegate.swift:2511+`, PostHog `:2550` start before Settings is reachable. **Fix:** add a first-run consent gate.
- Skills install hashes+copies synchronously on the main actor: `AgentSkillsModel` `@MainActor` (`AgentSkillsView.swift:9`), `install()` (`:150`) called straight from Button actions (`:522,533`) — UI hangs on large trees; `contentHash` (`SkillInstaller.swift:339`) follows symlinks outside the skill boundary (resolves `.isRegularFileKey` of the target). **Fix:** move install off-main; don't follow symlinks past the boundary.

### E. Test-suite de-rot (P1.8) — CONFIRMED (suite cannot go green)
- ~33 of 37 `tests_v2` `_find_cli_binary()` only find a binary named `cmux` (copy the dual-name `("c11","cmux")` pattern from `test_socket_reliability_stress.py:59`; `test_doctor_command.py:28-48` is cmux-only).
- `test_m5_readme_markers.py:34-35` asserts dead `<h1>c11mux</h1>` branding; `test_m5_channel_identity.py:82` / `test_m5_built_bundle.py:118` pin bundle id `com.stage11.c11mux` (actual `com.stage11.c11[.debug]`) — cannot pass.
- `tests/claude_teams_test_utils.py:14` reads `/tmp/cmux-last-cli-path`; reload.sh writes `/tmp/c11-last-cli-path` (`:409,461`) — kills ~10 v1 tests.
- `tests/cmux.py` (49KB) + `tests_v2/cmux.py` (41KB) are pre-rename; no `c11.py` client. Only 15 of 151 tests_v2 files read `C11_SOCKET` (120 read `CMUX_SOCKET`).
- tests/ ↔ tests_v2/ duplication: 27 shared basenames, several diverged with fixes only in v2.
- Policy-banned source-grep tests + dead shell tests (`test_app_keystrokes.sh` ~0 assertions, `test_homebrew_sha.sh`, `test_nightly_universal_build.sh`).
- **Fix:** rename clients to `c11.py`, fix the dual-name resolver, retire `c11mux`/bundle-id tests, de-dup, drop banned/dead tests (per the repo test-quality policy).

### F. Repo hygiene (P2.2) — CONFIRMED
- Untrack `node_modules/` — **4,943** tracked paths (~2/3 of the repo, incl. an 18MB binary). `git rm -r --cached` + gitignore.
- Untrack `.lattice/.daemon/*.log` (15 tracked); add `branch = main` to the `vendor/bonsplit` stanza in `.gitmodules` (ghostty + homebrew-c11 already have it).

### G. Skills & docs accuracy sweep (P2.5) — CONFIRMED (with corrections)
- Delete the `c11 install claude-code` section in `skills/c11/references/api.md:254-265` (writes hooks into `~/.claude/settings.json`; removed in C11-17, "do not revive"). NOTE: a different `c11 skill install` command still exists (`CLI/c11.swift:16222`) — don't confuse them.
- `docs/socket-api-reference.md` — entirely pre-rename (48 `cmux` refs), documents nonexistent commands; CONTRIBUTING.md:146 links it as canonical. Rewrite or delete.
- The stale `cc --resume` lives in `api.md:604/609` (NOT `SKILL.md` — `SKILL.md:106` is already correct). Fix the api.md copy.
- `api.md:140` caller-pane recipe greps the first `pane_ref` in an unordered dict (can hit the `focused` block — the exact failure it warns about). `orchestration.md:129` jq path → use `.caller.workspace_ref`.
- `docs/c11-mailbox-guide.md:13` documents the wrong state dir (`c11mux` vs `c11`).
- `skills/MANIFEST.json` missing `c11-hotload` + `release` from `installable`; schema key still `c11mux_skill_manifest_schema`.
- Version-history claims wrong (0.44-0.46 refs at 0.51.0, `SKILL.md:609`); journey-style backstory violates the timeless-skill rule.
- `PHILOSOPHY.md:3` references nonexistent `ROADMAP.md`; `TODO.md` is 0 bytes. Create ROADMAP.md (or drop the ref).
- **After every skill edit:** `scripts/sync-installed-skills.sh` (HARD RULE).
- **Drop, do NOT chase:** the `api.md:53` socket-override finding (the override IS real — CLI reads `C11_SOCKET_PATH`/`C11_SOCKET` at `CLI/c11.swift:1450,1500,...`); and B's "SKILL.md empty-`--surface` footgun note is stale" (the footgun is live until ticket #1's P0.2 lands).

### H. Silent-failure ergonomics (P2.6) — CONFIRMED
`try?`-swallowed config/decode errors (`DefaultAgentConfig.swift:183,241`, `DefaultAgentProjectConfig.swift:28` — unknown `defaultAgent` silently falls to `.claudeCode`/`.factory`), fire-and-forget mailbox dispatch-log writes (`MailboxDispatchLog.swift:100-106`, comment says "intentionally silent"), unknown mailbox handler indistinguishable from I/O error (both `.eio`, `MailboxDispatcher.swift:328/350`). **Fix:** add DEBUG logs at the `try?` sites; give unknown-handler a distinct outcome. (Note: the "silent timeout discards" sub-claim is softer than stated — those paths do record a `.timeout` outcome.)

### I. The two god files (P2.1) — enabling refactor, SEQUENCE deliberately
`Sources/TerminalController.swift` (19,786 LOC, ~553 cases) and `CLI/c11.swift` (16,990 LOC, ~407 cases). Extract cohesive handler clusters (browser, sidebar telemetry, debug, workspace/surface/pane, socket accept loop; CLI: browser, SSH tunnel, mailbox, claude-hook, snapshot/blueprint). **This conflicts with tickets #2/#3/#4 — do it AFTER those land, not in parallel.** Listed here for tracking; treat as the final phase.

### J. P3 cleanup grab-bag
- **Localization:** hardcoded English NSAlert (also breaks close-confirmation *detection* in non-English locales — the one functional loc bug, fix first), `.safeHelp` literals, relative-time strings, worktree chip labels, `"Terminal"` default title, InfoPlist.xcstrings gaps.
- **Dead code:** `Sources/TerminalView.swift` (legacy SwiftTerm, zero refs — delete), `TabManager.startSearch` unreachable block, browser dialog dead responders, `captureLsof` ignored param.
- **Script polish:** `sanitize_bundle` literal-backslash sed; tags with `/` break app-copy; launchd plist hardcodes `/Users/atin`; `setup.sh` cache key needs `C11_*`; relative `rm -rf` in download-prebuilt; `find | head` SIGPIPE under pipefail.
- **Test polish:** blanket 3-attempt retry masks flakes; wall-clock benchmark assertions; `Thread.sleep` as sync; `/Users/atin` fixtures; `test_signals_auto.py` tests macOS not c11.
- **Minor security hardening:** non-constant-time socket password compare; socket perms applied after bind; predictable hooks tempfile in `Resources/bin/claude` (use mktemp); address-bar `postMessage("*")`.
- **Misc UX:** duplicate-shortcut detection absent; markdown file-watch gives up after ~3s; Mermaid renderer 15s serial block; `read_screen --scrollback` clobbers the user pasteboard mid-copy; `UpdateDriver` skips `.installing` UI; CLI `unknowncmd --help` exits 0.
- **Satellites:** web i18n MISSING_MESSAGE on wall-of-love (18 locales); feedback route rate-limit fails open off-Vercel; dual lockfiles; upstream-triage paused mid-sweep — decide resume or archive.

### Acceptance
`web/` either fully c11-branded or explicitly marked undeployed; CONTRIBUTING points at the stage11 fork; release/nightly gate on tests and `set -euo pipefail`; the test suite goes green locally on the safe `c11-logic` scheme + CI; node_modules untracked; the docs/skills sweep done with `sync-installed-skills.sh` run; the god-file extraction landed last.
