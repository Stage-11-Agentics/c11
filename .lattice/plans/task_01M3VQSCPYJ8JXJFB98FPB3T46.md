# C11-250: Close safety follow-ups from the #469 review

Non-blocking findings from the fresh Opus review of #469 (merged 2edc4e374, shipped in 0.67.0). Fix the real ones (2, 5, 6), decide 4 and 7, close the test gaps.

# PR #469 follow-ups (non-blocking, from fresh Opus review; merged as 2edc4e374)
1. AppDelegate.swift:4395-4403 — @discardableResult + "Full clean boundary" doc now sit on persistLastWindowSnapshot(); move back to persistCleanShutdownSnapshot.
2. AppDelegate.swift:2165-2171/13139 — mainWindowCloseGuards sole strong ref removed in unregisterMainWindow; willClose observer (5047) may release guard before windowWillClose reaches it.
3. AppDelegate.swift:13143 — up to 5 s main stall on last-window close (persistLastWindowSnapshot waits on conversation suspension). CHANGELOG line.
4. Snapshot taken before teardown: closed-only-workspace resurfaces in next resume picker.
5. AppDelegate.swift:6105 — socket close-window returns OK when an operator close sheet is attached; return invalid_state.
6. PaneInteractionCardView.swift:51 — highlight fallback .confirm vs runtime fallback .cancel.
7. close_above/close_below and tab close_others still mass-close without prompt.
8. Test gaps: v2RejectUnresolvedTargetRefs, close-guard routing, SessionPersistenceTests:748 vacuous, tests_v2 stale-ref test, Thread.sleep in CloseWorkspaceCmdDUITests.
9. AppDelegate.swift:6171 — debug seam re-entrant close (tests only).
