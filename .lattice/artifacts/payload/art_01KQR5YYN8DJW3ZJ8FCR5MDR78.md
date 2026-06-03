# Merged Plan Review — C11-6 (App chrome UI scale)

## 1. Verdict

**FAIL (plan-level)**

Two of three reviewers (claude, codex) returned blocking issues that take the plan back to planning rather than implementation. Gemini's PASS does not outweigh the substantive findings: both blockers are concrete, verifiable against the current repo state, and would cause the implementation to either fail at the submodule-push step or ship an incomplete feature that misses stated acceptance criteria.

## 2. Synthesis

The plan is unusually thorough and earns sincere praise from all three reviewers for its grounded code-area survey, typing-latency awareness, sensible Phase 1 / Phase 2 split, exemplary "Open decisions" section, and strict adherence to localization and test-quality policy. The two blocking issues both cluster around the Bonsplit seam: (a) the documented submodule push/PR workflow points at `manaflow-ai/bonsplit` and a `manaflow` remote that do not exist in this worktree (origin is `Stage-11-Agentics/bonsplit`, and writing to `manaflow-ai/*` violates an explicit hard rule), and (b) `Appearance.tabBarHeight` is currently a public knob with **no internal consumers** in Bonsplit, so a "Phase 1 only" landing cannot meet the acceptance criterion of visible tab bar height scaling — it would need actual Bonsplit-internal wiring. Several supporting MAJOR/MINOR issues compound the picture: the live-update path leaks state on writers that don't post the custom notification, the only proposed integration test is gated on a `GhosttyApp.shared` caveat that probably won't hold, and small policy/UI rationale slips (the `@AppStorage` policy citation, segmented picker subtitles, environment-injection root). The fixes are individually small; together they justify another planning pass before code is written.

## 3. Issues (consolidated, ordered by severity)

### [CRITICAL] Bonsplit submodule push/PR target is wrong on multiple axes
*(claude CRITICAL + codex MAJOR — same root issue)*

The plan instructs `git push manaflow <branch>` and a PR against `manaflow-ai/bonsplit:main`, "mirroring the ghostty pattern." On the ground in this worktree:

1. `vendor/bonsplit` has only `origin = https://github.com/Stage-11-Agentics/bonsplit.git`. There is no `manaflow` remote — the push will fail outright.
2. Bonsplit's lineage per `CLAUDE.md` is `almonk/bonsplit`, not `manaflow-ai/bonsplit`. There is no `manaflow-ai/bonsplit` repo.
3. Saved operator memory (`feedback_no_upstream_writes.md`) is explicit: **"never push, branch, or PR against manaflow-ai/* … All work stays in Stage-11-Agentics forks."**
4. The "mirroring the ghostty pattern" justification doesn't hold either — the ghostty submodule in this checkout is also `origin = Stage-11-Agentics/ghostty`, with no `manaflow` remote.

Following the plan as written would either fail at push or violate a hard rule, and a wrong remote name leads directly to the orphaned-detached-HEAD failure mode `CLAUDE.md` warns about.

**Recommendation:** Rewrite the discipline section: (a) push the Bonsplit branch to `origin` (Stage-11-Agentics/bonsplit); (b) open the PR against `Stage-11-Agentics/bonsplit:main`; (c) optionally flag the new Appearance knobs as an upstream-suggestion candidate to `almonk/bonsplit` per the bidirectional pattern in `CLAUDE.md`, but **never** to `manaflow-ai`. Update the merge-base verification (`git -C vendor/bonsplit merge-base --is-ancestor HEAD origin/main`) accordingly. Drop the ghostty-mirror sentence; if a `manaflow` remote is actually wanted, include the exact command to add it.

---

### [CRITICAL] Phase 1 cannot satisfy the tab bar height / icon scaling acceptance criteria
*(codex CRITICAL + claude MAJOR — strongly overlapping)*

