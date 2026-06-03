# C11-6 Plan v2 Review (claude)

## 1. Verdict

**FAIL (plan-level)**

## 2. Summary

Reviewed the v2 plan for C11-6 (App chrome UI scale) against the ticket AC, the
current `vendor/bonsplit/` source, `Sources/Workspace.swift`, and
`Sources/ContentView.swift`. The plan is significantly stronger than v1 — KVO
spine, pure `applyChromeScale(_:to:)` helper, parameter-seam resolver,
explicit submodule push order against `Stage-11-Agentics/bonsplit`, and a
realistic per-token test plan. It fails because three load-bearing claims do
not hold against the current code: (a) repurposing `Appearance.tabBarHeight`
silently changes the Default-preset bar shell height, (b) the listed
re-routing for terminal/globe tab icons does not actually flow through the
new `tabIconSize` knob, and (c) the proposed `Workspace`-as-KVO-target shape
will not compile because `Workspace` is `@MainActor final class` and does
not inherit `NSObject`. None of the three is structural — fixable inline —
but each will burn implementation time and risks landing under-tested if
left for the Impl phase to discover.

## 3. Issues

**[CRITICAL] Bonsplit wiring → `Appearance.tabBarHeight` default mismatch silently bumps Default-preset shell height**

`vendor/bonsplit/.../BonsplitConfiguration.swift:182,260` declares
`Appearance.tabBarHeight` with initializer default `33`. But the actual bar
shell today is laid out at `TabBarMetrics.barHeight = 30` (verified at
`TabBarView.swift:559` and `TabBarView.swift:624`). When the plan's commit 3
re-routes the shell from `TabBarMetrics.barHeight` to
`appearance.tabBarHeight`, every embedder that doesn't override the knob —
including c11 at Default preset, where `surfaceTabBarHeight = 33.0 *
1.0 = 33` — will see the bar shell visibly grow from 30pt to 33pt. The plan
claims "Default values match the existing `TabBarMetrics` constants
(33 / 30 / 14 / 6 / 9), so untouched embedders see today's behavior" and
"Default: 1.00x"; both are inconsistent with the actual constants. The
`Appearance.compact` and `Appearance.spacious` presets at lines 242–254 of
the same file (`tabBarHeight: 28` and `38`) compound the issue: today they
are inert; after rerouting they materially change the shell.

**Recommendation:** Pick one explicitly:
- Lower `Appearance.tabBarHeight`'s initializer default to `30` and set
  `surfaceTabBarHeight = 30.0 * multiplier`, so Default preset is byte-exact
  with today and other Bonsplit embedders see no change. State this in the
  Bonsplit PR description (`Appearance.compact`/`spacious` numerics may need
  adjustment too).
- OR own the +10% bump as intentional, update the resolver and the picker
  subtitle so "Default" no longer reads as 1.00× of-today, and add an
  explicit Validation step that screenshots the bar shell at Default before
  and after the change for sign-off.

**[CRITICAL] Bonsplit wiring → terminal / globe / browser tab icons will not scale**

`vendor/bonsplit/.../TabItemView.swift:299–306` defines `glyphSize(for:)`:

```swift
private func glyphSize(for iconName: String) -> CGFloat {
    if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
        return max(10, TabBarMetrics.iconSize - 2.5)
    }
    return TabBarMetrics.iconSize
}
```

These three icon names cover the two most common tab types in c11 (terminal
surfaces and unloaded/loading browser surfaces). The function is invoked at
line 151 (`Image(systemName:).font(.system(size: glyphSize(...)))`). The
plan's Bonsplit-internal change list at line 333 of the plan reads
"`TabItemView.swift:303, 305, 331` — keep `glyphSize(for:)` and clamp logic
deriving from `appearance.tabIconSize` / `appearance.tabItemHeight`." That
sentence is ambiguous and, read literally, says "leave the function alone."
But the function body today derives from `TabBarMetrics.iconSize` (the
constant 14) and so will not scale even after the public knob is added.

The acceptance criterion is explicit: "Top surface tab strip icons and
accessory glyphs, including **terminal/browser/markdown icons**, close
glyphs, zoom glyphs, dirty/activity indicators where practical, and
shortcut-hint glyph sizing." Without rewriting `glyphSize(for:)` to derive
from `appearance.tabIconSize`, the most visible class of icon — terminal —
fails this AC at Large and Extra Large.

