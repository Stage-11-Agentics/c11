# C11-151: opencode exact-session resume via plugin rail — Plan

**Delegator:** inline-full (one Claude session: plan / impl / review). Branch `feat/c11-151-opencode-resume` off `main`. Phase A of `docs/agent-exact-resume-plan.md` (opencode only; independent of pi/omp Phase B).

## Goal

When the operator runs `opencode` inside a c11 terminal surface and later quits + relaunches c11 with session resume, the restored surface must re-attach to the **exact** prior opencode session — typing `opencode --dangerously-skip-permissions -s <ses_id>` (cd-prefixed into the session's project dir) — rather than launching fresh.

## Verified facts (checked against the live machine 2026-06-28/29)

- opencode 1.17.5. Session store: SQLite at `~/.local/share/opencode/opencode.db`, table `session`.
- Real columns (NOT the SDK camelCase): `id` (PK), `parent_id`, `directory`, `time_updated` (ms epoch), `time_created`. The WIP scraper already queries `id, time_updated, directory` — column names are correct.
- **Id grammar: `ses_` + 26 chars, base62.** All 131 local rows match `^ses_[0-9A-Za-z]{26}$` (0 exceptions, all length 30). **83 of 131 contain `I/L/O/U` after `ses_`** → the WIP `feat/opencode-resume` Crockford-base32 regex (`[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]`) would **wrongly reject 83 real sessions**. Confirmed example `ses_0fda89a49ffeLHwJXtrxnn4X6g`. **The fix to base62 is load-bearing, not cosmetic.**
- Sub-agent sessions have `parent_id` set; root sessions have `parent_id = NULL`. The plugin must push **only root sessions** (`!info.parentID`) so a sub-agent's session id never overwrites the surface's primary conversation.
- Plugin event shape (`@opencode-ai/sdk` `EventSessionCreated`): `event.type === "session.created"`, `event.properties.info` is a `Session` with `.id` and `.directory` (and `.parentID`).
- Resume flag: `opencode -s <id>` (verified in plan doc). We type `opencode --dangerously-skip-permissions -s <id>`.
- `c11 conversation push` (handler `v2ConversationPush`, `TerminalController.swift:10243`) validates `--id` via `strategy.isValidId(id)` when a strategy is registered for the kind. So installing the real base62 `OpencodeStrategy.isValidId` makes the CLI reject malformed pushes — desired.
- opencode-plugins is **not** in `skills/MANIFEST.json` `installable` → editing `c11-notify.js` needs **no** `sync-installed-skills.sh` run.
- `OpencodeStrategy()` is **already** registered in `StrategyRegistry.v1`, and the opencode manifest **already** has `hasConversationStrategy: true`. The golden parity test (`AgentManifestTests.testConversationStrategyPresenceParity`) is already satisfied — I keep both as-is; replacing the placeholder body doesn't change registration. No parity flip needed (the boot's item 5 is a no-op safeguard here, but I verify the test stays green).

## Architecture context

Two parallel resume systems exist; this ticket targets the **ConversationStrategy** system (push/scrape rail), not the legacy `AgentManifest.resume` (`ResumeSpec`) restart-registry:

- **Push rail** (live): a hook/plugin calls `c11 conversation push` → `ConversationStore` → persisted on snapshot. On restore, `Workspace.pendingRestartPlans` reads each surface's active `ConversationRef`, hands it to `strategy.resume(ref:)`, and types the returned command. This is the rail opencode gets via its plugin.
- **Scrape rail** (`Sources/Conversation/Scrapers/`): a unit-tested seam **not yet wired into live capture** (Phase B). `OpencodeScraper` lands here as crash-recovery infrastructure + the backing for `transcriptExists`, but live capture stays push-only for Phase A.

The project dir flows as `ConversationRef.cwd` (pushed via `--cwd <directory>`); `OpencodeStrategy.resume` builds the `cd '<cwd>' && …` prefix from `ref.cwd`. The reserved metadata keys (`opencode.session_id` / `opencode.session_project_dir`) are added for parity with the `claude.*` reservation and defense-in-depth at the metadata boundary (they guard any future writer of those keys); the live resume path reads `ref.cwd`, not the metadata key.

## Work items

### 1. Reserved keys — `Sources/WorkspaceMetadataKeys.swift`
- Add `opencodeSessionId = "opencode.session_id"` and `opencodeSessionProjectDir = "opencode.session_project_dir"` public statics (port WIP, **rewrite doc comments** to say base62, not Crockford/ULID).
- Add `opencodeSessionIdPattern` = `^ses_[0-9A-Za-z]{26}$` (**base62**, NOT Crockford) and `isValidOpencodeSessionId(_:)`.
- Add `isValidOpencodeSessionProjectDir(_:)` delegating to `isValidClaudeSessionProjectDir`.

### 2. Reserved-key validation — `Sources/SurfaceMetadataStore.swift`
- Add both keys to the `reservedKeys` array.
- Add `case "opencode.session_id"` (string + `isValidOpencodeSessionId`) and `case "opencode.session_project_dir"` (string + `isValidOpencodeSessionProjectDir`) to `validateReservedKey`.
- **Do NOT** port the WIP's `opencode-run` addition to `canonicalTerminalTypes` — out of scope and risks the manifest parity test.