The plan claims that if Phase 2 is delayed, a Phase-1-only c11 PR still scales tab title text and tab bar height visibly. Verifying against `vendor/bonsplit/Sources/Bonsplit/`: `Appearance.tabBarHeight` is **declared and initialized only**; `rg "tabBarHeight" vendor/bonsplit/Sources/Bonsplit` shows zero internal consumers. `TabBarView` frames the shell with `TabBarMetrics.barHeight = 30`; `TabItemView` frames items with `TabBarMetrics.tabHeight`; `glyphSize(for:)` reads `TabBarMetrics.iconSize`, not `appearance.tabIconSize`. Phase 1 therefore scales tab title font and accessory affordances (because `accessoryFontSize` derives from `tabTitleFontSize`), but **not** the tab bar shell, tab item height, icons, padding, or close-button sizing — all of which are in scope and listed in acceptance criteria.

**Recommendation:** Treat the Bonsplit-internal wiring as **required**, not optional, for C11-6 to pass. Concretely: (a) make the existing public `Appearance.tabBarHeight` actually drive the tab bar shell/reserved height inside Bonsplit; (b) add only the additional public knobs that remain necessary (`tabItemHeight`, `tabIconSize`, close/accessory sizing, padding) and wire them through `TabBarMetrics`/`TabBarView`/`TabItemView`; (c) remove the "Phase 1 only" deferral path from the plan, or explicitly negotiate the acceptance criterion down with the operator before splitting. Don't ship a partial that fails the criterion.

---

### [MAJOR] Proposed `tabBarShellHeight` duplicates the existing unused `tabBarHeight`
*(codex MAJOR)*

Adding a new `tabBarShellHeight` while keeping `tabBarHeight` distinct preserves a dead/ambiguous public API instead of fixing the existing one, and conflicts with the ticket's own "prefer existing appearance knobs first" guidance.

**Recommendation:** Define the intended semantics of `Appearance.tabBarHeight` and wire it through. If Bonsplit genuinely needs both an outer shell and an inner item height, repurpose `tabBarHeight` as the outer bar and add a clearly named `tabItemHeight` for the inner frame. Avoid `tabBarShellHeight` unless there's a documented compatibility reason.

---

### [MAJOR] Live-update relies on a custom Notification that external writers won't post
*(claude MAJOR)*

`@AppStorage` propagates UserDefaults changes to subscribed SwiftUI views, so the sidebar updates regardless of writer. But `Workspace.applyChromeScale(reason:)` is wired only to `ChromeScaleSettings.didChangeNotification`, posted by the Settings UI setter and the optional socket command. Any other writer — `defaults write com.stage11.c11 chromeScalePreset large`, a future migration, a not-yet-imagined keyboard shortcut, or even an `@AppStorage` write that doesn't accompany the manual post — will update the sidebar but leave the Bonsplit tab strip stale until the next chrome-affecting event. Classic "looks fine in dev, drifts in the wild" partial-update bug.

**Recommendation:** Use `UserDefaults.standard` KVO on `chromeScalePreset` (or `NSUserDefaultsDidChangeNotification`) for `Workspace`'s subscription, instead of (or in addition to) the custom notification. KVO fires regardless of writer; keep the custom notification only as belt-and-suspenders if there's a reason to.

---

### [MAJOR] Primary integration test is gated on a `GhosttyApp.shared` caveat that probably won't hold
*(claude MAJOR)*

Test #4 ("Workspace appearance plumbing") is the only proposed test exercising the resolver → Bonsplit appearance path end-to-end, but the plan acknowledges it moves to the Validate phase if `Workspace` can't be constructed without `GhosttyApp.shared`. Given how many existing `Workspace` paths route through `GhosttyApp.shared`, this caveat is likely to fire — leaving CI with only pure token-math tests, which won't catch a regression where someone adds a field to `BonsplitConfiguration.Appearance` and `Workspace.bonsplitAppearance(...)` quietly stops threading scale through.

