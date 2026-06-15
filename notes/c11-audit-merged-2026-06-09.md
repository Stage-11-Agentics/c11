# c11 Audit — Merged & Prioritized (2026-06-09)

Synthesis of two independent audits, both at HEAD `5c1227bfe` / 0.51.0:

- **A** = `notes/c11-audit-findings-2026-06-09.md` (systemic framing, Sev|Conf ratings, deep on core subsystems)
- **B** = `notes/c11-audit-20260609.md` (10-agent fan-out, broadest coverage, several findings verified live)

Provenance tags: `[A]`, `[B]`, `[A+B]` = independently corroborated (highest confidence). `✓` = re-verified during this merge pass. Findings the audits got wrong are corrected inline.

**Adjudication notes from the merge:**
- The one direct conflict — does an empty `--surface ""` still silently misroute to the focused surface? — resolves in **A's favor**. ✓ Verified: `CLI/c11.swift:2433` guards `!= nil` but not `!= ""`, and `normalizeSurfaceHandle` (`:4514`) nils out empty strings, so the params reach the server without a `surface_id` and fall back to `ws.focusedPanelId`. B's "0.51.0 rejects empty refs" is wrong (only the fully-absent flag errors). B's skills-drift item claiming the SKILL.md footgun note is stale should be **dropped** — the footgun is live.
- Spot-verified from B: `node_modules` tracked (✓ 4,943 of 7,395 tracked files), `prune-tags.sh:49` sed delimiter bug (✓ `s|...(c11|cmux)...|` — `|` as both delimiter and alternation), `rebuild.sh` `pkill -9 -f "c11"` (✓).

---

## P0 — Decisions, data loss, ship-stoppers

These either lose user data, freeze the app, kill the operator's processes, or block everything downstream until a direction is picked.

### P0.1 The `C11_*` / `CMUX_*` identity split (the keystone decision) [A+B, both verified live]
The binary exports only `CMUX_*` to shells; every skill, doc, and convention says `C11_*`. One decision unblocks ~15 downstream findings. **Recommended: export both from the binary**, then sweep docs.
- `Sources/GhosttyTerminalView.swift:3339-3413` — PTY env seeds `CMUX_*` only; no `C11_SHELL_INTEGRATION`/`C11_SURFACE_ID`/etc. [A+B]
- `Sources/C11EnvBridge.swift:5-16` — `mirrorC11CmuxEnv()` only mutates the *app process* env, never reaches spawned shells. [A]
- `C11_AGENT_TYPE`/`C11_AGENT_MODEL`/`C11_AGENT_TASK` exist nowhere in the codebase, yet the skill's canonical orient recipe depends on them; `c11 set-agent --type "$C11_AGENT_TYPE"` errors (`--type` required). Implement spawn-path seeding or delete the doc claims. [B]
- `Sources/SocketControlSettings.swift:296-298,460,650,667` — socket control reads only `CMUX_SOCKET_PATH`/`_PASSWORD`/etc.; `C11_*` silently fails auth. [A]
- CLI socket auto-discovery is entirely cmux-named (`Application Support/cmux/cmux.sock`, `/tmp/cmux-debug*.sock`, `cmux*` globs, `cmux/last-socket-path`) while the server binds c11-named paths — any caller outside a c11 pane (cron, launchd, fresh shell) can't find a running server. `CLI/c11.swift:694-757,809,1459,283-302` vs `SocketControlSettings.swift:300-303`. [A+B, B verified live]
- Same gap in `daemon/remote/cmd/c11d-remote/cli.go:354-370,515-516`. [B]
- `skills/c11/SKILL.md:19-48` detection + orient recipes are broken against the shipping binary until the export lands. [A+B]
- **Do this before any blind `cmux→c11` rename** — renaming code without fixing the export side breaks working paths. [A]

