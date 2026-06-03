# Merged Code Review — C11-27 (Split `c11Tests` into pure-logic vs host-required)

## 1. Verdict

**FAIL (implementation-level)** — one MAJOR gap (baseline-comparison CI gate) plus one MAJOR diff-hygiene caveat (xcodeproj churn) need resolution before merge. The split itself is mechanically correct and the schemes/build settings are sound; the failure is at the CI-gating seam where the plan explicitly required *something* and neither option was delivered. A small CI wrapper or an explicit PR-description carveout flips this to PASS.

## 2. Synthesis

The two completed reviews (claude + codex; gemini timed out) converge on the same substantive picture: the target split is clean (74 logic + 27 host = 101 files, matches the plan's math), schemes are correctly wired for both BuildAction and TestAction in all three places (`c11-logic`, `c11-unit`, `c11-ci`), `TEST_HOST` is cleared, and the Strategy-B `c11.debug.dylib` + rpath adaptation is the right correction over the plan's §2.3 spec. Both reviewers flag the same single blocker — the baseline-comparison harness from plan §3 step 1 is missing — but classify it differently: claude treats it as PR-description-fixable and votes PASS, codex treats the unmet gate as implementation-level FAIL. They diverge on one minor: claude reads `scripts/c11-27-split-tests.rb`'s inline `c11.debug.dylib` comment block as exemplary documentation of the spike's discovery, while codex reads the script's top-of-file header summary as contradicting the implemented loader code. Inspection shows both can be true — the header is stale, the inline block is correct — so codex's nit stands. Net: the underlying engineering work is high quality; the merge-readiness gap is in CI plumbing and PR framing, not in the split itself.

## 3. Issues (consolidated by severity)

**[MAJOR] CI baseline-comparison harness not implemented; plan §3 step 1 unmet — `.github/workflows/ci.yml:198`, `.github/workflows/mailbox-parity.yml`**
*Found by: claude, codex.* The plan offered two options: (a) wrap the `xcodebuild test` step to diff PR failures against `.lattice/plans/c11-27-baseline-failures.txt`, exiting 0 when the PR set is a subset; or (b) document plainly in the PR that `c11-unit` stays red until the 47 baseline failures are fixed/isolated. Neither shipped. Run 25953710923 on this branch is red with exactly the 5 baseline failures (`MailboxDispatcherTests.testDispatchesToNamedRecipient`, `…testInvalidEnvelopeQuarantinedToRejected`, `…testResolveEmptyWhenRecipientNotLive`, `…testSecondDispatchOfSameIdIsNoop`, `StdinHandlerFormattingTests.testDeliverReturnsTimeoutEvenWhenWriterBlocksMultipleSeconds`). Reviewer-side cross-check is awkward because the baseline file labels them `c11Tests.X` while CI now reports `c11LogicTests.X` (bundle-prefix needs stripping).
**Fix:** Pick one. Lighter touch: in the PR description, enumerate the 5 expected baseline failures, link `.lattice/plans/c11-27-baseline-failures.txt`, and pin them to `origin/main@7e0e0b282`. Heavier (and the right long-term answer): a bash wrapper around `xcodebuild test` that captures `Test Case .* failed` lines, normalizes the `c11LogicTests./c11Tests.` prefix, and `diff`s against the baseline; exit 0 if subset. Either unblocks merge.

**[MAJOR] `GhosttyTabs.xcodeproj/project.pbxproj` — Plan §8 "no formatting churn" gate is unmet**
*Found by: claude.* The bulk-move commit (`12f506a27`) is 1182 ins / 1050 del in `project.pbxproj` alone (2232 lines). The xcodeproj gem rewrote indentation (mixed tabs+spaces → tabs only), reordered some `PBXBuildFile` entries, and re-issued some object IDs. Line-by-line diff review is impractical; structural gates (`xcodebuild -list`, file-membership count, build-settings spot-check) are the only realistic acceptance path — and they all pass.
**Fix:** Don't fight the gem. Add a one-liner to the PR description noting the diff is large because of xcodeproj-gem normalization, and that the structural checks in §8 are the right gate. Optionally fold a "pbxproj edits via the xcodeproj gem normalize formatting" note into `CLAUDE.md`'s Pitfalls section so the next pbxproj-touching ticket isn't surprised.

**[MINOR] `.lattice/plans/task_01KRQD33HPPS66DHVKANVA8KWJ.md:922` — Required `c11-27-memory-note.md` artifact missing**
*Found by: codex.* The plan's acceptance checklist requires `.lattice/plans/c11-27-memory-note.md` (capturing the Strategy-B / dylib discovery for future agents). It's not in the diff.
**Fix:** Either add the memory note (one short paragraph: Strategy B requires Debug `BUNDLE_LOADER = c11.debug.dylib` because `ENABLE_DEBUG_DYLIB = YES`, plus the `@loader_path/../../../c11 DEV.app/Contents/MacOS` rpath arithmetic), or strike the artifact from the plan if it's been superseded by the CLAUDE.md edits.

**[MINOR] `scripts/c11-27-split-tests.rb` — Top-of-file header summary contradicts the implemented Debug loader path**
*Found by: codex.* The script header summarizes Strategy B as pointing at `c11.app` / `c11 DEV.app`, but the actual Debug `BUNDLE_LOADER` (correctly) points at `c11.debug.dylib`. The inline comment block at lines 140–148 documents the dylib decision well; the file header is the stale piece.
**Fix:** Bring the header in line with the inline block (Debug → `c11.debug.dylib` + rpath; Release → `c11 DEV.app/Contents/MacOS/c11`).

**[MINOR] `.github/workflows/mailbox-parity.yml:12` — Header comment still references `c11-unit`**
*Found by: codex.* The `-only-testing:` selectors and `-scheme` flag are correctly updated to `c11-logic` / `c11LogicTests`, but the top-of-file comment hasn't caught up.
**Fix:** One-line edit: replace `c11-unit` in the header comment with `c11-logic` / `c11LogicTests`.

**[MINOR] Git history — Spike commit not isolated; merged into bulk move**
*Found by: claude.* Plan §3 step 2 and §8 acceptance prescribed a separate first commit for the four spike files (Mailbox/Stdin/Theme/Workspace) so the spike could be reviewed in isolation. Actual history goes baseline-pin → AppKit-import-drop → bulk move (74 files, one commit) → schemes → CI → docs.
**Fix:** Not worth rewriting history for. PR description should note the spike was validated locally against §2.2 candidates with the monitored `pgrep` block before the bulk move; future similar tickets should keep the spike as its own commit.

**[MINOR] `CLAUDE.md:138` — Wall-time framing reads as if every checkout pays the c11 build cost**
*Found by: claude.* Current copy says first invocation pays the multi-minute c11 build because `c11-logic` depends on the `c11` target via `BUNDLE_LOADER`. Accurate but undersells the warm-cache fast loop.
**Fix:** Optional polish. Trim to one sentence ("First invocation after a clean checkout builds the c11 app once for `BUNDLE_LOADER`; warm runs are ~30 s"); leave the dylib detail in the script comment where it already lives.

## 4. Positive Observations

- **Test membership split is exact.** 74 logic + 27 host = 101 files — matches plan §8 acceptance math.
- **Strategy-B `c11.debug.dylib` discovery is a real find and is documented inline.** The plan's §2.3 spec was wrong about Debug `BUNDLE_LOADER`; the implementer found, fixed, and explained it (`scripts/c11-27-split-tests.rb:140-148`). Exactly what the spike protocol existed for.
- **`LD_RUNPATH_SEARCH_PATHS` arithmetic checks out.** `@loader_path/../../../c11 DEV.app/Contents/MacOS` resolves to where the dylib actually lives; CI confirms tests load and run (the 5 failures are assertion-level, not load-level).
- **Schemes wired both at BuildAction and TestAction** for `c11-ci`, `c11-unit`, and the new `c11-logic`, avoiding the silent-build-no-compile footgun plan §4.5/§4.6 warned about.
- **`xcodebuild -showBuildSettings` confirms the spec:** `TEST_HOST` empty for both configs; `BUNDLE_LOADER` per-config; `PRODUCT_BUNDLE_IDENTIFIER = com.stage11.c11.logictests`.
- **Performance target met.** 92 selected tests run in ~7.4 s of test phase, ~12 s total scheme time — inside plan §8's cap, no DEV.app launch.
- **`mailbox-parity.yml` selector flip is complete.** All ten `-only-testing` flags moved to `c11LogicTests/...`; scheme correctly switched to `c11-logic`; CI evidence confirms the right bundle is selected.
- **No drive-by changes.** Only one source file (`TerminalControllerSocketSecurityTests.swift`, AppKit-import drop) is touched outside project / schemes / CI / docs — the legitimate VERIFY-PROMOTE edit, isolated to its own commit (`7356782e4`).
- **Script idempotency.** "Find existing target or create" + per-file membership skip + defensive `TEST_HOST = ''` means the script can be re-run safely.

## 5. Reviewer Agreement

**Strong agreement on substance.** Both reviewers agree the split is mechanically correct, the schemes are wired right, the file counts match, the Strategy-B dylib adaptation is the right call, and the `mailbox-parity.yml` selector flip is complete. Both flag the missing baseline-comparison CI gate as the most important loose end.

**Disagreement on verdict.** Claude votes PASS treating the baseline gap as a PR-description fix; codex votes FAIL treating it as an unmet plan-level gate. The disagreement is severity-classification, not factual — they describe the same hole the same way. This merged verdict sides with codex (FAIL implementation-level) on the grounds that plan §3 step 1 explicitly required one of two outcomes and neither shipped, but notes the fix is small and the underlying engineering work is high-quality.

**Disagreement on the Ruby script header.** Claude reads the script's inline comment block on the dylib decision as exemplary and doesn't mention the file header; codex reads the file header as contradicting the implementation. Inspection resolves it: the inline block is good, the header is stale. Codex's nit stands as a minor.

**Gemini failed/timed out**, so the merged review is built on two perspectives rather than three. The agreement between claude and codex on every substantive point reduces the risk of a missed angle, but a third lens on the pbxproj diff and the CI workflow would have been welcome.
