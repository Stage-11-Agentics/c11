C11-250 validation: existing proof mapped to the selected #469 follow-ups (batch fast rule)

Merged: PR #561, squash 8cfd73f8e4356c7f7c9af39b0f745373bed6e5a6, landing head e4c117f86aad9308a67cabd2160d07f6806945f8. Merge Captain receipt ev_01M3ZF762N6B11PDDSP0AXVFTF: exact-head gate 087a520f97464d8192f83d6eb8c0c0fd, Debug compile ok, full logic plus the targeted host tests 2,450 tests, 3 skips, 0 failures. The earlier failed gate cabc04c05d (ev_01M3ZEGZQ0RP64Q6K63R2BSZ2Z: whole-image TIFF byte equality in the card render test) was a test-method defect; the test-only repair at e4c117f86a classifies by pixel distance and passed red/green (ev_01M3ZEW6162FR8GRM8QMT0VEV5) and in the Captain's gate. Review: Astra round-2 PASS ev_01M3ZE20YVB0XFQQC5B23E63HV for product code (unchanged since); Orchestrator attestation ev_01M3ZEWVJAVG2P56DR2XTDXNHX for the test-only delta. No new runs were made for this comment.

Scope (owner cut line, ev_01M3ZBESQS2W6B386QZHQ6FYHY): fixes 2, 5 and 6. Findings 1, 3, 4, 7, 8 and 9 are not in this PR and remain open as written in the description; this validation does not claim them.

Fix -> evidence -> result
2. Close guard released before windowWillClose reaches it -> AppDelegateShortcutRoutingTests.testWillCloseNotificationRetainsCloseGuardUntilDelegateCallback drives the unregisterMainWindow teardown and a real window close and verifies guard cleanup; passed at owner invocation ab5dba61c81d407db868a0eae7c6cfa6 and in the Captain's gate 087a520f -> PASS. CI note: AppDelegateShortcutRoutingTests is a class-level quarantine in the hourly host gate, so the hourly run does not exercise this test; the proof is the targeted runs.
5. Socket close-window returned OK while an operator close sheet was attached -> SocketTabRefRejectionWiringTests.testWindowCloseRejectsAttachedSheetWithInvalidState (owner run and the Captain's gate, all 6 tests in the class pass); packaged tagged Debug app in an Atlas guest (ev_01M3ZBESQS2W6B386QZHQ6FYHY): real close button attached the sheet; v2 window.close returned invalid_state "Window has an attached sheet"; v1 close_window returned the same error; the window and sheet stayed; Cancel kept the window open; window.close with no sheet then closed it -> PASS. That guest run used the pre-review tree; the product code is unchanged through the landing head (review round 2 and the Captain's scope note).
6. Card highlight fallback (.confirm) disagreed with the runtime fallback (.cancel) -> AreaInteractionRuntimeTests missing-selection cases (logic) plus AreaInteractionCardRenderTests rendering the real card: missing selection renders at distance 7.5e-05 from Cancel-selected versus 1.106 from Confirm-selected; red with the old '?? .confirm' (0cf29beab03949e7afb33dce946a8573), green x3 (48e3d74379c541078ebf244704959d59) and in the Captain's gate -> PASS. Live keyboard Return and arrow behavior on the card: routed to sign-off.

Routed to C11-292 sign-off (signoff-additions.md)
- Repeat of the sheet-open window.close refusal and the normal close on a merged-main tagged build.
- Confirm card keyboard behavior: with no selection the Cancel button is highlighted and Return cancels; arrow keys move the highlight and Return activates the highlighted button.

No check contradicts a fix.

Verdict: COMPLETE for fixes 2, 5 and 6, with the live repeat and the card keyboard check routed to C11-292.