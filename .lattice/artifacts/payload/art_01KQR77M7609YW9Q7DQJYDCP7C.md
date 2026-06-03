# Merged Plan Review: C11-6 (App Chrome UI Scale)

## 1. Verdict

**FAIL (plan-level)**

Two of three reviewers (claude, codex) returned FAIL with overlapping CRITICAL findings against load-bearing code claims. Gemini returned PASS but operated at a higher level of abstraction and did not verify the v2 plan's specific code-level assertions (Bonsplit defaults, `glyphSize(for:)` body, `Workspace`'s NSObject status, `TabBarMetrics` consumer inventory). Where claude and codex independently inspected the same files and surfaced the same defects, that agreement outweighs gemini's clean read. The plan is structurally sound — the v1→v2 deltas (KVO spine, pure resolver helper, parameter-seam token, Bonsplit submodule push order) are real improvements — but it cannot be implemented as written without producing visible regressions at the Default preset and AC failures at Large / Extra Large.

## 2. Synthesis

Three reviews. Two FAIL with substantial code-grounded findings; one PASS at the architectural level. The two failing reviews converge on the same two CRITICALs and similar concerns about the live-update mechanism. Claude's review is the deepest — it goes line-by-line through `vendor/bonsplit/.../TabBarView.swift`, `TabItemView.swift`, and `Sources/Workspace.swift` and surfaces specific identifiers (`glyphSize(for:)`, `accessorySlotSize`, the `Workspace: ObservableObject` non-NSObject shape) that the plan glosses. Codex adds two orthogonal concerns the plan should address before coding starts: scope-creep risk from the v1 socket command (`c11 chrome.set-scale`) and missing project-file target-membership steps for the new Swift sources/tests. Gemini's positive observations are accurate; they describe the plan's architectural intent, but the failing reviewers are arguing about the executable details inside that intent.

The pattern across both failing reviews: the plan's Bonsplit-internal change list is too declarative ("keep glyphSize and clamp logic deriving from the new knobs") rather than showing the actual rewritten function bodies. That ambiguity is what hides the CRITICALs.

## 3. Issues (Consolidated, Ordered by Severity)

### [CRITICAL] Bonsplit `tabBarHeight` default mismatch silently bumps Default-preset shell height

*(Found by claude AND codex — independently verified against the same files.)*

`vendor/bonsplit/.../BonsplitConfiguration.swift:182,260` declares `Appearance.tabBarHeight` with default `33`, but the actual rendered shell is laid out at `TabBarMetrics.barHeight = 30` (`TabBarView.swift:559,624`). The plan's commit 3 reroutes the shell from `TabBarMetrics.barHeight` to `appearance.tabBarHeight`. At Default preset (`surfaceTabBarHeight = 33.0 * 1.0 = 33`), every embedder — c11 included — silently grows the shell from 30pt to 33pt, despite the plan explicitly claiming "Default values match the existing TabBarMetrics constants" and "Default: 1.00x." The `Appearance.compact` (28pt) and `Appearance.spacious` (38pt) presets at lines 242–254 compound the issue: today inert, after rerouting they materially change the shell for any embedder selecting them.

**Recommendation:** Pick one explicitly and document the choice in the plan and in the Bonsplit PR body:
- Lower `Appearance.tabBarHeight`'s initializer default to `30` and set the resolver to `surfaceTabBarHeight = 30.0 * multiplier` so Default is byte-exact with today and other Bonsplit embedders see no change. Adjust `Appearance.compact` / `.spacious` accordingly.
- OR own the +10% bump as intentional, update the picker subtitle so "Default" no longer reads as 1.00× of-today, and add a Validation step screenshotting the bar shell at Default before/after sign-off.

### [CRITICAL] Terminal / globe / browser tab icons will not scale; `glyphSize(for:)` rewrite is unspecified