**Recommendation:** Refactor `Workspace.bonsplitAppearance(...)` so the chrome-scale wiring lives in a *pure* helper — e.g. `applyChromeScaleTokens(_ tokens: ChromeScaleTokens, to appearance: inout BonsplitConfiguration.Appearance)` — called from both the static factory and `applyChromeScale(reason:)`. The test then becomes "given a default `Appearance` and `tokens(multiplier=1.12)`, the helper produces an `Appearance` with `tabTitleFontSize ≈ 12.32`, …", decoupled from `GhosttyApp.shared`. This matches the c11 test-quality policy ("add a small runtime seam or harness first, then test through that seam").

---

### [MINOR] `bonsplitAppearance` becomes UserDefaults-dependent without a parameter seam
*(claude MINOR — closely related to the integration-test issue)*

The plan extends `bonsplitAppearance(...)` to read `UserDefaults.standard.string(forKey: ChromeScaleSettings.presetKey)` directly, making the function impure: hidden global-state dependency, `Workspace`-init-order fragility (one-frame staleness if the key is written between `init` and the first `applyChromeScale` fire).

**Recommendation:** Take the multiplier (or `ChromeScaleTokens`) as a parameter on `bonsplitAppearance(...)`, with call sites resolving from `UserDefaults.standard` once. This mirrors `WorkspacePresentationModeSettings.mode(defaults:)` and combines naturally with the testable seam above.

---

### [MINOR] `@AppStorage` policy rationale is misstated
*(claude MINOR)*

