### 1. Verdict

**FAIL (plan-level)** — the plan is close, but a few implementation-blocking details should be corrected before work starts.

### 2. Summary

I reviewed the C11-27 plan to split `c11Tests` into `c11LogicTests` and host-required tests. The decomposition, file audit, risk register, and spike-first workflow are strong, but the default Strategy B build settings point at the wrong Debug app product, which would make the spike fail for the wrong reason. The CI and acceptance sections also need tightening so they do not weaken the ticket's "no worse than today" CI-time requirement or falsely verify "no DEV.app launch."

### 3. Issues

**[CRITICAL] §2.3 Build settings / §2.2 Spike protocol — Strategy B points `BUNDLE_LOADER` at a non-existent Debug product**
The Strategy B column sets `BUNDLE_LOADER = "$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11"` for both configurations, while the current project builds the Debug app product as `c11 DEV.app` (`PRODUCT_NAME = "c11 DEV"`). The existing `c11Tests` target already uses `$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11` for Debug and `$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11` for Release. Since the spike runs `xcodebuild ... -configuration Debug`, Strategy B is likely to fail at link/load time before it tests the actual question of whether `BUNDLE_LOADER` can work without launching the app.
**Recommendation:** Update Strategy B to use configuration-specific loader paths: Debug -> `$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11`, Release -> `$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11`. Also update the acceptance criterion that describes the expected `BUNDLE_LOADER` output so reviewers do not expect `c11.app` in Debug.

**[MAJOR] §4.1 CI / §8 Acceptance criteria — CI plan re-runs logic tests and weakens "no worse than today"**
The plan says `c11-unit` must run both `c11Tests` and `c11LogicTests` so one invocation covers all 101 tests, but §4.1 also adds a separate `c11-logic test` step before running `c11-unit test`. That means CI executes the logic suite twice. The task's acceptance says total CI time should be "no worse than today," but §8 relaxes that to "today's CI wall time + 30 s." This is a measurable weakening of the ticket's acceptance bar, and the "host-required" CI step name is misleading because `c11-unit` still runs both targets.
**Recommendation:** Choose one explicit CI shape and make the acceptance criteria match it. Either run only `c11-unit` in the main CI job after adding both TestableReferences, with mailbox parity using `c11-logic`, or add a separate host-only scheme such as `c11-host` if CI should run `c11-logic` plus host tests without duplication. Keep the wall-time criterion as "no worse than today" unless the ticket owner explicitly accepts a regression budget.

**[MAJOR] §8 Acceptance criteria — `pgrep ... & ; xcodebuild ...` does not monitor app launch during the run**
The proposed command backgrounds a single `pgrep` invocation before `xcodebuild` starts. That can pass even if `c11 DEV.app` launches a moment later during the test phase, so it does not actually verify the key behavioral acceptance criterion.
**Recommendation:** Replace it with a real monitor around the test process. For example, start `xcodebuild` in the background, loop while it is alive, fail immediately if `pgrep -fl 'c11 DEV.app'` produces output, then wait for the test exit status. Also require an initial preflight that no stale `c11 DEV.app` test host is already running.

**[MINOR] §3 Step 7 / §2.2 — `c11-logic` scheme contents are underspecified for Strategy A vs. Strategy B**
The plan says to copy `c11-unit.xcscheme`, swap the BuildableReference to the new target, and strip the old TestableReference. In the current scheme, `c11-unit` also has a c11 app BuildAction and MacroExpansion. Under Strategy B, building the app target is necessary for the loader binary; under Strategy A, keeping the app BuildAction would erode the "logic-only" loop by building unrelated app code.
**Recommendation:** Add a small scheme template section: under Strategy B, `c11-logic` should build `c11` plus `c11LogicTests`; under Strategy A, it should build only `c11LogicTests` and should not retain the app MacroExpansion unless Xcode requires it for a concrete reason.

### 4. Positive Observations

The plan is unusually thorough for a project-file-heavy change: it locks naming, gives a per-file classification table, requires a spike before bulk pbxproj edits, and calls out the `mailbox-parity.yml` selector risk that commonly causes silent zero-test CI passes. The choice to commit the Ruby project-edit script is also good review hygiene because it makes a fragile Xcode mutation reproducible. The updated testing-policy text captures the corrected problem framing well: the operator's main c11 is not the process that freezes, but the spawned test host still makes local full-test runs painful.