*(Found by claude; codex's incomplete-geometry-audit CRITICAL covers the same surface area more generally.)*

`vendor/bonsplit/.../TabItemView.swift:299–306` defines `glyphSize(for:)`, which derives from the constant `TabBarMetrics.iconSize` (14) and special-cases `terminal.fill` / `terminal` / `globe` — covering the two most common tab types in c11. The plan's Bonsplit change list reads "keep `glyphSize(for:)` and clamp logic deriving from `appearance.tabIconSize` / `appearance.tabItemHeight`," which is ambiguous and, read literally, leaves the function alone. The AC explicitly requires terminal/browser/markdown icons to scale.

**Recommendation:** In commit 3, explicitly rewrite `glyphSize(for:)` to derive from `appearance.tabIconSize`:
```swift
private func glyphSize(for iconName: String) -> CGFloat {
    if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
        return max(10, appearance.tabIconSize - 2.5)
    }
    return appearance.tabIconSize
}
```
Add a Validation step that screenshots terminal and browser tabs at Compact / Default / Large / Extra Large.

### [MAJOR] Tab-strip geometry audit is incomplete — multiple `TabBarMetrics` consumers stay constant while item height grows

*(Found by both claude and codex; claude enumerates the specific call sites.)*

Claude's grep of `vendor/bonsplit/Sources/Bonsplit/Internal/Views/` surfaces consumers the plan does not address:

- `TabBarView.swift:475` — leading anchor cell (`TabBarMetrics.tabHeight`)
- `TabBarView.swift:486` — bar horizontal padding (`TabBarMetrics.barPadding`)
- `TabBarView.swift:524` — trailing chrome backdrop (`TabBarMetrics.tabHeight`)
- `TabBarView.swift:890` — drop-indicator/spacer cell (`TabBarMetrics.tabHeight`)
- `TabItemView.swift:127` — icon→title gap (`TabBarMetrics.contentSpacing`)
- `TabItemView.swift:552` — selected-tab accent underbar (`TabBarMetrics.activeIndicatorHeight`, 3pt)
- `TabItemView.swift:576` — notification badge (`TabBarMetrics.notificationBadgeSize`)
- `TabItemView.swift:581` — dirty indicator (`TabBarMetrics.dirtyIndicatorSize`) — **explicitly named in the AC**

At Large / Extra Large, per-tab cells grow but spacer/anchor cells stay at 30pt, producing visible misalignment in scroll endpoints and drop preview. The notification dot and dirty indicator stay constant against scaled titles — a visually obvious failure mode for a "chrome scale" feature, and dirty indicators are explicitly called out in the ticket.

**Recommendation:** Either expand the new public-knob set to cover these (minimum: `tabContentSpacing`, `tabDirtyIndicatorSize`, `tabNotificationBadgeSize`, `tabActiveIndicatorHeight`, plus the trailing/anchor/drop frames driven from `tabItemHeight`) and re-route every `TabBarView` spacer, or scope-document each unrouted consumer in the plan's "Do NOT ship" section with a one-line reason. Dirty / notification indicators almost certainly belong in the scaled set.

### [MAJOR] Persistence design — `Workspace`-as-KVO-target won't compile; KVO mechanics are underspecified

*(Found by both claude and codex from different angles.)*

`Sources/Workspace.swift:5071–5072`: `@MainActor final class Workspace: Identifiable, ObservableObject` — not an `NSObject` subclass. `UserDefaults.addObserver(_:forKeyPath:options:context:)` requires NSObject. The plan's "Each `Workspace` registers a KVO observer on `UserDefaults.standard`" will not compile. Promoting `Workspace` to `NSObject` is a non-trivial refactor that also disturbs its actor isolation story. Additionally, KVO callbacks fire on the writer's thread, which can be off-main; `Workspace.applyChromeScale(reason:)` is `@MainActor`-isolated. Codex separately notes that the codebase currently uses `UserDefaults.didChangeNotification` rather than key-specific KVO, and that external `defaults write` is not a reliable live-update mechanism for an already-running app.

**Recommendation:** Introduce a small NSObject-based observer helper held by `Workspace`:
```swift
final class ChromeScaleObserver: NSObject {
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) { … }
    deinit { UserDefaults.standard.removeObserver(self, forKeyPath: ChromeScaleSettings.presetKey) }
    override func observeValue(forKeyPath: …, of: …, change: …, context: …) {
        Task { @MainActor in onChange() }
    }
}
```
Hold one per `Workspace` (or a single app-level observer that fans out via `NotificationCenter` / Combine — cleaner). Update the test plan to test `ChromeScaleObserver` directly rather than a hypothetical "minimal Workspace" (impractical given Workspace's init-time dependencies). Separately, narrow the live-update requirement: support in-process writers as the supported path; if external `defaults write` is a real validation goal, design a socket command for it instead of relying on default notification semantics.

### [MAJOR] `accessorySlotSize` clamp is bounded by a constant ceiling

*(Claude — specific identifier-level issue.)*

`TabItemView.swift:329–332`:
```swift
private var accessorySlotSize: CGFloat {
    min(TabBarMetrics.tabHeight, max(TabBarMetrics.closeButtonSize, ceil(accessoryFontSize + 4)))
}
```
The inner `max(…)` grows correctly via `accessoryFontSize`, but the outer `min(…)` caps at the constant `TabBarMetrics.tabHeight = 30`, so close button, zoom button, and shortcut-hint capsule cannot grow past 30pt at Extra Large even though title and per-tab cell do.

**Recommendation:** Rewrite the clamp in terms of the new public knobs:
```swift
private var accessorySlotSize: CGFloat {
    min(appearance.tabItemHeight, max(appearance.tabCloseIconSize + 7, ceil(accessoryFontSize + 4)))
}
```
Add a Validation step exercising a tab with the close + zoom indicators visible at Extra Large.

### [MAJOR] Environment injection at `WindowGroup` doesn't cover `Workspace`'s `BonsplitController` post-construction path

*(Claude.)*

`.environment(\.chromeScaleTokens, …)` on the `WindowGroup` root reaches SwiftUI consumers, but `Workspace.bonsplitController` is a non-SwiftUI object initialized once in `Workspace.init` (`Sources/Workspace.swift:5536–5561`) with appearance resolved at that moment. The plan covers the live-update path via KVO (subject to the MAJOR above) but does not state how `Workspace.init` itself acquires tokens — important for any Workspace constructed after a chrome-scale change but before the KVO callback fires.

**Recommendation:** In commit 4, show the `Workspace.init` change explicitly: pass `tokens: ChromeScaleTokens.resolved()` into the `Self.bonsplitAppearance(...)` call at line 5536. Add an init-path test that constructs an `Appearance` via the static `bonsplitAppearance(...)` with non-default tokens and asserts every routed knob.

### [MAJOR] v1 socket command (`c11 chrome.set-scale`) — scope creep + missing skill/docs updates

*(Codex.)*

The ticket does not require a socket command. Adding one in v1 expands the surface area and triggers the project rule that every CLI/socket protocol change must update the c11 skill contract (`skills/c11/SKILL.md`). The plan includes the command but does not include skill updates, command help, parser test coverage, focus-safety tests, or a rollback path if the command delays the UI-scale work.

**Recommendation:** Either drop the socket command from v1 (validate live updates through Settings only), or keep it as an explicit AC-supporting deliverable with skill updates, command help, socket parser tests, focus-safety tests per the project's socket focus policy, and localization/error-message handling itemized in the commit plan.

### [MAJOR] Build/test integration — missing `project.pbxproj` target-membership steps; Bonsplit harness is hand-waved

*(Codex.)*

This Xcode project has manual `project.pbxproj` source/test entries; new files don't auto-join targets. The plan adds `Sources/Chrome/ChromeScale.swift` and several new tests but does not say to add them to the app and `c11-unit` targets. On the Bonsplit side, "verify the rendered view tree honors them" risks collapsing into brittle SwiftUI introspection unless a concrete harness exists.

**Recommendation:** Add explicit "add to app target" and "add to c11-unit target" steps to the commit plan for every new c11 source/test file. For Bonsplit, define a small pure layout/metrics resolver or hosted-view measurement harness exercisable in `vendor/bonsplit/Tests`, and replace generic "rendered view tree" promises with concrete test shapes against that harness.

### [MINOR] `Appearance.compact` / `.spacious` presets become load-bearing for downstream embedders

*(Claude.)*

After the rerouting in commit 3, the inert `Appearance.compact` (`tabBarHeight: 28`) and `Appearance.spacious` (`tabBarHeight: 38`) materially change the shell for any future Bonsplit embedder selecting them. c11 doesn't use them but the Bonsplit PR description should document the change.

**Recommendation:** Add a "Behavior change" paragraph to the Bonsplit PR body listing the three pre-defined `Appearance` constants and their now-effective `tabBarHeight` values; cross-link from the c11 PR.

### [MINOR] `displayName` map should be in commit 1 deliverables

*(Claude.)*

The picker uses `Text(preset.displayName)`; the plan describes the mapping but doesn't show the snippet, making it easy to forget to ship in commit 1.

**Recommendation:** Add the `ChromeScaleSettings.Preset.displayName` extension snippet to commit 1's deliverables list, with the four `String(localized:defaultValue:)` calls per the localization plan.

### [MINOR] `ChromeScaleTokens` `==` is load-bearing for typing latency — needs a doccomment

*(Claude.)*

`ChromeScaleTokens` enters the typing-latency-sensitive `==` for `TabItemView`. Default-synthesized `Equatable` only compares stored properties (currently just `multiplier`). A future contributor adding a non-multiplier stored property + sidebar hot-path consumer needs to know this contract.

**Recommendation:** Add a doccomment to `ChromeScaleTokens` (and a one-liner at the `==` site in `TabItemView`) noting that the type is intentionally single-stored-property + computed-tokens to keep `==` cheap on the typing hot path.

### [MINOR] `surfaceTabMinWidth` / `MaxWidth` floors are inert at the four ship presets

*(Claude.)*

`max(112.0 * multiplier, 96)` and `max(220.0 * multiplier, 180)` only bite below ~0.86 / ~0.82; the four ship presets (0.90 / 1.00 / 1.12 / 1.25) never reach the floor.

**Recommendation:** Either drop the floors and use plain multiplications, or add a one-line comment that they're guard rails for a possible future "Custom multiplier" follow-up.

## 4. Positive Observations

All three reviewers agreed on the following strengths:

- **Real engagement with v1 review feedback.** The KVO spine, pure `applyChromeScale(_:to:)` helper, parameter-seam resolver, and explicit Bonsplit submodule push order against `Stage-11-Agentics/bonsplit` are real plan-shape changes, not cosmetic responses (claude, gemini).
- **Performance awareness on the typing hot path.** Threading an `Equatable` `ChromeScaleTokens` value as a precomputed `let` into `TabItemView` and integrating it into the existing `==` preserves scroll/typing performance without adding `@AppStorage` reads per row (gemini, claude).
- **Submodule discipline is precise.** Branch → push → PR → fast-forward sequence with the right remote and the `merge-base --is-ancestor HEAD origin/main` verification, plus the explicit refusal of detached-HEAD parent-pointer commits (claude, gemini).
- **Bonsplit-as-generic, c11-as-resolver split is the right boundary.** Bonsplit gains generic public knobs; c11 owns `ChromeScaleTokens` and writes resolved values into `Appearance`. Keeps Bonsplit upstream-compatible and isolates the c11 fork-level concern (claude, codex, gemini).
- **Test plan honors CLAUDE.md quality policy.** Explicitly forbids grep-of-source / xcstrings-inspection / AST-fragment shapes; proposes a pure-helper test for `Workspace.applyChromeScale(_:to:)` decoupled from `GhosttyApp.shared` — exactly the runtime-seam pattern the policy requests (claude, gemini).
- **Scope is correctly bounded.** Semantic presets rather than freeform multiplier; Ghostty terminal sizing held out of scope; C11-5 sidebar hierarchy preservation called out and threaded through the resolver (codex, claude).
- **Validation checklist is unusually thorough** and would be valuable once the live-update and tab-geometry assumptions are tightened (codex).

## 5. Reviewer Agreement

**Strong agreement (claude + codex, independently):**
- Verdict: FAIL (plan-level).
- The `Appearance.tabBarHeight` 33-vs-30 mismatch is a CRITICAL silent regression at Default.
- The Bonsplit tab-strip geometry audit is incomplete — multiple `TabBarMetrics` consumers will not scale even after the plan's stated changes. Claude enumerates the specific call sites; codex frames it generically. Same defect.
- The UserDefaults KVO live-update story is overstated and underspecified, with main-actor / threading concerns unaddressed. Claude additionally proves the chosen target type (`Workspace`) cannot host KVO without inheriting from `NSObject`.

**Where reviewers diverge:**
- **Gemini returned PASS, claude and codex returned FAIL.** Gemini's review reads at the architectural-intent layer and praises exactly the structures (KVO spine, `Equatable` token, submodule discipline) where claude and codex find executable defects. Gemini did not appear to verify the specific code-level claims (Bonsplit defaults, `Workspace`'s NSObject status, `glyphSize(for:)` body, `TabBarMetrics` consumer inventory). The PASS should not block on the FAILs given the latter are grounded in inspected source.
- **Codex flags two issues claude does not:** the v1 socket command's scope-creep / missing skill update, and `project.pbxproj` target-membership steps for new Swift sources/tests. Both are real and warrant inclusion in the v3 plan.
- **Claude flags issues codex does not surface specifically:** the `accessorySlotSize` constant ceiling, the `WindowGroup` environment vs. `Workspace.init` construction-path gap, and the inert `Appearance.compact` / `.spacious` presets becoming load-bearing for embedders. These are concrete and worth addressing.

**Net.** Treat claude + codex as the binding verdict. The plan is one revision away from PASS: resolve the two CRITICALs explicitly (don't paper over the 33↔30 question; rewrite `glyphSize(for:)` and the unrouted `TabBarMetrics` consumers in commit 3), tighten the KVO design with a concrete `NSObject` observer or in-process notification path, decide socket-command scope, and add `project.pbxproj` target-membership and `Workspace.init` construction-path steps. None of the issues is structural; v3 should be a straightforward revision rather than a rewrite.
