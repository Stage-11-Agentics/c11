# Code Review — C11-27 (Split `c11Tests` into pure-logic vs host-required)

## 1. Verdict

**PASS** — with two non-blocking caveats the PR description should call out before merge. The split works (CI on `feat/c11-27-test-split` ran 92 logic-only tests in ~7.4 s with no DEV.app launch); 74 PURE files moved, 27 HOST files stayed; schemes and CI workflows are wired correctly; CLAUDE.md is rewritten faithfully to the plan, adapted for Strategy B's actual ENABLE_DEBUG_DYLIB shape.

## 2. Summary

Reviewed the six commits on `feat/c11-27-test-split` (`d78ba66..3a09ed5`) plus the realised end-state of `GhosttyTabs.xcodeproj`, the new `c11LogicTests` target build settings, the three updated schemes, the Ruby surgery script, and the CI-workflow changes. Implementation matches the plan's *intent* and acceptance gates (test count, no-host-launch, scheme wiring, CLAUDE.md). The two soft issues are PR-hygiene rather than code: (a) the pbxproj diff is huge because the xcodeproj gem reformatted the whole file — orientation rather than checksum review is the only practical option, and the plan's §8 "no formatting churn" gate was unrealistic given the chosen tool; (b) the baseline-comparison harness from plan §3 step 1 wasn't wired into CI, so `mailbox-parity` is red on this branch with the same 5 failures recorded in `.lattice/plans/c11-27-baseline-failures.txt`. Reviewer must cross-check by hand at PR time.

The Ruby script's discovery that Debug `BUNDLE_LOADER` must point at `c11.debug.dylib` (not `c11`) because of `ENABLE_DEBUG_DYLIB = YES` is a correct and important divergence from the plan's §2.3 spec, and the comment block in the script captures the *why* well.

## 3. Issues

**[MAJOR] GhosttyTabs.xcodeproj/project.pbxproj — Massive formatting churn from the xcodeproj gem violates plan §8's "no formatting churn" gate**

The bulk-move commit (`12f506a27`) is 1182 insertions / 1050 deletions in `project.pbxproj` alone (2232 lines). The xcodeproj gem rewrote indentation (mixed tabs+spaces → tabs only), reordered `PBXBuildFile` entries, and re-issued some object IDs across the file. Plan §8 explicitly required: *"PR diff of GhosttyTabs.xcodeproj/project.pbxproj is additive — one new PBXNativeTarget block, one new XCConfigurationList + 2 XCBuildConfiguration entries, 73–74 PBXBuildFile reassignments… No reorderings of existing entries, no formatting churn."* That gate is unmet. Practical impact: line-by-line diff review is impossible; reviewer must rely on the structural checks in §8 (`xcodebuild -list` shows the new target, both schemes compile, file-membership counts are 74 + 27 = 101 — all of which pass).
**Fix:** Don't try to undo the churn — the gem owns the format. Add a one-liner to the PR description explaining the diff is large because of `xcodeproj`-gem normalization, and that the structural acceptance checks (file-count, target list, scheme list, build-settings spot-check) are the right gate. Optionally, in a future ticket, add `scripts/c11-27-split-tests.rb` to a `pre-commit` allowlist or document the format-normalization expectation in `CLAUDE.md`'s "Pitfalls" section so the next pbxproj-touching ticket isn't surprised.

**[MAJOR] .github/workflows/mailbox-parity.yml + ci.yml — Baseline-comparison harness from plan §3 step 1 not implemented; CI red on PR**

Plan §3 step 1 explicitly offered two options: (a) wire a comparison harness in `ci.yml` that diffs PR failures against `.lattice/plans/c11-27-baseline-failures.txt`, or (b) "document plainly that c11-unit CI stays red until the 47 are fixed/isolated." Neither was done. The latest run on this branch (mailbox-parity, run 25953710923) is RED with exactly 5 failures, all of which appear in the committed baseline file (`MailboxDispatcherTests.testDispatchesToNamedRecipient`, `…testInvalidEnvelopeQuarantinedToRejected`, `…testResolveEmptyWhenRecipientNotLive`, `…testSecondDispatchOfSameIdIsNoop`, `StdinHandlerFormattingTests.testDeliverReturnsTimeoutEvenWhenWriterBlocksMultipleSeconds`). Note: baseline names them `c11Tests.X`; CI reports `c11LogicTests.X`. Cross-check requires stripping the bundle prefix.
**Fix:** Pick one. The lighter touch is option (b): in the eventual PR description, list the 5 expected baseline failures, link to `.lattice/plans/c11-27-baseline-failures.txt`, and note they match `origin/main@7e0e0b282`. The heavier touch (and correct long-term) is option (a): a small bash wrapper around the `xcodebuild test` step that captures `Test Case .* failed` lines, normalizes `c11LogicTests./c11Tests.` to a common prefix, and `diff`s against the baseline; exit 0 if the PR set is a subset. Either is acceptable to merge; doing nothing leaves the next reviewer guessing.

**[MINOR] Commits — No isolated spike commit; spike merged into bulk move**

