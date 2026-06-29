# Code Review: C11-151 — opencode exact-session resume (own-reviewer fallback)

**Reviewer:** delegator-c11-151 (own-reviewer fallback). The headless
`lattice code-review --mode single --base origin/main` exited 0 but produced
a **vacuous artifact** ("Diff is empty — no changes detected"): the CLI
resolved the diff range against the `LATTICE_ROOT` main checkout (on `main`,
without this branch's commit) rather than the worktree branch. Per the
delegator HARD RULE, I executed the own-reviewer pass against the real range
`git diff origin/main..HEAD` (7 files, +740/-11, commit `2068d63ff`).

## Verdict: **PASS** — no Critical/Major. Ready for the live validation gate.

## Scope reviewed
- `Sources/WorkspaceMetadataKeys.swift` — reserved keys + base62 grammar
- `Sources/SurfaceMetadataStore.swift` — reserved-key validation cases
- `skills/opencode-plugins/c11-notify.js` — `session.created` push handler
- `Sources/Conversation/Strategies/Opencode.swift` — real strategy
- `Sources/Conversation/Scrapers/OpencodeScraper.swift` — SQLite reader
- `GhosttyTabs.xcodeproj/project.pbxproj` — file membership
- `c11Tests/OpencodeResumeTests.swift` — 26 tests (all green on c11-logic)

## Correctness (the load-bearing items)
- **base62 grammar is correct and verified empirically.** `^ses_[0-9A-Za-z]{26}$`
  matches all 131 live `session` rows; 83 contain I/L/O/U which the WIP
  Crockford alphabet rejected. A dedicated regression test feeds real I/L/O/U
  ids through both `isValidOpencodeSessionId` and the store validator.
- **Resume command is shell-safe and flag-correct.** Id and cwd are both
  passed through `conversationShellQuote` (single-quote escaping); the id is
  additionally grammar-gated before interpolation (defense in depth). The
  command is bare `opencode -s '<id>'` — verified `--dangerously-skip-permissions`
  is `opencode run`-only against opencode 1.17.5 `--help`, so the interactive
  TUI resume must not carry it. cd-prefix only when cwd is present AND passes
  `isValidOpencodeSessionProjectDir` (single-quote/NUL/newline banned).
- **Sub-session guard.** The plugin pushes only `!info.parentID` (root)
  sessions — a sub-agent `session.created` cannot clobber the surface's
  primary conversation. Confirmed against the SDK `EventSessionCreated` shape
  (`event.properties.info.{id,directory,parentID}`).
- **Three-valued `transcriptExists` honored.** `OpencodeScraper.sessionExists`
  returns nil when the DB is absent/unopenable or the id is malformed (cannot
  verify → ref stays `.unknown`), true/false only when the DB is readable.
  Tested all three branches against a real temp SQLite DB.

## SQLite safety
- Opens `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`, 2 s busy-timeout,
  every handle/statement has a matching `defer` finalize/close; partial
  open is closed before returning nil. Parameterized binds (no string
  interpolation into SQL) — no injection surface. `withCString` + nil
  (SQLITE_STATIC) destructor is sound: bytes are read within the closure and
  not retained. Any non-ROW/DONE step degrades to nil/partial, never crashes.
- Privacy contract upheld: only `id`, `time_updated`, `directory` are read;
  `message`/`part` tables never opened.

## Minor notes (non-blocking, no change required)
1. `capture` reads `inputs.scrapeCandidates` (`[ScrapeCandidate]`) as a
   fallback, but `OpencodeScraper` returns `[ConversationRef]` and the live
   scrape-capture pipeline is Phase B. This branch is dormant in Phase A and
   mirrors `ClaudeCodeStrategy`'s shape; Phase B will add the ref→candidate
   bridge. Intentional, documented in the code comment.
2. The reserved metadata keys are defense-in-depth at the store boundary; the
   live resume path reads `ref.cwd`, not the metadata key. Documented in the
   plan's Architecture section.

## pbxproj
Gated on membership symmetry, not the line diff: `OpencodeScraper.swift`
(c11 target) and `OpencodeResumeTests.swift` (c11LogicTests target) each add
exactly the 4 expected entries (buildfile + fileref + group + sources). The
diff is the minimal 8 lines — the gem did not reformat. `xcodebuild -list`
unchanged (5 targets, 7 schemes).

## Test result
`c11-logic` scheme, 26 tests, **0 failures** (`** TEST SUCCEEDED **`). The
host-scheme `ConversationStrategyTests`/parity tests are CI-verified;
opencode strategy coverage is deliberately co-located in `c11LogicTests` so
the local gate exercises this ticket's code (per plan R3).

## Gate
Unit-green is `partial`. The load-bearing acceptance is the **live**
quit+relaunch exact-resume, with the installed plugin precondition (R1).
Proceeding to `in_validation`.