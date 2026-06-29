# C11-153: pi exact-session resume (PiScraper + PiStrategy)

**Delegator:** inline-full (one Claude session, all hats; headless plan/code review between phases).
**Branch:** `feat/c11-153-pi-resume`, based on `main` (C11-152 already merged as PR #273 / `e6edf9513`). No cross-branch dependency at merge time — C11-152's scrape-capture seam is in `main`.

## Goal

Light up **exact-session** resume for `pi` by adding the two missing per-kind pieces to C11-152's live scrape-capture pipeline:

1. `PiScraper` — the pull rail over `~/.pi/agent/sessions/`.
2. `PiStrategy` — the scrape-primary + ambiguity-aware resolver, mirroring `CodexStrategy`, whose `resume` types `pi --session '<id>'`.

Then register both in the v1 registries and flip the `pi` manifest's `hasConversationStrategy` flag — in **one commit** so `AgentManifestTests.testConversationStrategyPresenceParity` never sees drift.

## Verified context (read during planning)

- **Pipeline pairs by kind.** `ScrapeCapturePipeline.captureRefs` (`Sources/Conversation/ScrapeCapturePipeline.swift`) looks up `scrapers.scraper(forKind:)` and `strategies.strategy(forKind:)` for each restore context. Registering a `pi` scraper + a `pi` strategy in the two `v1` registries is the entire wiring — no pipeline edit needed.
- **Forward only `.scrape` provenance.** The pipeline keeps a ref only when `ref.capturedVia == .scrape`. `CodexStrategy.capture` stamps `.scrape` on real disk matches and returns the wrapper-claim placeholder otherwise — mirror that exactly.
- **Filename grammar.** pi sessions are `~/.pi/agent/sessions/<cwd-slug>/<ISO-ts>_<uuid>.jsonl`. The ISO timestamp uses dashes/`T` (no underscore), so the session id is the substring **after the last `_`** of the filename stem. `isValidConversationUUID` accepts the 8-4-4-4-12 hex shape — a UUIDv7 is still that shape, so the existing validator is correct for pi (no new grammar needed).
- **Recursive lister exists.** `ConversationFilesystem.listSessionsRecursivelyByMtime` already walks one+ level deep, sorts newest-first by mtime, caps at `max`, and is stat-only (privacy contract). `CodexScraper` already uses it for the year/month/day layout; pi's `<cwd-slug>/` layout is the same shape.
- **Manifest dual-rail.** The `pi` manifest keeps `resume: .fixed("pi -c\n")` (the phase-1 best-effort restart rail). `hasConversationStrategy` is an independent flag that the parity test ties to `ConversationStrategyRegistry.v1.contains("pi")`. Codex is the precedent: `resume: .fixed("codex resume --last\n")` AND `hasConversationStrategy: true`. So I flip only `hasConversationStrategy` → `true`; I do **not** touch `resume:` (keeps `testResumeCommandReproducesPhase1` green).
- **Test target placement.** `ScrapeCapturePipelineTests` and `AgentManifestTests` are members of **`c11LogicTests`** (safe `c11-logic` scheme). The existing `ConversationScraperTests`/`ConversationStrategyTests` are host-bound (`c11Tests`). I put the new pi tests in **`c11LogicTests`** so they run locally under the safe scheme, with locally-declared mocks (the host-target `MockFS` is not reachable from the logic target — mirror `ScrapeCapturePipelineTests`'s local-mock pattern).

## Implementation

### 1. `Sources/Conversation/Scrapers/PiScraper.swift` (new)
- `struct PiScraper: ConversationScraper`, `kind = "pi"`, injected `filesystem` + `maxCandidates` (default 16), mirroring `CodexScraper`.
- `sessionsRoot()` → `~/.pi/agent/sessions/` (nil if no HOME).
- `candidates(cwd:)`: `listSessionsRecursivelyByMtime(root, extensionFilter: "jsonl", max:)`, then per entry: drop `.jsonl`, take substring after last `_`, `guard isValidConversationUUID(id)`, build `ScrapeCandidate(id:filePath:mtime:size:cwd:)`. A filename with no `_`, or whose post-`_` segment isn't a UUID, is dropped by the validator.

### 2. `Sources/Conversation/Strategies/Pi.swift` (new)
- `struct PiStrategy: ConversationStrategy`, `kind = "pi"`. Copy `CodexStrategy`'s `capture` (cwd + claim-time + activity-floor filter; empty → wrapper-claim placeholder; sort newest-first; >1 → `.unknown` + `diagnosticReason: "ambiguous: N candidates; chose newest"`; 1 → `.alive`).
- `resume(ref:)`: identical guards (placeholder→skip, `.unknown`→skip "ambiguous", tombstoned/unsupported→skip, invalid grammar→skip), then `text = "pi --session \(conversationShellQuote(ref.id))"`, `.typeCommand(text:, submitWithReturn: true)`.
- `isValidId` → `isValidConversationUUID`.

### 3. Registries
- `ConversationScraperRegistry.v1`: append `PiScraper(filesystem: filesystem)`.
- `ConversationStrategyRegistry.v1`: append `PiStrategy()`.

### 4. Manifest
- `Sources/AgentManifest.swift` pi entry: `hasConversationStrategy: false` → `true`. Leave `resume: .fixed("pi -c\n")` unchanged. Update the stale comment that calls the JSONL scraper "a tracked follow-up" → now shipped.

### 5. Tests — `c11Tests/PiConversationTests.swift` (new, **c11LogicTests** target)
Local `MockFS` + local `MockScraper` (copy the shapes from `ConversationScraperTests`/`ScrapeCapturePipelineTests`). Cases:
- `testPiScraperExtractsUUIDAfterLastUnderscore` — fixture `2026-06-28T12-30-45_<uuid>.jsonl` → candidate id == uuid.
- `testPiScraperRejectsNonUUIDTail` — `...._not-a-uuid.jsonl` and a stem with no `_` → dropped.
- `testPiScraperEmptyWhenDirMissing`.
- `testPiScraperStampsCwd`.
- `testPiSingleCandidateResumesExactSession` — via `ScrapeCapturePipeline` with `pi` registered: 1 candidate → `.scrape`/`.alive` ref, `PiStrategy().resume` → `.typeCommand("pi --session '<uuid>'", submit: true)`.
- `testPiAmbiguousCandidatesSkip` — 2 candidates same cwd → `.unknown` → `resume` skip "ambiguous".
- `testPiPlaceholderSkips`.

### 6. pbxproj (xcodeproj gem)
- Add `PiScraper.swift` + `Pi.swift` to the **c11** target Sources phase (group `Sources/Conversation/Scrapers` + `Strategies`).
- Add `PiConversationTests.swift` to the **c11LogicTests** target Sources phase.
- Gate: `xcodebuild -list` parses; `c11` Swift source count +2, `c11LogicTests` +1; expect gem-normalized whitespace churn (per CLAUDE.md, don't fight it).

## Validation (load-bearing — `pr_open` blocked until live resume observed)
1. `c11-logic` scheme, narrowed: `-only-testing:c11LogicTests/PiConversationTests` + `:c11LogicTests/AgentManifestTests` (the parity test). NEVER the host scheme.
2. Live exact-resume: `./scripts/reload.sh --tag c11-153`; launch `pi` in a surface; note the newest `~/.pi/agent/sessions/<slug>/<ts>_<uuid>.jsonl`; quit tagged c11; relaunch `./scripts/launch-tagged-automation.sh c11-153 --qa resume`; confirm the restored surface types `pi --session <same uuid>`. `c11 state verify` is the dry-run oracle. Attach the uuid + typed command + oracle output as a validation note.

## Plan-Review Cycle 1 Resolutions (AUTHORITATIVE)

Plan-review verdict: **PASS** (artifact `art_01KW8ESEKP8S3KWHN4W7HRRHQ3`). Five MINOR items, resolved:

1. **Branch base (MINOR).** Verified: worktree HEAD == `origin/main` == `e6edf9513` (C11-152 merge), pipeline seam present. The reviewer's stale-local-`main` risk does not apply to this worktree. No action beyond this confirmation.
2. **`ConversationScraperRegistry.v1` is a `static func`, not a `static let` (MINOR).** Confirmed. The `PiScraper(filesystem: filesystem)` edit goes **inside the array literal of `static func v1(filesystem:)`** (alongside `ClaudeCodeScraper`/`CodexScraper`). The `PiStrategy()` edit goes in the `static let v1` array on the strategy side. Use the `filesystem` param on the scraper side.
3. **`testPiPlaceholderSkips` must build the placeholder ref directly (MINOR).** pi has no wrapper-claim rail, so `capture` returns `nil` (not a placeholder) when there are no scrape candidates — correct behavior. The test will construct a placeholder `ConversationRef` explicitly and assert `resume` skips it; a file comment notes pi has no claim rail so the branch only guards future wiring.
4. **Ambiguity cwd-filter is mtime-only, mirroring codex (MINOR).** In scope and consistent with `CodexScraper`. Keep as planned; no scope expansion. (Possible future enhancement noted: pi's slug encodes cwd and could be parsed for sharper filtering — out of scope here.)
5. **Validator doc-comment says "UUID v4" (MINOR, cosmetic).** Confirmed validator accepts v4 and v7 (8-4-4-4-12 hex, no version nibble). I will NOT touch `Strategy.swift` for a cosmetic comment (keeps the diff tight to pi). Skipped.

## Impl-Time Deviation (AUTHORITATIVE — supersedes plan §1 PiScraper + Plan-Review item 4)

**What changed:** `PiScraper` does **cwd-scoped lookup**, not a literal `CodexScraper` whole-tree mirror. When the surface cwd is known, it lists only that cwd's slug directory (`~/.pi/agent/sessions/<slug>/`); with no cwd it falls back to whole-tree top-N.

**Why (this is load-bearing, not gold-plating):** The plan and Plan-Review item 4 accepted the codex-mirror's no-op cwd filter as "consistent with codex." That equivalence is false: **codex narrows candidates by its wrapper-claim time floor; pi has no wrapper and no hook, so it has no floor at all.** With the whole-tree mirror, every restore on a machine with >1 pi session (this machine has 17 session dirs) yields multiple candidates that all pass `PiStrategy.capture`'s (no-op) cwd filter → `state = .unknown` → resume **skips**. Net: pi would *never* positively resume in practice, which fails the ticket's explicit acceptance criterion ("live pi resumes exact session"). cwd-slug scoping is the minimum change that makes exact resume actually fire, and it is faithful to pi's own model (pi resolves sessions by cwd via `SessionManager.list(cwd, …)`).

**Faithfulness:** Slug encoding mirrors pi's `migrations.js` exactly (`"--" + cwd.drop-leading-slash with [/\\:]→"-" + "--"`, dots preserved) — verified against real on-disk dir names and tested (`testPiSessionSlugMatchesPiEncoding`). PiStrategy remains a faithful CodexStrategy mirror; the refinement is scraper-only. Within a single cwd, multiple sessions still → ambiguous → skip (the legitimate codex-like case).

**Reversibility:** Contained to `PiScraper.candidates`. Revert = restore the whole-tree lister. Flagged for Orchestrator/MV visibility.

## Risks
- **UUIDv7 vs v4 validator** — confirmed: both are 8-4-4-4-12 hex, validator accepts. No regex change.
- **No live `~/.pi/` on the machine** — if `pi` has never run, the live step needs a real `pi` session first (launch `pi`, send a prompt, let it write a JSONL). Plan accounts for this in the validation sequence (launch `pi` before the resume cycle).
