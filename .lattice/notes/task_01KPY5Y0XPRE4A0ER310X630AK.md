# C11-13 Implementation Plan: Tab Bar Chrome — Collapse, Expand, and Hide

**Ticket:** C11-13 `task_01KPY5Y0XPRE4A0ER310X630AK`  
**Status:** planning  
**Author:** agent:claude-opus-4-7-plan  

---

## 0. Scope Boundary

This plan addresses the **Bonsplit per-pane surface tab bar** — the horizontal row at the top of each pane showing surface tabs (Terminal, Browser, Markdown) and split controls.

The fake custom titlebar (`customTitlebar` in `ContentView.swift`) is **not in scope**. It contains no tabs, and hiding it is already the job of the existing `Presentation Mode > Minimal` feature. The two settings stack: a user can enable Minimal Mode (hides fake titlebar) **and** set tab bar chrome to Hidden (hides Bonsplit tab bar) for maximum vertical space recovery.

Sidebar visibility (`sidebarState.isVisible`) is **not in scope**. The companion collapse-all affordance is a follow-on ticket (see Section 6).

---

## 1. State Model

### Enum definition

```swift
// In Sources/c11App.swift — near WorkspacePresentationModeSettings (line ~19)
enum TabBarChromeState: String {
    case full     // current default — tab bar fully visible
    case shrunk   // tab bar hidden, floating handle in top-right
    case hidden   // tab bar gone entirely — menu/shortcut only
}

enum TabBarChromeSettings {
    static let stateKey = "tabBarChromeState"
    static let defaultState: TabBarChromeState = .full

    static func state(for rawValue: String?) -> TabBarChromeState {
        TabBarChromeState(rawValue: rawValue ?? "") ?? defaultState
    }
}
```

### Storage: Global `@AppStorage`

**Decision: global `@AppStorage("tabBarChromeState")`, string-backed.**

Rationale:
- Per-window storage doesn't exist natively in SwiftUI `@AppStorage`; passing per-window state through the view tree to every `Workspace` adds significant plumbing.
- Global is consistent with how `workspacePresentationMode` and `titlebarControlsStyle` are stored today. Most operators want the same chrome behavior across all windows.
- Matches user expectation: "I want compact mode everywhere."

If per-window behavior is later desired, it can be layered on top via a separate `@SceneStorage` key. Not in scope for C11-13.

### Initialization guard for new workspaces

New workspaces created after the state is set must inherit the current state. `Workspace.init` cannot use `@AppStorage` (it is not a View), so read directly from `UserDefaults.standard`:

```swift
// In Workspace.init (Sources/Workspace.swift, line ~5356)
let chromeState = TabBarChromeSettings.state(for: UserDefaults.standard.string(forKey: TabBarChromeSettings.stateKey))
// pass to bonsplit configuration at init time (see Section 2)
```

---

## 2. View Tree Changes

### 2a. Bonsplit: add `showsTabBar` to configuration

**File:** `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift`

Add to `Appearance` struct (after `tabBarLeadingInset`, ~line 207):

```swift
/// When false, the tab bar is not rendered and its height collapses to zero.
/// Use to recover vertical space; combine with an external handle for navigation.
public var showsTabBar: Bool
```

Update the `init` signature (default `true`) and the existing preset values. Since `tabBarHeight` is defined in `Appearance` but **is not read by any internal view** (they all use the hardcoded `TabBarMetrics.barHeight`), the new `showsTabBar: Bool` is the correct and complete toggle.

**File:** `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`

`PaneContainerView` already holds `@Environment(BonsplitController.self) private var bonsplitController`. Its `body` is a `VStack` with `TabBarView` on top. Change the `body`:

```swift
var body: some View {
    VStack(spacing: 0) {
        if bonsplitController.configuration.appearance.showsTabBar {
            TabBarView(
                pane: pane,
                isFocused: isFocused,
                showSplitButtons: showSplitButtons,
                trailingAccessory: trailingAccessoryBuilder
            )
        }
        contentAreaWithDropZones
    }
    ...
}
```

Because `BonsplitController` is `@Observable`, the conditional will re-evaluate when `configuration.appearance.showsTabBar` changes. No additional bindings or passes are needed.

**Upstream note:** This is a minimal, additive change to vendor/bonsplit. It should be offered upstream to `manaflow-ai/cmux` after landing here (per the upstream contribution guidance in CLAUDE.md).

