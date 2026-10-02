# Plan Review: C11-245

## 1. Verdict

**PASS** (for Phase 1, the HTML prototype). The Swift phase needs the amendments below before it starts, and the trigger-rule issues (1 and 2) should go into the prototype notes now, so the operator signs off on the right rule.

## 2. Summary

I reviewed the C11-245 plan against the ticket and the code on main. Round five (#465) is merged, so the rail setting exists. The plan's three actions map onto public APIs that already exist: `TabLayoutSettings.modeKey`, `BonsplitController.setRailOpen(_:inPane:)` and `BonsplitController.setTabSheetOpen(_:inPane:)`. Gating Swift behind a prototype is the right call. The main concern is the definition of an overflow day. As written, it counts narrow areas holding a single tab, and it does not say how a state that runs for days counts on each new day. Both would make the signal fire for the wrong operators or miss the right ones. The plan also says nothing about how the tip behaves around keyboard focus, or when it goes away, which matters in a terminal app.

## 3. Issues

**[MAJOR] Trigger — "folded into the solid block" counts narrow areas that are not overflowing on tab count**
`recomputeLayoutTier` (`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:1080`) folds to `.narrow` when `roomForTabs < min(150, desiredTabsWidth)`. A narrow split pane with one or two tabs folds on width alone. An operator who keeps many small splits would pile up overflow days without ever having "more tabs than the bar can show". The tip would then point them at the rail. The rail takes 200pt or up to 45% of the area (`TabRailView.swift:16-19`), which is the wrong advice for a narrow area.
**Recommendation:** Define overflow by hidden tabs, not by tier. An area overflows when at least one tab, better two, is not visible: scrolled off the strip, or behind the block with `tabs.count >= 2`. Also replace "strip scrolled" with "tab content wider than the visible strip". That is a state; "scrolled" reads as a user scroll event. Optionally, offer Try Rail only when the area is wide enough for the rail to leave usable content (for example ≥ 560pt), and offer only Show tab list below that width.

**[MAJOR] Trigger — the day counting is undefined for long uptimes and for areas the operator cannot see**
The plan rightly says c11 stays open for days. But "a day on which any area's strip scrolled or folded" can be built two ways. If it fires on the transition into overflow, an area that overflows continuously for five days marks only one day. If it fires on the state, it also marks days when the screen is locked, the Mac sleeps, or the overflowing area sits in a hidden workspace. Inactive workspaces stay mounted and keep computing tiers (`TabBarView.swift:547` comment).
**Recommendation:** State it as a state rule. Mark today when a visible area (interactive workspace, visible window, app active, screen unlocked) has been overflowing for ≥ 2 s. Re-check on day rollover and on app activation, so long-running overflow counts once per day of real use.

**[MAJOR] Tip — no lifetime, focus contract, or rule for when it appears**
"Non-modal popover" is not enough for a terminal. The plan does not say:
- Whether the tip may take keyboard focus. A SwiftUI `.popover` or `NSPopover` can become key, and keystrokes meant for the terminal would then be lost.
- When an ignored tip goes away: timeout, outside click, workspace switch, area resize out of overflow, tier change, rail opening.
- When the predicate is evaluated, and what suppresses the tip: a tab drag, an open tab sheet, an open rail, a non-key window, a modal sheet.
- What happens to "steps aside, then returns" if the sheet closes after the area has stopped overflowing.
**Recommendation:** Add a short tip contract:
- The tip never takes first responder, and the terminal keeps typing.
- It auto-hides after about 20 s, on an outside click, on a workspace switch, or when its area stops overflowing.
- It is suppressed during drags, while the sheet or rail is open, and in non-key windows.
- Evaluate on a natural moment: the operator creates or selects a tab that leaves the focused area overflowing, or hovers the tab bar. Avoid a timer that pops it over someone who is typing.
Show the auto-hide in the prototype.

**[MAJOR] Later — the Bonsplit seam the Swift phase needs is not named**
The overflow state lives in private `@State` inside Bonsplit's `TabBarView`: `layoutTier` at `:347`, and strip overflow in the scroll bridge. The count-cell anchor that the popover needs is private too (`CollapsedSheetTrailingAnchorReader`). c11 cannot read either today. The Swift phase therefore needs a Bonsplit PR: a per-pane overflow signal (with hidden-tab count) on `BonsplitController`, plus an anchor rect for the count cell. That means a PR pair and the submodule rule (push the Bonsplit commit to `main` before bumping the pointer). It also has to stay off the typing hot path, so the update fires only on layout change, never per keystroke.
**Recommendation:** Add to "Later": the files touched (Bonsplit `TabBarView.swift`, `BonsplitController.swift`; c11 a new `TabRailTip*.swift` and the host that presents it), the PR-pair and submodule order, and a note that the signal is computed only on width, tab-set or tier changes.

**[MINOR] Storage — "not on the socket" conflicts with validating the tip**
Atin bans synthesized input on Hyperion, and round-five validation ran through `#if DEBUG` socket seams plus `screencapture -l` (`debug.tab_sheet.open`, `debug.tab_rail.open` in `Sources/SocketHandlers/DebugHandlers.swift:84`). Without a seam, an agent cannot show the tip, inspect the predicate, or reset state. It would have to wait four real days.
**Recommendation:** Narrow the rule to "never leaves the machine: not in logs, health, Sentry breadcrumbs or release socket commands". Add `#if DEBUG` seams such as `debug.rail_tip.show`, `debug.rail_tip.state` and `debug.rail_tip.reset`. Document the `defaults write … c11.tabRailTip.dismissed -bool true` opt-out in the c11 skill next to `tabLayoutMode`.

**[MINOR] Trigger/Storage — "has never been set to Rail" cannot be known, and the observer is per workspace**
There is no record of a rail setting made before this ships. `TabLayoutObserver` is created per `Workspace` (`Sources/TabLayoutSettings.swift:37`), and the skill documents `defaults write … tabLayoutMode -string rail`, which can happen while c11 is closed.
**Recommendation:** Say "has not been Rail since this shipped". Set `dismissed` from one app-level observer, and also at launch when the mode reads `rail`. Decide whether the Settings reset (`Sources/c11App.swift:6602`) clears the tip keys. Suggestion: leave them alone.

**[MINOR] Later — localization covers English only**
Repo policy and the round-five rules require all seven locales, in the same commit, via a translator sub-agent.
**Recommendation:** Add the translation pass, and name where the strings live: c11 `Resources/Localizable.xcstrings` if the tip is presented by c11, Bonsplit `.lproj` strings if it lives in Bonsplit.

**[MINOR] Actions — Try Rail is a global, one-click change with no stated undo**
`tabLayoutMode` is global, so one click re-lays every area in every window.
**Recommendation:** Say in the copy that it changes all areas and where to switch back (Settings → Tab layout). Optionally add a short-lived "Undo" in the opened rail.

**[MINOR] Trigger — an ignored tip comes back every 30 days indefinitely**
"Rare" holds, but an operator who never engages sees it about 12 times a year.
**Recommendation:** Retire the tip after two or three ignored offers. Store an `offerCount` beside `lastOffered`.

**[MINOR] Later — the test seam and automation launches**
Days are "local calendar days", so the predicate depends on clock, calendar and time zone. Separately, a QA or automation launch should never show the tip unless a seam forces it, to keep validation screenshots clean.
**Recommendation:** Inject `now`, `Calendar` and `UserDefaults(suiteName:)` into the predicate, and test the day rollover, the 14-day window edge, and a time-zone change. Suppress the tip when `C11_QA_LAUNCH` is set.

## 4. Positive Observations

- Prototype first, Swift later, with no `xcodebuild` without a build slot. This fits the operator's review loop and the Hyperion load rules.
- Measuring days of use rather than launches is the right insight for an app that stays open for days.
- The offer conditions are concrete and testable (4 of 14 days, a 30-day cooldown, a never-dismissed flag, overflowing now), and "one tip for the app" keeps it rare.
- The storage is minimal and local. The keys are named, retention is capped at 30 days, and the plan states that nothing goes to logs, health or the socket. That meets "never leaves the machine".
- The actions are well separated. Show tab list is explicitly not a dismissal, and Try Rail and Don't show again both retire the tip. The "switching back to Tabs does not re-arm" assumption is called out in the notes for the operator to confirm.
- The three actions land on public APIs that already exist (`setRailOpen`, `setTabSheetOpen`, the `tabLayoutMode` default), so they need no new plumbing.