**Recommendation:** In commit 3, explicitly rewrite `glyphSize(for:)` to:
```swift
private func glyphSize(for iconName: String) -> CGFloat {
    if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
        return max(10, appearance.tabIconSize - 2.5)
    }
    return appearance.tabIconSize
}
```
and add a Validation step that screenshots a terminal tab and a browser tab
at Compact/Default/Large/ExtraLarge to confirm icon scaling.

**[MAJOR] Persistence design → `Workspace` cannot host UserDefaults KVO directly**

`Sources/Workspace.swift:5071–5072` declares `@MainActor final class
Workspace: Identifiable, ObservableObject` — not an `NSObject` subclass.
`UserDefaults.addObserver(_:forKeyPath:options:context:)` requires the
observer to be NSObject (it relies on the legacy KVO machinery on
NSObject). The plan says "Each `Workspace` registers a KVO observer on
`UserDefaults.standard` for the `chromeScalePreset` key in `init` and
removes it in `deinit`." This will not compile against the current
`Workspace` class shape, and changing `Workspace` to inherit from `NSObject`
is a non-trivial refactor that also changes its actor isolation story
(NSObject's KVO callbacks are not `@MainActor`-isolated).

A second wrinkle: KVO on UserDefaults fires on the thread that issued the
`set`, which can be off-main (`defaults write` from a CLI; remote daemon
writers; future migrations). `Workspace.applyChromeScale(reason:)` is
implicitly `@MainActor`, so the callback must hop to main.

**Recommendation:** Introduce a small NSObject-based observer helper held
by `Workspace`:
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
Hold one instance per `Workspace` (or — cleaner — a single app-level
observer that fans out to a `Notification` or a Combine subject that all
Workspaces subscribe to via `objectWillChange` machinery). Update the test
plan to commit to testing `ChromeScaleObserver` directly rather than a
hypothetical "minimal Workspace" — the latter is impractical given the
init-time dependencies (Bonsplit, terminal panel, mailbox dispatcher,
remote daemon registry, etc.).

**[MAJOR] Bonsplit wiring → re-routing list misses several `TabBarMetrics` consumers**

`grep TabBarMetrics vendor/bonsplit/Sources/Bonsplit/Internal/Views/` shows
consumers the plan does not address:

- `TabBarView.swift:475` — `Color.clear.frame(width: 0, height: TabBarMetrics.tabHeight)` (leading anchor cell for scroll alignment).
- `TabBarView.swift:486` — `.padding(.horizontal, TabBarMetrics.barPadding)` (the bar's own horizontal inset; currently 0, but if it's ever non-zero it should track).
- `TabBarView.swift:524` — `.frame(width: trailing, height: TabBarMetrics.tabHeight)` (trailing chrome backdrop height).
- `TabBarView.swift:890` — `.frame(width: 30, height: TabBarMetrics.tabHeight)` (drop-indicator/spacer cell).
- `TabItemView.swift:127` — `HStack(spacing: TabBarMetrics.contentSpacing)` (icon→title gap).
- `TabItemView.swift:552` — `.frame(height: TabBarMetrics.activeIndicatorHeight)` (selected-tab accent underbar; already 3pt — visibly thin at Extra Large).
- `TabItemView.swift:576` — `.frame(width: TabBarMetrics.notificationBadgeSize, …)` (notification dot).
- `TabItemView.swift:581` — `.frame(width: TabBarMetrics.dirtyIndicatorSize, …)` (dirty indicator — explicitly named in AC: "dirty/activity indicators where practical").

At Large and Extra Large, the per-tab cell grows (because `tabItemHeight`
is rerouted) but the spacer/anchor cells in `TabBarView` remain at 30pt,
producing visible misalignment in scroll endpoints and during tab-drag
preview. The notification badge and dirty indicator stay constant against
a scaled tab title — the most visually obvious failure mode for a
"chrome scale" feature.

**Recommendation:** Either expand the new public-knob set to cover these
(at minimum: `tabContentSpacing`, `tabDirtyIndicatorSize`,
`tabNotificationBadgeSize`, `tabActiveIndicatorHeight`) and re-route every
spacer in `TabBarView`, or scope-document each unrouted consumer in the
"Do NOT ship" section with a one-line reason ("active indicator stays at
3pt — scaling it visibly thickens selection chrome and makes the tab strip
feel heavier"). The dirty/notification indicators almost certainly belong
in the "scale" set per the AC.

**[MAJOR] `accessorySlotSize` clamp is bounded by a constant ceiling**

`TabItemView.swift:329–332`:
```swift
private var accessorySlotSize: CGFloat {
    min(TabBarMetrics.tabHeight, max(TabBarMetrics.closeButtonSize, ceil(accessoryFontSize + 4)))
}
```

`accessoryFontSize` already derives from `appearance.tabTitleFontSize` (line
325), so the inner `max(...)` grows correctly. But the outer `min(...)`
caps the slot at the constant `TabBarMetrics.tabHeight = 30`, which means
the zoom button, close button, and shortcut-hint capsule can't grow past
30pt at Extra Large even though the title text and the per-tab cell do.
The plan's line 333 mentions this clamp but, as in CRITICAL #2, does not
explicitly rewrite the body.

**Recommendation:** Rewrite the clamp to derive from the new public knobs:
```swift
private var accessorySlotSize: CGFloat {
    min(appearance.tabItemHeight, max(appearance.tabCloseIconSize + 7, ceil(accessoryFontSize + 4)))
}
```
or a similar form that uses appearance-driven bounds. Add a Validation
step that exercises a tab with the close button and zoom indicator visible
at Extra Large.

**[MAJOR] Environment injection at `WindowGroup` doesn't cover `Workspace`-owned `BonsplitController` post-construction**

The plan installs `.environment(\.chromeScaleTokens, …)` on the
`WindowGroup`'s root content. SwiftUI consumers downstream re-read on
`@AppStorage` change. Good for `SurfaceTitleBarView`, sidebar (also via
the precomputed `let`), and any future surface. But `Workspace`'s
`bonsplitController` is a non-SwiftUI object initialized once in
`Workspace.init` (`Sources/Workspace.swift:5536–5561`) with the
appearance resolved at that moment. The plan covers the live-update path
via KVO (modulo MAJOR #3) but does not state how `Workspace.init` itself
acquires tokens. If a Workspace is constructed *after* a chrome-scale
change but before the KVO callback fires, it must re-resolve from
`UserDefaults.standard` at init time. This is straightforward
(`ChromeScaleTokens.resolved(from: .standard)`), but the plan should
explicitly thread it into `Workspace.init`'s call to
`Self.bonsplitAppearance(...)` so future-readers see the tokens flow on
both the construction path and the KVO path.

**Recommendation:** In commit 4, show the `Workspace.init` change
explicitly: pass `tokens: ChromeScaleTokens.resolved()` into the
`Self.bonsplitAppearance(...)` call at line 5536. Add an init-path test
that constructs a `BonsplitConfiguration.Appearance` via the static
`bonsplitAppearance(...)` call with a non-default tokens object and
asserts every routed knob.

**[MINOR] `Appearance.compact` / `.spacious` presets become load-bearing**

`vendor/bonsplit/.../BonsplitConfiguration.swift:242–254` defines
`Appearance.compact` (`tabBarHeight: 28`) and `Appearance.spacious`
(`tabBarHeight: 38`). Today these are inert because no consumer reads
`tabBarHeight`. After the rerouting in commit 3, any Bonsplit embedder
selecting these presets will see the shell change. c11 doesn't use them
(`Workspace.bonsplitAppearance(...)` constructs a fresh `Appearance`),
but the Bonsplit PR description should document the change so future
embedders aren't surprised.

**Recommendation:** Add a one-paragraph "Behavior change" section to the
Bonsplit PR body listing the three pre-defined `Appearance` constants and
their now-effective `tabBarHeight` values; cross-link from the c11 PR.

**[MINOR] Localization plan: `displayName` map needs to be in commit 1**

The plan's table at lines 540–547 lists keys for the picker label,
subtitle, and four preset names. The resolver pseudocode at line 165
declares `case compact, standard, large, extraLarge`, and the picker uses
`Text(preset.displayName)`. The plan mentions "Preset display names ... are
surfaced via a `displayName` computed property on
`ChromeScaleSettings.Preset` that maps each case to the corresponding
localized key" but doesn't show the snippet — easy to forget to ship in
commit 1, where the picker depends on it.

**Recommendation:** Add the `displayName` extension snippet to the commit
1 deliverables list:
```swift
extension ChromeScaleSettings.Preset {
    var displayName: String {
        switch self {
        case .compact:    return String(localized: "settings.chromeScale.preset.compact",    defaultValue: "Compact")
        case .standard:   return String(localized: "settings.chromeScale.preset.standard",   defaultValue: "Default")
        case .large:      return String(localized: "settings.chromeScale.preset.large",      defaultValue: "Large")
        case .extraLarge: return String(localized: "settings.chromeScale.preset.extraLarge", defaultValue: "Extra Large")
        }
    }
}
```

**[MINOR] `ChromeScaleTokens` `==` is load-bearing for typing latency — needs a doccomment**

The plan threads `chromeTokens: ChromeScaleTokens` as a precomputed `let`
into `TabItemView` and adds it to the typing-latency-sensitive `==`
function. The default-synthesized `Equatable` only compares stored
properties (currently just `multiplier`). If a future contributor adds a
non-multiplier stored property to `ChromeScaleTokens`, the `==` still
works — but if they add a new computed token *and* use it in a sidebar
hot path, they need to know that `==` only checks `multiplier`. A
two-line doccomment on `ChromeScaleTokens` describing this contract will
save the next maintainer an afternoon.

**Recommendation:** Add a doccomment to `ChromeScaleTokens` (and a one-liner
to the `==` site in `TabItemView`) noting that the type is intentionally
single-stored-property + computed-tokens to keep `==` cheap on the typing
hot path.

**[MINOR] `surfaceTabMinWidth/MaxWidth` floors are inert at the four ship presets**

The resolver's `max(112.0 * multiplier, 96)` and `max(220.0 * multiplier,
180)` floors only bite at multipliers below ~0.86 and ~0.82 respectively;
the four ship presets are 0.90/1.00/1.12/1.25, none of which reach the
floor. They're harmless but read as "this feature might support custom
multipliers later" without saying so.

**Recommendation:** Either drop the floors and use plain multiplications
(simpler, equally correct for the ship presets), or add a one-line
comment noting that the floors exist as guard rails for a possible
future "Custom multiplier" follow-up — matching the line in the
Do-NOT-ship list.

## 4. Positive Observations

- **Real engagement with v1 review feedback.** The introductory paragraph
  names the prior reviewers' verdicts and tracks each CRITICAL/MAJOR/MINOR
  to a specific structural fix. KVO spine, pure helper, parameter seam,
  and Bonsplit submodule push order are all real plan-shape changes, not
  cosmetic responses.
- **C11-5 hierarchy preservation analysis.** Lines 105–112 correctly
  identify that the workspace title needs to remain visually dominant
  across all presets and route the invariant through the resolver
  (uniform multiplier, per-row weight unchanged). This is exactly the
  kind of thing that's easy to miss until QA finds it.
- **Submodule discipline is precise.** The branch-→push-→PR-→fast-forward
  sequence at lines 405–420 names the right remote
  (`Stage-11-Agentics/bonsplit`), the right verification command
  (`merge-base --is-ancestor HEAD origin/main`), and the right anti-pattern
  to refuse (committing a parent pointer at a detached HEAD). Verified
  against `git -C vendor/bonsplit remote -v`.
- **Bonsplit-as-generic, c11-as-resolver split.** Open decision #8 is
  correctly resolved: Bonsplit gains generic public knobs, c11 owns
  `ChromeScaleTokens` and writes resolved values into `Appearance`. This
  keeps Bonsplit upstream-compatible and the c11 fork-level concern
  isolated.
- **Test plan honors the CLAUDE.md test-quality policy.** Explicitly lists
  forbidden test shapes (grep-of-source, xcstrings inspection, AST
  fragment) and proposes a pure-helper test for
  `Workspace.applyChromeScale(_:to:)` that decouples from
  `GhosttyApp.shared` — exactly the runtime-seam pattern CLAUDE.md
  requests.
- **No-Phase-1-deferral path is correctly rejected.** The acceptance
  criteria require visible scaling of bar shell, item height, icons, and
  accessories. The plan correctly refuses a "ship narrow, follow up" path
  that would fail AC and instead bundles the Bonsplit submodule changes
  with the c11 pointer bump in commit 4.
- **Belt-and-suspenders notification is correctly de-emphasized.** Lines
  274–278 make explicit that `ChromeScaleSettings.didChangeNotification`
  is *not* the primary signal — KVO is — and explain why (multi-writer
  coverage). This kills the v1 ambiguity around two notification paths
  fighting each other.
