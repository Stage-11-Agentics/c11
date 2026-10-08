C11-266 validation: existing runtime proof mapped to acceptance criteria (batch fast rule)

Merged: PR #566, squash 24dbf1afb1b2c389786970415191276e0b6cfe8e, landing head cff75ba86d1ca3367b779088cff4088bc6441a1c. Merge Captain receipt ev_01M3ZNYPTYW4NS0WJXHW8GPV7T: exact-head gate d7eb0cdf739146ff80144714347edfe0, Debug compile ok, full c11LogicTests plus FeedQuickViewTests and the two new routing tests 2,471 tests, 3 skips, 0 failures (FeedQuickViewTests 6/6, FeedQuickViewSelectionTests 2/2); installed c11 skill synced. Review: Astra round-2 PASS ev_01M3ZGY899X8Y3QR8GRS8ZV8VG (focus-ring blocker fixed) and merge-review round-2 PASS ev_01M3ZNH66AYHV7XXV6N1BHE98X at the landing head, with an independent guest replay (socket Return blocked, operator Return switches). Orchestrator attestations for docs-only remerges ev_01M3ZH1NAG3CRFRD06YH3WYAA2 and ev_01M3ZHRSQE9A0ZS2GMVR765GQ0. No new runs were made for this comment.

Packaged guest proofs (owner, disposable Atlas guests, tagged builds):
- G1 keyboard flow: feed_quick_view_keyboard_probe.py PASS 30.8 s, 11 steps with screenshots, build 87b3fad8 at b4cd7e22b4 (ev_01M3ZEFTBJS53B37V2HN1FJ72H; screenshots attached, owner-inspected: fixed 64 pt rows, fixed filter/hint/status frames, highlight follows keys, flag-first order, counts match projection).
- G2 Tab/Shift-Tab: the same probe PASS 32.8 s with Tab, Shift-Tab, Shift-Tab, Tab, Tab and 30 screenshots, build 95cf799009 (ev_01M3ZGRF68WMAC2S8T57AA4SMC). The selected fill is always on the active filter.
- G3 socket versus operator Return: feed_quick_view_workspace_switch_probe.py PASS 6.0 s, build 43a7fe72e5cb45a485d516abb7d5acf6 at e148fe1ebe, product-identical to the landing head (ev_01M3ZMG5G8JKZKCKDSDZBDWFSY). A socket `simulate_shortcut return` leaves workspace 1 with the view open; the operator's real Return lands on the flagged tab in workspace 2; screenshots inspected. Independently replayed by the reviewer.

Criterion -> evidence -> result
1. Command-I opens; keys move the selection; Return opens the exact tab; Esc returns to the originating focus; nothing is sent -> G1, G3; routing tests testCmdIStillTriggersShowNotificationsShortcut, testOperatorReturnInQuickViewSwitchesToTheTabsWorkspace and testSocketSimulatedReturnInQuickViewIsRefusedAndAttributed (Captain gate); the quick view has no reply or approval path (review) -> PASS. A socket Return is refused with workspace_switch_blocked, consistent with C11-323.
2. Default filter shows asks and flags without turn_end; Turns is explicit; switching does not resize or invoke a row -> testToggleFilterCyclesBothFiltersWithoutOpeningAny and testFilterFocusFollowsActiveFilterForTabShiftTabAndPointerWithFixedFrames (red e5c0055f before the fix, green 3fc60a17 and in the Captain gate); G2 -> PASS.
3. The selected ask keeps its identity across insertions and clock changes; on removal a defined neighbor is selected without activation -> FeedQuickViewSelectionTests 2/2 (Captain gate) -> PASS at model level; the live insertion and removal (owner scenario steps 4-5) are routed to sign-off.
4. Row heights, filters, hint bar and targets stay fixed with short, multiline and missing prompts, long names, rising counts and six-locale strings; empty and loading states do not jump -> fixed 64 pt rows and fixed frames in G1 and G2 screenshots; quick-view host tests -> PASS for English layout. Six-locale product translations are not claimed here: they belong to C11-291 (its Japanese UI sign-off step covers the Feed). The multiline, missing-prompt and long-name visual pass is routed to sign-off.
5. Visible order and counts match the A3 projection, including suppressed flags and a flag plus ask on one tab; a closed target shows an understandable unavailable state -> FeedProjectorTests 14 and AttentionOrderTests 5 (owner runs and Captain gate); G1 counts match the projection -> PASS. The live closed-target "That tab is unavailable" row is routed to sign-off.

Residuals, stated plainly
- The system focus ring on the active filter segment is intermittent (it may draw only while the popover window is key); the selected fill is always correct. Cosmetic.
- Fleet-update soak against F2: C11-270.
- CI note: AppDelegateShortcutRoutingTests is a class-level quarantine in the hourly host gate, so the two quick-view routing tests run only in targeted gates such as the Captain's.

Routed to C11-292 sign-off (signoff-additions.md): live selection stability while rows are inserted and removed; the closed-target unavailable state; Esc focus return; varied-prompt layout; and a merged-build repeat of socket-versus-operator Return.

No check contradicts a criterion.

Verdict: COMPLETE with the live-list checks routed to C11-292, locales on C11-291 and the soak on C11-270.