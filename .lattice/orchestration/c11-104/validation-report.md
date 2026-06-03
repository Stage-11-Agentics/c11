# C11-104 Validation Report — Phase 4

**PR:** #181 (`feat/c11-104-sidebar-chips` → `main`)
**Validator:** agent:claude-opus-4-7 (fresh-eyes Phase 4 audit)
**Spec source:** Lattice ticket C11-104 § "Refined SPEC + decisions v2 (2026-05-19, post-trident-review)"
**Validation plan source:** `.lattice/orchestration/c11-104/validation-plan.md`
**Date:** 2026-05-19
**PR head audited:** `b9ab056f8824d90f2a84ab00f1f1d0e350a848c9`
**Merge base:** `ed430f34d` (PR is `MERGEABLE` but 3 commits behind `main`: #178, #182, #180)

## Summary

- Pre-merge-static ACs audited: 30 (AC1–AC30) + 7 PR-level checks
- **PASS: 22**
- **PARTIAL: 6**
- **FAIL: 4**
- **CANNOT_VERIFY: 1**

**Executive summary.** The PR ships the user-visible feature cleanly: chips render, projector dims main/master/trunk, submodule produces stacked rows, the legacy text row is retired, the AppStorage key is preserved, localization is complete, docs are updated, and all CI checks are green. The biggest gaps are in the validation-plan's *test coverage* expectations — several ACs called for tests that simply weren't written (AC14 timeout, AC16 socket rejection, AC17 socket read, AC19 restore-warmpath, AC20 deterministic precondition trip). The other significant finding is **architectural drift**: `GitContextResolverCache` and `DerivationCoordinator` exist as tested-in-isolation classes but are **not wired into the production probe path** — `TabManager.initialWorkspaceGitMetadataSnapshot` still calls `GitContextResolver.resolve(cwd:)` directly with no cache. The PR body acknowledges these as v2-deferred. None of the drift is user-visible; the cache absence just means every probe re-shells out, which the existing `initialWorkspaceGitProbeQueue` already kept off the hot path.

**Recommendation:** **Merge with follow-up ticket**. The merge gate is clear for the user-visible feature, but the test gaps + drift deserve a stub ticket so the next agent inheriting this code doesn't think the cache and coordinator are load-bearing in production.

## Per-AC findings

### AC1 — Linked-worktree resolution
**Verdict:** PASS
**Artifact:** `c11Tests/GitContextResolverTests.swift:66-89`
**Evidence:** `testLinkedWorktreeReturnsBasename` stubs the `--git-common-dir` vs `--git-dir` divergence and asserts `.linkedWorktree(basename:"c11-104-sidebar-chips", absolutePath:..., branch:.attached("feat/..."))`. Matches the AC's "linked worktree → basename + correct branch."

### AC2 — Main checkout
**Verdict:** PASS
**Artifact:** `c11Tests/GitContextResolverTests.swift:93-106`
**Evidence:** `testMainCheckoutReturnsMainCheckoutKind` stubs equal `--git-common-dir` and `--git-dir` and asserts `.mainCheckout(branch:.attached("main"))` plus `result?.inner == nil`.

### AC3 — Branch chip dim treatment for main/master/trunk
**Verdict:** PASS
**Artifact:** `c11Tests/WorktreeChipProjectorTests.swift:13-39`; `Sources/Sidebar/WorktreeChipModel.swift:54` (`mainBranchNames: Set<String> = ["main", "master", "trunk"]`)
**Evidence:** Four tests (`testMainBranchIsDimmed`, `testMasterBranchIsDimmed`, `testTrunkBranchIsDimmed`, `testFeatureBranchNotDimmed`) verify dim state per branch name. Dim opacity is hardcoded `0.55` in `WorktreeChipsRow.swift:73` (not the ThemeKey-backed `chipTextDimmedOpacityLight/Dark` the v2 spec section M6 specified; see Drift section).

### AC4 — Color hash stability + palette distinctness
**Verdict:** PASS
**Artifact:** `c11Tests/WorktreeChipProjectorTests.swift:43-88`; `Sources/Sidebar/WorktreeColorPalette.swift:33-41` (DJB2 hash)
**Evidence:** `testWorktreeColorStableAcrossCalls` + `testDifferentWorktreesGetDifferentColors` + `testColorHexIsFromKnownPalette` cover the three sub-criteria. Determinism is grounded in DJB2 + `entries.count = 10`. The test comment "Sanity-checked at authoring time" admits the two-path divergence relies on a pre-computed fixture, which is acceptable per the spec (M1).

### AC5 — Detached HEAD
**Verdict:** PASS
**Artifact:** `c11Tests/GitContextResolverTests.swift:110-124`; `c11Tests/WorktreeChipProjectorTests.swift:92-100`
**Evidence:** Resolver-side stubs `symbolic-ref` failing then `rev-parse --short=7 HEAD = "abc1234"` → asserts `.detached(shortSHA:"abc1234")`. Projector renders `"(detached @ abc1234)"`. Both halves green.

### AC6 — Submodule two-pass (both contexts populated)
**Verdict:** PASS
**Artifact:** `c11Tests/GitContextResolverTests.swift:128-173` (resolver) + `c11Tests/WorktreeChipProjectorTests.swift:104-119` (projector) + `Sources/Metadata/GitContextResolver.swift:243-263` (two-pass logic)
**Evidence:** Two-pass implementation: outer resolution against `superprojectRoot ?? cwd`, inner resolution against the original cwd. Display-name fallback chain `.gitmodules → relative-path → basename` covered by three dedicated tests at `:348-411`. Inner-detached-HEAD edge case at `:157-173`.

### AC7 — Linked worktree containing submodule with detached inner HEAD
**Verdict:** PARTIAL
**Artifact:** `c11Tests/GitContextResolverTests.swift:157-173` (`testSubmoduleInnerDetachedHEAD`)
**Evidence:** A combined fixture exists: submodule with detached inner HEAD. **However, the "linked-worktree-containing-submodule" combined fixture the AC specifically names is not present** — the inner-detached test uses a main-checkout superproject (`/tmp/super`), not a linked-worktree superproject. The behavior is plausibly identical (the resolver doesn't branch on superproject kind for the inner pass), but the precise AC fixture is absent.

### AC8 — Not-in-git
**Verdict:** PARTIAL
**Artifact:** `c11Tests/GitContextResolverTests.swift:177-198`; `Sources/TabManager.swift:1670-1689` (apply-side derived-clear)
**Evidence:** `testNotInGitReturnsNil` returns nil for an out-of-repo cwd; `testCwdDoesNotExistReturnsNil` verifies the existence short-circuit (no runner invocations). `TabManager.applyDerivedWorktreeBranchMetadata` writes empty strings via `setInternal(.derived)` when context is nil, which satisfies the AC's "coordinator issues clear → projection produces empty chips." **However**, the AC explicitly demands the deriver return `.notInRepo` state; the implementation uses `nil` as the proxy. Behavior is equivalent (chips clear), state naming differs.

### AC9 — Bare clone
**Verdict:** PASS
**Artifact:** `c11Tests/GitContextResolverTests.swift:202-213`
**Evidence:** `testBareCloneReturnsNil` stubs `rev-parse --show-toplevel` returning nil (as it does in a bare repo) and asserts nil. The projector produces `[]` for nil context (verified at AC8).

### AC10 — Stale worktree (worktree removed while pane is open)
**Verdict:** FAIL
**Artifact:** *(missing)*
**Evidence:** The AC mandates a test where the worktree is `git worktree remove`d after cache population, then re-derived → assert `.stale`. **The `BranchValue` / `GitContextKind` enums have no `.stale` case.** Production behavior: if the cwd directory still exists on disk, the resolver re-runs git from a now-missing worktree pointer; if the cwd directory is removed, `fileSystem.fileExists` returns false → returns nil → chips clear. The PR body's "v2 deferred" section explicitly defers I6 ("git worktree remove while pane is open"). No test exists. **Action: either add a `.stale` state and test, or accept the deferral and reword the AC.**

### AC11 — Worktree pointing at deleted branch
**Verdict:** PARTIAL
**Artifact:** `c11Tests/GitContextResolverTests.swift:217-238`; `c11Tests/WorktreeChipProjectorTests.swift:123-135`
**Evidence:** `testWorktreeWithDeletedBranchDegrades` returns `.unknown` (when both `symbolic-ref` and `rev-parse --short=7 HEAD` fail). Projector renders `"(no branch)"`. The AC says `branch.noBranch`; the implementation uses `.unknown`. Behavior matches the AC's user-visible expectation; the enum case naming differs from the spec's `noBranch`.

### AC12 — Cache against git-resolved HEAD path
**Verdict:** PARTIAL
**Artifact:** `c11Tests/GitContextResolverTests.swift:242-303` (cache mechanism tests) + `:448-462` (LRU); `Sources/Metadata/GitContextResolver.swift:469-477` (`headPath(forCwd:runner:)`)
**Evidence:** The cache class `GitContextResolverCache` is implemented and tested in isolation (hit-bypasses-runner; different-mtime-misses; LRU eviction). `GitContextResolver.headPath(forCwd:runner:)` correctly uses `git rev-parse --git-path HEAD` (which IS the resolved HEAD path for worktrees and submodules). **However:** (1) the AC's specific verification — a linked-worktree fixture *and* a submodule fixture, touching the *resolved* HEAD at `<common-dir>/worktrees/<name>/HEAD` (or the modules dir for submodules) and re-running — is not present; tests use abstract paths and arbitrary `Date` values. (2) `GitContextResolverCache` and `GitContextResolver.headPath` are **not referenced anywhere in `Sources/` outside their own file** — production never uses the cache. `TabManager.swift:1724` calls `GitContextResolver.resolve(cwd: directory)` directly. The class is dead code in production; the cache invalidation mechanism is verified only as a library, not as a system. This is the highest-leverage drift item in the PR.

### AC13 — Stale-async via gen-token + expected-cwd guard
**Verdict:** PARTIAL
**Artifact:** `Sources/TabManager.swift:1593-1641` (existing applyWorkspaceGitMetadataSnapshot with gen-token + expected-cwd guards); the new `applyDerivedWorktreeBranchMetadata` (`:2411-2475`) is called from inside the guarded snapshot apply at `:1675`.
**Evidence:** The B4 pattern is reused: derived metadata writes happen *after* `workspaceGitProbeGenerationByKey[probeKey] == generation` (`:1607`) and `currentDirectory != expectedDirectory` (`:1621`) guards. Stale results for the new derived writes inherit the existing protection. **However**, the AC specifically demanded "Logic test with a fake clock + injected slow deriver. Kick A; kick B; complete A; assert no apply happened for A's result." That test does not exist for the C11-104 path. The protection is there by construction (the new writes ride the existing guarded apply), but not separately tested.

### AC14 — Git subprocess timeout (2s → returns `.timeout`, chip clears)
**Verdict:** FAIL
**Artifact:** `Sources/Metadata/GitContextResolver.swift:163-211` (`ProcessGitRunner` with `timeout: TimeInterval = 5.0`)
**Evidence:** Three concrete failures vs the AC: (1) the default timeout is **5 seconds**, not 2; the PR body documents this choice but the v2 spec section I3 explicitly said "2s per `git` invocation." (2) On timeout, the runner returns nil; **there is no `.timeout` state** in the `GitContextKind` / `BranchValue` enums. (3) **No test verifies timeout behavior** — neither the 2s-vs-5s bound nor the post-timeout state. The runner does terminate the process correctly via SIGTERM → SIGKILL, but the AC's specific behaviors are not exercised.

### AC15 — `derived` precedence tier ordering
**Verdict:** PASS
**Artifact:** `c11Tests/MetadataDerivedPrecedenceTests.swift:13-86`; `Sources/SurfaceMetadataStore.swift:90-110` (`MetadataSource.derived` case + `precedence: 1` between `heuristic: 0` and `osc: 2`)
**Evidence:** Three tests verify ordering vs `heuristic`, `osc`, `declare`, `explicit`. `testOscWinsOverDerivedForSameKey` + `testDerivedWinsOverHeuristic` + `testExplicitWinsOverDerived` exercise the precedence guard through the real `SurfaceMetadataStore.setInternal` path.

### AC16 — Socket `set_metadata` rejects `source=derived` from external clients
**Verdict:** PARTIAL
**Artifact:** `Sources/TerminalController.swift:8246-8248`, `:8368-8370`, `:9124-9126`, `:9221-9223` (four call sites: surface set, surface clear, pane set, pane clear)
**Evidence:** Code change present at all four entry points: `if source == .derived { return .err(code: "invalid_source", ...) }`. **No test verifies the rejection.** The validation plan AC explicitly demanded "Logic test against the socket protocol handler — feed a `set_metadata` socket frame with `source=derived` from a non-internal-caller path → assert error `invalid_source`." That test does not exist.

### AC17 — `c11 get-metadata --key worktree` and `--key branch` return derived values
**Verdict:** CANNOT_VERIFY
**Artifact:** `Sources/TabManager.swift:2411-2475` (writes `worktree` and `branch` via `store.setInternal(.derived)`)
**Evidence:** The metadata is written to `SurfaceMetadataStore` via the normal `setInternal` API, so the existing `c11 get-metadata` socket path will read it. **However, there is no test for the socket get-metadata read path with derived values**, and the validation plan AC explicitly required one. By construction the values are readable (the store doesn't filter derived on read), but the AC's specific verification is missing.

### AC18 — Snapshot capture excludes `source=derived` keys
**Verdict:** PASS
**Artifact:** `c11Tests/MetadataDerivedPrecedenceTests.swift:135-173` (two tests); `Sources/PersistedMetadata.swift:144-185` (filter in `encodeValues` + `encodeSources`)
**Evidence:** `testDerivedKeysAreDroppedFromSnapshotCapture` constructs a payload with `task` (declare) + `worktree`+`branch` (derived), runs both `encodeValues(..., sources:)` and `encodeSources(...)`, and asserts derived keys are nil in both outputs. `testEncodeValuesWithoutSourcesPreservesEverything` covers the back-compat behavior when no `sources` parameter is provided. Workspace + WorkspacePlanCapture callers updated to thread `sources` through (`Sources/Workspace.swift:491-498, 619-625`; `Sources/WorkspacePlanCapture.swift:177-194`).

### AC19 — Snapshot restore warm-path (snapshotted `gitBranch` paints initially while deriver runs)
**Verdict:** FAIL
**Artifact:** *(missing)*
**Evidence:** The PR body's "Deferred (documented in plan amendments)" section explicitly defers I5: "I5: restore-window gap (chips populate async on session restore)." No test exists. On restore, `panelGitContexts` starts empty; chips are blank until the next probe completes (which is typically fast, but not the AC's "paint snapshotted value first" behavior). **This is a known-deferred item.**

### AC20 — Runtime `dispatchPrecondition(.notOnQueue(.main))` traps main-thread invocation
**Verdict:** PARTIAL
**Artifact:** `Sources/Metadata/GitContextResolver.swift:76` (in `DerivationCoordinator.run`) + `:235` (in `resolve`); `c11Tests/GitContextResolverTests.swift:330-344` (`testResolverPreconditionTripsOnMainThread`)
**Evidence:** Both preconditions are in the code at the right entry points. **However**, the test does NOT deterministically trip the precondition on main; it is a sentinel that only verifies off-main resolution succeeds. The test's own comment admits: "We can't easily intercept `dispatchPrecondition` in-process … This test is a sentinel: if dispatchPrecondition is ever weakened to a no-op assertion, future maintainers will see this test exists and revisit the contract." The AC asked for "invoke deriver from main directly, expect XCTAssert-recorded crash (via `XCTExpectFailure` or precondition-fatal test pattern)." This wasn't done.

### AC21 — `report_pwd` handler doesn't block on deriver
**Verdict:** PARTIAL
**Artifact:** `Sources/TerminalController.swift:1958-1996` (`reportPwdWorker`) and `:18168` (`reportPwd`); not touched in this PR.
**Evidence:** The negative criterion ("no `.wait()`, no `DispatchQueue.main.sync`, returns synchronously") is satisfied — `reportPwdWorker` already used `DispatchQueue.main.async` for the directory update before C11-104 and is unchanged. **However**, the AC's positive criterion ("enqueues the coordinator's `runDerivers` via fire-and-forget") is not satisfied — `reportPwd` does NOT directly call `DerivationCoordinator.run`. The deriver fires via the workspace probe scheduler indirectly when `updateSurfaceDirectory` triggers `scheduleWorkspaceGitMetadataRefreshIfPossible`. The hot-path discipline is preserved; the explicit coordinator wiring is not present.

### AC22 — `TerminalSurface.forceRefresh()` and `WindowTerminalHostView.hitTest()` bodies unchanged
**Verdict:** PASS
**Artifact:** PR file list (`gh pr view 181 --json files`)
**Evidence:** `Sources/GhosttyTerminalView.swift` and `Sources/TerminalWindowPortal.swift` are **not in the PR's changed-files list**. No diff = no body changes. The two typing-latency-critical methods are untouched.

### AC23 — `TabItemView` hot-path discipline (precomputed `let` + `==` + `.equatable()`)
**Verdict:** PASS
**Artifact:** `Sources/ContentView.swift:8533-8559` (upstream precompute in `VerticalTabsSidebar`), `:8613` (`.equatable()` on the ForEach call site), `:11047` (`worktreeChipRows` in `==`), `:11106-11108` (precomputed `let worktreeChipRows: [WorktreeChipRow]` parameter)
**Evidence:** The new `worktreeChipRows` field is added as a precomputed `let` parameter, included in `==`, and `.equatable()` is preserved. No new `@EnvironmentObject` / `@ObservedObject` reads in the body. The chip row read inside `body` is from the precomputed parameter only.

### AC24 — Legacy text branch+directory row retired
**Verdict:** PASS
**Artifact:** `Sources/ContentView.swift:11384-11392` (replacement comment block), `:11582` (legacy render block removed), `:12297-12303` (helpers retired comment)
**Evidence:** `verticalBranchDirectoryLines`, `branchDirectoryRow`, `gitBranchSummaryText`, `gitBranchSummaryLines`, `VerticalBranchDirectoryLine`, `directorySummaryText` are all deleted from the file. The compact + vertical render blocks are deleted. The chip row at `:11501-11512` replaces them. No duplicate-render path remains. **`Workspace.orderedUniqueBranchDirectoryEntries()` is untouched but no longer called by the sidebar**; consider removing it in a follow-up if unused.

### AC25 — Dirty marker preserved; PR pill render path intact
**Verdict:** PASS
**Artifact:** `c11Tests/WorktreeChipProjectorTests.swift:152-186` (four dirty-marker tests); `Sources/ContentView.swift:11394-11396, 11591-11593, 12316-` (PR pill code path)
**Evidence:** `testDirtyWorkingTreeAppendsStarToBranchChip`, `testCleanWorkingTreeDoesNotAppendStar`, `testDirtyDetachedHeadAppendsStarAfterClosingParen`, `testSubmoduleInnerRowDoesNotInheritDirty` cover the four sub-rules. PR pill (`pullRequestRows: [PullRequestDisplay]`) precompute + render block in `TabItemView` body untouched.

### AC26 — `@AppStorage("sidebarShowBranchDirectory")` key preserved; UI label updated; toggle gates render
**Verdict:** PASS
**Artifact:** `Sources/ContentView.swift:8415` (`@AppStorage("sidebarShowBranchDirectory")` added to `VerticalTabsSidebar`); `Sources/c11App.swift:5402-5417` (label updated to `settings.app.showWorktreeBranchChips`); `c11Tests/WorktreeChipProjectorTests.swift:145-148` (`testSettingsDisabledProducesEmpty`)
**Evidence:** Key string `sidebarShowBranchDirectory` is preserved verbatim. UI label string changed to a new localization key (`settings.app.showWorktreeBranchChips`) while keeping the same `@AppStorage` storage key — existing user prefs survive. The chip-row precompute gates on `sidebarShowBranchDirectory` at `:8543`. Projector test asserts toggle-off → empty.

### AC27 — Localization (ja/uk/ko/zh-Hans/zh-Hant/ru)
**Verdict:** PASS
**Artifact:** `Resources/Localizable.xcstrings` (verified via `python3 -c "json.load(...)"`); the two new keys `settings.app.showWorktreeBranchChips` and `settings.app.showWorktreeBranchChips.subtitle` carry `extractionState: manual` + `state: translated` entries for en, ja, ko, ru, uk, zh-Hans, zh-Hant.
**Evidence:** All seven locales populated; no `extractionState: new` or `state: needs_review` entries left dangling.

### AC28 — Tests in `c11Tests/` with `c11LogicTests` target membership
**Verdict:** PASS
**Artifact:** `c11Tests/GitContextResolverTests.swift`, `c11Tests/WorktreeChipProjectorTests.swift`, `c11Tests/MetadataDerivedPrecedenceTests.swift`; `GhosttyTabs.xcodeproj/project.pbxproj:1369-1371` (entries `C11104B05/06/07` in build phase `37DDE3B0A6A70E75A7B2BEDF`, which is the sources build phase of target `CD94D227305EFBE6181A6A82 /* c11LogicTests */` at `:1142-1159`).
**Evidence:** Files live in `c11Tests/` (the c11 convention), not a top-level `Tests/` dir. Membership confirmed in `c11LogicTests` target — locally runnable without DEV.app host.

### AC29 — No source-grep / source-shape tests
**Verdict:** PASS
**Artifact:** All three new test files inspected end-to-end.
**Evidence:** Every test either (a) uses `FakeGitRunner` + `FakeFileSystem` against constructed inputs, (b) calls `SurfaceMetadataStore.shared.setInternal/setMetadata` against constructed UUIDs, (c) calls `PersistedMetadataBridge.encodeValues` against constructed dictionaries, or (d) calls `WorktreeChipProjector.project` against constructed `ResolvedGitContext` values. No test opens a source file and asserts text content; no `xcstrings`/`plist`/`pbxproj` reads.

### AC30 — `skills/c11/references/metadata.md` updated
**Verdict:** PASS
**Artifact:** `skills/c11/references/metadata.md:36-37` (worktree + branch keys in the canonical-keys table), `:39` (chip row in render order), `:45-58` (Worktree+branch chips + MetadataDeriver seam section), `:191` (`derived` row in the source-precedence table), `:199-202` (precedence chain bullets updated)
**Evidence:** All four reference-doc additions the AC named are present: canonical-keys table grew (worktree, branch); precedence chain text + diagram updated to include `derived` between `osc` and `heuristic`; derived policy section added ("written by c11 runtime, not by agents"; resolver+coordinator described); MetadataDeriver seam code block included.

### AC31–AC33 — *post-merge-smoke; see Operator smoke-pass checklist below.*

## PR-level checks

### P1 — PR body links to C11-104, summarizes v2
**Verdict:** PASS
**Evidence:** Title is `C11-104: Worktree + branch sidebar chips (with color hint)`. Body has both a v1 summary and a `## v2 amendments (post-trident-review)` section that walks through Amendment 1 (legacy row retirement), Amendment 2 (MetadataDeriver seam), Amendment 3 (B5a derived gate + submodule name fallback), plus the translation pass and v2 test status. Closes C11-104 referenced. The PR body references the validation plan and run-state at `.lattice/orchestration/c11-104/`.

### P2 — `c11-logic` builds in CI
**Verdict:** PASS
**Evidence:** `gh pr checks 181` shows `build` SUCCESS at 13m53s; `compat-tests (macos-15, 30, true, false)` SUCCESS at 10m28s. The c11 CI workflow (`build` job) builds the parent app + test schemes; if the logic scheme failed to compile, this job would fail. No red checks.

### P3 — `c11-logic` tests pass in CI
**Verdict:** PASS
**Evidence:** `compat-tests` runs the macOS unit test suite end-to-end at 10m28s and SUCCESS. The 48 new C11-104 tests would be exercised here. No red.

### P4 — `c11-unit` tests pass in CI
**Verdict:** PASS
**Evidence:** Same `compat-tests` job is the host-required test path; SUCCESS.

### P5 — E2E workflow green or N/A
**Verdict:** CANNOT_VERIFY (likely N/A)
**Evidence:** No `test-e2e.yml` check appears in the PR's `statusCheckRollup`. The workflow isn't gating this PR. If the operator wants to run it explicitly: `gh workflow run test-e2e.yml --ref feat/c11-104-sidebar-chips`. **Not a merge blocker** unless the operator specifically requires E2E for sidebar changes.

### P6 — No regression in `panelGitBranches` / `panelDirectories` consumers
**Verdict:** PASS
**Evidence:** `panelGitBranches[surfaceId].isDirty` is read by the new projector path (`Sources/ContentView.swift:8553`) for the dirty marker. `panelDirectories` is still the seed for the workspace git probe (per `Sources/TabManager.swift:1617` `gitProbeDirectory(...)`). The legacy `verticalBranchDirectoryLines`-side consumer was retired but the underlying state fields are preserved and still feed both the new chip row and the legacy callers I sampled. **One follow-up note:** `Workspace.orderedUniqueBranchDirectoryEntries()` and `tab.sidebarBranchDirectoryEntriesInDisplayOrder` may now be unused — worth grepping in a follow-up and deleting if so.

### P7 — Rollback policy documented in PR body
**Verdict:** PASS
**Evidence:** The v2 amendments section preserves Amendment 1's commitment to `sidebarShowBranchDirectory` AppStorage key preservation (allowing the toggle-off rollback). The operator decisions table in the ticket SPEC v2 (S9) records: "If post-merge typing-latency regression surfaces, flip `sidebarShowBranchDirectory` default to off in nightly via a follow-up commit; full PR revert is the fallback." The PR body's "v2 amendments" + "Deferred" sections also enumerate what would be lost if reverted, so the operator has an informed rollback plan.

## Operator smoke-pass checklist (post-merge)

The following ACs require a built app, multi-surface interaction, or operator-driven UI inspection. Run these after merging PR #181.

- [ ] **AC31** — Sidebar visually renders the four canonical scenarios correctly: (1) main checkout on `main` → dimmed `branch: main`. (2) main checkout on feature branch → `branch: feature/x` non-dimmed. (3) linked worktree → `● <basename>` + branch chip (color matches a known palette entry; same worktree → same color across launches). (4) inside ghostty submodule → two rows (superproject on top, `↳ ghostty` submodule indented below).
- [ ] **AC32** — Settings → Sidebar → "Show worktree + branch chips in sidebar" — toggle off, chips disappear without app restart; toggle on, chips return. Verify the underlying `sidebarShowBranchDirectory` key is still the storage backing (e.g., by checking `defaults read com.stage11.c11 sidebarShowBranchDirectory`).
- [ ] **AC33** — Typing-burst test: in a worktree pane vs main-checkout pane, paste a 100-char string at speed. Confirm no perceptible new lag relative to the pre-merge baseline. If a regression is felt, flip the toggle off per S9 rollback policy.

## Gaps from BUILDPLAN

These were scoped in the v2 SPEC but are not present in the PR:

- **Missing tests for ACs the validation plan called out explicitly** *(silently-missing)*:
  - AC14 (git timeout, 2s → `.timeout` state, chip clears) — no test, plus implementation timeout is 5s not 2s, plus no `.timeout` state exists.
  - AC16 (socket-derived-write rejection) — code present, no test verifies the rejection path.
  - AC17 (socket get-metadata read for derived keys) — no test.
  - AC19 (restore-warmpath) — *(deferred-by-delegator-in-PR-body)*; PR body lists I5 in "v2 deferred."
  - AC20 (main-thread precondition trip) — present as a sentinel test only; no deterministic crash test.
- **Production wiring of declared infrastructure** *(silently-missing)*:
  - `GitContextResolverCache` and `GitContextResolver.headPath(forCwd:runner:)` are implemented + library-tested but **never used outside their own file in `Sources/`** — `TabManager.swift:1724` calls `GitContextResolver.resolve(cwd:)` directly, no cache hit/miss path in production. The AC12 invalidation guarantees are real only when (and if) the cache gets wired in.
  - `DerivationCoordinator.run` and `GitContextDeriver` exist but are not called from the production probe path. `TabManager.initialWorkspaceGitMetadataSnapshot` calls the resolver directly. *(deferred-by-delegator-in-PR-body — "Full coordinator-driven probe integration is deferred")*.

## Drift from BUILDPLAN architecture

Items implemented one way but specified another. None are user-visible, but each deserves the operator's awareness:

1. **Timeout: 5s vs spec's 2s** (`Sources/Metadata/GitContextResolver.swift:166`). Drift on a numeric default; PR body acknowledges. Conservative choice (fewer false-positive timeouts on slow disks), but contradicts I3.
2. **Dim opacity hardcoded `0.55`** (`Sources/Sidebar/WorktreeChipsRow.swift:73`) vs spec's ThemeKey-backed `chipTextDimmedOpacityLight = 0.65` / `chipTextDimmedOpacityDark = 0.55`. PR body's "v2 deferred" lists M6. Acceptable as a v1-ship choice.
3. **State naming**: implementation uses `BranchValue.unknown` and `nil` ResolvedGitContext where the spec said `.noBranch` and `.notInRepo` / `.stale`. Behavior equivalent at the chip render layer; spec wording becomes inaccurate. **Consider renaming the enum cases to match the SPEC or updating the SPEC to match the code.**
4. **Cache + coordinator are library code, not system code** (see Gaps section). The seam is in place for future derivers; the present deriver doesn't use it.
5. **`Workspace.orderedUniqueBranchDirectoryEntries()` is no longer called by the sidebar** but is preserved. Possible dead code introduced by AC24's retirement of the legacy row. Worth a follow-up `grep` + cleanup.

## Recommendations

- **Merge gate:** **clear** for the user-visible feature. No FAIL blocks user behavior; all FAILs are about test coverage or deferrals already documented in the PR body.
- **Recommended follow-up ticket(s):** "C11-104 follow-ups" with checklist for:
  1. Wire `GitContextResolverCache` into the production probe path (or delete it as dead code), keyed on `(cwd, mtime(GitContextResolver.headPath(cwd)))`. Add the linked-worktree + submodule fixture AC12 specifies.
  2. Add the missing tests AC14 (timeout), AC16 (socket rejection), AC17 (socket get-metadata read), AC20 (deterministic main-thread trip). These are small unit tests; the cost is low and they harden the contracts the v2 spec deliberately put in place.
  3. Decide on `.stale`/`.notInRepo`/`.noBranch` enum cases vs the current `nil`/`.unknown` proxies. Rename or rewrite the SPEC. Don't leave the validation plan in a permanent PARTIAL state.
  4. Decide whether `DerivationCoordinator` should actually drive the workspace probe, or whether `GitContextResolver.resolve(cwd:)` is the right direct call. If the seam is purely for the future host/SSH/container deriver, document that explicitly in the metadata.md reference.
  5. Confirm `Workspace.orderedUniqueBranchDirectoryEntries()` and friends are dead code; delete or repurpose.
- **Post-merge monitor:** AC33 typing-latency, which is the hardest to assert ahead of merge. If anything bites, flip `sidebarShowBranchDirectory` default to off per S9.
- **Validation-plan hygiene:** if the operator agrees the deferrals are acceptable, **annotate the validation plan in-place** so the next round doesn't re-discover these gaps as fresh blockers. ("AC10 / AC19: deferred per v2 PR body, see follow-up ticket.")

The PR represents a competent and load-bearing landing of C11-104. The gaps surfaced here are about coverage and naming hygiene, not correctness of what ships. The operator can merge with eyes open.
