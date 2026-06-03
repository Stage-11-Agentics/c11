# C11-101: c11Tests stabilization: triage 32 expectation timeouts + profile slow test

Diagnose and fix the 32 `XCTestExpectation` 1-second-timeout failures in `c11Tests` so the host-bound scheme can return to hard-fail status in CI. Parent: C11-98. Sibling: CI unblock ticket (makes c11-unit advisory until this completes).

**Failing-test clusters** (per audit, recurring across 4+ post-PR-#164 main builds):
- `AppDelegateShortcutRoutingTests` — multiple, starting at `c11Tests/AppDelegateShortcutRoutingTests.swift:2323`
- `GhosttyConfigTests` (`c11Tests/GhosttyConfigTests.swift:1576, 1696`)
- `NotificationBurstCoalescerTests`
- `TabManagerReopenClosedBrowserFocusTests` (`c11Tests/TabManagerUnitTests.swift:974`)
- `TerminalNotificationDirectInteractionTests`
- `BrowserDeveloperToolsVisibilityPersistenceTests`
- `BrowserPanelHostContainerViewTests`

**Plus** the one outlier: `AppDelegateShortcutRoutingTests.testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView` at `c11Tests/AppDelegateShortcutRoutingTests.swift:878-912` — 104-123s wall time (vs 10.5s for the next-slowest test). Quarantined in the CI-unblock ticket; needs real fix here.

**Approach**
1. Pull the full failure list from any recent CI run via `gh run view --log` + the `-resultBundlePath` artifact. Add `-resultBundlePath` to `scripts/test-unit-local.sh` (from the runnability ticket) and to CI for ongoing visibility.
2. For each failing test: decide between (a) raise the expectation timeout from 1s to 5-10s if the wait is legitimate, (b) replace polling/timer-based waits with deterministic notification observers, (c) move the test to `c11LogicTests` if it doesn't actually need the host, (d) quarantine with `XCTSkip` and Lattice link if the test design is wrong.
3. Profile the 104s slow test with `sample(1)`:
   ```bash
   scripts/test-unit-local.sh -only-testing:c11Tests/AppDelegateShortcutRoutingTests/testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView \
     -resultBundlePath /tmp/slow-test.xcresult &
   sleep 30
   sample $(pgrep -n xctest) 5 -file /tmp/c11-unit-sample.txt
   ```
   Determine what `createMainWindow` (`Sources/AppDelegate.swift:6269`) actually does for 100s. Likely SwiftUI scene graph + responder swizzle install — fixing it benefits production launch latency too (relevant to C11-1 hang investigation).
4. Re-enable the quarantined slow test once the actual fix is in.

**Acceptance**
- c11-unit step in CI green on `main` for 5+ consecutive runs
- CI flips `c11-unit` from `continue-on-error: true` back to hard-fail (removes the advisory flag)
- Quarantined slow test re-enabled
- AAR comment on this ticket covering what was actually broken — most likely a class of timing assumption that's wrong on shared-tenant CI runners (this insight is portable to future test design)

**Soft dependency on** local-runnability ticket — strongly recommended to land first so the owner can iterate without 10-min CI roundtrips.
