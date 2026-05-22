Minimal port of upstream PR #4233 (commit 5cb4715a8) merged as 7fc8bd023.

**Validation:**
- c11-logic test suite: 870 tests, 0 failures
- Single-surface manual repro on tagged build: PTY materializes immediately
- 30/30 single-workspace stress
- 32/32 multi-workspace stress (8 workspaces × 4 offscreen surfaces)
- Focused new-pane path unchanged
- All 6 CI checks green (build, build-ghosttykit, compat-tests, remote-daemon-tests, web-typecheck, workflow-guard-tests)

**Scope shipped:** headless NSWindow at TerminalSurface init, uiWindow/isViewInWindow/isHeadlessStartupWindow API, requestBackgroundSurfaceStartIfNeeded retreats from off-window createSurface and delegates to headless, attachToView releases headless on real-window arrival, forceRefresh ignores headless (typing-latency safe), GhosttyNSView calls reconcileAttachedWindowIfNeeded when surface is already attached, ScrollView.uiWindow + focus/visibility callsites updated, callers in AppDelegate/Workspace/TabManager/Panels/TerminalPanel/TerminalController switched to surface.isViewInWindow/.uiWindow, regression test ported to tests_v2/.

**Out of scope (filed as follow-ons if pursued):** upstream's enum-returning sendInputResult/NamedKeySendResult API, PendingKeyEvent/PendingSocketInput-with-keys queueing, localized error strings for socket send failures, TerminalController send-path refactor.

PR: https://github.com/Stage-11-Agentics/c11/pull/199
Merge commit: 7fc8bd023c347616db8fc841fd940e768cbbe205