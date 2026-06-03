### 1. Verdict

**FAIL (plan-level)**

### 2. Summary

The plan correctly identifies the operator pain and the high-value split between pure logic and host-required tests, but it leaves the central Xcode feasibility question unresolved. A no-host XCTest bundle cannot simply move existing `@testable import c11` tests into a new target unless the plan defines how that bundle links the app code without `TEST_HOST`/`BUNDLE_LOADER`.

### 3. Issues

**[CRITICAL] Approach / Risks — Hostless test target linkage is not planned**
Most sampled "pure" tests import the app module through `@testable import c11` or `@testable import c11_DEV`. The current `c11Tests` target works because it has `TEST_HOST` and `BUNDLE_LOADER` pointing at `c11 DEV.app`/`c11.app`; a standalone logic test bundle will not have the app executable as its bundle loader. The plan treats `@testable import c11` as a workaround, but that is exactly the path that usually requires either a host executable or a framework/library product for the test bundle to link against.
**Recommendation:** Revise the plan to choose and specify the code-under-test strategy before implementation: extract a small `c11Core`/SwiftPM or Xcode framework target for the pure sources, or explicitly dual-compile a curated subset of source files into the logic test target with clear exclusions for `c11App.swift` and UI/AppKit-heavy files. Include the exact build settings for the new target, especially empty `TEST_HOST`/`BUNDLE_LOADER`, dependencies, linker inputs, and module import shape.

**[MAJOR] Approach / Audit — Direct grep classification is insufficient for target membership**
Classifying tests only by direct mentions of `AppKit`, `SwiftUI`, `WebKit`, `NSWindow`, etc. does not prove they are hostless. A test file can have zero hits while calling app types whose source files import AppKit, touch `NSApp`, use `@MainActor`, depend on app singletons, or require app resources. The plan notes this as a risk, but it does not add a concrete audit step beyond compiling and chasing errors.
**Recommendation:** Add a second-stage classification before pbxproj edits: for each candidate pure test, record the production types/functions it exercises and the production source files those symbols live in. Mark files as logic-eligible only when those source files can be linked into the chosen no-host target without app lifecycle or UI dependencies. Keep the generated classification artifact in the plan doc or repo so reviewers can see why each file moved.

**[MAJOR] Approach / CI and docs — Update surface is underspecified**
The plan says update `.github/workflows/ci.yml`, `mailbox-parity.yml`, "etc.", and `CLAUDE.md`, but the repository has more active references that affect this change: `ci-macos-compat.yml`, `test-e2e.yml`, `c11-ci.xcscheme`, `docs/DEVELOPMENT.md`, and the mirrored agent docs (`AGENTS.md`, plus the canonical `~/.claude/CLAUDE.md` per local instructions). `mailbox-parity.yml` also uses `-only-testing:c11Tests/...`, so moving Mailbox tests changes test identifiers unless target naming is accounted for.
**Recommendation:** Add an explicit file-by-file update list covering schemes, workflows, docs, and any `-only-testing` filters. Decide the new test target product/module name up front and include a migration rule for CI filters such as `-only-testing:<newTarget>/MailboxDispatcherTests`.

**[MINOR] Acceptance — Verification criteria are not fully testable**
The acceptance criteria say `c11-logic` passes "modulo pre-existing failures" and runs in under five seconds, but they do not define how to prove that no app host launches. The pass criterion is also ambiguous if any of the moved pure tests are among the known pre-existing failures.
**Recommendation:** Add concrete checks: `xcodebuild -showBuildSettings -scheme c11-logic` shows empty `TEST_HOST` and `BUNDLE_LOADER`; a logic test run produces no `c11 DEV.app` process/window; runtime is measured from a clean-enough local invocation; and any pre-existing failing test that remains in the logic target is listed explicitly or left in the hosted target until fixed.

### 4. Positive Observations

The plan is grounded in a real audit of the current test surface and correctly focuses on the highest-leverage subset rather than trying to headless-ify the UI-heavy tests. It also calls out pbxproj fragility, pre-existing failures, PR ordering with #164, and the need to update CI and testing policy. The separation between `c11-unit` as full coverage and `c11-logic` as a fast no-host loop is aligned with the task's goal.
