### 1. Verdict

**FAIL (plan-level)** — The direction is right, but the implementation plan leaves the central no-host XCTest linkage strategy unresolved. Implementation should not begin until the plan states exactly how the new hostless target will access c11 production code without `TEST_HOST` / `BUNDLE_LOADER`.

### 2. Summary

I reviewed the C11-27 plan against the current Xcode project, schemes, CI workflows, and `c11Tests` source shape. The plan correctly identifies the operator pain and the broad split between UI-hosted and pure-logic tests, but it treats the split mostly as target membership even though the moved tests currently use `@testable import c11` against an app executable target. The main blocker is that a hostless XCTest bundle cannot simply keep the current app-hosted import/linking model; the plan needs a concrete module strategy before pbxproj work starts.

### 3. Issues

**[CRITICAL] Approach / Risks — No concrete linkage strategy for hostless tests**
The current `c11Tests` target is an app-hosted unit-test bundle: its build settings set `BUNDLE_LOADER = "$(TEST_HOST)"`, `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11"`, and `TEST_TARGET_NAME = c11`. The test files overwhelmingly use `@testable import c11` or `@testable import c11_DEV`. If the pure target has no host application and no `BUNDLE_LOADER`, the plan does not explain how those tests will resolve symbols from the c11 app executable at runtime. The risk section lists "`@testable import c11`" as a workaround, but that is the current hosted shape, not a demonstrated no-host solution.

**Recommendation:** Add a required spike before bulk migration: create the new hostless target with one representative pure test, explicitly set empty `TEST_HOST` and `BUNDLE_LOADER`, and prove compile + run. The plan must then lock one production-code access strategy: extract a `c11Core` / SwiftPM library target, compile a carefully selected set of pure production sources into the logic-test target, or another verified approach. If extracting a library is necessary, remove it from "Out of scope" and plan the smallest viable extraction.

**[MAJOR] Approach / CI — Target rename effects on `-only-testing` selectors are underspecified**
The plan says to update CI workflows broadly, but `.github/workflows/mailbox-parity.yml` uses explicit selectors such as `-only-testing:c11Tests/MailboxEnvelopeValidationTests`, `MailboxDispatcherTests`, and `StdinHandlerFormattingTests`. The plan says all Mailbox tests are in the pure bucket, so those selectors will need the new target name after migration. If not updated, CI can silently run no tests or fail in a confusing way depending on xcodebuild behavior and target membership.

**Recommendation:** Decide the exact target/module name up front, then add a file-specific migration step for `mailbox-parity.yml`: update every `-only-testing:c11Tests/...` selector to `-only-testing:<newLogicTarget>/...`. Also explicitly audit `ci.yml`, `ci-macos-compat.yml`, `test-e2e.yml`, `c11-unit.xcscheme`, and `c11-ci.xcscheme`.

**[MAJOR] Audit / Risk Identification — Grep classification is not strong enough to prove hostless safety**
The classifier only checks a narrow list of direct UI symbols. A broader scan catches many more files with AppKit/Foundation UI-adjacent symbols or main-thread assumptions (`@MainActor`, `NSScreen`, `NSColor`, `NSWorkspace`, `DispatchQueue.main`, etc.). More importantly, a test can contain zero UI symbols while exercising production code that initializes app-only or main-actor state transitively. The plan mentions chasing compile errors, but it does not require a runtime smoke pass or classify by exercised production dependencies.

**Recommendation:** Keep the grep audit as a first pass, but add a validation phase that migrates a small representative slice first: one Mailbox test, one Health parser test, one Theme/settings test, and one Workspace snapshot/blueprint test. Use the result to refine the classifier before moving all 73 files. The pinned classified list should include the reason each moved file is considered hostless, not only "zero grep hits."

**[MAJOR] Approach / Completeness — Exact files and project mutations are not specified**
The plan names `GhosttyTabs.xcodeproj/project.pbxproj`, two example workflows, and `CLAUDE.md`, but the repo has additional active surfaces: `c11-unit.xcscheme`, `c11-ci.xcscheme`, `.github/workflows/ci-macos-compat.yml`, `.github/workflows/test-e2e.yml`, `AGENTS.md` as the repo symlink to `CLAUDE.md`, and the global canonical `~/.claude/CLAUDE.md` called out by the local instructions. The plan also leaves the target name undecided (`c11-logic-tests` vs `c11Tests-Pure`), which affects scheme XML, product names, module imports, and CI selectors.

**Recommendation:** Revise the plan with a concrete file-by-file change list and one chosen name for the new target, product, scheme, and module. Include the mirrored docs update explicitly: repo `CLAUDE.md`/`AGENTS.md` plus `~/.claude/CLAUDE.md` if this implementation agent is expected to update the canonical copy.

**[MINOR] Acceptance — Runtime target is optimistic and not fully measurable**
The acceptance criterion says the new target runs in `<5 seconds`. That may be feasible for a warm no-host run, but 73 test files include disk-heavy Mailbox and persistence tests, so `<5 seconds` may be an arbitrary constraint rather than a validated requirement. "No app host launches" is also not paired with a concrete verification method.

**Recommendation:** Change acceptance to something measurable and tied to the actual goal: no `c11 DEV.app` process/window is launched, `TEST_HOST`/`BUNDLE_LOADER` are empty for the logic target, and logic-test wall time is recorded with a target threshold based on the vertical-slice run. Keep `<5 seconds` only if the spike demonstrates it.

### 4. Positive Observations

The plan frames the real user pain accurately and corrects the earlier misconception that the operator's existing c11 instance is what freezes. It also makes the right high-level product decision: splitting pure logic tests from host-required tests is a smaller, higher-value move than trying to headless-ify every UI/window test.

The plan is appropriately cautious about pbxproj editing and pre-existing test failures, and it preserves the full `c11-unit` behavior while adding a faster `c11-logic` loop. The audit numbers are useful as a starting point, and the out-of-scope boundaries are mostly sensible once the core linkage question is resolved.