### P0.2 Absent-vs-empty surface refs silently misroute writes [A, ✓ verified]
Empty string refs are treated as "absent" and fall back to the *focused* surface across many write paths — a sub-agent stomps a peer's terminal/metadata with an identical-looking `OK`.
- `Sources/TerminalController.swift:7654,6363,6610` + `:4064-4066` — `v2UUID`/`v2String` nil out empty strings; handlers resolve `?? ws.focusedPanelId`.
- `CLI/c11.swift:2433-2435,2456` — `send`/`send-key` guard passes an exported-but-empty `CMUX_SURFACE_ID`. ✓
- `CLI/c11.swift:14555,15026-15034` — SessionStart conversation-push hook falls back to the focused surface, mis-keying conversation refs (wrong session resumes in wrong pane). Compounded by P0.1.
- `Sources/TerminalController.swift:18034-18046,18141` — same for `--tab=""`/`--panel=""`.
- **Root fix once at the parse layer:** distinguish absent from empty/whitespace and ERROR on explicitly-empty refs (`v2UUID` vs `v2UUIDAny` already diverge at `:4114-4130` — unify).

### P0.3 Session/conversation data loss [A+B]
- Saves while the launch resume-picker is open: autosave (8s), `willResignActive`, and `willTerminate` all overwrite `session-*.json` with the fresh empty state before the operator decides; quit-while-deciding permanently destroys the prior session. Gate saves until the restore decision resolves. `AppDelegate.swift:3145-3188,3657,2946,3888`. [B, H]
- `readConversationsByPanelIdSync` returns `[:]` on a 2s actor timeout → snapshot writes `.empty` for every panel, silently dropping ALL conversation refs; `willTerminate` then `promoteToClean`s over it, so refs are permanently lost. Also a data race on the timeout path (detached task writes `captured` while caller reads). `Workspace.swift:181,416-428,758`, `AppDelegate.swift:2903-2927`. [A+B]
- `markAllUnknown` resurrects `.tombstoned` conversations on crash recovery — user-`/exit`ed sessions re-resume, violating "tombstone is terminal". `Sources/Conversation/Store.swift:188-198`. [A, H|H]
- `SessionPersistence.load` returns nil on any decode error or version mismatch (`try?`), and the next autosave clobbers the file — no `.corrupt` sidecar, no migration, no salvage. `SessionPersistence.swift:472-480`. [A+B]
- Shutdown write-ordering race: terminate path writes directly while async autosaves run on the queue; last-writer-wins. `AppDelegate.swift:4051-4078`. [B]

### P0.4 Main-thread freezes reachable from the socket [B, all H]
- `pane.confirm` beachballs the whole app: runs under `main.sync` then `semaphore.wait` on main for a dialog only main could answer (cap 300s). `TerminalController.swift:1811,9665`.
- `feedback.submit` always freezes main ~35s then fails: blocks on a semaphore whose signaling Task inherits @MainActor and can never start. `TerminalController.swift:10263-10297`.
- Concurrent browser commands wedge a socket thread permanently: nested `CFRunLoopRun`s — outer timeout stops only the innermost loop, deadlocking inside `main.sync`. `TerminalController.swift:10473-10497`.
- Pipe-buffer deadlock in workspace git probes: waits for exit before draining pipes; >64KB of `git status` wedges the serial probe queue forever. `TabManager.swift:2022-2081`.

### P0.5 Destructive scripts [B, ✓ verified]
- `scripts/rebuild.sh:9-10` — `pkill -9 -f "c11"` SIGKILLs the prod app and every agent with `c11` in its command line. Stale cmux-era script; delete or guard. ✓
- `scripts/prune-tags.sh:49` — `running_tags()` sed uses `|` as both delimiter and alternation, errors out, returns nothing → running tagged builds are NOT protected (verified live: weekly launchd agent deleted a running tag). ✓
- `scripts/smoke-test-ci.sh:25-26` — `pkill -x "c11"` kills the operator's production c11 when run locally (no CI guard). [A]

### P0.6 `web/` is half-rebranded and leaks to manaflow if deployed [B, H]
PostHog inits with manaflow's key/host; feedback emails route to `feedback@manaflow.com`; nightly page serves upstream cmux DMGs; legal pages name Manaflow as the Company; canonical domain is `cmux.com`. **Decide: finish the rebrand or mark `web/` inherited/undeployed.** `web/app/[locale]/posthog.tsx:9-10`, `web/app/api/feedback/route.ts:11,118,254`, `nightly/page.tsx:55,77`, legal pages, `layout.tsx`/`sitemap.ts`/`robots.ts`/`proxy.ts`.

### P0.7 CONTRIBUTING.md directs contributors to push to manaflow's repo [B, H]
`CONTRIBUTING.md:102-121` — `git push manaflow my-ghostty-feature`; no such remote and policy forbids upstream writes. Rewrite to the stage11-fork workflow.