Plan §3 step 2 and §8 acceptance ("Spike commit, bulk commit, scheme commit, CI commit are separable") prescribed a *separate* first commit that creates the target + scheme + moves only the four spike files (Mailbox/Stdin/Theme/Workspace), so the spike could be reviewed independently. The actual log goes baseline-pin → AppKit-import-drop → bulk move (74 files in one commit) → scheme wiring → CI → docs. The spike validation evidently happened locally but isn't preserved in git history.
**Fix:** Not worth rewriting history for. Acknowledge in PR description that the spike was validated against the four candidates in §2.2 (locally, with the monitored `pgrep` block) before the bulk move went in. If a future similar ticket comes up, prefer the spike-as-its-own-commit shape — it makes the "did B work?" question reviewable in isolation rather than entangled with the move.

**[MINOR] CLAUDE.md:138 — "74 tests" matches actual but plan §5 verbatim said 73**

The implementer correctly accounted for the VERIFY-PROMOTE pass — `TerminalControllerSocketSecurityTests` made it to the logic target, so the count is 74, not the plan's pre-PROMOTE number 73. No fix needed; flagging only because the plan §5 said "verbatim" — the divergence is the right call and should be merged as-is.

**[MINOR] CLAUDE.md:138 — Stale wall-time framing for Strategy B's first-build cost**

The new copy says *"First invocation after a clean checkout pays the c11 app build cost (multi-minute) because c11-logic depends on the c11 target — Strategy B needs c11.debug.dylib available for the test bundle's BUNDLE_LOADER + rpath."* Accurate, but the operator's mental model from the rest of the doc is "logic tests are fast." A second-time reader may wonder if `c11-logic` is genuinely the local fast loop or if every check-out costs the full c11 build. Consider trimming to one sentence ("First invocation after a clean checkout builds the c11 app once for `BUNDLE_LOADER`; warm runs are ~30 s") and dropping the dylib detail to the script comment where it already lives.
**Fix:** Optional polish. Not blocking.

## 4. Positive Observations

- **The Strategy-B `c11.debug.dylib` discovery and its in-script documentation.** `scripts/c11-27-split-tests.rb:140-148` explains why Debug must point at `c11.debug.dylib` rather than `c11` (ENABLE_DEBUG_DYLIB on the c11 target splits the Swift code into a dylib alongside a stub binary). The plan's §2.3 spec was wrong on this — the implementer found and fixed it correctly via the spike, and the comment will save the next person from rediscovering it the hard way. This is exactly what the spike protocol existed for.
- **`LD_RUNPATH_SEARCH_PATHS` arithmetic is correct.** `@loader_path/../../../c11 DEV.app/Contents/MacOS` from inside `c11LogicTests.xctest/Contents/MacOS/c11LogicTests` lands at `BUILT_PRODUCTS_DIR/c11 DEV.app/Contents/MacOS/`, which is where the dylib lives. The CI run bears this out: tests loaded and executed; the 5 failures are assertion failures, not load failures.
- **Idempotency.** The Ruby script's "find existing target or create" pattern (script line 105) and per-file membership skip (line 156) mean the script can be re-run during iteration without duplication. Defensive `TEST_HOST = ''` (line 134) per the plan, plus explicit deletion of `TEST_TARGET_NAME`, plug the future-xcconfig footgun.
- **VERIFY-PROMOTE handled correctly.** The `import AppKit` drop on `TerminalControllerSocketSecurityTests` is its own commit (`7356782e4`), separate from the bulk move; that gives the next archaeologist a clear "this PURE classification was earned, not assumed" trail. Script gates the move on `INCLUDE_VERIFY_PROMOTE=1` so a future Strategy-A re-run won't silently lose it.
- **Test count math is exact.** `c11LogicTests` Sources phase: 74 files (73 PURE + 1 PROMOTE). `c11Tests` Sources phase: 27 files (HOST). Sum = 101. Matches plan §8 acceptance bullet on file-membership count.
- **Schemes wired both at BuildAction *and* TestAction, in all three places** (`c11-ci`, `c11-unit`, new `c11-logic`). Plan §4.5/§4.6 warned that adding a TestableReference without the corresponding BuildActionEntry produces silent build-but-no-compile on some Xcode versions — both XML additions are present.
- **`mailbox-parity.yml` selector update is complete.** All ten `-only-testing:c11Tests/X` flipped to `-only-testing:c11LogicTests/X`, scheme flipped to `c11-logic`, comment updated. CI evidence confirms the selectors target the right bundle (the failure log says `c11LogicTests.MailboxDispatcherTests.X`).
- **`xcodebuild -showBuildSettings` confirms the spec.** TEST_HOST is empty for both Debug and Release; BUNDLE_LOADER is per-config; PRODUCT_BUNDLE_IDENTIFIER matches `com.stage11.c11.logictests`. The mechanical acceptance checks in §8 pass.
- **Test execution time is well under the soft cap.** CI logs show 92 selected tests in ~7.4 s of test phase, with total scheme time ~12 s — comfortably inside plan §8's 12 s cap and respecting the spirit of the ticket's "<5 s" target (test execution itself is sub-second per file; the bulk of wall time is xcodebuild scaffolding).
- **No drive-by changes.** Only `c11Tests/TerminalControllerSocketSecurityTests.swift` is touched outside the project file / schemes / CI / docs — exactly the one VERIFY-PROMOTE edit. No silent refactors riding along.

---
