### 1. Verdict

**FAIL (plan-level)** — The plan is strong overall, but it still has several implementation-shaping gaps that should be corrected before coding starts.

### 2. Summary

I reviewed the C11-6 plan against the ticket requirements and checked its key code assumptions in `Sources/` and `vendor/bonsplit/`. The plan has good decomposition and correctly identifies the major integration seams, but it has blocking issues around Bonsplit sizing defaults, incomplete tab-strip geometry coverage, and an overstated live-update mechanism.

### 3. Issues

**[CRITICAL] Bonsplit wiring — `tabBarHeight` default mismatch would change existing behavior**
The plan says the new public Bonsplit knobs default to the existing `TabBarMetrics` constants so untouched embedders see today's behavior. That is false for the bar shell: `Appearance.tabBarHeight` currently defaults to `33`, while `TabBarMetrics.barHeight` is `30`, and the current rendered shell uses `TabBarMetrics.barHeight`. Repurposing `tabBarHeight` without reconciling this means default c11 and any untouched Bonsplit embedder will grow the tab bar from 30pt to 33pt at the standard preset, despite the plan claiming no behavior change.
**Recommendation:** Decide explicitly whether standard scale preserves the current rendered 30pt shell. If yes, set the resolver and Bonsplit defaults to the current rendered constants, or migrate only c11's appearance values deliberately. Update the plan's token defaults, tests, and validation expectations so `Default` is unambiguous.

**[CRITICAL] Bonsplit wiring — tab-strip geometry audit is incomplete**
The plan routes `TabItemView` height and the outer `TabBarView` shell, but `TabBarView` has additional `TabBarMetrics.tabHeight` consumers that affect layout and hit/drop regions: the leading scroll anchor, trailing drop zone, and split-button/drop-zone frames. Leaving those at 30pt while the item height grows risks clipped or misaligned hit targets at Large/Extra Large. The plan also leaves `dirtyIndicatorSize` and `notificationBadgeSize` fixed even though the ticket calls out dirty/activity indicators "where practical" and the validation checklist says dirty/notification affordances should scale.
**Recommendation:** Expand the Bonsplit seam audit to cover every tab-row geometry consumer. Add public appearance knobs or derived helper methods for tab item height, icon slot, close/pin glyph, dirty indicator, notification badge, accessory slot, trailing drop zone, and any split-toolbar frame that visually belongs to the tab strip. If any indicator remains fixed, state why it is not practical and remove it from the "must visually scale" validation list.

**[MAJOR] Persistence design — UserDefaults KVO is overstated and underspecified**
The plan makes UserDefaults KVO the live-update spine and claims it fires for every writer, including `defaults write` from outside the app. The current codebase appears to use `UserDefaults.didChangeNotification` for defaults-driven refreshes, not key-specific KVO on `UserDefaults`, and external-process `defaults write` is not a reliable live notification mechanism for an already-running app. The plan also does not state that `bonsplitController.configuration` mutation must happen on the main actor/main queue from any observer callback.
**Recommendation:** Narrow the live-update requirement to in-app writers unless external `defaults write` is truly required. Use an explicit in-process setting setter or `UserDefaults.didChangeNotification` plus last-value diffing, and ensure the observer schedules Bonsplit configuration mutation on the main actor. If external CLI mutation remains a validation goal, design and test a robust app-side socket command as the supported writer instead of relying on `defaults write`.

**[MAJOR] Commit 6 — new socket command adds scope and misses required c11 skill/docs updates**
The ticket does not require a `c11 chrome.set-scale` command. Adding a socket/CLI command in v1 expands the surface area and triggers the project rule that every CLI/socket protocol change must update the c11 skill contract. The plan includes the command but does not include `skills/c11/SKILL.md` updates, command help/docs, parser coverage, or a clear rollback path if the command delays the UI-scale work.
**Recommendation:** Either drop the socket command from v1 and validate live updates through Settings, or keep it as an explicit acceptance-supporting deliverable with skill updates, command help, socket parser tests, focus-safety tests, and localization/error-message handling called out in the commit plan.

**[MAJOR] Test plan — build/test integration is not concrete enough for this repo**
The plan adds `Sources/Chrome/ChromeScale.swift` and several new unit tests, but this Xcode project has manual `project.pbxproj` source/test entries. The plan does not say to add the new source and test files to the app and `c11-unit` targets. On the Bonsplit side, "verify the rendered view tree honors them" is not yet tied to an existing harness; without a concrete runtime seam, that can collapse into an untestable or brittle SwiftUI introspection test.
**Recommendation:** Add project-file target membership to the commit plan for every new c11 source/test file. For Bonsplit, define a small pure layout/metrics resolver or hosted-view measurement harness that can be exercised in `vendor/bonsplit/Tests`, and avoid promising generic "rendered view tree" assertions unless the harness is known to exist.

### 4. Positive Observations

The plan correctly treats the setting as semantic presets rather than a freeform multiplier and keeps Ghostty terminal sizing out of scope. It does a good job preserving the C11-5 sidebar hierarchy by threading an `Equatable` token value into the hot `TabItemView` path instead of adding more observed state there.

The Bonsplit boundary is also mostly well framed: c11 owns the scale resolver, Bonsplit gets generic appearance knobs, and the plan correctly flags the submodule workflow and upstream-candidate nature of the generic Bonsplit work. The validation checklist is unusually thorough and would be valuable once the live-update and tab-geometry assumptions are tightened.
