# C11-109: CI: skip 7 flaky host-bound test classes to drop advisory step from ~6min to ~90s

**Problem**

The advisory `Host-bound unit tests` step in CI (.github/workflows/ci.yml ~line 200) runs the full c11Tests target via `-only-testing:c11Tests` and takes ~6 minutes. Most of that wall time is consumed by 32 expectation-timeout failures (~10s each) clustered in 7 named classes — these are the exact classes that C11-99 Area C is supposed to stabilize. Until Area C lands, those classes contribute zero signal: the step is `continue-on-error: true`, so the failures don't block merges, they just burn build minutes and make PRs feel sticky.

**Fix**

Add `-skip-testing:c11Tests/<ClassName>` for the 7 named classes. The remaining ~20 c11Tests still run and still provide host-runtime signal (AppKit responder chain, Ghostty surface, WKWebView, UNNotificationCenter). Estimated wall-time drop: 6min → <90s.

**Classes to skip** (all confirmed against c11Tests/ source):

- AppDelegateShortcutRoutingTests
- GhosttyConfigTests
- NotificationBurstCoalescerTests
- TabManagerReopenClosedBrowserFocusTests
- TerminalNotificationDirectInteractionTests
- BrowserDeveloperToolsVisibilityPersistenceTests
- BrowserPanelHostContainerViewTests

**Reverse path**

When C11-99 Area C lands 5+ consecutive green runs, drop the `-skip-testing` flags and flip `continue-on-error` back to false (per the comment block on the step already). The skip list is a temporary scaffolding, documented inline so the next agent knows what to remove and when.

**Out of scope**

- Splitting the advisory step into a separate job (would surface gate conclusion faster but doesn't save wall time).
- Parallelization (`-parallel-testing-enabled YES`) — risky given shared-state in c11Tests (sockets, NSWorkspace).
- Fixing the flaky tests themselves — that's C11-99 Area C.
