# Code Review: C11-152 — Live scrape-capture pipeline (own-reviewer fallback)

**Reviewer:** delegator-c11-152 (own-reviewer fallback — `lattice code-review` CLI returned an
empty diff because it resolves git from `LATTICE_ROOT` (the main checkout) which has no copy of the
unpushed feature commit; per the boot HARD RULE this self-review stands in for the vacuous artifact).
**Base:** origin/main (3428ceb20) **Head:** 00e5801c9 **Diff:** 9 files, +503/-5.

## Verdict: PASS (no Critical/Major). Two non-blocking observations noted for follow-up.

## What was reviewed
The new seam wiring scrapers into restore: `ConversationScraper` protocol + registry, the pure
`ScrapeCapturePipeline` (+ `ScrapeCaptureContext.contexts(from:)`), the `ConversationStore`
`recordScrape`→`applyScrape` rename + `runScrapeCapture` actor driver, and the live call site in
`AppDelegate.prepareStartupSessionSnapshotIfNeeded`. Verified against the plan's authoritative seam
shape and the plan-review resolutions.

## Correctness

- **Provenance filter is the right safety property.** `captureRefs` forwards a strategy result only
  when `ref.capturedVia == .scrape`. A strategy that echoes back the wrapper-claim placeholder (no
  disk match) or returns a `.hook` ref produces nothing to apply, so the scrape path can never write
  a placeholder or displace a live hook ref. Confirmed by `ClaudeCodeStrategy.capture` (push wins →
  `.hook`, filtered) and `CodexStrategy.capture` (placeholder echo → `.wrapperClaim`, filtered).
- **Input routing matches the live path.** The seeded active ref is routed to `push` when its source
  is non-`wrapperClaim`, else to `wrapperClaim`, so `CodexStrategy`'s claim-time floor and push-wins
  logic behave exactly as designed. Correct.
- **No claude/codex resume regression (validation row 5).** claude: hook ref preserved (filtered),
  and a claude pane with no hook gets at most a `.scrape`/`.unknown` ref → `resume()` skips, identical
  observable behavior to today. codex: this is the new capability — single unambiguous cwd+mtime match
  → `.alive` → `codex resume '<uuid>'`; ambiguous → `.unknown` → skip. Both proven by the new tests.
- **Ordering preserved.** Scrape-capture runs after `seedFromSnapshot` and before the `--no-resume`
  sentinel (`markAllUnknown`) and dirty `reclassifyAfterCrash`, so those still win — the `/exit`
  no-resume and crash-recovery contracts are intact.
- **Concurrency.** `runScrapeCapture` is actor-isolated; the call site uses the established
  `Task.detached` + `DispatchSemaphore.wait(1s)` pattern (breaks `@MainActor` so the actor body runs
  while main blocks), matching its two immediate neighbours. Correct.
- **Privacy/boundedness unchanged.** Scrapers remain stat-only and `maxCandidates`-capped; the
  pipeline opens no transcript bytes and adds no unbounded walk.
- **pbxproj.** 3 product files → `c11` target, 1 test → `c11LogicTests` only (single-membership
  verified). File-ref paths corrected to the flat-`Sources`-group convention; `xcodebuild -list`
  parses; ref counts symmetric. Small 16-line diff (no gem reformat churn this pass).

## Observations (non-blocking)

1. **[Minor / perf] Redundant directory walks per surface.** Each context calls
   `scraper.candidates(cwd:)`, which does a full recursive walk of the kind's session root. With N
   codex surfaces that is N walks of the same `~/.codex/sessions` within the 1s actor budget. Bounded
   and correct (same `DefaultConversationFilesystem` + 1s budget parity as `reclassifyAfterCrash`),
   but a future optimization could memoize candidates per kind across contexts. Left as-is for the
   seam; pi/omp inherit the same shape. Not blocking.

2. **[Minor] `lastActivityTimestamp` is always nil from `contexts(from:)`.** The snapshot carries no
   live-activity floor, so codex's `activityFloor` filter is inert at restore; the wrapper-claim's
   `capturedAt` still floors when a claim was seeded, and the >1-candidate ambiguity guard protects
   the multi-session case. This is consistent with `CodexStrategy`'s documented scrape-primary design.
   The field exists on the context for callers that do know activity. Not blocking.

## Tests
7 new logic-target cases (all green) covering the end-to-end `ScrapeCandidate → applyScrape → resume
.typeCommand` round-trip, ambiguity-skip, hook-ref-preserved, empty/unregistered-kind, the
`runScrapeCapture` actor round-trip, and `contexts(from:)` extraction. Regression guard
`ConversationCrashRecoveryTests` green (14). Host-target `ConversationStrategyTests` /
`WorkspaceConversationResumeTests` (the `applyScrape` caller) are CI-verified per the no-local-host rule.