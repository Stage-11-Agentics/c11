# Code Review: C11-153 — pi exact-session resume (PiScraper + PiStrategy)

**(own-reviewer fallback)** — the headless `lattice code-review` exited with a vacuous
"Diff is empty" because it resolves the diff range against LATTICE_ROOT (the MAIN checkout,
sitting on clean `main`), not this delegator's worktree branch (the MV-flagged systemic issue,
ev_01KW8DQMQV3XJMWZSGJKT88BJT). I reviewed the real range `git diff origin/main...HEAD` in the
worktree instead.

## Verdict: PASS — no Critical/Major/Minor blocking issues.

## Scope reviewed
7 files, +450/-6. Production: `PiScraper.swift` (new), `Pi.swift` (new, PiStrategy),
`ConversationScraperRegistry.swift` (+1 line), `StrategyRegistry.swift` (+1 line),
`AgentManifest.swift` (flag flip + comment). Tests: `PiConversationTests.swift` (new, 9 cases).
pbxproj: 3 file refs + 3 build-file entries, no reformat churn.

## Correctness
- **Id extraction is the one real divergence from codex, and it's right.** pi filenames are
  `<ISO-ts>_<uuid>.jsonl`; the ISO timestamp (`2026-06-27T21-35-42-003Z`) contains no `_`, so
  `stem.lastIndex(of: "_")` + slice after it yields the UUID. Verified against a real on-disk
  file: `2026-06-27T21-35-42-003Z_019f0b02-83b3-7c97-b12c-05946daccc84.jsonl`. No-underscore and
  non-UUID-tail cases are dropped by the `lastIndex` guard + `isValidConversationUUID`. Tested.
- **UUIDv7 validator fit confirmed.** `isValidConversationUUID` is 8-4-4-4-12 hex with no version
  nibble enforcement, so pi's UUIDv7 passes. No new grammar needed.
- **PiStrategy is a faithful CodexStrategy mirror.** Identical capture filter (cwd + claim-time +
  activity-floor), identical ambiguity policy (>1 candidate → `.unknown` + diagnosticReason →
  `resume` skips "ambiguous"), identical guards. Only the resume text differs:
  `pi --session '<id>'` via `conversationShellQuote` (defence-in-depth; id already grammar-checked).
- **Privacy contract preserved.** PiScraper reads filename/mtime/size only via the stat-only
  recursive lister; never opens transcript bytes.
- **Registration + manifest flip atomic.** PiScraper in scraper-registry `v1` func array, PiStrategy
  in strategy-registry `v1` array, `hasConversationStrategy: true` — all in one commit, so
  `AgentManifestTests.testConversationStrategyPresenceParity` stays green (verified: 8/8 pass).
  Manifest `resume: .fixed("pi -c\n")` phase-1 fallback left intact → `testResumeCommandReproducesPhase1`
  unaffected.

## Tests
9 PiConversationTests run on the safe `c11-logic` scheme, local mocks (host-target `MockFS` not
reachable). Covers: id-after-last-underscore, non-UUID/no-underscore rejection, recursive
top-by-mtime, missing-dir empty, cwd stamping; single-candidate → `pi --session '<uuid>'`,
ambiguous → skip, placeholder → skip, grammar validation. End-to-end through `ScrapeCapturePipeline`.
Result: `** TEST SUCCEEDED **`, 17 tests (9 pi + 8 manifest), 0 failures.

## Notes (non-blocking)
- Ambiguity disambiguation is mtime-only (the cwd filter is a no-op because, like codex, the
  scraper stamps the *surface* cwd not a slug-parsed one). In scope and consistent with codex; a
  future enhancement could parse pi's cwd-slug for sharper filtering. Not expanded here.
- `testPiScraperExtractsUUIDAfterLastUnderscore` indexes `candidates[0]` after an `XCTAssertEqual
  count` — mirrors the existing claude/codex scraper tests; on failure it hard-crashes rather than
  failing soft, but green tests make this moot.

Validation gate (live exact-resume) is next and load-bearing per the plan; pr_open blocked until observed.