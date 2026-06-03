### 1. Verdict

**FAIL (plan-level)** — The plan is close, but two implementation-critical areas need revision before work begins: the Strategy A fallback is not fully executable, and the scheme update instructions are incomplete enough to risk a target that exists but is not reliably built/tested by the intended schemes.

### 2. Summary

I reviewed the C11-27 plan to split `c11Tests` into host-required and logic-only Xcode test targets. The plan is unusually thorough on classification, risk tracking, CI selector updates, and acceptance gates, but it still has gaps in the mechanics that actually make the new target compile and run under all schemes. Fixing those gaps now should be straightforward and will avoid wasting the implementation pass on Xcode scheme/project churn.

### 3. Issues

**[MAJOR] §2.1 / §3 — Strategy A fallback omits the bulk `@testable import` rewrite**

Strategy A says moved tests must remove their existing `@testable import c11` / `@testable import c11_DEV` lines because production sources are dual-compiled into the `c11LogicTests` module. The spike step edits the four spike files, but the bulk workflow and Ruby script only move target membership and add source files; they do not remove imports from the remaining 70+ moved tests. If Strategy B fails and the implementer falls back to A, the plan likely leaves the target in an uncompilable or internally inconsistent state.

**Recommendation:** Add an explicit Strategy A bulk rewrite step, preferably in `scripts/c11-27-split-tests.rb` or a companion script, that removes the conditional `canImport(c11_DEV)` / `canImport(c11)` import block from every file moved into `c11LogicTests`. Include a validation check that no moved Strategy A test still contains `@testable import c11` or `@testable import c11_DEV`.

**[MAJOR] §4.5 / §4.6 — Scheme updates specify TestableReferences but not BuildActionEntries**

The plan says to add `c11LogicTests` as a `TestableReference` to `c11-unit.xcscheme` and `c11-ci.xcscheme`, but it does not explicitly add a matching `<BuildActionEntry buildForTesting="YES">` for the new test target. Existing schemes include both app and test bundle build action entries. Without the new build action entry, `xcodebuild build -scheme c11-unit` may not compile the logic target, and `xcodebuild test` behavior becomes dependent on Xcode's implicit testable handling rather than an explicit scheme contract.

**Recommendation:** Add exact XML or xcodeproj-driven scheme mutation steps for all three schemes: `c11-logic`, `c11-unit`, and `c11-ci`. For `c11-unit` and `c11-ci`, require both a BuildActionEntry and a TestableReference for `c11LogicTests`, and add an acceptance check that `xcodebuild build -scheme c11-unit` compiles both test bundles.

**[MINOR] §8 — Test-count acceptance criterion confuses files with XCTest cases**

The plan repeatedly uses "101 tests" to mean 101 test files, then proposes verifying via xcresult test-case counts: "73-74 from `c11LogicTests`, 27-28 from `c11Tests`, sum = 101." XCTest result counts are test methods/suites, not source files, so this criterion will not verify what the plan intends.

**Recommendation:** Reword this acceptance gate to count test bundle file membership from the project file or count XCTest suites by class name if that is the intended proxy. Keep method-count verification separate, since it will be much larger than 101.

**[MINOR] §8 — Memory update requirement points outside the project workflow**

The acceptance list requires `feedback_no_local_xcodebuild_test.md` to be updated, but the plan later frames this as either a project note or something for Atin to update directly. In this environment the matching memory files are under `~/.claude/projects/.../memory/`, outside the repo's normal reviewable diff, so making this a hard PR acceptance item is ambiguous.

**Recommendation:** Make the PR requirement concrete and reviewable: add `.lattice/plans/c11-27-memory-note.md` with the exact memory change request, and leave the actual `~/.claude` memory edit as an operator follow-up unless the implementer is explicitly authorized to edit it.

### 4. Positive Observations

The plan does a strong job correcting the original problem framing and keeping the implementation scoped to a target split rather than drifting into hostless UI-test refactors or a `c11Core` extraction.

The PURE/HOST audit is detailed, and the second pass over misleading AppKit imports is exactly the right kind of skepticism for this task. The spike-first strategy is also good: proving Strategy B before bulk project surgery is much cheaper than migrating 70+ files and discovering the loader approach does not work.

The CI update list is concrete, especially the `mailbox-parity.yml` selector migration and the explicit decision not to double-run `c11-logic` in `ci.yml`. The risk register captures the important failure modes and gives the implementer useful fallback paths once the scheme and Strategy A gaps above are closed.