---

## P1 — High-impact correctness, security, perf

### P1.1 Typing-latency hot path [A+B]
- Per-keystroke pasteboard XPC: `forceRefresh` → `hasTabDragPasteboardTypes()` reads `NSPasteboard(name:.drag).types` before any short-circuit — an XPC roundtrip per keystroke, violating the documented forceRefresh rule. Check `isDragResizeEvent` first. `GhosttyTerminalView.swift:4478-4498,4534`. [B, H]
- Sidebar sampler invalidates the whole sidebar at 2-10 Hz regardless of changes; each tick recomputes per-tab metadata snapshots, chip resolvers, themed colors — sustained O(workspaces) CPU. `ContentView.swift:8394,8540-8587`; `canonicalMetadataSnapshot` allocs at `TerminalController.swift:11084-11094`. [A, H|H]
- `handleCustomShortcut` runs five `String(localized:)` lookups + an `NSApp.windows` scan + recursive view walk on every keyDown before any modifier early-out. `AppDelegate.swift:9966-10017`. [B]
- `hitTest` pointer branch reads the drag pasteboard on every mouseMoved — one XPC per mouse-move. `TerminalWindowPortal.swift:281-283`. [B]
- `TabItemView.==` compares colors via `hexString()` (NSColor conversion + String alloc) in the equality hot path. `ContentView.swift:11244-11245`. [A]
- Every `GhosttyNSView` installs an app-wide scrollWheel monitor with eager string interpolation in Release. `GhosttyTerminalView.swift:4211,4307-4355`. [B]

### P1.2 Socket threading & focus policy violations [A+B, corroborated]
- Telemetry hot path (`set_status`/`report_*`/`log`/`set_progress` without explicit selector) runs full handlers under `DispatchQueue.main.sync`; `send`/`send_key` slow path holds main up to 2s while the operator types. Violates the project's own policy. `TerminalController.swift:1903-1908,1827-1834,17196,17384`. [A+B]
- `socketCommandFocusAllowanceStack` is a process-global stack mutated by concurrent per-connection threads; `.last`/blind `popLast()` read another command's allowance — non-focus commands can steal focus under concurrency. Key per-request. `TerminalController.swift:174-176,396-450,1633`. [A+B]
- `settings.open` (defaults `activate=true`) and DEBUG `debug.type`/`simulate_*` activate the app without being focus-intent commands. `TerminalController.swift:10227-10247,14220-14247,15055-15065`. [A+B]
- `handleClient` is a @MainActor method executed on a detached thread, reading `accessMode` unsynchronized. `TerminalController.swift:1721-1779`. [B]

### P1.3 Socket/CLI I/O correctness [A+B]
- Multibyte UTF-8 split across 4096-byte read chunks is dropped (`String(bytes:) ?? ""` per chunk) — corrupts CJK/emoji `send` payloads. Accumulate bytes, decode after framing. `TerminalController.swift:1761-1762`. [A]
- CLI `write()` doesn't handle short writes (`sent < len`) and doesn't retry `EINTR` — silent command truncation. `CLI/c11.swift:963-971`. [A+B]
- No read timeout on accepted clients + one detached thread per connection + `stop()` never closes accepted fds (`clientHandlers` declared, never populated) — unbounded thread/fd growth. `TerminalController.swift:1758,1633,170`. [A+B]
- Every v2 CLI invocation pays a 120ms idle-read tax on single-line responses. `CLI/c11.swift:935,963-1002`. [A+B]
- `send` doesn't reject unknown flags — `--text "hi"` types `--text` literally into the terminal (documented footgun, unguarded in code). `CLI/c11.swift:2437`. [A, H|H]
- `set-status`/`log` forwarding quotes with sh-style `shellQuote()` but the v1 tokenizer doesn't do quote-concatenation — messages with apostrophes silently truncate. Use `v1QuoteForTokenizer`. `CLI/c11.swift:11903-11906`. [A, H|H]
- Password with embedded newline injects a second command on the wire; embedded space breaks auth tokenization. `CLI/c11.swift:582-585,4259`. [A]

