PR #45 merged 2026-04-22. All three original failure modes verified by visual test on main.

Failure 1 — sidebar neutrality: PASS. Rail/list background stays neutral across saturated custom colors; only the selected workspace tab/card carries the color.

Failure 2 — continuous workspace outline: PASS. Portal-hosted frame overlay draws above terminal/browser content so the outline is unbroken around the right-edge scrollbar, split dividers, and mixed terminal/browser/markdown layouts. Internal chrome (browser address bar, terminal title bar, surface title bar) correctly excluded.

Failure 3 — live custom color refresh: PASS. Rapid green → yellow → magenta changes propagate atomically to outer frame, tab strip, active tab indicator (Bonsplit), split dividers, and workspace card. No relaunch / workspace switch / manual refresh required. Holds across 2-pane and 3-pane splits.

Failure 4 — mixed surface sanity (terminal + browser + markdown): PASS.

No regressions observed. Related work (CMUX-32 workspace color prevalence / theme M2) remains the ongoing track; this ticket was a focused regression pass and is complete.