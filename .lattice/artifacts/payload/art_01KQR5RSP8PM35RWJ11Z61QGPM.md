### 1. Verdict

**FAIL (plan-level)** - The plan is mostly thorough, but it has a blocking mismatch around Bonsplit tab bar height and treats a required acceptance item as deferrable.

### 2. Summary

I reviewed the C11-6 plan against the ticket requirements and did a light repository check of the referenced Bonsplit and c11 seams. The plan is strong on scope control, typography-token decomposition, localization awareness, and hot-path caution, but it has a concrete feasibility gap: `BonsplitConfiguration.Appearance.tabBarHeight` is currently not consumed by Bonsplit internals, so Phase 1 will not visibly scale tab bar height, and deferring Phase 2 would miss required acceptance criteria.

### 3. Issues

**[CRITICAL] Bonsplit wiring / Phase 1-2 deferral - Required tab bar height scaling is not actually satisfied**

The plan says Phase 1 routes scale through existing Bonsplit appearance knobs and later states that, if Phase 2 is delayed, visual verification at Large/XL would still pass for tab title text and bar height. In the current repo, `Appearance.tabBarHeight` is only declared/initialized in `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift`; `rg "tabBarHeight" vendor/bonsplit/Sources/Bonsplit` shows no internal consumers. `TabBarView` still frames the shell with `TabBarMetrics.barHeight`, and `TabItemView` frames individual tabs with `TabBarMetrics.tabHeight`. That means the proposed Phase 1 cannot satisfy "Top surface tab bar height" or "tab item height/padding needed to avoid clipping at larger scale values." Since those are in scope and in the acceptance criteria, Phase 2 cannot be optional for a complete C11-6 implementation.

**Recommendation:** Revise the plan so the Bonsplit height seam is required before C11-6 can pass. Prefer making the existing public `Appearance.tabBarHeight` actually drive the tab bar shell/reserved height, then add only the extra public knobs that remain necessary (`tabItemHeight`, icon size, close/accessory sizing, padding). Remove the claim that a Phase 1-only PR satisfies tab bar height.

**[MAJOR] Bonsplit public API design - Proposed `tabBarShellHeight` duplicates an existing unused knob**

The plan proposes adding `tabBarShellHeight` while keeping `tabBarHeight` distinct. Because `tabBarHeight` already exists as the public height knob and is currently unused internally, adding a second shell-height concept risks preserving a dead/ambiguous API instead of fixing the existing one. It also conflicts with the task's Bonsplit note to prefer existing appearance knobs first.

**Recommendation:** Define the intended semantics of `Appearance.tabBarHeight` and wire it through Bonsplit. If Bonsplit genuinely needs separate outer shell and inner item heights, use `tabBarHeight` for the outer bar and add a clearly named `tabItemHeight` for the inner tab frame. Avoid `tabBarShellHeight` unless there is a documented compatibility reason.

**[MAJOR] Submodule workflow - Remote instructions do not match this worktree**

The plan's mandatory Bonsplit submodule steps refer to `git push manaflow <branch>` and verification against `origin/main`. In this worktree, `vendor/bonsplit` only has `origin` configured, pointing at `https://github.com/Stage-11-Agentics/bonsplit.git`. Following the plan literally will fail before implementation can publish the submodule change.

**Recommendation:** Update the plan to match the actual Bonsplit remote setup, or explicitly include the command to add the missing remote if `manaflow` is required. Keep the parent-pointer rule, but make the exact push/PR/merge-base sequence executable in this repository.

**[MINOR] Settings UI design - Segmented picker subtitles are underspecified**

The plan calls for four segmented options "with subtitles." A standard SwiftUI segmented picker generally only has room for the option label, and the existing `SettingsPickerRow` style in `appearanceSettingsPage` appears to use simple `Text(...).tag(...)` options. This is not a blocker, but it leaves implementers with a small UI ambiguity and may create unnecessary localization strings if subtitles do not ship.

**Recommendation:** Specify either a segmented picker with labels only plus one localized explanatory row subtitle, or a non-segmented/card/radio control if per-preset subtitles are required. Trim the localization table to the strings the chosen control can actually render.

**[MINOR] Environment/token propagation - Root injection points should be made explicit**

The plan defines `EnvironmentValues.chromeScaleTokens` and says a wrapper view near the Workspace root and inside the sidebar parent will push tokens down, but the commit plan mostly relies on explicit threading for sidebar and a direct environment read in `SurfaceTitleBarView`. Without naming the exact root/container injection point for surface title bars, implementation could wire sidebar scaling while leaving title-bar environment consumers at the default token value.

**Recommendation:** Add the exact c11 view(s) where `.environment(\.chromeScaleTokens, tokens)` will be installed, or avoid the environment for v1 and thread tokens explicitly everywhere in scope.

### 4. Positive Observations

The plan is unusually complete in its code-area survey and correctly calls out the typing-latency sensitivity of `ContentView.TabItemView`, including the need to preserve `.equatable()` and include new render-affecting values in `==`.

The token-based approach is well aligned with the ticket: it keeps Ghostty terminal sizing out of scope, preserves the C11-5 sidebar hierarchy, and avoids raw multipliers scattered through call sites.

The plan also respects localization and test-quality policy by requiring call-site localized strings, delegating translation, and avoiding grep-style tests against source or metadata files.

The upstream-candidate framing for generic Bonsplit appearance knobs is the right instinct; once the height/API issues above are corrected, that portion should be suitable to surface upstream.
