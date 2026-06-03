# CMUX-30: Bonsplit ↔ c11mux — `TrailingAccessory` slot, extract toolbar buttons out of bonsplit

## Update 2026-04-19 — ship-today scope

Per operator direction 2026-04-19, both upstream tickets were **cancelled** in favor of going direct to CMUX-30:

- **CMUX-22** (tactical 114→184 bump, previously `done` on `cmux-22-tab-x-fix` branches) — **cancelled**. Throwaway since CMUX-30 deletes the constant. Branch left un-merged for archaeology.
- **CMUX-31** (consolidated drift-bug elimination via dynamic measurement) — **cancelled, folded into CMUX-30 Phase 1**. The `SplitButtonsWidthKey` measurement work becomes the internal plumbing step of Phase 1 (add slot + measurement, keep `EmptyView` default, don't move buttons yet). This de-risks the measurement mechanism under the existing button row *before* the architectural cutover in Phase 2. §7 Phase 1 already reads this way; §8 now applies as "CMUX-31's mechanism is Phase 1 of this ticket, not a separate ticket."

Target: ship today.

---

Strategic architectural move (not the tactical fix — that was CMUX-22/31, now subsumed). The buttons themselves do not belong in bonsplit. They are c11mux chrome — Terminal/Browser/Markdown name c11mux surface kinds, and even Split/+ are host-policy concerns about *what* a new tab is. Bonsplit should reserve trailing space for "whatever the host hands it" and otherwise have no opinion. This plan is filed so that the next time a second consumer of bonsplit shows up — or the same drift bug surfaces a fourth time — the design is already on the shelf.

## 1. Strategic framing

The Trident evolutionary review of CMUX-22 (`/tmp/c11mux-cmux22/notes/trident-review-CMUX-22-pack-20260419-1452/synthesis-evolutionary.md`, sections 1.3, 2.7, and 4 "Loop B") converged across all three reviewers on the same move with three vocabularies — Claude's "TrailingAccessory slot" (`evolutionary-claude.md`, suggestion #4 and "Most Exciting Opportunity"), Codex's "chrome budget" (`evolutionary-codex.md`, "What's Really Being Built" and Concrete Suggestion #6), Gemini's "Pluggable Tool-Shelf" (`evolutionary-gemini.md`, "How This Could Evolve"). The four wins, in the order the synthesis ranks them:

1. **Bug-class elimination by structure.** With the buttons hosted by c11mux and a measured trailing inset published by bonsplit, there is no second hand-maintained constant that can drift from the row's intrinsic width — and there is no in-bonsplit button row whose existence is the *reason* a constant is needed. Even if CMUX-31 internally measures the row, the bug is "two chrome owners on one strip." CMUX-30 collapses the chrome owners to one. (synthesis §2.7, claude §"Most Exciting" #1, codex §"Leverage Points")
2. **Bonsplit as a genuinely reusable primitive.** Today bonsplit's 1.x API encodes c11mux concepts: `BonsplitConfiguration.SplitButtonTooltips` carries `newTerminal`/`newBrowser`/`newMarkdown` strings (`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift:105-130`), and `requestNewTab(kind: String, ...)` ships an opaque kind to the delegate. None of this is generic. Removing it shrinks the public surface toward something a second Stage 11 project can consume. (synthesis §1, claude §"Flywheel", codex §"Closing Thought")
3. **Concept ownership returns to the host.** "What is a terminal" / "what is a browser" / "what is a markdown surface" is c11mux's language. Hosting those buttons in c11mux puts string semantics, action closures, and (eventually) localization decisions next to the code that defines those concepts. (claude §"Mutations" #1)
4. **Flywheel toward agent-injected chrome.** Once the slot is a pure `@ViewBuilder` and the actions are owned by c11mux, agents can register contextual buttons (Approve Diff, Run Tests, Toggle Preview-on-Save) over the c11mux socket. This is the "Loop B → Loop C" ending of the synthesis (gemini §"Wild Ideas" #3, claude §"Mutations" — flywheel addendum). Out of scope for this ticket; explicitly enabled by it.

This ticket is **deferred from the tactical fix** because:
- CMUX-31 is the right move *now*: it kills the recurring drift class internally, ships in one PR, and requires no host changes.
- CMUX-30 is the right move when **either** condition fires: (a) a second consumer of bonsplit appears (Lattice surface chrome, Aurum, an external OSS user, c11mux's own sidebar tab strip), **or** (b) the drift class recurs after CMUX-31 lands (very unlikely if CMUX-31 ships dynamic measurement; possible if CMUX-31 falls back to "executable static metrics"), **or** (c) the agent-injected-button capability becomes a roadmap priority.
- CMUX-31's internal mechanism (PreferenceKey-driven measurement of an internal `splitButtons` view) is *exactly* the substrate CMUX-30 exposes publicly. Doing CMUX-31 first means CMUX-30 is "rename the internal measurement to a public `@ViewBuilder` parameter, move the buttons out, delete the constant" — not net-new measurement plumbing.

## 2. Current state — what lives in bonsplit today that is c11mux chrome

### The six toolbar button identities

`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:783-841` (`splitButtons` private `@ViewBuilder`):

- L787-L793: Terminal button (`systemImage: "terminal"`, calls `controller.requestNewTab(kind: "terminal", inPane: pane.id)`)
- L795-L801: Browser button (`systemImage: "globe"`, kind `"browser"`)
- L803-L809: Markdown button (`systemImage: "doc.text"`, kind `"markdown"`)
- L811: `splitButtonsGroupSeparator` (the visual grouping rule — see §10c for whether this stays in bonsplit)
- L813-L820: Split-Right button (`systemImage: "square.split.2x1"`, calls `controller.splitPane(pane.id, orientation: .horizontal)`)
- L822-L829: Split-Down button (`systemImage: "square.split.1x2"`, `.vertical`)
- L831-L837: New-Tab button (`systemImage: "plus"`, kind `"newTab"`)

All six call into bonsplit's `BonsplitController` — three via `requestNewTab(kind:inPane:)` (which forwards to the delegate's `splitTabBar(_:didRequestNewTab:inPane:)`), two via `splitPane(_:orientation:)` (a public bonsplit API), one via `requestNewTab(kind: "newTab")` (also a delegate forward).

### Where the actions actually run

In c11mux, all six routes terminate in `Sources/Workspace.swift:10451-10481`. The `didRequestNewTab` delegate handler dispatches by string:
- `"terminal"` → `newTerminalSurface(inPane:)`
- `"browser"` → `newBrowserSurface(inPane:)`
- `"markdown"` → `newMarkdownSurface(inPane:)`
- `"newTab"` → `createNewTabOfFocusedKind(inPane:)` (host-side selection logic that picks the kind from the focused panel)

The split actions go through `BonsplitController.splitPane(_:orientation:)` (`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:355-405`), which runs entirely inside bonsplit (mutates the split tree, fires `didSplitPane` for c11mux to react). When the buttons move host-side, c11mux still calls `bonsplitController.splitPane(...)` from its accessory view — that public API does not change.

**Net:** all six button *actions* are already either (a) c11mux-defined (the three new-X handlers + new-tab logic) or (b) public bonsplit API calls (the two splits). Nothing host-side requires reaching into bonsplit internals after the move. The migration is mostly cut-and-paste of `splitButtons` into a c11mux file plus deletion of the in-bonsplit row.

### The overlay mechanism that hosts the row

`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:478-506`:
- L478: `.overlay(alignment: .trailing) { ... }` on the tab strip's outer container.
- L480: `let shouldShow = !isMinimalMode || isHoveringTabBar` — minimal mode hides the row except on hover (a c11mux UX behavior for the chromeless presentation mode; see §10b).
- L486-L496: `ZStack(alignment: .trailing)` with the opaque backdrop (`splitButtonsBackdropWidth`-wide gradient + rectangle) sitting under `splitButtons`.
- L498-L499: `splitButtons.saturation(tabBarSaturation)` — saturation comes from `isFocused`. Worth preserving as host-controllable; see §3.
- L501-L504: Padding, opacity, hit-test gating, animation.

### The constant whose existence depends on the buttons

`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:168-204`:
- L169: `static let splitButtonsBackdropWidth: CGFloat = 114` (the constant CMUX-22 bumped to 184; CMUX-31 will replace with measurement).
- L194-L204: `trailingTabContentInset(showSplitButtons:isMinimalMode:)` — the routing seam that drives the scroll content's trailing padding (see L405 in the same file).

This entire constant exists only to size a host-specific button row. After CMUX-30, neither the constant nor the function survives — the trailing inset is just "the measured width of whatever `trailingAccessory` rendered, with sensible zero default."

### Two code paths

- **Standard mode** (L194-L203, L478-L506): backdrop visible, buttons visible, scroll content reserves `splitButtonsBackdropWidth`.
- **Minimal mode** (L196 returns 0; L480 `shouldShow = isHoveringTabBar`): scroll content reserves zero; buttons fade in on hover, drawn over the trailing tabs. This is a c11mux UX choice (see §10b) — once the buttons leave bonsplit, this hover-fade either becomes the host's responsibility or vanishes.

### Public API surface that encodes c11mux chrome

`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift:105-130` — `SplitButtonTooltips` with six fields named after c11mux concepts. Once the buttons move out, this struct can be deprecated. (Keep it for one minor release for compat; remove on next major.)

`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.Appearance` fields `showSplitButtons` (L179) and `splitButtonsOnHover` (L182): the first becomes "is the trailing accessory rendered" — but the host already controls that by passing or not passing an accessory; deprecate. The second moves to host-side UX since it's about how the *host's* buttons present.

## 3. Proposed API — `trailingAccessory` slot

### Public addition to `BonsplitView`

`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitView.swift`: add an additional generic + initializer parameter, defaulting to `EmptyView` so the change is SemVer-minor (additive).

```swift
public struct BonsplitView<Content: View, EmptyContent: View, TrailingAccessory: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Tab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent
    private let trailingAccessoryBuilder: (PaneID, _ isFocused: Bool) -> TrailingAccessory

    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent,
        @ViewBuilder trailingAccessory: @escaping (PaneID, _ isFocused: Bool) -> TrailingAccessory
    ) { ... }
}
```

Provide the existing two-builder initializer as a convenience that forwards `EmptyView` for the accessory (preserves source compat for callers that don't opt in):

```swift
extension BonsplitView where TrailingAccessory == EmptyView {
    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.init(
            controller: controller,
            content: content,
            emptyPane: emptyPane,
            trailingAccessory: { _, _ in EmptyView() }
        )
    }
}
```

And similarly the existing `EmptyContent == DefaultEmptyPaneView` convenience extension gets an accessory-defaulting peer.

### Why `(PaneID, isFocused) -> View`

- Per-pane accessories: the accessory closure is invoked for each pane's tab bar. The current bonsplit behavior renders the row in every pane's `TabBarView`. C11mux's six buttons are pane-scoped (terminal/browser/markdown/split create-into-this-pane). Pass `PaneID` so the host can wire pane-correct actions without going through the `BonsplitController.focusedPaneId` indirection.
- `isFocused` is already used at L498-L499 to drive saturation. Surfacing it lets the host match bonsplit's existing focused/unfocused chrome dimming. Without this, the accessory would have to reach into `BonsplitController` and re-derive focus state.

### Internal plumbing — same mechanism CMUX-31 introduces, exposed publicly

The host-provided accessory is rendered in the same overlay region (L478-L506). Bonsplit measures its intrinsic width with the same `PreferenceKey` mechanism CMUX-31 lands inside `splitButtons`, except now it measures whatever the host drew:

```swift
private struct TrailingAccessoryWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// inside TabBarView body (replaces L478-L506 splitButtons block):
.overlay(alignment: .trailing) {
    let shouldShow = !isMinimalMode || isHoveringTabBar  // see §10b for whether this stays
    let backdropColor = ...  // existing backdrop color logic
    ZStack(alignment: .trailing) {
        // Backdrop sized to whatever the accessory measured.
        HStack(spacing: 0) {
            LinearGradient(colors: [backdropColor.opacity(0), backdropColor],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
            Rectangle().fill(backdropColor)
        }
        .frame(width: trailingAccessoryWidth)

        trailingAccessoryBuilder(pane.id, isFocused)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TrailingAccessoryWidthKey.self,
                                           value: geo.size.width)
                }
            )
    }
    ...
}
.onPreferenceChange(TrailingAccessoryWidthKey.self) { trailingAccessoryWidth = max($0, 0) }
```

And the trailing inset that `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:405` reads becomes:

```swift
.padding(.trailing, isMinimalMode ? 0 : trailingAccessoryWidth)
```

### EmptyView semantics

When the host passes `EmptyView()` (or omits the parameter, hitting the `TrailingAccessory == EmptyView` extension), the measured intrinsic width is 0. The backdrop renders with `.frame(width: 0)` (effectively invisible), and the trailing inset is 0. **Bonsplit has no opinion about chrome.** A consumer building a generic split tab bar gets a clean trailing edge; a consumer with toolbar buttons gets exactly the space they hand in.

### What goes away

- `TabBarStyling.splitButtonsBackdropWidth` (the constant CMUX-22 fought).
- `TabBarStyling.trailingTabContentInset(showSplitButtons:isMinimalMode:)` (collapses to inline `isMinimalMode ? 0 : trailingAccessoryWidth`).
- The private `splitButtons` `@ViewBuilder` and the six `SplitToolbarButton` calls.
- `splitButtonsGroupSeparator` (or stays as a public `SplitToolbarSeparator` styling helper — see §10c).
- `SplitToolbarButton` (the styled 22pt button — keep as a public helper if useful for consumers; see §10c).
- `BonsplitConfiguration.SplitButtonTooltips` (deprecated this release, removed next major).
- `BonsplitConfiguration.Appearance.showSplitButtons` and `splitButtonsOnHover` (deprecated; presence of accessory + host UX replaces them).

### What survives

- `requestNewTab(kind:inPane:)` and the `didRequestNewTab` delegate hook (keep — useful for non-button trigger paths like keyboard shortcuts; bonsplit doesn't need to know whether a button or shortcut fired).
- `splitPane(_:orientation:)` (keep — it's a model operation, not chrome).
- The whole `BonsplitController` API (unchanged).

## 4. Migration path — c11mux side

Create a new file `Sources/Panels/TabBarTrailingAccessory.swift` (or `Sources/TabBarTrailingAccessory.swift` — `Panels/` is closer to the surface-kind concepts the buttons reference; either works). Approximate shape:

```swift
import SwiftUI
import Bonsplit

struct TabBarTrailingAccessory: View {
    let paneId: PaneID
    let isFocused: Bool
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(systemImage: "terminal",
                              tooltip: String(localized: "tabbar.newTerminal", defaultValue: "New Terminal")) {
                _ = workspace.newTerminalSurface(inPane: paneId)
            }
            ToolbarIconButton(systemImage: "globe",
                              tooltip: String(localized: "tabbar.newBrowser", defaultValue: "New Browser")) {
                _ = workspace.newBrowserSurface(inPane: paneId)
            }
            ToolbarIconButton(systemImage: "doc.text",
                              tooltip: String(localized: "tabbar.newMarkdown", defaultValue: "New Markdown")) {
                _ = workspace.newMarkdownSurface(inPane: paneId)
            }
            ToolbarSeparator()
            ToolbarIconButton(systemImage: "square.split.2x1",
                              tooltip: String(localized: "tabbar.splitRight", defaultValue: "Split Right")) {
                _ = workspace.bonsplitController.splitPane(paneId, orientation: .horizontal)
            }
            ToolbarIconButton(systemImage: "square.split.1x2",
                              tooltip: String(localized: "tabbar.splitDown", defaultValue: "Split Down")) {
                _ = workspace.bonsplitController.splitPane(paneId, orientation: .vertical)
            }
            ToolbarIconButton(systemImage: "plus",
                              tooltip: String(localized: "tabbar.newTab", defaultValue: "New Tab")) {
                workspace.createNewTabOfFocusedKind(inPane: paneId)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .saturation(isFocused ? 1.0 : 0.0)
    }
}
```

Notes on the migration:

- `ToolbarIconButton` and `ToolbarSeparator` are c11mux-side replacements for the deleted `SplitToolbarButton` / `splitButtonsGroupSeparator`. Either: (a) build them in c11mux from scratch (small, ~30 lines total), or (b) keep `SplitToolbarButton` / `SplitToolbarSeparator` as **public** helpers in bonsplit so any consumer building a trailing accessory has a styled button primitive that matches the rest of bonsplit's chrome (preferred — see §10c).
- `createNewTabOfFocusedKind(inPane:)` currently lives on `Workspace` as a private method (`Sources/Workspace.swift:10470-10481`). Promote it to `internal` or `fileprivate(set) internal(get)` so the accessory file can call it.
- Localization: per `c11mux/CLAUDE.md` "All user-facing strings must be localized," tooltips become `String(localized:)` calls keyed in `Resources/Localizable.xcstrings`. The keys can preserve the existing `tabbar.newTerminal` style.
- The old `BonsplitConfiguration.SplitButtonTooltips` callsite goes away; c11mux owns its tooltip strings directly.

Wire-up at `Sources/WorkspaceContentView.swift:61`:

```swift
let bonsplitView = BonsplitView(
    controller: workspace.bonsplitController,
    content: { tab, paneId in /* unchanged */ },
    emptyPane: { paneId in /* unchanged */ },
    trailingAccessory: { paneId, isFocused in
        TabBarTrailingAccessory(
            paneId: paneId,
            isFocused: isFocused,
            workspace: workspace
        )
    }
)
```

## 5. Bonsplit public API impact

- **SemVer:** minor (additive). The new `BonsplitView` initializer with `trailingAccessory:` is additive; the existing two-parameter initializer survives via the `TrailingAccessory == EmptyView` extension. Existing callers (the bonsplit `Example/` app and any external user, of which there are none in-tree) compile unchanged.
- **Deprecations (still SemVer-minor):**
  - `BonsplitConfiguration.SplitButtonTooltips` → `@available(*, deprecated, message: "Use trailingAccessory: on BonsplitView instead")`
  - `BonsplitConfiguration.Appearance.showSplitButtons` → deprecated
  - `BonsplitConfiguration.Appearance.splitButtonsOnHover` → deprecated
  - `requestNewTab(kind:inPane:)` and `didRequestNewTab` delegate method: **not** deprecated. Useful for non-button trigger paths (keyboard shortcuts, menu bar, agent socket).
- **Removed types** (next major release, e.g., 2.0.0): the deprecated tooltip struct and appearance flags.
- **Internal removals** (this release, no API impact): `TabBarStyling.splitButtonsBackdropWidth`, `splitButtons` private view, `splitButtonsGroupSeparator`, the private `SplitToolbarButton` (or promote to public per §10c).
- **CHANGELOG.md** entry under `## [Unreleased] / Added` and `### Changed`:
  ```markdown
  ## [Unreleased]

  ### Added
  - `BonsplitView` initializer parameter `trailingAccessory: (PaneID, Bool) -> View` — host-provided trailing-edge accessory rendered in the tab bar with auto-measured width feeding the scroll content's trailing inset and the accessory backdrop. Eliminates the hand-maintained `splitButtonsBackdropWidth` constant by construction.
  - `SplitToolbarButton` and `SplitToolbarSeparator` promoted to public for use inside trailing accessories. (Optional — see §10c.)

  ### Deprecated
  - `BonsplitConfiguration.SplitButtonTooltips` — host owns tooltip strings via the trailing accessory.
  - `BonsplitConfiguration.Appearance.showSplitButtons`, `splitButtonsOnHover` — accessory presence + host UX replace these flags.

  ### Removed (internal)
  - `TabBarStyling.splitButtonsBackdropWidth` — replaced by per-render measurement.
  - The private `splitButtons` HStack and its six hard-coded buttons — moved to the host as a `trailingAccessory`.
  ```

- **Submodule-bump ordering** (per `c11mux/CLAUDE.md` "Submodule safety"): bonsplit lands first (PR + merge to `origin/main`), then a parent-repo PR bumps the `vendor/bonsplit` pointer **atomically with** the c11mux migration. The two cannot be split because deleting `splitButtons` on the bonsplit side without the host providing an accessory leaves the tab bar with no chrome at all. See §6 for whether to ship a transitional release that supports both.

## 6. Compatibility period

**Recommendation: clean cutover.** The only known consumer is c11mux (the `vendor/bonsplit/Example/` app is bonsplit's own demo, easily updated in the same PR). The Trident synthesis explicitly framed this as "strategic, not tactical" — meaning when it ships, it ships completely. Dual paths add complexity for zero real benefit since there's no third-party caller to protect.

**Cutover order (atomic):**
1. Bonsplit PR: add the `trailingAccessory` API + measurement plumbing **and** delete the in-bonsplit `splitButtons` row + `splitButtonsBackdropWidth` constant in the same PR. Update the `Example/` app to pass an `EmptyView` accessory (or a demo accessory). Update CHANGELOG. Tag a new minor version (e.g., 1.2.0).
2. C11mux PR: bump `vendor/bonsplit` pointer + add `Sources/Panels/TabBarTrailingAccessory.swift` + wire into `WorkspaceContentView.swift` + remove the now-orphan `splitTabBar.didRequestNewTab` switch arm for the moved kinds (the delegate handler stays for keyboard-shortcut-triggered new-tab paths).

**Alternative (rejected):** Keep `splitButtons` as the default when `trailingAccessory` is unset for one release, then remove. Rejected because it preserves the bug class for one extra release, requires double maintenance, and there's no consumer to protect.

**One concession:** keep `requestNewTab(kind:)` and `didRequestNewTab` delegate as-is. They're useful even without buttons (keyboard shortcuts that ask the host to make a tab of a given kind). No deprecation.

## 7. Phases

### Phase 1 — Bonsplit: add the slot, ship internally

**Inside bonsplit, no host coupling:**
1. Add `TrailingAccessoryWidthKey` PreferenceKey in `TabBarView.swift`. (If CMUX-31 already added `SplitButtonsWidthKey`, rename/generalize it here.)
2. Add new `BonsplitView` initializer with `trailingAccessory: @ViewBuilder` parameter (and the `TrailingAccessory == EmptyView` extension for source-compat).
3. Thread the builder through `SplitViewContainer` → `SplitNodeView` → `PaneContainerView` → `TabBarView`. Each layer gets a `trailingAccessory: (PaneID, Bool) -> some View` closure parameter. Default to `{ _, _ in EmptyView() }` at every layer for in-tree call sites that don't pass one yet.
4. Inside `TabBarView`, replace the `splitButtons`-rendering overlay (L478-L506) with the host-accessory rendering described in §3, measuring its width via PreferenceKey, feeding that into both the backdrop frame and `trailingTabContentInset`.
5. Update `vendor/bonsplit/Example/BonsplitExample/ContentView.swift` to pass either `EmptyView` or a demo accessory (e.g., a single "+" button) using the new initializer.
6. Add a unit test in `vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift` (using the existing `NSHostingView` harness pattern at L676-L719):
   - **`testEmptyTrailingAccessoryReservesZeroInset`** — render a `TabBarView` with an `EmptyView` accessory, lay out, assert the trailing inset is 0 and the rightmost tab extends to the trailing edge minus standard padding.
   - **`testPopulatedTrailingAccessoryReservesMeasuredWidth`** — render a `TabBarView` with a fixed-width accessory (e.g., a 100pt `Rectangle()`), assert the trailing inset converges to that width within ±1pt after layout.
7. Bonsplit CHANGELOG entry per §5.
8. CI passes (via existing CI; per `c11mux/CLAUDE.md` "Never run tests locally," do not run tests locally).
9. Ship as bonsplit 1.2.0 (tag in the bonsplit submodule's `origin/main`).

### Phase 2 — c11mux: extract buttons + wire slot

**Single PR in c11mux:**
1. Bump `vendor/bonsplit` submodule pointer to the 1.2.0 commit (per `c11mux/CLAUDE.md` "Submodule safety": bonsplit must already be on `origin/main`).
2. Create `Sources/Panels/TabBarTrailingAccessory.swift` with the six buttons (sketch in §4).
3. Promote `Workspace.createNewTabOfFocusedKind(inPane:)` from `private` to `internal`.
4. Update `Sources/WorkspaceContentView.swift` to pass `trailingAccessory:` into `BonsplitView`.
5. Add localized string keys for the six tooltips in `Resources/Localizable.xcstrings` (English + Japanese per `CLAUDE.md` localization rule).
6. Trim `Workspace.splitTabBar(_:didRequestNewTab:inPane:)` switch — the four kinds (terminal/browser/markdown/newTab) are now invoked directly by the accessory; the delegate handler can either be deleted or kept as a thin compatibility hook for keyboard-shortcut paths. Recommend keeping for keyboard-shortcut paths.
7. Trident review (per `c11mux/CLAUDE.md` "Test quality policy" + the standing trident-review pattern) of the c11mux PR. The bonsplit PR can land with the standard bonsplit review.
8. Tagged dev build (`./scripts/reload.sh --tag cmux-30-trailing-accessory`) for visual smoke test.

### Phase 3 — Bonsplit cleanup

**In a follow-up bonsplit PR (or batched into Phase 1 if Phase 2 ships in the same release window):**
1. Remove `BonsplitConfiguration.SplitButtonTooltips` (deprecated in Phase 1; remove on next major).
2. Remove `BonsplitConfiguration.Appearance.showSplitButtons` and `splitButtonsOnHover` (same).
3. If the test from Phase 1 step 6 referenced any soft-deprecated symbol, update.

## 8. How this interacts with CMUX-31

CMUX-31 (plan at `/Users/atin/Projects/Stage11/code/c11mux/.lattice/plans/task_01KPKK4ES0S1MV118YM5GM9JKA.md`) is the tactical durable fix: replace `splitButtonsBackdropWidth` with PreferenceKey-driven measurement of the in-bonsplit `splitButtons` row (with executable-static-metrics fallback if SwiftUI ripple regresses typing latency).

**The relationship:**
- CMUX-31's PreferenceKey (`SplitButtonsWidthKey`) is the same mechanism CMUX-30 generalizes into `TrailingAccessoryWidthKey`. The internal substrate becomes the public seam.
- **Order: CMUX-31 first.** This is the right ordering because:
  - CMUX-31 is a small, low-risk, single-file change inside bonsplit. It eliminates the *bug* now.
  - CMUX-30 is a larger architectural change touching the public API and a host PR. Doing it under time pressure (during a recurring CMUX-22-class regression) would conflate firefighting and architecture.
  - When CMUX-30 lands, CMUX-31's `SplitButtonsWidthKey` rename to `TrailingAccessoryWidthKey` is one mechanical step. The measurement plumbing is reused; nothing is wasted.
- **If CMUX-30 lands before CMUX-31** (not recommended): CMUX-30 makes CMUX-31 obsolete — there is no in-bonsplit `splitButtons` row to measure once it's been moved out. CMUX-31 would just be cancelled.
- **If neither has landed and a new regression forces a fourth iteration of CMUX-22:** ship CMUX-31's executable-metrics fallback (no PreferenceKey), in 5 minutes. That keeps the tactical option available until the strategic move is ready.

## 9. Agent-injected buttons (optional future, not in this scope)

Once the slot exists and the accessory is a c11mux-owned `View` with c11mux-side action closures, agents (Claude Code, Codex, etc.) could register contextual buttons via the c11mux socket — "Approve Diff" while a diff view is selected, "Run Tests" in a project context, "Toggle Preview-on-Save" in a markdown context. This is the "agentic flywheel" closing of the synthesis (`synthesis-evolutionary.md` §4 closing paragraph; `evolutionary-gemini.md` "Agent-Driven Actions"; `evolutionary-claude.md` Mutations addendum).

The plumbing it would need:
- A new socket command (e.g., `tab.registerAccessoryButton`) accepting `{paneId, agentId, label, systemImage, action}` payloads.
- An observable `[AccessoryButton]` registry on `Workspace` keyed by `paneId`.
- The accessory view ForEaches over the registry's pane-scoped entries before rendering the static six.
- Lifecycle: buttons unregister when the agent disconnects or the surface kind changes.

Explicitly **out of scope for CMUX-30**. CMUX-30 unlocks this; it does not implement it. Worth its own ticket when an agent skill needs it.

## 10. Risks & unknowns

### (a) Are there other bonsplit consumers?

Confirmed by Glob: `vendor/bonsplit/Example/BonsplitExample/ContentView.swift` is the only other in-tree consumer, and it's bonsplit's own demo. No external consumers exist (bonsplit is a private submodule). Risk: **none.** Mitigation: update Example app in same PR.

### (b) Minimal-mode hover-overlay UX

The minimal-mode logic at `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:480` (`shouldShow = !isMinimalMode || isHoveringTabBar`) is currently a c11mux UX choice baked into bonsplit. After extraction, options:

- **Option B-1 (recommended):** Move the hover-show behavior host-side. The accessory view reads `isHoveringTabBar` from a new `@Environment(\.bonsplitTabBarHover)` value that bonsplit publishes. The accessory animates its own opacity / `allowsHitTesting` based on the env value when the host wants minimal-mode behavior. **Pro:** chrome behavior fully owned by host. **Con:** requires a new bonsplit env value (small additive).
- **Option B-2:** Bonsplit keeps a generic `accessoryVisibilityPolicy: .always | .onHover` parameter. **Pro:** simpler for hosts. **Con:** bonsplit takes opinion on chrome again, partially undoing the win.
- **Option B-3:** Drop hover-fade in minimal mode entirely. Accessory always renders; minimal mode just means a thinner bar. **Pro:** simplest. **Con:** UX regression for users who like the chromeless feel.

Recommend B-1. Worth one round of operator feedback from Atin before locking in.

### (c) `SplitToolbarButton` / `splitButtonsGroupSeparator` — generic helpers or delete?

Both are bonsplit-internal styled views. They're useful as reference styling for any host building a trailing accessory that wants to match bonsplit's tab-bar look (22pt button, hover-highlight, group separator with the same stroke color as tab separators). Three options:

- **Promote to public:** `public struct SplitToolbarButton: View` in `Sources/Bonsplit/Public/SplitToolbarButton.swift`, and a `public struct SplitToolbarSeparator`. Bonsplit's own Example app uses them in its demo accessory; c11mux's `TabBarTrailingAccessory` uses them. **Pro:** consistent tab-bar chrome across consumers. **Con:** bonsplit takes more API surface.
- **Delete entirely:** host builds its own. **Pro:** bonsplit shrinks more. **Con:** every consumer reinvents the styled button.
- **Keep internal, expose styling helpers:** bonsplit publishes `BonsplitTabBarStyle.toolbarButtonStyle` / `.separatorColor(...)` so hosts can build their own buttons but match the look. **Pro:** bonsplit owns the look without owning the buttons. **Con:** more API to design.

Recommend **promote to public** (option 1). The button is a small, useful, opinionated primitive; making it public costs little and keeps c11mux's chrome visually consistent with bonsplit's styling.

### (d) Saturation / focused-state propagation

The current overlay reads `tabBarSaturation` (derived from `isFocused` + `dragSourcePaneId`). Passing `isFocused: Bool` into the accessory closure (per §3) covers the simple case. The drag-source nuance (bonsplit dims unfocused panes' chrome when one of them is the drag source) does not need to be exposed — it's internal to bonsplit's drag UX, and the host accessory can just match `isFocused` for visual chrome without worrying about drag state.

### (e) What CMUX-22 fixed must not regress during the transition

Phase 1 ships dynamic measurement (the same protection CMUX-31 provides) before any host extraction. So between bonsplit 1.2.0 (Phase 1) and the c11mux pointer bump (Phase 2), there is **no window** where the bug class can recur — the only valid host integration after Phase 1 is one that supplies an accessory (or `EmptyView`), and either way the inset is correctly sized. The `Example/` app inside bonsplit must also pass `EmptyView` or a real accessory in Phase 1 so the demo doesn't ship broken.

### (f) Drag-and-drop interactions

The trailing tab drop-zone overlay at `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift:430-452` (the `TabBarDragZoneView` for empty post-tab area) is independent of the split-button overlay. It uses `containerGeo.size.width - contentWidth`, where `contentWidth` already includes the trailing inset via L405. After CMUX-30, `contentWidth` includes `trailingAccessoryWidth`, so the drag zone math stays correct. Verify in Phase 1 testing.

## 11. Ship plan

**Branches & PRs:**
- `bonsplit/cmux-30-trailing-accessory` against `bonsplit/main`. Single PR. Includes API addition, internal extraction, Example app update, tests, CHANGELOG.
- `c11mux/cmux-30-trailing-accessory` against `c11mux/main`. Single PR. Includes submodule pointer bump + new accessory file + WorkspaceContentView wiring + localizations + delegate handler trim.

**Order:**
1. Bonsplit PR opens, gets review (trident if scope warrants — likely standard review since this PR has its own behavioral test), lands on `bonsplit/main`. Tag `1.2.0` on the bonsplit submodule.
2. c11mux PR opens with the `vendor/bonsplit` pointer at the 1.2.0 commit. Per `c11mux/CLAUDE.md` "Submodule safety," verify with `cd vendor/bonsplit && git merge-base --is-ancestor HEAD origin/main` before committing the parent pointer.
3. Tagged dev build (`./scripts/reload.sh --tag cmux-30`) for visual smoke test of the six buttons in the new home + minimal-mode hover behavior.
4. Trident review of the c11mux PR (per the project pattern). Concerns to flag for reviewers: (a) is the accessory file's import surface clean? (b) are tooltip localizations present in both English and Japanese? (c) does the saturation match the prior look?
5. Merge c11mux PR.

**Verification matrix (manual smoke test in the tagged dev build):**
- Standard mode, single pane: six buttons visible, all functional, no overlap with rightmost tab close-X.
- Standard mode, 4-pane split, 5 tabs each (the CMUX-22 stress condition): no occlusion, hit-tests route correctly.
- Minimal mode, hover off → on → off: accessory fades correctly per §10b decision.
- Drag a tab into the empty trailing post-tab area: drop zone still works (per §10f).
- Focused vs unfocused pane: saturation behaves correctly.

**Documentation:** Update `vendor/bonsplit/README.md` with a `trailingAccessory` example. The README currently shows the configuration-flag approach (L353); add a section "Customizing the trailing toolbar accessory."

## 12. Firewall / do-nots

- **Plan only.** This document is read-only output. No bonsplit edits, no c11mux edits, no Lattice writes (except the planned status transition at the end).
- **Submodule safety** (per `c11mux/CLAUDE.md`): when the time comes to implement, bonsplit changes ship first to `bonsplit/origin/main`; the c11mux submodule pointer bump comes second. Never commit the parent pointer to a detached HEAD or a branch not yet merged to bonsplit's `origin/main`.
- **Do not regress CMUX-22.** Phase 1 must land dynamic measurement (or be sequenced after CMUX-31's measurement work) so there is never a moment when the trailing inset is sized by a hand-maintained constant unaware of the row's intrinsic width.
- **Do not generalize prematurely.** Resist the urge to also (a) implement the agent-injected button registry, (b) build the responsive-collapse policy, (c) ship the chrome-budget ledger. Each of those is its own ticket. CMUX-30 is *just* the slot extraction; the synthesis explicitly stages those as later moves.
- **Do not break source compatibility.** The new `BonsplitView` initializer must be additive; existing two-builder callers must compile unchanged via the `TrailingAccessory == EmptyView` extension.
- **Localization.** Per `c11mux/CLAUDE.md`: every tooltip string the accessory displays must go through `String(localized:)` with entries in `Resources/Localizable.xcstrings` for English and Japanese. No bare string literals.

---

### Critical Files for Implementation

- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Public/BonsplitView.swift`
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Internal/SplitViewContainer.swift`
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitNodeView.swift`
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift` (recursive threading)
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/Sources/Bonsplit/Internal/Views/SinglePaneWrapper.swift` (NSHostingController coordinator)
- `/Users/atin/Projects/Stage11/code/c11mux/vendor/bonsplit/CHANGELOG.md`
- `/Users/atin/Projects/Stage11/code/c11mux/Sources/WorkspaceContentView.swift`
- `/Users/atin/Projects/Stage11/code/c11mux/Sources/Workspace.swift` (for `createNewTabOfFocusedKind` visibility promotion; keep the delegate arm)

---

## 13. Plan-review-notes (appended 2026-04-19 after clear-codex review)

The clear-codex plan review surfaced four blockers and several important items. The plan is amended as follows; the earlier sections above remain as the reference record but are superseded by this section where they conflict.

### 13.1 Staged path is the ship path (resolves Blocker #2, #4)

Phase 1 **keeps `splitButtons` rendering** inside bonsplit. The in-bonsplit `splitButtons` row becomes the **internal default accessory** that `BonsplitView` supplies when the host passes `EmptyView` (or omits `trailingAccessory:` entirely and hits the `TrailingAccessory == EmptyView` source-compat extension). Unchanged callers see **zero behavior change** after Phase 1.

Phase 2 flips c11mux to supply its own accessory, at which point the internal default `splitButtons` row still renders for any other callers (the bonsplit Example app, if it continues to hit the source-compat init). Phase 3 (bonsplit cleanup) finally deletes the in-bonsplit `splitButtons` row and `splitButtonsBackdropWidth` constant, and is when `BonsplitConfiguration.SplitButtonTooltips` / `showSplitButtons` / `splitButtonsOnHover` are removed. The `Example/` app is updated in Phase 3 (or earlier) to pass an explicit accessory so it does not lose chrome.

This means §3's "EmptyView semantics" (lines 180-181) is **wrong** as written; `EmptyView()` from the host does **not** mean "zero backdrop" during Phases 1 and 2 — it means "fall through to internal default." Correct at Phase 3.

The PR release is still SemVer-minor because behavior is preserved for unchanged callers during Phases 1 and 2; the behavior-affecting cleanup is Phase 3, which can either carry a minor tag (since the only consumer is c11mux, which has already migrated) or be bundled with the 2.0 cut. Decision: release Phase 1 as 1.2.0 (additive API); Phase 3 as 2.0.0 (behavior-breaking cleanup, no extant consumer).

### 13.2 Delegate arm retention (resolves Blocker #1, Missed #1)

The `"terminal"` delegate arm in `Workspace.splitTabBar(_:didRequestNewTab:inPane:)` **must remain** past Phase 2. Empty trailing-space overlay (`TabBarView.swift:430-452`, L439) and `dropZoneAfterTabs` (L743-L754, L751) both call `controller.requestNewTab(kind: "terminal", inPane:)` outside `splitButtons`. These are not in scope for extraction in CMUX-30; they remain bonsplit-owned UX. Phase 2 trims only the `"browser"` / `"markdown"` / `"newTab"` arms and can leave the `"terminal"` arm documented as "empty-space double-click + trailing drop-zone routing from bonsplit."

Future work (separate ticket if needed): make even those two sites accessory-provided. **Out of scope for CMUX-30.**

### 13.3 Generic threading or AnyView (resolves Blocker #3, Missed #3)

The plan's "`trailingAccessory: (PaneID, Bool) -> some View`" phrasing does not compile for stored closures. Implementation MUST thread `TrailingAccessory: View` as a third generic parameter through every container type and stored property:

- `BonsplitView<Content, EmptyContent, TrailingAccessory>`
- `SplitViewContainer<Content, EmptyContent, TrailingAccessory>`
- `SplitNodeView<…>`
- `PaneContainerView<…>`
- `SplitContainerView<…>` (recursive)
- `SinglePaneWrapper<…>` and its `NSHostingController` coordinator

**Fallback:** if threading through the `NSHostingController` coordinator is non-trivial because of Objective-C runtime type constraints, erase only at the coordinator boundary via `AnyView`. Document the tradeoff inline.

### 13.4 Backdrop width math (resolves Important #1)

Expose two distinct widths:

- `accessoryWidth` — measured intrinsic width of `trailingAccessoryBuilder(pane.id, chromeSaturation)`. Used for the trailing content inset (so tabs don't flow under the accessory hit region).
- `backdropWidth = accessoryWidth + fadeWidth` where `fadeWidth = 24`. Used for the backdrop `.frame(width:)` so the gradient-to-opaque transition sits to the left of the accessory, not under it.

### 13.5 Chrome saturation exposure (resolves Important #3, Nit #2)

Pass `chromeSaturation: Double` (not `isFocused: Bool`) into the builder. Bonsplit computes `chromeSaturation = tabBarSaturation` (which already includes `isFocused || dragSourcePaneId == pane.id`) and hands a scalar to the host. The host applies `.saturation(chromeSaturation)` uniformly. Preserves the existing drag-source nuance.

Final builder signature:
```swift
@ViewBuilder trailingAccessory: @escaping (PaneID, Double) -> TrailingAccessory
```

### 13.6 Minimal-mode hover (Option B-1, Important #2)

Operator default: B-1. Phase 1 publishes a `@Environment(\.bonsplitTabBarHover)` value (a `Bool` — true when `isHoveringTabBar`). Phase 1's internal default accessory (`splitButtons`) keeps its current hover-fade behavior (reading the env internally). Phase 2's c11mux accessory reads the env to replicate the fade on the host side.

### 13.7 Test policy (resolves Important #5)

The two Phase 1 unit tests must be **behavioral**, not introspective:

1. Render a `TabBarView` with `EmptyView` accessory (host) + internal `splitButtons` still rendering — assert the tab strip's trailing content inset equals the measured `splitButtons` width (± 2pt), and that the rightmost tab's close affordance is hit-reachable.
2. Render a `TabBarView` with a fixed 100pt accessory and `EmptyView` for internal splitButtons (test-only API) — assert trailing inset ≈ 100pt (± 2pt), assert a click on the accessory's hit region reaches it, and a click on the rightmost tab's close-X reaches the tab.

If any test requires a seam, add a test-only `internal` initializer on `TabBarView` with a comment noting the purpose.

### 13.8 `SplitToolbarButton` / `SplitToolbarSeparator` promotion (Important #6)

Defer to Phase 2. Phase 1 keeps them internal. In Phase 2, either (a) promote them to public types with public initializers + stable `appearance` parameters + `safeHelp` preserved, OR (b) keep them internal and have c11mux build its own `ToolbarIconButton` + `ToolbarSeparator`. Orchestrator will re-evaluate during Phase 2 dispatch based on bonsplit internals; default to (b) for lower coupling unless (a) is cheap.

### 13.9 `@ObservedObject` → `let workspace` (Important #4)

In Phase 2, the c11mux `TabBarTrailingAccessory` holds a plain `let workspace: Workspace` (or explicit action closures), not an `@ObservedObject`. The accessory only needs stable action targets; it does not subscribe to published state.

### 13.10 Deprecated-flag semantics during transition (Missed #2)

During Phases 1–2, the deprecated fields behave as follows:

- `BonsplitConfiguration.Appearance.showSplitButtons`: read only by the internal default accessory (when host passes `EmptyView`, the internal `splitButtons` honors this flag just like today). When host supplies a real accessory, this flag is ignored (but still settable; no warning other than the `@available(*, deprecated)` attribute).
- `splitButtonsOnHover`: same — applies only to the internal default accessory; ignored when host supplies its own.
- `SplitButtonTooltips`: still consumed by the internal default `splitButtons` row. Host-supplied accessories are responsible for their own tooltip strings.

Phase 3 removes all three. Because by then c11mux is no longer the consumer of them and the `splitButtons` internal default is deleted.

## Reset 2026-04-20 by human:atin

## Reset 2026-05-05 by human:atin