### P1.4 Browser surface security [A+B]
- `browser.eval` executes arbitrary caller JS; `browser.state.save/load` read/write cookies+localStorage at arbitrary caller paths — in `automation` mode any local same-user process can exfiltrate or inject session auth. `TerminalController.swift:11559-11577,13925-14053`. [A, H|H]
- `browser.state.save` writes auth material with 0644 perms — chmod 0600. `TerminalController.swift:13966-13972`. [B]
- `browser.state.load` applies the storage-restore script before navigation completes — payload lands in the previous origin. Wait for `didFinish`. `TerminalController.swift:14013-14043`. [B]
- `addinitscript`/`addstyle` accumulate permanently (no removal, no dedupe, not re-registered after WebContent crash, fire in cross-origin frames). `TerminalController.swift:14055-14129`. [A+B]
- Subframe navigations bypass the insecure-HTTP and external-URL filters (`targetFrame?.isMainFrame != false`); `javascript:` scheme accepted in the omnibar. `Panels/BrowserPanel.swift:6127-6222,860-874`. [A]
- Per-surface browser dicts (`v2BrowserElementRefs`, init scripts/styles, dialog queues, download events) never pruned on close — plus a data race: written on main, read from socket threads. `TerminalController.swift:310-317,10602-10638,11929-11936`. [A+B]
- Dialog model mismatch: a page `confirm()` before any dialog command deadlocks the agent until a human clicks; once shimmed, native dialogs are silently swallowed for humans. `BrowserPanel.swift:6423-6477`, `TerminalController.swift:13154-13189`. [B]
- `BrowserSnapshotStore` retains full-res NSImages for hibernated-never-resumed surfaces for process lifetime. `BrowserSnapshotStore.swift:43`. [A]

### P1.5 Conversation store & resume correctness [A]
- ClaudeCode resume types `claude --resume <id>` with no `cd <project_dir>` — sessions captured in worktrees/subdirs are non-resumable; `ref.cwd` carried but never used. `Strategies/ClaudeCode.swift:56-57`. [A, M|H]
- `shouldReplace` lets a newer-mtime scrape demote a confident `.alive`/`.suspended` ref to ambiguous. `Strategies/Codex.swift:50-60`, `Store.swift:241-243`. [A]
- The `state=ended`→`.unknown` shutdown invariant is enforced only client-side; any direct socket caller can demote a live ref. `TerminalController.swift:9842-9858`, `CLI/c11.swift:15110-15112`. [A]
- The `CMUX_DISABLE_CONVERSATION_STORE=1` kill-switch resumes Codex via `codex resume --last` — the exact global-lookup bug the new architecture fixes. `AgentRestartRegistry.swift:171-174`. [A]
- SurfaceActivity disambiguation floor is permanently nil and the cwd filter is a structural no-op — the same-cwd ambiguity the primitive exists for is not actually disambiguated (live-but-inert code). `Conversation/SurfaceActivity.swift:70,79`, `Scrapers/ClaudeCodeScraper.swift:45-59`. [A]
- `restoreSessionSnapshot` replaces `tabs` without panel/remote/mailbox teardown for discarded workspaces. `TabManager.swift:5515-5610`. [B]

### P1.6 Mailbox correctness [A+B]
- Dispatch `id` taken from the outbox **filename**, never validated nor checked against the envelope's own `id` — drives dedup and all bookkeeping. `MailboxDispatcher.swift:227`. [A]
- Dedup ring is in-memory only; restart re-dispatches (documented guarantee lost on relaunch). No Stage-2 `_processing/` recovery sweep — in-flight envelopes at kill time are permanently stranded. `MailboxDispatcher.swift:99-103,229,243`. [A]
- `invokeHandlerSynchronously` data race on the timeout path. `MailboxDispatcher.swift:387-412`. [B]
- `validateSurfaceName` doesn't reject reserved names — a surface named `_outbox` aliases the shared outbox and can re-dispatch-loop after restart. `MailboxLayout.swift:143-162`. [B]
- JSON-array `mailbox.delivery` silently registers zero handlers; duplicate-title fan-out with no warning; valid-title-but-unsafe-path recipients drop mail as `.eio`. `MailboxSurfaceResolver.swift:39-43,74-77`, vs `MailboxLayout.swift:143-162`. [A]
- Body XML-escaping doesn't neutralize ANSI/OSC sequences — terminal-escape injection into the recipient agent's PTY. `StdinMailboxHandler.swift:171-183`. [A]