### 3. Plugin handler — `skills/opencode-plugins/c11-notify.js`
- Add `case "session.created":` to the event switch:
  - `const info = event.properties?.info;`
  - guard `info?.id` present **and** `!info.parentID` (root sessions only).
  - `await c11(["conversation", "push", "--kind", "opencode", "--id", info.id, "--source", "hook", "--state", "alive", ...(info.directory ? ["--cwd", info.directory] : [])]);`
  - dependency-free, no-ops if c11 absent (existing `c11()` wrapper). No surface targeting needed — the c11 CLI resolves the calling surface from its env/socket (same as the existing `set-metadata` calls).

### 4. `OpencodeStrategy` (replace placeholder) — `Sources/Conversation/Strategies/Opencode.swift`
- `capture`: push-primary (`inputs.push` if non-placeholder) → scrape-candidate fallback (`inputs.scrapeCandidates.first` validated via `isValidOpencodeSessionId`, `state = .unknown`) → `inputs.wrapperClaim`. Mirrors `ClaudeCodeStrategy`.
- `resume`: skip placeholder; skip `.unknown/.tombstoned/.unsupported`; for `.alive/.suspended` validate `isValidOpencodeSessionId(ref.id)` then build `opencode --dangerously-skip-permissions -s <quoted id>`, prefixing `cd <quoted cwd> && ` when `ref.cwd` is present **and** `isValidOpencodeSessionProjectDir(cwd)`. Use `conversationShellQuote`.
- `isValidId` → `isValidOpencodeSessionId`.
- `transcriptExists(for:filesystem:)` → delegate to `OpencodeScraper(homeDirectory: filesystem.homeDirectory).sessionExists(id: ref.id)`: `nil` when DB unavailable / id invalid (can't verify), `true`/`false` when the DB can be read. This honors the seam's three-valued contract.

### 5. `OpencodeScraper` (port WIP, fix grammar) — `Sources/Conversation/Scrapers/OpencodeScraper.swift`
- Port the WIP file; **rewrite the Crockford/ULID doc comments to base62**; the `isValidOpencodeSessionId` it calls is now the base62 one.
- Add `sessionExists(id:) -> Bool?`: validate id (nil if bad) → open `databasePath()` readonly (nil if absent/unopenable → can't verify) → `SELECT 1 FROM session WHERE id = ? LIMIT 1` → `SQLITE_ROW` true, `SQLITE_DONE` false, any error → nil. 2s busy-timeout, never crashes.
- Keep `scrape(cwd:) -> [ConversationRef]` for future Phase-B/crash-recovery use.
- New Swift file → **add to the `c11` app target** in `GhosttyTabs.xcodeproj` via the `xcodeproj` Ruby gem (the strategy/scraper dir is already in the target; confirm membership). `import SQLite3` (system module, same as ClaudeCodeScraper has no SQLite but the build links libsqlite3 implicitly via the SDK — verify compile).

### 6. Registry / manifest — `Sources/Conversation/StrategyRegistry.swift`, `Sources/AgentManifest.swift`
- Already wired (`OpencodeStrategy()` in `v1`, `hasConversationStrategy: true`). Verify no change needed; confirm `AgentManifestTests` parity test stays green.

### 7. Tests (`c11LogicTests` target — SAFE scheme `c11-logic`)
- `isValidOpencodeSessionId`: accepts real ids incl. those with `I/L/O/U` (regression guard for the exact bug — e.g. `ses_0fda89a49ffeLHwJXtrxnn4X6g`); rejects wrong length, wrong prefix, embedded shell metachars/newlines, Crockford-only assumption.
- Reserved-key validation: store accepts a valid `opencode.session_id` / `opencode.session_project_dir`, rejects malformed (wrong grammar, non-string, non-absolute path, embedded quote).
- `OpencodeStrategy.resume`: placeholder→skip; `.unknown`→skip; valid `.alive` ref with cwd → `cd '<cwd>' && opencode --dangerously-skip-permissions -s '<id>'`; without cwd → no cd prefix; invalid id → skip.
- `OpencodeStrategy.capture`: push-primary wins; scrape fallback yields `.unknown` ref; wrapperClaim fallback.
- `OpencodeScraper.sessionExists` + `scrape`: build a **temp** SQLite DB with a `session` table + rows (pointing `homeDirectory` at a temp dir laid out as `.local/share/opencode/opencode.db`), assert `sessionExists` true for present id, false for absent id (DB present), nil for absent DB; `scrape(cwd:)` returns rows filtered by directory, newest-first, grammar-validated. This is a real runtime/behavioral test (writes + reads a live SQLite file), satisfying the test-quality policy.

### 8. Validation (LOAD-BEARING gate)
- Fast local: `xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug -destination "platform=macOS" test -only-testing:c11LogicTests/<new classes>`. **Never** the host `c11-unit`/bare `xcodebuild test`.
- Live exact-resume: tagged build (`./scripts/reload.sh --tag c11-151`), launch `opencode` in a terminal surface, note its `ses_` id (SQLite or `opencode session list`), quit tagged c11, relaunch with `./scripts/launch-tagged-automation.sh c11-151 --qa resume`, confirm the restored surface types `opencode … -s <same ses_id>` and `session.time_updated` advances. `c11 state verify` as the dry-run oracle. Attach the observed evidence to the ticket. **`pr_open` blocked until live resume is OBSERVED.**

## Risks / watch-items
- **Regex is the whole point.** Any reintroduction of the Crockford alphabet silently breaks 63% of real sessions. Tests pin base62 explicitly with I/L/O/U ids.
- **Sub-session capture.** Without the `!parentID` guard, a sub-agent `session.created` would clobber the surface's primary session id. Guard + note in plugin comment.
- **`transcriptExists` three-valued contract.** Returning `false` when the DB is merely absent would wrongly demote a resumable ref to `.unknown`; `sessionExists` returns `nil` in that case.
- **SQLite linkage in c11-logic.** `OpencodeScraper` is compiled into the `c11` target which `c11-logic` depends on; confirm `import SQLite3` links cleanly (first warm build may pay the app-build cost).
- **pbxproj discipline.** New file added via `xcodeproj` gem; gate on `xcodebuild -list` + file-membership ref-count symmetry, not the line diff.

---

## Plan-Review Cycle 1 Resolutions (AUTHORITATIVE)

Plan-review (single mode, headless) verdict: **PASS**. Artifact `art_01KW8C7NK320H8WKE2HPCYJXTH`. Four findings, all folded:

### R1 [MAJOR] — Live gate depends on the *installed* plugin copy; refresh + verify it as a precondition
The live acceptance test reads `~/.config/opencode/plugins/c11-notify.js` (the copy opencode actually auto-loads), NOT the repo source. Verified: the live copy today is 2103 bytes, dated 2026-06-25, and **has no `session.created` handler** (`grep -c` = 0). It is c11-managed (sidecar `c11-notify.c11-plugin.json` present). `SkillInstaller.installPlugins` sources from the **app bundle's** `skills/opencode-plugins/`, triggered via the Agent Skills settings flow — it is NOT auto-run on every launch. **Resolution:** Make "the updated handler is live in `~/.config/opencode/plugins/c11-notify.js`" an explicit precondition of the live gate. After the tagged build, install the plugin from the (bundled/worktree) source into the live path and confirm with `grep -c "session.created" ~/.config/opencode/plugins/c11-notify.js` ≥ 1 before the quit+relaunch. The `source_sha256` sidecar differs once the handler is added, so a normal (non-force) reinstall overwrites the stale copy rather than skipping it.

### R2 [WATCH→RESOLVED] — `--dangerously-skip-permissions` is `opencode run`-only; interactive resume uses bare `opencode -s <id>`
Verified against `opencode 1.17.5 --help`: the interactive TUI default command exposes `-s/--session <id>` and `-c/--continue` but **not** `--dangerously-skip-permissions` — that flag belongs to `opencode run`. Exact-session resume must re-attach the *interactive* TUI, so the resume command is **`cd '<dir>' && opencode -s '<id>'`** (drop `--dangerously-skip-permissions`; it is invalid for the interactive command and the operator drives permissions live on a resumed surface). This overrides the ticket-description text "opencode --dangerously-skip-permissions -s '<id>'". The `-s` flag is confirmed valid for the interactive command.

### R3 [MINOR] — Parity test is host-scheme/CI-verified, not local
`testConversationStrategyPresenceParity`, `ConversationStrategyTests`, and `WorkspaceConversationResumeTests` live in `c11Tests` (host `c11-unit` scheme), not `c11LogicTests`. Since opencode already has `hasConversationStrategy: true` and is already in `StrategyRegistry.v1`, parity is **unchanged** by this ticket — I verify no manifest/registry edit is needed and note the parity check is **CI-verified only**. New `OpencodeStrategy.resume`/`capture`/`OpencodeScraper` tests go in `c11LogicTests` (the `c11` target it depends on exports the types) — accepting a documented split from the existing host-scheme `ConversationStrategyTests`.

### R4 [MINOR] — Drop the muddled SQLite-linkage justification
Remove the `ClaudeCodeScraper` comparison from the SQLite-linkage risk (it's `stat`-based, irrelevant to SQLite). The real basis: `import SQLite3` resolves against the macOS SDK system module and auto-links `libsqlite3.tbd`, same as the WIP `OpencodeScraper` already does. The `c11-logic` compile in the validation step is the proof.

**Net code deltas vs. the original plan:** (a) resume command drops `--dangerously-skip-permissions` → `cd '<dir>' && opencode -s '<id>'`; (b) validation adds an explicit "install + grep-verify the plugin in `~/.config/opencode/plugins/`" precondition step before quit+relaunch. No change to reserved keys, scraper, or registry items.