### 2b. Workspace: propagation method

**File:** `Sources/Workspace.swift`

Add a new method near `applyGhosttyChrome` (~line 5267):

```swift
func setTabBarVisible(_ visible: Bool) {
    guard bonsplitController.configuration.appearance.showsTabBar != visible else { return }
    var next = bonsplitController.configuration
    next.appearance.showsTabBar = visible
    bonsplitController.configuration = next
}
```

Update `Workspace.init` (the section that builds `BonsplitConfiguration`, ~line 5397) to initialize `appearance.showsTabBar` from `UserDefaults`:

```swift
let initialChromeState = TabBarChromeSettings.state(
    for: UserDefaults.standard.string(forKey: TabBarChromeSettings.stateKey)
)
// In the BonsplitConfiguration.Appearance init:
showsTabBar: initialChromeState == .full
```

### 2c. ContentView: handle overlay and propagation

**File:** `Sources/ContentView.swift`

**Where:** In the main `WorkspaceView` struct (around line 2402 body, or in `terminalContent`).

Add `@AppStorage(TabBarChromeSettings.stateKey)` in the containing view and a computed `tabBarChromeState: TabBarChromeState` property (pattern mirrors the existing `isMinimalMode` derivation).

**Propagate to all mounted workspaces when state changes:**

```swift
.onChange(of: tabBarChromeStateRaw) { _, newRaw in
    let state = TabBarChromeSettings.state(for: newRaw)
    let visible = state == .full
    for tab in tabManager.tabs {
        tab.setTabBarVisible(visible)
    }
}
```

**Handle overlay (shrunk state):**