### P1.7 CI / release / build gates [A+B]
- Release/nightly build with no `test` action and no `set -euo pipefail` — logic regressions ship with no gate before sign/notarize/publish. `release.yml:155-161`, `nightly.yml:209-218`. [A]
- `workflow_dispatch` from a branch can never succeed but burns ~1h of macos-15-xlarge first, and the upload fallback can create a malformed release tagged `refs/heads/main`. `release.yml:30-78,329`. [A+B]
- `update-homebrew.yml:33-37` — `inputs.version`/`head_branch` interpolated directly into `run:` (script injection). Pass via `env:`. [A+B]
- `SPARKLE_PRIVATE_KEY` passed as a positional CLI arg — visible in `ps`. `release.yml:151`, `nightly.yml:205`. [A]
- `reload.sh:301-302` — `PIPESTATUS[0]` captured after `|| true` clobbers it; a killed xcodebuild reads as success and a stale build launches. [B]
- No CI lint for ungated `dlog(` (the documented Release-breaking footgun). Add a pre-merge grep guard. [A]
- Host-bound test step is `continue-on-error: true` — those classes never block merges. `ci.yml:215`. [A]
- `drawbridge-sweep.yml:64` — digest never posts exactly when 1-10 items exist (`set -e` + `&&` group). [B]
- `scripts/run-e2e.sh:11` dispatches against `manaflow-ai/cmux` (forbidden); target workflow gone. CLAUDE.md/AGENTS.md document `test-e2e.yml` which doesn't exist. [B]
- `scripts/sync-upstream.sh:120,167` uses `mapfile` — dies on macOS bash 3.2 (verified). [B]
- `scripts/setup.sh:34-44` — 300s lock staleness < the ~10min zig build it protects; concurrent setup corrupts the cache. [B]

### P1.8 Test-suite rot (suite cannot go green) [B]
- 35 `tests_v2` files' `_find_cli_binary()` only find a binary named `cmux`; `test_m5_readme_markers.py` asserts dead "c11mux" branding; `test_m5_*` pin bundle id `com.stage11.c11mux` (actual `com.stage11.c11[.debug]`).
- `tests/claude_teams_test_utils.py:14` (+2 more) read `/tmp/cmux-last-cli-path`; reload.sh writes only `/tmp/c11-last-cli-path` — kills ~10 v1 tests.
- Shared test clients (`tests/cmux.py`, `tests_v2/cmux.py`) are entirely pre-rename; only 14 of 119 socket tests read `C11_SOCKET`.
- tests/ ↔ tests_v2/ duplication with drift (14+ identical, 8 diverged with fixes landing only in v2).
- Policy-banned genres still present (source-grep tests, grep-lint-as-test paying a full app relaunch); several dead/always-skipping shell tests (`test_nightly_universal_build.sh`, `test_homebrew_sha.sh`, `test_app_keystrokes.sh` with zero assertions).

### P1.9 Wrappers / packaging [B]
- `Resources/bin/claude:197` — guard reads `$cmux_set_agent_bin` (never set) instead of `$C11_SET_AGENT_BIN` — the C11-24 conversation-claim rail is silently dead for Claude sessions.
- Three readers use Info.plist key `CMUXCommit` but the build writes only `C11Commit` (verified on installed bundle) — skill manifests record empty commit provenance, about surfaces show none. `SkillInstaller.swift:506`, `c11App.swift:3178`, `ContentView.swift:8916`.
- Telemetry is opt-out default-ON with no first-run disclosure (Sentry + PostHog start before Settings is reachable). `c11App.swift:4253-4266`, `AppDelegate.swift:2494-2532`.
- Skills install hashes + copies synchronously on the main actor — UI hangs on large trees. `AgentSkillsView.swift:150-191`; `contentHash` follows symlinks outside the skill boundary. `SkillInstaller.swift:195-199,339-379`. [A+B]

---

## P2 — Maintainability, performance hygiene, docs/skills accuracy

### P2.1 The two god files (enabling refactor) [A, S3]
`Sources/TerminalController.swift` (~19.7k LOC, 551 socket cases) and `CLI/c11.swift` (~16.7k LOC, 335 cases). Extract cohesive handler clusters (browser, sidebar telemetry, debug, workspace/surface/pane, socket accept loop; CLI: browser, SSH tunnel, mailbox, claude-hook, snapshot/blueprint). Every P0/P1 fix above is riskier until this lands; conversely, doing it first churns line numbers — sequence deliberately (suggested: land P0 fixes, then extract, then P1 batches).

