# C11-250 implementation plan

Source review base: current origin/main 61b4d6d94da02dd60418135a765ae321c3fcf2d4. The commit after the initial c3dc4a8bc2 source review contains Lattice board state only; Sources and c11Tests are unchanged.

## Verified findings and changes

1. Finding 2: retain the main-window close guard through its delegate callback. Sources/AppDelegate.swift still removes the guard in unregisterMainWindow, called by the NSWindow.willCloseNotification observer, while MainWindowCloseGuardDelegate.windowWillClose is responsible for the final release after forwarding. Remove the premature release and keep callback teardown as the owner. Add a host test that drives the observer-before-delegate order, checks the guard remains alive, then closes the window and checks normal cleanup.
2. Finding 5: reject socket close while a sheet is attached. Sources/AppDelegate.swift and Sources/SocketHandlers/WindowHandlers.swift currently acknowledge the v2 window.close after performClose even if AppKit refuses because attachedSheet is non-nil. Sources/TerminalController.swift has the same false-success path for legacy close_window. Return a typed close outcome, map the attached-sheet state to invalid_state on v2 and an explicit error on v1, preserve not_found for an unknown window, and preserve ok for a close accepted by AppKit. Add a host test that sends both command forms through their normal dispatch paths with a real test window and attached sheet, then checks the error and that the window remains.
3. Finding 6: make the card highlight match Return-key behavior. Sources/Tabs/AreaInteractionCardView.swift falls back to confirm; AreaInteractionRuntime.acceptSelectedConfirm falls back to cancel. Put the display fallback in Sources/Tabs/AreaInteraction.swift, use it in the card and Return routing, and add a runtime test that missing selection displays cancel.

## Acceptance evidence

- Finding 2 answers the observed delegate-lifetime race during window teardown. The lifecycle test must fail if unregisterMainWindow drops the last strong reference before windowWillClose.
- Finding 5 answers the observed false close acknowledgement with an operator sheet attached. The socket-path test must fail unless v2 returns invalid_state, v1 returns its explicit error, and the window and sheet stay open.
- Finding 6 answers the observed disagreement between the visible destructive choice and Return's selected action. The runtime test must fail if the card's missing-selection fallback is confirm.

Use Atlas tag c11-250 for the native targeted tests and tagged runtime validation. Exercise window.close against a synthetic tagged-build window with its close-confirmation sheet attached; expect invalid_state, with the window and sheet still present, then cancel and confirm the window stays open. The change does not enter the app-termination callback.

## Boundaries

Findings 4 and 7 are deferred from this implementation because the owner brief selects 2, 5, and 6; this plan makes no product-policy change to snapshot contents or bulk-close prompts. Findings 1, 3, 8's unrelated gaps, and 9 are out of this cut. No dependency beyond current main; avoid C11-257 messaging files. No new strings, localization keys, persisted fields, or migrations. No typing, focus, or sidebar hot path changes.
