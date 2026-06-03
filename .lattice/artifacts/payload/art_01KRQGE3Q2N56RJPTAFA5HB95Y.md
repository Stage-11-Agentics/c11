### 1. Verdict

**FAIL (plan-level)** — The plan is strong and close, but it changes acceptance semantics and leaves a few execution-critical contradictions unresolved before implementation.

### 2. Summary

I reviewed the C11-27 plan for splitting `c11Tests` into host-required and logic-only test targets. The decomposition, file audit, scheme/workflow inventory, and risk register are unusually thorough, but implementation should not start until the plan resolves three plan-level issues: the timing criterion is relaxed before owner approval, local `xcodebuild test` usage contradicts the current repo policy, and baseline test failures are captured but not integrated into the raw CI commands that will gate the PR.

### 3. Issues

**[MAJOR] §8 Acceptance criteria — Task's `<5 seconds` requirement is changed to `≤ 12 seconds` without pre-implementation approval**

The task acceptance says the new target runs in `<5 seconds`; the plan replaces that with "test phase under 12 s" and says Atin can confirm acceptance at PR review. That is too late. If the ticket owner really requires `<5 seconds`, the implementer could spend the whole pass building toward a target that fails acceptance.

**Recommendation:** Resolve this before implementation. Either keep the original `<5 seconds` criterion and add explicit optimization steps if the spike misses it, or update the ticket/plan with owner-approved wording such as "no app launch; warm test phase ≤ 12 s; total wall time documented separately."

**[MAJOR] §2.2 / §3 / §8 — Plan requires local `xcodebuild test` runs before the local-test policy is changed**

The current repo policy says never run tests locally, and `CLAUDE.md` still says `c11-unit` is "safe" even though the task exists because that is false for hosted tests. The plan tells the implementer to run monitored `xcodebuild test -scheme c11-logic` locally during the spike and acceptance checks. That may be the right validation, but it needs an explicit, narrow exception approved in the plan; otherwise the implementer is asked to violate standing repo instructions before the new safe scheme has been proven.

**Recommendation:** Add a "C11-27 local test exception" section before the spike protocol. It should authorize only the monitored `c11-logic` spike command, require a preflight `pgrep`, forbid `c11-unit`/`c11-ci` local test runs, and state who runs it if agents should not.

**[MAJOR] §3 / §6 / §8 — Baseline failures are recorded but not reconciled with raw CI `xcodebuild test` gates**

The plan repeatedly says pre-existing main failures are out of scope and should be treated as non-regressions, but the CI update still runs raw `xcodebuild ... test`. A raw XCTest failure exits nonzero; a checked-in `.lattice/plans/c11-27-baseline-failures.txt` does not make CI pass "modulo baseline." If those failures still exist in either bundle, the PR will remain red despite the plan declaring them acceptable.

**Recommendation:** Clarify the actual current state. If main is green, remove or downgrade the "47 pre-existing failures" path so it does not confuse acceptance. If main is not green, add an explicit CI comparison harness or state that C11-27 cannot require green CI until the baseline failures are fixed/isolated.

**[MAJOR] §3 Ruby script / Strategy A — Strategy A source lookup and dependency handling are under-specified**

The fallback Strategy A script resolves source references by basename only:

```ruby
sources_group.recursive_children.find { |c| c.respond_to?(:path) && c.path == leaf }
```

That can select the wrong file if `Sources/` ever has duplicate leaf names, and Strategy A also does not specify how to add package/framework/resource dependencies needed by dual-compiled production sources. Because Strategy A is the official fallback if Strategy B fails, it needs to be robust enough to execute without new planning.

**Recommendation:** Make Strategy A consume full project-relative source paths and resolve file refs by full path/real path. Add a script section that mirrors required package/framework dependencies for the audited source set, or explicitly defines Strategy A as a stop-and-replan point if those dependencies are nontrivial.

**[MINOR] §3 baseline capture — `gh run list` may capture the wrong run**

The baseline recipe triggers `ci.yml` on `main`, then separately asks for the latest main run. If another run is queued or completes around the same time, the captured baseline may not be the run just triggered.

**Recommendation:** Capture the run id from the workflow dispatch path if possible, or filter by created time/head SHA and verify the selected run's `headSha` equals `origin/main@7e0e0b282`.

**[MINOR] §2.4 — PROMOTE wording is stale**

The plan says "For PROMOTE files (the 7 listed in §1)" even though §1 now has exactly one `VERIFY-PROMOTE` file after re-audit.

**Recommendation:** Update the wording to "For the VERIFY-PROMOTE file" to avoid implementer confusion.

### 4. Positive Observations

- The plan resolves the target and scheme naming up front (`c11LogicTests`, `c11-logic`, `com.stage11.c11.logictests`), which should prevent naming churn in `pbxproj` and CI review.
- The file-by-file audit is detailed, and the re-audit of false PROMOTE candidates catches the real NSColor dependency shape rather than relying on shallow grep hits.
- The Strategy B spike is a good way to test the important assumption: `BUNDLE_LOADER` without `TEST_HOST` must not launch the app.
- The scheme/workflow inventory is concrete and mostly matches the current repository layout, including the important `mailbox-parity.yml` `-only-testing` selector migration.
- The risk register is practical and calls out the main failure modes: `pbxproj` fragility, selector drift, transitive AppKit dependencies, and app-launch false positives.
