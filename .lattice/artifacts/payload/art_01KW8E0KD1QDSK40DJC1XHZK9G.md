# Validation: C11-152 — Live scrape-capture pipeline

**Branch:** feat/c11-152-scrape-capture @ 00e5801c9 (base origin/main 3428ceb20). Scheme: `c11-logic`
(safe — no host DEV.app). Host `c11-unit` / bare `xcodebuild test` NOT run, per CLAUDE.md.

## 1. Acceptance gate — end-to-end round-trip (the load-bearing test)
`ScrapeCapturePipelineTests` (c11LogicTests target only), all 7 cases green:

```
** TEST SUCCEEDED **
testSingleCodexCandidateBecomesResumableTypeCommand   passed   <- ACCEPTANCE: ScrapeCandidate -> capture -> applyScrape -> resume == .typeCommand("codex resume '<uuid>'")
testRunScrapeCaptureAppliesRefToStoreAndRoundTripsToResume  passed   <- actor driver: candidate flows into a real ConversationStore and the stored ref resumes to .typeCommand
testAmbiguousCodexCandidatesYieldUnknownAndSkip       passed   <- >1 candidate -> .unknown -> resume .skip
testClaudeHookRefIsNotOverwrittenByScrapePath         passed   <- regression guard: seeded .hook ref not displaced via scrape path
testEmptyScraperOutputProducesNoRefs                  passed
testKindWithoutRegisteredScraperIsSkipped             passed
testContextsExtractedFromSnapshotTerminalPanelsOnly   passed   <- contexts(from:) extracts (surfaceId,kind,cwd) for terminal panels only
Executed 7 tests, with 0 failures (0 unexpected) in 0.012s
```

The acceptance criterion ("a scraped `ScrapeCandidate` flows end-to-end and becomes a resumable ref
whose `strategy.resume` returns a `.typeCommand`") is directly asserted by
`testSingleCodexCandidateBecomesResumableTypeCommand` and reconfirmed through a real `ConversationStore`
by `testRunScrapeCaptureAppliesRefToStoreAndRoundTripsToResume`.

## 2. No claude/codex resume regression (validation row 5)
`ConversationCrashRecoveryTests` (the store/strategy crash-recovery guard, c11LogicTests), all green:

```
** TEST SUCCEEDED **
Executed 14 tests, with 0 failures (0 unexpected) in 0.015s
```

Plus `testClaudeHookRefIsNotOverwrittenByScrapePath` above proves the scrape path cannot displace a
live hook ref. claude resume behavior is unchanged (hook wins; scrape-only claude refs stay `.unknown`
→ skip). codex gains resume (the intended new capability), it does not lose any.

Host-target suites that exercise the same surface — `ConversationStrategyTests` and
`WorkspaceConversationResumeTests` (the single `applyScrape` rename caller) — are **CI-verified** per
the no-local-host-test rule; they are not runnable on the safe local scheme.

## 3. Full app-target build
The `c11-logic` test run compiles the entire `c11` app target (it links `c11.debug.dylib` as the test
bundle loader), so the live call site in `AppDelegate.prepareStartupSessionSnapshotIfNeeded` and all
new product files compile in the real app target, not merely a test bundle. A standalone
`xcodebuild -scheme c11 build` was additionally run to confirm the app links: **`** BUILD SUCCEEDED **` (`xcodebuild -scheme c11 -configuration Debug build`, exit 0)**.

## 4. Why full live-agent codex resume is deferred to C11-153/154
C11-152 is the pipeline *foundation*; it has no agent of its own to resume. codex is the incidental
live consumer, but a meaningful live codex quit+relaunch depends on the codex **wrapper-claim rail**
(which mints the placeholder whose `capturedAt` floors the scrape filter) — orthogonal live
infrastructure, not this seam. The seam's end-to-end behavior (`ScrapeCandidate → applyScrape →
resume .typeCommand`) is proven by the integration tests above. Per the delegator boot's explicit
allowance, full **observed live-agent exact-session resume** is owned by the consuming tickets
C11-153 (pi) and C11-154 (omp) — which the BUILDPLAN (Phase B step 5) assigns per-agent live
snapshot/restore validation, and which import against the stable public seam this ticket publishes.