### P2.2 Repo hygiene [B, ✓ verified]
- Untrack `node_modules/` — ✓ 4,943 of 7,395 tracked files (~2/3 of the repo), incl. an 18MB binary.
- Untrack `.lattice/.daemon/*.log`; add `branch = main` for `vendor/bonsplit` in `.gitmodules`.

### P2.3 Unbounded in-memory stores [A]
Notifications array (no cap, O(n) rebuild + dock-badge refresh per mutation), browser per-surface dicts (P1.4), snapshot images, scrollback replay temp files (`cmux-session-scrollback/`, also stale-named), mailbox dedup ring. Add caps/eviction.

### P2.4 SwiftUI structural perf [A+B]
- `ContentView.body`: 16+ nested `AnyView(...).onReceive` wrappers defeat structural diffing; observes six observable objects so any chatty `@Published` re-evaluates the heavy body. `ContentView.swift:2461-2730,1464-1471`. [A]
- Autosave fingerprint blocks main up to 0.5-2s every 8s on the conversation sync read. `AppDelegate.swift:3801-3813`. [B]
- (spec — verify first) `SurfaceMetricsSampler.swift:346` may understate sidebar CPU% ~41.7× (missing `mach_timebase_info` conversion). [B]

### P2.5 Skills & docs accuracy sweep [A+B]
One batch pass; the skill is the agents' contract. Highlights (full lists in both source docs):
- Wrong commands agents will run: `c11 install` section (removed in C11-17 — delete, don't revive) [A+B]; `docs/socket-api-reference.md` documents four nonexistent commands and is entirely pre-rename — rewrite or delete (CONTRIBUTING links it as canonical) [A+B]; SKILL.md says resume = `cc --resume <id>`, actual is `claude --dangerously-skip-permissions --resume <id>` [A]; `set-agent --task` partial-write example errors [B].
- Internal contradiction: SKILL.md "open reuses the browser surface" vs "open stacks a new surface each time". [A]
- `references/orchestration.md:129` jq path yields null (`.caller.workspace_ref` is correct); `api.md:140` caller-pane recipe greps the *focused* block — the exact wrong-target failure it warns about; `api.md:53` documents a socket override chain that isn't real. [B]
- Version-history claims wrong (0.44-0.46 refs at 0.51.0); journey-style backstory violating the timeless-skill rule. [A+B]
- `docs/c11-mailbox-guide.md:13` documents the wrong state dir (`c11mux` vs `c11`). [B]
- `skills/MANIFEST.json` missing `c11-hotload` + `release`; schema key still `c11mux_skill_manifest_schema`. [A+B]
- **Correction from this merge:** B's item "SKILL.md empty-`--surface` footgun note is stale" is itself wrong — keep the footgun documented until P0.2 lands, then update both.
- CONTRIBUTING.md misquotes test policy; points at 0-byte TODO files; PHILOSOPHY.md references nonexistent ROADMAP.md. [B]
- After every skill edit: `scripts/sync-installed-skills.sh` (HARD RULE).

### P2.6 Silent-failure ergonomics pass [A theme 3, corroborated by B items]
Recurring shape: `try?`-swallowed config/decode errors (DefaultAgentConfig field decodes, unknown `defaultAgent` ignored with no log, project `.c11/agents.json` parse failures), fire-and-forget log writes (mailbox dispatch log), timeouts that discard results silently (terminate-path suspend wait), unknown mailbox handler indistinguishable from I/O error. Surface these as DEBUG logs / non-zero exits — sharply cuts future debugging time.

### P2.7 Lifecycle / teardown leaks [A+B]
Block-based NotificationCenter observers never removed (TabManager, AppDelegate, GhosttyTerminalView); `browser.download.wait` leaks its observer on timeout; portal teardown relies solely on `willCloseNotification`; per-markdown-panel app-wide mouse monitors; FSEvents teardown races (spec). Batch as one teardown-discipline pass.

### P2.8 Metadata store consistency [A]
64KiB cap excludes the `sources` sidecar; char-vs-byte cap inconsistency with the mailbox layer; mixed sync/async queue ordering races in `removeSurface`/`pruneWorkspace`; `enforceSizeCap` can silently drop a canonical key on restore; `sameJSONValue` `1`==`true` bridging dedupes type-changing writes.

### P2.9 Hot-path data races (lower likelihood than P0.4 but same genre) [B]
`applyDefaultBackground` mutates shared state from the Ghostty callback thread; `UpdateDriver.lastFeedURLString` cross-thread without locking; (spec) `performOnMain` main.sync from Ghostty callbacks.

---

## P3 — Cleanup, cosmetics, low-risk debt

- **Localization batch:** hardcoded English NSAlert (also breaks close-confirmation *detection* in non-English locales — the one functional loc bug, fix first), `.safeHelp` literals, relative-time strings, worktree chip labels, `"Terminal"` default title, InfoPlist.xcstrings gaps, needs_review keys. [A+B]
- **Dead code:** `Sources/TerminalView.swift` (legacy SwiftTerm path, zero refs — delete), `TabManager.startSearch` unreachable block, browser dialog dead code w/ uninvoked responders, `captureLsof` ignored param. [B]
- **Naming residue (sequence AFTER P0.1):** `~/.cmuxterm/` hook-state path, `discoverSockets` cmux-prefix filter, `Resources/bin/open` cmux-era gating, UserDefaults `cmux` migration keys (note: renaming re-runs migration — likely keep), `web/app/env.ts` CMUX_FEEDBACK_*, daemon go.mod module path, user-facing "cmux" strings in window titles/notifications, `homebrew-cmux` module dir + stale cask pin. [A+B]
- **Script polish:** `sanitize_bundle` literal-backslash sed never fires; tags with `/` break app-copy; cleanup-pkill suggestion uses mismatched slug; launchd plist hardcodes `/Users/atin`; `setup.sh` cache key needs `C11_*` read; relative `rm -rf` in download-prebuilt; `find | head` SIGPIPE under pipefail; bump-version/appcast quoting. [A+B]
- **Test polish:** blanket 3-attempt retry masks flakes (log counts); wall-clock benchmark assertions; `Thread.sleep` as synchronization; `/Users/atin` fixtures; manual scripts in automated dirs; `test_signals_auto.py` tests macOS not c11. [B]
- **Minor security hardening:** non-constant-time socket password compare; socket perms applied after bind; mailbox symlink-follow (0700 dir, low risk); single-quote attr escaping; `jsStringEscape` backtick omission; predictable hooks tempfile in `Resources/bin/claude` (use mktemp); address-bar `postMessage("*")`; (spec) entitlements over-grant — test release build without `allow-unsigned-executable-memory`. [A+B]
- **Misc UX/robustness:** duplicate-shortcut detection absent; markdown file-watch gives up after ~3s; Mermaid renderer 15s serial blocks + undrained stderr; `read_screen --scrollback` clobbers the user pasteboard mid-copy; notification tab-reorder no-op for non-frontmost windows; sweepStaleAgentPIDs clears all workspace notifications; AgentDetector dropped kicks during in-flight scans + path-substring misclassification (spec); opencode resume uses the headless runner (spec); UpdateDriver skips `.installing` UI; CLI usage/exit-code contract (`unknowncmd --help` exits 0, split streams); 120ms CLI tax (also in P1.3); `=`-form global flags fall through to `looksLikePath`. [A+B]
- **Satellites:** web i18n MISSING_MESSAGE on wall-of-love (18 locales); feedback route rate-limit fails open off-Vercel; dual lockfiles; `c11d-remote` trailing-flag drop; computer-use runner tool declaration (spec); upstream-triage paused mid-sweep — decide resume or archive. [B]

---

## Already fixed / verified clean (do not re-litigate)

- Legacy `~/.c11/agents.json` A-button pin bug — fixed on HEAD (PR #217). Residual spec-level sharp edge: a valid v2 file with explicit `defaultAgent` overrides Settings for every cwd under `~`. [A+B agree]
- Verified clean by B: all 116 v2 CLI↔server method parity; `dlog` gating in terminal layer; SurfaceSearchOverlay layering contract; TabItemView Equatable contract; C11-105 fix intact; submodule pointers ancestors of remote main; browser JS-injection escaping (`v2JSONLiteral`); drawbridge `pull_request_target` hardening; Sentry DSN / PostHog key are public-by-design (A listed this as Low — B's adjudication is correct, drop it).
- Installed-skill sync state on this machine: no content drift. [A]
