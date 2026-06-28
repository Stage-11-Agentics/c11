# Exact-session resume for opencode / pi / omp — follow-up plan

**Status:** planned 2026-06-28, after the agent-registry landed (PR #271). The registry made opencode, pi (`pi`), and oh-my-pi (`omp`) first-class with **best-effort** resume (restart-on-reboot: `pi -c`, opencode/omp relaunch). This doc scopes **exact-session** resume — reattaching to a *specific* prior session.

## The architectural finding (why this isn't just "add a scraper")

c11's conversation store captures sessions from a **push rail** (a hook/plugin calls `c11 conversation push`). The **scrape rail** (`Sources/Conversation/Scrapers/`) exists as a unit-tested seam but **is not invoked anywhere in live code** — `grep` for scraper call sites in `Sources/` returns 0, true even for claude/codex. So:

- A bare `PiScraper`/`OmpScraper` would be **dead code** until the live scrape-capture pipeline exists.
- **opencode** can get exact-resume *without* that pipeline, via its **plugin** push rail.
- **pi/omp** have no hook/plugin rail c11 can use, so they *require* the scrape pipeline.

## Verified facts (checked against a real machine, 2026-06-28)

| Agent | Session store | Id format | Resume flag | Capture rail available |
|-------|---------------|-----------|-------------|------------------------|
| opencode | SQLite `~/.local/share/opencode/opencode.db`, `session` table (`id, directory, time_updated`) | `ses_` + **26 base62** → `^ses_[0-9A-Za-z]{26}$` | `opencode -s <id>` | **plugin** `session.created` (c11 already ships `c11-notify.js`) |
| pi | JSONL `~/.pi/agent/sessions/<cwd-slug>/<ISO-ts>_<uuid>.jsonl` | UUIDv7 (in filename, after `_`) | `pi --session <id>` | **scrape only** (no c11 hook) |
| omp | JSONL `~/.omp/agent/sessions/<cwd-slug>/<ISO-ts>_<uuid>.jsonl` (+ per-session subdir of `*.log`) | UUIDv7 (in filename) | `omp --resume=<id>` | **scrape only** (no c11 hook) |

⚠ **Bug in the `feat/opencode-resume` WIP branch:** its `isValidOpencodeSessionId` regex is Crockford-base32 (`[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]`), which **rejects valid ids** containing `I/L/O/U` (e.g. `ses_0fda89a49ffeLHwJXtrxnn4X6g`). Use base62: `^ses_[0-9A-Za-z]{26}$`.

## Phased plan

### Phase A — opencode exact-resume (plugin rail, contained)
1. **Reserved keys** (port from `feat/opencode-resume`, FIX the regex to base62): `opencode.session_id`, `opencode.session_project_dir` in `WorkspaceMetadataKeys.swift` + `SurfaceMetadataStore.validateReservedKey`.
2. **Plugin handler**: extend `skills/opencode-plugins/c11-notify.js` with a `session.created` handler → `c11 conversation push --kind opencode --id <ses_…> --source hook --state alive --cwd <directory>`.
3. **`OpencodeStrategy`** (replace placeholder): `resume` → `cd '<project_dir>' && opencode --dangerously-skip-permissions -s '<id>'` (cd-prefix when `opencode.session_project_dir` present); `transcriptExists` → SQLite stat; `isValidId` → base62 grammar.
4. **`OpencodeScraper`** (SQLite, port WIP) as the crash-recovery fallback for `transcriptExists`.
5. Tests + **live** validation: launch opencode in a tagged build, quit, relaunch, confirm it resumes the exact `ses_` session (`c11 state verify` is the dry-run oracle; then a real snapshot/restore).

### Phase B — live scrape-capture pipeline (unlocks pi/omp, + codex)
1. Wire scrapers into the capture path: at surface restore, invoke the per-kind scraper → `ScrapeCandidate`s → `strategy.capture(inputs:)` → `store.applyScrape`. This is the missing seam (architectural; benefits codex too).
2. **`PiScraper` / `OmpScraper`** (JSONL): walk `~/.<k>/agent/sessions/` recursively for `*.jsonl`, extract the UUID after the last `_`, validate via `isValidConversationUUID`. (Skip omp's per-session `*.log` subdir files.)
3. **`PiStrategy` / `OmpStrategy`** (mirror `CodexStrategy`'s scrape-primary + ambiguity policy): resume → `pi --session <id>` / `omp --resume=<id>`.
4. Register all three strategies in `ConversationStrategyRegistry.v1`; flip the manifests' `hasConversationStrategy` to `true` (the golden test enforces the match).
5. Tests + live snapshot/restore validation per agent.

## Execution note
Phases A and B (and the three agents within B) are largely independent — a good fit for the lattice-orchestrator (one delegator per slice, all targeting one branch; integrate the shared files: `StrategyRegistry`, reserved keys, the capture seam, pbxproj). Loopy snapshot/restore validation per agent is the gate — "I saw it resume," not "it should."