Add to the outermost view in `body` (or `contentAndSidebarLayout`'s return value):

```swift
.overlay(alignment: .topTrailing) {
    if tabBarChromeState == .shrunk {
        TabBarChromeHandle(onExpand: {
            tabBarChromeStateRaw = TabBarChromeState.full.rawValue
        })
        .padding(.top, isMinimalMode ? 4 : titlebarPadding + 4)
        .padding(.trailing, 8)
    }
}
```

**`TabBarChromeHandle` view** (add as private struct in `ContentView.swift` near the bottom):

```swift
private struct TabBarChromeHandle: View {
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "accessibility.tab_bar.expand_handle",
                                  defaultValue: "Expand tab bar"))
    }
}
```

SF Symbol: `sidebar.left` — this communicates "the sidebar/chrome lives to the left of this handle." Alternative: `chevron.left` is fine but less semantic. Recommend `sidebar.left`.

**Hover reveal zone (hidden state) — Phase 2:**

When `tabBarChromeState == .hidden`, a persistent hover zone allows mouse-over reveal. This is Phase 2 complexity — it requires coordinating a `@State private var isHoverRevealed: Bool` flag, a `withAnimation` show/hide, and a delayed hide-on-mouse-out (using `DispatchWorkItem`). The basic "hidden" state without hover reveal (menu/shortcut only) ships in Phase 1. Phase 2 adds:

```swift
// 8pt-high clear view at the very top of content, below window chrome
.overlay(alignment: .top) {
    if tabBarChromeState == .hidden {
        Color.clear
            .frame(height: 8)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoverRevealed = hovering
                }
                if !hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !isHoveringRevealZone { isHoverRevealed = false }
                    }
                }
            }
    }
}
```

When `isHoverRevealed == true`, set all workspaces' `showsTabBar = true` without changing `tabBarChromeStateRaw`. On mouse-out + delay, restore to false.

---

## 3. Menu + Keyboard Shortcut Wiring

### Menu location

**File:** `Sources/c11App.swift`

In `CommandGroup(after: .toolbar)` (~line 848), immediately after the "Toggle Sidebar" item and its `Divider()`:

```swift
Menu(String(localized: "menu.view.tabBar", defaultValue: "Tab Bar")) {
    Button(String(localized: "menu.view.tabBar.full", defaultValue: "Full")) {
        tabBarChromeStateRaw = TabBarChromeState.full.rawValue
    }
    Button(String(localized: "menu.view.tabBar.shrunk", defaultValue: "Shrunk")) {
        tabBarChromeStateRaw = TabBarChromeState.shrunk.rawValue
    }
    Button(String(localized: "menu.view.tabBar.hidden", defaultValue: "Hidden")) {
        tabBarChromeStateRaw = TabBarChromeState.hidden.rawValue
    }
}
```

Alternatively (simpler cycling pattern):

```swift
splitCommandButton(
    title: String(localized: "menu.view.tabBar.cycle", defaultValue: "Cycle Tab Bar"),
    shortcut: tabBarChromeMenuShortcut
) {
    cycleTabBarChromeState()
}
```

**Recommendation: use the submenu pattern** — it makes each state individually actionable and shows the user there are three states. The cycling shortcut is more keyboard-friendly for quick toggling.

Ship both: submenu in View menu + single cycling shortcut.

### Keyboard shortcut

**New action in `KeyboardShortcutSettings.Action`:**

```swift
case toggleTabBarChrome  // in KeyboardShortcutSettings.swift
```

Default: `StoredShortcut(key: "b", command: true, shift: true, option: false, control: false)` → `⌘⇧B`

**Collision check:**
- `⌘B` = toggleSidebar ✓ free
- `⌘⇧B` — not assigned to any action in the current `KeyboardShortcutSettings.Action` table
- Static menu bindings (non-customizable): none use `⌘⇧B`

`⌘⇧B` is mnemonic: `B` for Bar, `⌘` for command, `⇧` for "modify." Mirrors `⌘⇧T` (reopen browser pane) and `⌘⇧L` (open browser) patterns.

The shortcut cycles through `full → shrunk → hidden → full`.

**Files:**
- `Sources/KeyboardShortcutSettings.swift` — add `toggleTabBarChrome` case to `Action` enum with label, defaultsKey (`"shortcut.toggleTabBarChrome"`), and `defaultShortcut`
- `Sources/c11App.swift` — add `@AppStorage(KeyboardShortcutSettings.Action.toggleTabBarChrome.defaultsKey) private var toggleTabBarChromeShortcutData = Data()` in the main app struct, and a `splitCommandButton` in the commands block

---

## 4. Persistence Decision

**Global `@AppStorage("tabBarChromeState")` — applies to all windows.**

Key: `"tabBarChromeState"`, type: `String` (raw value of `TabBarChromeState`), default: `"full"`.

Rationale (restatement):
- Per-window AppStorage doesn't exist in SwiftUI; per-window via SceneStorage requires scene identity plumbing.
- Consistent with `workspacePresentationMode` (also global AppStorage, also affects all windows the same way).
- Most operators want a uniform experience: "I'm on a laptop, hide the chrome everywhere."
- If a per-window preference is needed later (e.g., "main monitor full, laptop shrunk"), it's a separate feature.

---

## 5. Hover Reveal Zone — Phase 2 Decision

**Phase 1:** `hidden` state restores via menu + `⌘⇧B` shortcut only. No persistent reveal UI.

**Phase 2 (flag for follow-on):** 8pt hover zone at the top edge of the content area. On hover, tab bars across all mounted workspaces temporarily reveal with a 150ms ease-in animation. On mouse-out + 500ms delay, they re-hide. The `tabBarChromeStateRaw` value does not change during hover reveal — this is purely a transient display state (`@State private var isHoverRevealed: Bool`).

**Why Phase 2:** The hover reveal requires careful interaction design — it should not conflict with tab drag gestures that start near the top edge, and the reveal-then-hide animation must not produce jitter on fast mouse movements. Deferring to Phase 2 lets Phase 1 ship quickly and gathers operator feedback on whether hover reveal is actually needed or if the keyboard shortcut is sufficient.

---

## 6. Interaction with Sidebar Collapse

**Decision: C11-13 does NOT couple to sidebar visibility.**

The tab bar chrome state (`tabBarChromeState`) and sidebar visibility (`sidebarState.isVisible`) are independent preferences. A user can have:
- Sidebar visible + tab bar shrunk (saves pane chrome space while keeping workspace nav)
- Sidebar hidden + tab bar full (rare but valid)
- Both hidden (maximum space recovery on laptops)

A companion affordance that collapses both sidebar AND tab bar with one action ("focus mode") is a follow-on ticket. C11-13 scopes to the tab bar chrome only.

---

## 7. Localization Strings (English Only)

All new user-facing strings to add to `Resources/Localizable.xcstrings`:

```
"tab.bar.state.full"                     defaultValue: "Full"
"tab.bar.state.shrunk"                   defaultValue: "Shrunk"
"tab.bar.state.hidden"                   defaultValue: "Hidden"
"menu.view.tabBar"                       defaultValue: "Tab Bar"
"menu.view.tabBar.full"                  defaultValue: "Full"
"menu.view.tabBar.shrunk"               defaultValue: "Shrunk"
"menu.view.tabBar.hidden"               defaultValue: "Hidden"
"menu.view.tabBar.cycle"                 defaultValue: "Cycle Tab Bar"
"shortcut.toggleTabBarChrome.label"      defaultValue: "Cycle Tab Bar Chrome"
"accessibility.tab_bar.expand_handle"    defaultValue: "Expand tab bar"
```

English only — translator agent handles ja, uk, ko, zh-Hans, zh-Hant, ru after English is final.

---

## 8. Files to Touch

| File | Change |
|------|--------|
| `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift` | Add `showsTabBar: Bool = true` to `Appearance` |
| `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift` | Wrap `TabBarView` in `if bonsplitController.configuration.appearance.showsTabBar` |
| `Sources/c11App.swift` | Add `TabBarChromeSettings` enum; add `@AppStorage` for shortcut; add menu item in `.commands`; add `cycleTabBarChromeState()` helper |
| `Sources/KeyboardShortcutSettings.swift` | Add `.toggleTabBarChrome` case with label, key, defaultShortcut |
| `Sources/Workspace.swift` | Add `setTabBarVisible(_:)` method; wire `showsTabBar` in `Workspace.init` |
| `Sources/ContentView.swift` | Add `@AppStorage(TabBarChromeSettings.stateKey)`; add `.onChange` propagation; add `TabBarChromeHandle` view; add handle `.overlay`; (Phase 2) add hover zone |
| `Resources/Localizable.xcstrings` | Add 10 new English strings |

**Does NOT touch:**
- `Sources/TerminalWindowPortal.swift` (latency-critical `hitTest` path — untouched)
- `TabItemView` body (performance-sensitive `.equatable()` path — untouched)
- `Sources/GhosttyTerminalView.swift` (`forceRefresh` hot path — untouched)
- `Sources/WorkspaceContentView.swift` (no change needed; Bonsplit config propagates via `@Observable`)

---

## 9. Open Questions / Escalate

**No human escalation required.** The plan makes concrete decisions on all four open questions from the ticket:

| Question | Decision |
|----------|----------|
| Shrunk handle placement + styling | Top-right overlay, 32×32pt, `.ultraThinMaterial`, `sidebar.left` SF Symbol, `.secondary` foreground, 8pt corner radius shadow |
| From hidden: path back | Phase 1: menu item + `⌘⇧B` shortcut. Phase 2: hover reveal zone (flagged as follow-on) |
| Interaction with sidebar footer | Decoupled — independent preferences, no coupling in C11-13 |
| Persistence scope | Global `@AppStorage("tabBarChromeState")` |

The only implementation-time risk to flag:

1. **Bonsplit `showsTabBar = false` with single-tab panes:** Confirm that hiding the tab bar when a pane has only one tab doesn't produce any layout artifacts (since the Bonsplit traffic light leading inset relies on `tabBarLeadingInset` being set). Likely fine since we're fully removing the view, not just zeroing height.

2. **`tabBarHeight` in config is currently unused:** The plan adds `showsTabBar` rather than wiring the existing `tabBarHeight = 0` approach, because `tabBarHeight` is not consumed by any internal Bonsplit view (`TabBarMetrics.barHeight` is hardcoded). This is the correct choice — do not wire `tabBarHeight` as a side-effect.

3. **Upstream Bonsplit contribution:** The `showsTabBar` addition to `vendor/bonsplit` should be upstreamed to `manaflow-ai/cmux` after this ships. Flag to operator at PR time.

---

## Implementation Order

1. Bonsplit: add `showsTabBar` to config + `PaneContainerView` conditional render
2. Workspace: `setTabBarVisible(_:)` + `init` wiring
3. `KeyboardShortcutSettings`: add `.toggleTabBarChrome`
4. `c11App.swift`: `TabBarChromeSettings` enum + menu + shortcut plumbing
5. `ContentView.swift`: `@AppStorage` read + `.onChange` propagation + handle overlay
6. `Localizable.xcstrings`: English strings
7. Translator agent pass for all six locales
8. (Phase 2, separate PR) Hover reveal zone
