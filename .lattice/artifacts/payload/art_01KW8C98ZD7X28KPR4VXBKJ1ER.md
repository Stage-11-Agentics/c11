# Plan Review: C11-152 — Live scrape-capture pipeline

### 1. Verdict

**FAIL (plan-level)**

The architecture is sound and the public seam is well-designed, but the plan rests on two factual claims about the existing code that are wrong, and both would fail *outside* the plan's own local validation surface (which runs only the `c11-logic` scheme). Each is a small, mechanical fix, but they materially change the implementation steps and must be corrected before work begins — otherwise the implementer ships a green-locally / red-in-CI change.

### 2. Summary

Reviewed the full C11-152 plan to wire the existing-but-dead scrape rail into surface restore (scraper → `[ScrapeCandidate]` → `strategy.capture` → `store.applyScrape`), verifying its claims against `Sources/Conversation/`, `Sources/AppDelegate.swift`, the test layout, and `GhosttyTabs.xcodeproj/project.pbxproj`. The seam shape, the AppDelegate call-site analysis, the ordering-vs-no-resume/dirty reasoning, and the kind-alignment all check out against the real code. The blocking concern: the plan's "`recordScrape` has zero callers" premise is false (a host-target test calls it), and its "reuse `MockFS` from `ConversationScraperTests`" test approach won't compile across the target boundary.

### 3. Issues

**[CRITICAL] §5 Store write method rename — "zero callers (grep-verified)" is false**
The plan states `recordScrape(surfaceId:ref:)` has **zero callers** and renames it to `applyScrape` on that basis. There is a live caller: `c11Tests/WorkspaceConversationResumeTests.swift:78` — `await ConversationStore.shared.recordScrape(surfaceId: surfaceId, ref: ref)`. Renaming the method without updating that call site breaks the `c11Tests` (host) target. Critically, `WorkspaceConversationResumeTests` is a member of the **host** `c11Tests` target, which the plan's own Validation section does *not* run locally (it runs only `c11-logic`). So this break is invisible to the plan's local green check and surfaces only in CI — the exact "logic regression sails through local, only red in CI" footgun CLAUDE.md calls out. The plan's Files table also omits this file.
**Recommendation:** Either (a) add `c11Tests/WorkspaceConversationResumeTests.swift` to the Files table and update its `recordScrape` call as part of the rename, explicitly noting the host-target change is CI-verified per the no-local-host-test rule; or (b) keep `recordScrape` as a one-line deprecated alias forwarding to `applyScrape` to avoid touching the host test at all. Drop the "zero callers" claim.

**[MAJOR] §Tests — `MockFS` reuse won't compile across the target boundary**
The plan places the new `ScrapeCapturePipelineTests` in the `c11LogicTests` target and says to "reuse the `MockFS` shape from `ConversationScraperTests`." But `ConversationScraperTests.swift` (which declares `final class MockFS: ConversationFilesystem`) is a member of the **host `c11Tests` target only** — verified via pbxproj target membership; only `ConversationCrashRecoveryTests` is in `c11LogicTests`. A `c11LogicTests`-target test cannot see a `MockFS` defined in a host-only test file, so the new test will fail to compile. (Note: `ConversationFilesystem` / `DefaultConversationFilesystem` themselves are *product* code in `Sources/Conversation/Scrapers/ClaudeCodeScraper.swift`, so they are reachable — it is specifically the test-side `MockFS` helper that is not.)
**Recommendation:** Either declare a fresh local mock filesystem + mock scraper inside the new test file, or extract `MockFS` into a small shared helper file added to **both** test targets. State the chosen approach in the plan. Also note this is why the mock-scraper conformance the pipeline needs (`func candidates(cwd:) -> [ScrapeCandidate]`) must be authored locally in the new test, not borrowed.

**[MINOR] §Files / §Tests — `c11LogicTests/` is a target, not an on-disk directory**
The plan lists the new test at `c11LogicTests/ScrapeCapturePipelineTests.swift`. There is no `c11LogicTests/` directory on disk; logic-target tests live physically in `c11Tests/` (e.g. `c11Tests/ConversationCrashRecoveryTests.swift`) and are assigned to the `c11LogicTests` *target* via pbxproj membership. Creating a literal `c11LogicTests/` directory would diverge from the established layout.
**Recommendation:** Author the file at `c11Tests/ScrapeCapturePipelineTests.swift` and add it to the `c11LogicTests` target only (not `c11Tests`), so it runs on the safe scheme. Update the Files table path and the §Tests heading accordingly.

**[MINOR] §Validation — no explicit guard that the new test is on the logic target *only***
Because the file lives physically in `c11Tests/`, it is easy to accidentally add it to both targets (the default the `xcodeproj` gem nudges toward). If it lands in the host `c11Tests` target too, it stops being locally-safe and the acceptance "`-only-testing:c11LogicTests/ScrapeCapturePipelineTests` green" can mislead.
**Recommendation:** Add a one-line check to Validation: confirm single-target membership for the new test via `xcodebuild -showBuildSettings`/build-file ref count, consistent with the plan's existing "gate on `xcodebuild -list` + ref-count symmetry" instruction for the pbxproj edit.

### 4. Positive Observations

- **The architectural finding is correct and load-bearing.** The diagnosis — scrapers produce candidates, strategies know how to `capture` them, but nothing connects the two at runtime so codex never resolves a real session id — matches the code. `CodexScraper`/`ClaudeCodeScraper` both expose `kind` + `candidates(cwd:)` today, and `CodexStrategy.capture` exists; the gap is exactly the missing call site the plan adds.
- **The AppDelegate call-site analysis is accurate to the line.** The proposed insertion (after `seedFromSnapshot`, before the `--no-resume` sentinel and `.dirty` reclassify branches) and the `Task.detached(priority:.userInitiated)` + `DispatchSemaphore` `wait(1s)` pattern precisely mirror the two existing neighbours in `prepareStartupSessionSnapshotIfNeeded`. The ordering reasoning (seed → scrape → no-resume/dirty, so `markAllUnknown`/`reclassifyAfterCrash` still win) is correct and preserves those contracts.
- **Kind alignment is verified-sound.** `terminal_type` metadata values are `AgentRegistry` manifest kinds (`"claude-code"`, `"codex"`), which match both the scraper `kind` literals and the strategy `kind` literals — so keying `ScrapeCaptureContext` on `terminal_type` resolves the right scraper/strategy. The `.scrape`/`.hook`/`.wrapperClaim` provenance enum and `capturedVia` filter the plan relies on all exist as described in `Ref.swift`.
- **Good privacy and boundedness discipline.** Reaffirming the metadata-only scraper contract, the `maxCandidates` cap, and stat-only walks keeps the seam consistent with the existing rail rather than introducing a new unbounded path.
- **The seam-stability framing for the blocked tickets (pi/omp) is the right call** — declaring the protocol/registry/pipeline signatures authoritative and additive, with pi/omp's only registry edit being a one-line append, is exactly the contract a downstream-blocking ticket should publish.

---

*Reviewer note: issues #1 and #2 are both "compiles/passes on the `c11-logic` scheme but breaks the host target or won't compile there" — squarely in the plan's validation blind spot. Fixing them is ~15 minutes of plan revision, but leaving them sends the implementer to a confident-but-red CI run.*