The plan says: "Per `CLAUDE.md`'s typing-latency policy, do not add a new `@AppStorage` directly to `TabItemView`." But the actual rule prohibits `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties **without updating `==`** — not `@AppStorage`. `TabItemView` already has 12 `@AppStorage` declarations. The threading-via-parent recommendation is still defensible (one fewer `UserDefaults` observer per row), but the rationale cited isn't right.

**Recommendation:** Restate as "the resolver is cheap to compute once at parent level and threading it as a precomputed `let` keeps `TabItemView`'s `@AppStorage` set from growing further," or accept the existing pattern. Don't pin the choice to a rule that doesn't exist.

---

### [MINOR] Phase 1 no-op guard axes underspecified
*(claude MINOR)*

`applyChromeScale(reason:)` will "mirror the shape" of `applyGhosttyChrome`'s no-op guard, but the comparison axes aren't specified. They should explicitly cover `tabBarHeight`, `tabTitleFontSize`, `tabMinWidth`, `tabMaxWidth` (Phase 1) plus `tabIconSize`, `tabItemHeight`, `tabHorizontalPadding`, `tabBarShellHeight`/`tabItemHeight`, `tabCloseIconSize` (Phase 2). One sentence in the plan or a code comment in the impl is enough; spelling them out prevents later drift.

---

### [MINOR] Settings UI picker style and subtitles are underspecified
*(claude MINOR + codex MINOR — same surface, two angles)*

The plan calls for a `.pickerStyle(.segmented)` with four options "with subtitles," but a SwiftUI segmented picker generally has room only for the option label, and the existing nearby pickers in `appearanceSettingsPage` use the default `Picker` style via `SettingsPickerRow`. This creates visual inconsistency *and* implementation ambiguity (do subtitles ship? as one row-level explanatory string? per-option?).

**Recommendation:** Either (a) match the existing `SettingsPickerRow(... selection: ...) { ForEach(...) { Text(...).tag(...) } }` shape with a single row-level subtitle, or (b) commit to a non-segmented control (card/radio) where per-preset subtitles fit, and note the deliberate UX choice. Trim the localization table to strings the chosen control can actually render.

---

### [MINOR] Environment/token propagation root injection points underspecified
*(codex MINOR)*

The plan defines `EnvironmentValues.chromeScaleTokens` and says a wrapper view "near the Workspace root and inside the sidebar parent" pushes tokens down, but the commit plan mostly relies on explicit threading for sidebar and a direct environment read in `SurfaceTitleBarView`. Without naming the exact c11 view installing `.environment(\.chromeScaleTokens, tokens)`, an implementer could wire sidebar scaling correctly while leaving title-bar consumers at the default token value.

**Recommendation:** Name the exact view(s) where the environment is installed, or drop the environment for v1 and thread tokens explicitly everywhere in scope.

## 4. Positive Observations (consensus)

- **Code-area survey is grounded and accurate.** Spot-checked line numbers across `c11App.swift`, `Workspace.swift`, `BonsplitConfiguration.swift`, `TabItemView.swift`, `TabBarMetrics.swift`, `ContentView.swift`, and `SurfaceTitleBarView.swift` all match the source. The 17-field `==` count for `TabItemView` is correct.
- **Typing-latency awareness is excellent.** Threading a precomputed, `Equatable` `ChromeScaleTokens` value (with `==` short-circuiting to a single `CGFloat` multiplier compare) instead of adding observers in `TabItemView` is exactly the right shape for the hot path. All three reviewers called this out.
- **Token-based architecture is well-aligned with the ticket.** Keeps Ghostty terminal sizing out of scope, preserves the C11-5 sidebar hierarchy invariant (workspace title remains the largest, semibold element), and avoids raw multipliers scattered through call sites.
- **Phase split is the right shape** even after the criticisms above — Phase 1 (c11-only resolver + title/bar wiring) demonstrates value early; Phase 2 treats the submodule change as a deliberate, separately-reviewable artifact. Modeling `ChromeScaleSettings` after `WorkspacePresentationModeSettings` maintains codebase consistency.
- **"Open decisions" section is exemplary.** Nine decisions, each with recommendation and rationale, each clearly the operator's call. Format other plans should copy.
- **Test-quality and localization policy compliance.** Explicitly forbids grep tests, AST fragments, xcstrings introspection. Localization plan covers all six locales with realistic subtitle copy and the standard sub-agent hand-off.
- **Out-of-scope list is concrete.** "No freeform slider for v1," "no per-workspace overrides," "no resizing of agent skills panel/command palette/mailbox" — the right boundaries declared upfront.
- **Validation plan addresses live-update without focus changes, `c11 tree --no-layout` rebalance, Ghostty-unchanged check, and a screenshot pack** — exactly the visual/behavioral things automated tests can't catch.

## 5. Reviewer Agreement

- **Strong agreement on quality of approach:** All three reviewers praise the typing-latency design, token-based architecture, Phase 1/Phase 2 split, localization plan, and test-quality discipline. No reviewer challenged the architectural shape.
- **Strong agreement on Bonsplit submodule problems:** Claude (CRITICAL) and codex (MAJOR) independently flagged that the documented push/PR workflow doesn't match the actual remote setup. Gemini missed this — likely from not running `git remote -v` in `vendor/bonsplit`.
- **Strong agreement on the Phase 1 deferral gap:** Claude (MAJOR) and codex (CRITICAL) independently identified that a Phase-1-only landing would not satisfy the tab-bar-height / icon-scaling acceptance criteria. Codex went further by verifying that `Appearance.tabBarHeight` has zero internal consumers in Bonsplit today, which is the load-bearing fact making this a CRITICAL.
- **Disagreement on overall verdict:** Claude and codex returned **FAIL (plan-level)**; Gemini returned **PASS** with no issues found. The merged verdict sides with the FAIL camp because both critical findings are concrete, verifiable, and load-bearing — Gemini's PASS appears to reflect a higher-altitude read that didn't probe the submodule remote configuration or audit Bonsplit-internal consumers.
- **Distinct contributions:** Claude added depth on the live-update Notification leak, the `GhosttyApp.shared`-gated test problem, and the `@AppStorage`-policy citation slip. Codex added the `tabBarShellHeight`-vs-`tabBarHeight` API duplication and the environment-injection root-point ambiguity. Gemini's value here is the consensus signal on the architectural choices that the other two reviewers also endorsed.
