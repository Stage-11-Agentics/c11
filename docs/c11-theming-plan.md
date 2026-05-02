# c11 — Custom Theming System Plan

**Date**: 2026-04-18
**Status**: Draft v2 — revised post-Trident plan review 2026-04-18T2026, see [`c11mux-theming-plan-review-pack-2026-04-18T2026/`](./c11mux-theming-plan-review-pack-2026-04-18T2026)
**Lattice ticket**: [CMUX-9](../.lattice/tasks/task_01KPHCQNQH2BKT128552QP46RE.json)
**Target branch**: feature branch off `main` (e.g. `theme-engine-foundation`), one PR per milestone
**Scope**: c11 chrome surfaces (sidebar, top bar, tab bar, dividers, outer workspace frame, pane title bars). Ghostty-owned surfaces (terminal cells, prompts, scrollback, cursor) are out of scope and never touched.

**Revision history**:

- **Namespace cleanup** (2026-04-22) — Supersedes the §9.3 / §12 #5 CLI namespace decision that kept `themes` for Ghostty terminal themes. Current c11 product language is: `c11 themes` for c11 chrome themes, `c11 terminal-theme` for Ghostty terminal themes, and `c11 workspace-color` for workspace color commands.
- **Draft v2** (2026-04-18) — Trident (nine-agent) plan review folded in: runtime-contract amendments (§3, §6.4, §6.5); M1 split into M1a/M1b and M2 into M2a/M2b/M2c (§10); `ThemeContext` struct + generic resolver (§3, §10); `WorkspaceFrameState` enum ships in M1 stub (§7.3, §10); cycle/invalid-value/unknown-key policies locked (§6.4-§6.5); schema keys reserved for M5+ (§6.5); `dividerThicknessPt` moved off `ChromeColors` onto new `DividerStyle` struct (§7.1); `ContentView.customTitlebar` explicitly in scope (§10 M1); legacy-override precedence matrix (§8); runtime-toggle vs launch-time-kill-switch split (§8.1, §9.4); bonsplit refresh trigger on `Workspace.customColor` mutation (§7.2); fuzz corpus + snapshot diff + perf regression tests added (§10 M1); new §14 Open questions post-Trident. §12 and the seven locked decisions are untouched.
- **Draft v1.1** (2026-04-18) — Seven open questions locked with operator (§12).
- **Draft v1** (2026-04-18) — Initial exploration.

---

## 1. Motivation

c11 today has **no unified theme engine**. Chrome colors are scattered across at least eight independent systems, each with its own persistence key, resolution logic, and rendering path:

| System | Lives at | Scope |
|---|---|---|
| `CmuxThemeNotifications.reloadConfig` | `Sources/AppDelegate.swift:36` | DistributedNotification trigger only — no store |
| `Workspace.bonsplitAppearance(...)` | `Sources/Workspace.swift:5084-5154` | Pushes Ghostty's background hex into `ChromeColors.backgroundHex`; **`borderHex` is never set** |
| `AppearanceMode` | `Sources/c11App.swift:3534-3583` | light/dark/system only |
| `SidebarTint` | `@AppStorage("sidebarTintHexLight"/"Dark")` + opacity | Sidebar window-glass tint |
| `BrowserThemeSettings` | `Sources/Panels/BrowserPanel.swift:166-196` | browser-surface only |
| `WorkspaceTabColorSettings` | `Sources/TabManager.swift:245-443` | workspace color palette + custom colors |
| `SidebarActiveTabIndicatorSettings` | `Sources/TabManager.swift:155-186` | `.solidFill` vs `.leftRail` sidebar render mode |
| `Resources/ghostty/themes/` + `c11 terminal-theme` CLI | Ghostty terminal themes | **not c11 chrome** — terminal cells only |

Three symptoms follow from the scatter:

1. **Dividers are invisible.** `BonsplitConfiguration.Appearance.ChromeColors` already has a `borderHex` field (`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift:138-140`) and bonsplit's `TabBarColors.nsColorSeparator(...)` already consumes it (`vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarColors.swift:20-25`). c11 never sets it — so every divider silently derives from Ghostty's background color. The color seam exists; the wiring doesn't.
2. **Workspace identity is sidebar-only.** `Workspace.customColor` (`Sources/Workspace.swift:4883`) — a fully developed 16-color palette plus user hex strings, persisted per workspace — renders in exactly one place: the sidebar tab for that workspace. The operator's peripheral vision gets no grounding for which workspace they're in once they're looking at the content area.
3. **Every future chrome decision is bespoke.** When an engineer adds a new chrome surface today, they have to decide from scratch: where does its color come from? Hardcode? `@AppStorage` key? System color? Ghostty-derived? There is no shared answer. A theme engine gives every future chrome decision a single well-known seam.

The goal is a **unified theme engine for c11 chrome** that:

- Leaves Ghostty strictly alone (terminal cells, prompts, scrollback, cursor remain Ghostty-owned).
- Makes the workspace color a first-class theme variable (`$workspaceColor`) that theme authors reference freely — so one theme definition works across every workspace and the color automatically gains prevalence wherever the author placed it.
- Adds a new first-class primitive: an **outer workspace frame** that wraps the right-hand content area (sidebar excluded), colored by the workspace color.
- Replaces the scattered `@AppStorage` keys with TOML theme files, with built-ins shipped in the app bundle and user themes dropped into `~/Library/Application Support/c11/themes/`.
- Ships as an overall UI convention — future chrome decisions reference the theme's variables instead of minting new `@AppStorage` keys.

---

## 2. Design principles

Locked from the exploration dialogue:

1. **Theme c11 chrome only. Never touch Ghostty.** Terminal cells, prompts, scrollback, cursor stay Ghostty-owned. Sidebar, top bar, tab bar, dividers, outer workspace frame, titlebars, sidebar status pills — c11-owned, theme-addressable.
2. **Workspace color gains subtle prevalence.** Peripheral-vision grounding, not loud. The operator should feel which workspace they're in without reading anything. Default values favour `$workspaceColor` mixed heavily with the chrome background (e.g. 65% toward neutral), not saturated.
3. **Theme engine becomes an overall UI convention.** Future chrome work references theme variables (`$workspaceColor`, `$background`, `$foreground`, `$surface`) rather than minting fresh `@AppStorage` keys. No new scattered theme systems.
4. **Outer workspace frame is a new first-class primitive.** A thin (1-2pt) border that wraps the **right-hand content area only** (sidebar excluded and stays neutral). Colored by the workspace color. It is the logical representation of the active workspace in the content area.
5. **Horizontal and vertical dividers are first-class theme knobs.** Color, thickness, potentially inset/opacity — all themable.
6. **Theme files, not settings-only.** `~/Library/Application Support/c11/themes/*.toml` plus built-ins shipped in `Resources/c11-themes/`. Users drop in theme files and select them.
7. **`$workspaceColor` is a first-class schema variable.** Themes reference it with opacity and mix modifiers — never hardcode workspace hexes. One theme works across every workspace.
8. **Additive, not migratory.** Existing `@AppStorage` keys (`sidebarTintHexLight/Dark`, `sidebarActiveTabIndicatorStyleRaw`, `BrowserThemeSettings`) stay as orthogonal controls in v1; the theme engine provides defaults those keys can override. Deprecations are deferred until the engine has bedded in.

---

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│ Discoverability (Settings picker, CLI, debug menu)           │  ← M4
├──────────────────────────────────────────────────────────────┤
│ User themes (~/Library/Application Support/c11/themes/)      │  ← M3
│ + file watcher + hot reload                                  │
├──────────────────────────────────────────────────────────────┤
│ Workspace frame primitive (outer content-area border)        │  ← M2
│ + divider color/thickness wired through bonsplit             │
│ + $workspaceColor variable resolved at render                │
├──────────────────────────────────────────────────────────────┤
│ C11muxTheme struct + loader + built-in default               │  ← M1
│ (plumbed through chrome without changing visuals)            │
├──────────────────────────────────────────────────────────────┤
│ Existing chrome surfaces (sidebar, title bar, bonsplit…)     │  ← already built
└──────────────────────────────────────────────────────────────┘
```

Each milestone lands as its own PR, in order. M1 is invisible plumbing; visible change starts with M2.

Runtime model:

```
┌─ ThemeManager (singleton, @MainActor) ──────────────────┐
│  • active: C11muxTheme (selected built-in or user file) │
│  • snapshot: ResolvedThemeSnapshot (immutable)          │
│  • resolve<T>(role: ThemeRole, context: ThemeContext)   │
│  • reload() on file-watcher fsevents (atomic swap)      │
│  • version: UInt64 + per-section publishers             │
└─────────────────────────────────────────────────────────┘
          ↓ reads from
┌─ C11muxTheme (Codable, loaded from TOML) ───────────────┐
│  identity: { name, author, version, schema }            │
│  palette: { ... }       ← raw hexes                     │
│  variables: { ... }     ← resolved references           │
│  chrome: {                                              │
│    windowFrame: { color, thicknessPt, inactiveOpacity } │
│    sidebar: { tint, activeTab, borderLeading }          │
│    dividers: { color, thicknessPt }   ← DividerStyle    │
│    titleBar: { background, foreground, border }         │
│    tabBar: { background, activeFill, divider, ... }     │
│    browserChrome, markdownChrome, statusPills …         │
│  }                                                      │
└─────────────────────────────────────────────────────────┘
          ↓ resolved per surface
┌─ Surface rendering (ContentView, WorkspaceContentView,  │
│   Bonsplit, SurfaceTitleBarView, BrowserPanelView …)    │
│  • reads ThemeManager.resolve(.divider_color, context)  │
│  • subscribes to per-section change publisher           │
└─────────────────────────────────────────────────────────┘
```

**`ThemeContext` struct** (introduced v2 per Trident review — unanimous recommendation): the resolver takes a context struct rather than a positional `workspaceColor: String?`. v1 fields: `workspaceColor: String?`, `colorScheme: ColorScheme`, `forceBright: Bool`, `ghosttyBackgroundGeneration: UInt64`. v1 also **reserves** `workspaceState: WorkspaceState?` (per §12 #10) — declared on the struct, populated as nil in v1; themes may reference `[when.workspaceState.*]` blocks which v1 warns-and-ignores and v1.x renders. Future fields (`agentRole`, `paneFocus`, `urgency`, `isInputActive`) extend without breaking callers. The cache key is the full `ThemeContext` hash, not a subset — this closes the correctness gap flagged by all three adversarial reviewers (`(role, workspaceColor)` alone is insufficient).

**`WorkspaceState` struct** (v1 reserved, v1.x populated per §12 #10): carries categorical workspace state separate from the color channel. v1.x shape:

```swift
public struct WorkspaceState: Sendable, Hashable {
    public var environment: String?      // e.g. "dev" | "staging" | "prod"
    public var risk: String?             // e.g. "low" | "medium" | "high"
    public var mode: String?             // e.g. "review" | "edit" | "readonly"
    public var tags: [String: String]    // free-form operator/agent tags
}
```

Populated from per-workspace metadata: `c11 set-workspace-metadata state.environment prod` maps to `WorkspaceState.environment = "prod"`. Reserved keys live under the `state.` prefix so they don't collide with existing workspace metadata. `$workspaceColor` stays a pure color token — state is expressed via `[when.workspaceState.*]` conditional blocks, not by overloading the color.

**Generic resolver** (`resolve<T>`): v1 uses `T = NSColor` exclusively. The generic signature is a forward-compatibility seam for future numeric/duration/typography values. Cost: one type parameter. Benefit: M5 conditional expressions and per-state overrides land without re-plumbing callers.

**ThemeRoleRegistry** (`Sources/Theme/ThemeRoleRegistry.swift`): a single compile-time source of truth enumerating every role, its default value, its owning surface file, and its fallback behavior. Prevents role sprawl; drives docs, tests, and the `c11 themes dump --json` output.

**Immutable snapshot model**: at each theme-change or file-reload event, `ThemeManager` computes a `ResolvedThemeSnapshot` (parse-time AST → evaluated values keyed by `(role, context-class)`). Views read the snapshot through per-section publishers (`sidebarPublisher`, `titleBarPublisher`, `dividerPublisher`, `framePublisher`) so unrelated theme changes don't invalidate `TabItemView`'s Equatable-gated body.

---

## 4. Current-state map (audit)

Every chrome surface in c11, where its color comes from today, and what M1–M3 turn it into. File:line references are verified against the tree at this repo's current HEAD (`ws-selected-keep-custom-color`, 2026-04-18).

### 4.1 Sidebar

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Sidebar window glass tint | `@AppStorage("sidebarTintHex"/"…Light"/"…Dark")` + `sidebarTintOpacity` (default `#000000` @ 0.18) | `Sources/ContentView.swift:13365-13398`, keys at `:13527-13528` | Stays — but defaults now come from theme (`sidebar.tintOverlay`); @AppStorage keys become overrides. |
| Sidebar active-tab background (`.solidFill`) | `resolvedCustomTabColor` (workspace hex, brightened for dark) OR `BrandColors.black` | `Sources/ContentView.swift:11476-11488`, resolver `:11505-11512` | Theme-driven: `sidebar.activeTab.fill = $workspaceColor` for custom, `sidebar.activeTab.fallback = …` otherwise. |
| Sidebar active-tab left rail (`.leftRail`) | `resolvedCustomTabColor.opacity(0.95)` (custom) or `BrandColors.goldSwiftUI` | `Sources/ContentView.swift:11494-11503` | Theme-driven: `sidebar.activeTab.railColor = $workspaceColor`, `sidebar.activeTab.railFallback = $accent`. Opacity moves into theme. |
| Sidebar inactive-tab tint | `resolvedCustomTabColor.opacity(0.7)` (or 0.35 multi-select) in `.solidFill` only | `Sources/ContentView.swift:11481-11483` | `sidebar.inactiveTab.customTint = $workspaceColor.opacity(…)` with theme-controlled opacity. |
| Sidebar unread-count badge fill | `cmuxAccentColor()` (Brand gold) | `Sources/ContentView.swift:10746-10748` | `sidebar.badge.background = $accent` (theme var). |
| Sidebar status / progress / log text | `.primary` / `.secondary` (system) | `Sources/ContentView.swift:12097-12338` | Stays system-default in v1; add `sidebar.status.foreground` as optional override in M3. |
| Sidebar ↔ content divider | Bonsplit `TabBarColors.nsColorSeparator(for: appearance)` — derived from `chromeColors.backgroundHex` because `borderHex` is unset | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift:113-128`; resolver `vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarColors.swift:20-25` | Theme-driven via `dividers.color` → writes to `ChromeColors.borderHex`. |

### 4.2 Top bar / window chrome

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Titlebar background (under traffic lights) | `GhosttyApp.shared.defaultBackgroundColor` (Ghostty-derived) at alpha-scaled opacity | `Sources/ContentView.swift:2200-2242` | **Stays Ghostty-derived** — intentional: the titlebar visually continues the terminal surface beneath it. Theme exposes `titleBar.background = $ghosttyBackground` as a variable ref so themes can override if needed but default preserves today's behavior. |
| Titlebar bottom separator | `Color(nsColor: .separatorColor)`, 1pt | `Sources/ContentView.swift:2238-2240` | `titleBar.borderBottom = $separator` (theme var, defaults to system separator). |
| Traffic-light buttons | macOS system-owned | — | **Out of scope.** System never themable. |

### 4.3 Tab bar (bonsplit)

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Tab strip background | `TabBarColors.background(for: appearance)` — reads `chromeColors.backgroundHex` | `vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarColors.swift` | Theme-driven via `tabBar.background`, which *currently* defaults to `$ghosttyBackground` for continuity. |
| Active tab fill | Lightened/darkened from backgroundHex for contrast | `TabBarColors.swift` | `tabBar.activeFill` with default formula preserved. |
| Tab divider | `TabBarColors.separator(...)` — uses `borderHex` if set, else derives from background | `vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarColors.swift:150-160` | Theme-driven via `dividers.color` (shared with pane dividers). |
| Active-tab bottom indicator | `TabBarMetrics.activeIndicatorHeight = 2` + accent color | `vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarMetrics.swift:18` | `tabBar.activeIndicator.color` — optional `$workspaceColor` in opinionated themes. |

### 4.4 Pane dividers (horizontal + vertical)

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Divider color | `splitView.customDividerColor = TabBarColors.nsColorSeparator(for: appearance)` — again derives from `backgroundHex` since `borderHex` unset | `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift:123` | Set via theme's `dividers.color` → written to `ChromeColors.borderHex` at workspace-level bonsplit config. |
| Divider thickness | `splitView.dividerStyle = .thin` (system constant ≈ 1pt) + `TabBarMetrics.dividerThickness = 1` | `SplitContainerView.swift:125`; `TabBarMetrics.swift:39` | **New bonsplit field `dividerThicknessPt: CGFloat?`** on `ChromeColors` (or sibling `DividerStyle` struct). When non-nil, override via `splitView.dividerThickness` (NSSplitView's dynamic property). Defaults preserved. |
| Divider inset / opacity | N/A today | — | Deferred to M5; `dividers.inset` / `.opacity` reserved in schema. |

### 4.5 Pane title bar (`SurfaceTitleBarView`)

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Title bar background | `Color(nsColor: NSColor.windowBackgroundColor).opacity(0.85)` | `Sources/SurfaceTitleBarView.swift:59-62` | `titleBar.background = $surface` (theme var). Keep ~85% opacity modifier. |
| Title bar bottom border | `Color(nsColor: .separatorColor)`, 1pt | `SurfaceTitleBarView.swift:63-67` | `titleBar.borderBottom = $separator`. |
| Title text | `.primary` | `SurfaceTitleBarView.swift:~89` | `titleBar.foreground` — defaults to `$foreground`; themes can override. |
| Description markdown body | Markdown theme (existing) | `SurfaceTitleBarView.swift` | **Out of scope for chrome theming** — markdown typography is content, not chrome. |

### 4.6 Sidebar status / progress / log areas

| Surface | Today's source | File:line | M1–M2 target |
|---|---|---|---|
| Sidebar metadata rows (role, model, task chips) | Hardcoded foreground + subtle background per chip kind | `Sources/ContentView.swift:12097-12338` | Stays in v1; no new theme variables. M3+ could add `sidebar.chip.*` roles. |

### 4.7 Browser surface chrome (not content)

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Browser chrome background (address bar area) | `resolvedBrowserChromeBackgroundColor(...)` — receives Ghostty terminal background | `Sources/Panels/BrowserPanelView.swift:205-243` | `browserChrome.background = $ghosttyBackground` (default). Theme can override. |
| Omnibar pill background | Darkened/blended from chrome bg | `BrowserPanelView.swift:228-243` | `browserChrome.omnibarFill = $surface.mix($background, 0.15)` (default formula preserved). |
| `BrowserThemeSettings` (light/dark/system for web content) | `@AppStorage("browserThemeMode")` | `Sources/Panels/BrowserPanel.swift:186-196` | **Stays orthogonal** — governs content rendering (prefers-color-scheme), not chrome. Not absorbed into theme engine. |

### 4.8 Markdown surface chrome (not content)

| Surface | Today's source | File:line | M2 target |
|---|---|---|---|
| Panel background | Hardcoded `NSColor(white: 0.12, alpha: 1.0)` dark / `0.98` light | `Sources/Panels/MarkdownPanelView.swift:270-274` | `markdownChrome.background = $background` (theme-driven default retains 0.12/0.98 fallback). |
| Content dividers | System `Divider()` | `MarkdownPanelView.swift:~61` | `$separator` (system default preserved). |
| Markdown typography theme | `titleBarMarkdownTheme(for: colorScheme)` | `MarkdownPanelView.swift:~114` | **Out of scope** — content typography, not chrome. |

### 4.9 Settings window

| Surface | Today's source | Decision |
|---|---|---|
| Settings window chrome | System background, system rows, system controls | **Out of scope for v1.** Settings window is an OS-native surface; skinning it fights the platform and adds maintenance. The Settings window *shows* theme controls (M4) but is not itself themed. |

### 4.10 Menu bar extra

| Surface | Today's source | Decision |
|---|---|---|
| Menu bar icon / popover | System menu bar owns the rendering | **Out of scope.** System-owned. |

---

## 5. Workspace color audit

### 5.1 Flow today

**Write path**: UI-only, four call sites:

- Context-menu "Workspace Color" submenu (`Sources/ContentView.swift:11348-11378`) → `applyTabColor(hex, targetIds)` → `TabManager.setTabColor` → `Workspace.setCustomColor` (`Sources/Workspace.swift:5757-5763`).
- Context-menu "Choose Custom Color…" → `promptCustomColor(targetIds)` (`ContentView.swift:12032-12059`) → validates/normalizes hex → `WorkspaceTabColorSettings.addCustomColor(...)` → `applyTabColor`.
- Settings pane "Workspace Colors" (`Sources/c11App.swift:4806-4890`) — palette overrides and custom-color management; does **not** itself set a workspace's color (per-workspace color is always via context menu).
- Session restore: `Workspace.setCustomColor(snapshot.customColor)` at `Sources/Workspace.swift:256`.

**Persistence**:

- `@Published var customColor: String?` on `Workspace` (`Sources/Workspace.swift:4883`) — in-memory only; no `@AppStorage`.
- Serialized as `SessionWorkspaceSnapshot.customColor` (`Sources/SessionPersistence.swift:385`) in the autosaved JSON snapshot (`~/.config/com.stage11.c11/session-com.stage11.c11.json`).
- Palette defaults + overrides + user customs live in `UserDefaults`: `workspaceTabColor.defaultOverrides` (dict) and `workspaceTabColor.customColors` (array), keys at `Sources/TabManager.swift:246-247`, getters/setters at `:399-417`.

**Read / render sites** (exhaustive — only sidebar today):

- `TabItemView` in `Sources/ContentView.swift`:
  - `resolvedCustomTabColor` computed property (`:11505-11512`) — the single read seam.
  - `backgroundColor` computed (`:11471-11488`) — `.solidFill` mode fills active tab; inactive tabs get `.opacity(0.7)` or `.opacity(0.35)`.
  - `explicitRailColor` computed (`:11494-11503`) — `.leftRail` mode fills a thin left edge at `.opacity(0.95)`.
  - `tabColorSwatchColor(for:)` (`:11514-11520`) — renders the swatches in context menu / settings.
- v2 API surface (`Sources/TerminalController.swift:3592`): exposes `custom_color` in `workspace` JSON for CLI inspection — **read-only**, no setter.
- Debug log (`TerminalController.swift:16156`): stringified as `color=<hex|"none">`.

No other SwiftUI view reads `customColor` today. The gain-prevalence work in M2 is the first multi-surface consumption.

### 5.2 Dark-mode brightening

`WorkspaceTabColorSettings.displayNSColor(hex:, colorScheme:, forceBright:)` (`Sources/TabManager.swift:382-397`) is the single entry point. In dark mode (or when `forceBright` is true — `.leftRail` forces it), values pass through `brightenedForDarkAppearance(...)` at `:419-442`:

```
HSB-space adjustment:
  brightness' = min(1, max(b, 0.62) + (1 - b) * 0.28)   // min 62% + 28% of headroom
  saturation' = (s ≤ 0.08) ? s : min(1, s + (1 - s) * 0.12)   // preserve neutral greys
  hue preserved
```

This is per-hex, render-time, stateless. Each palette color is a single hex; there's no separate light/dark pair. M2 preserves this helper verbatim.

### 5.3 Named palette (verified)

16 entries in `Sources/TabManager.swift:250-271` (`originalPRPalette`):

| Name | Hex | Name | Hex | Name | Hex | Name | Hex |
|---|---|---|---|---|---|---|---|
| Red | `#C0392B` | Olive | `#4A5C18` | Blue | `#1565C0` | Magenta | `#AD1457` |
| Crimson | `#922B21` | Green | `#196F3D` | Navy | `#1A5276` | Rose | `#880E4F` |
| Orange | `#A04000` | Teal | `#006B6B` | Indigo | `#283593` | Brown | `#7B3F00` |
| Amber | `#7D6608` | Aqua | `#0E6B8C` | Purple | `#6A1B9A` | Charcoal | `#3E4B5E` |

Plus up to 24 user customs and per-name overrides.

### 5.4 Persistence confirmation

`customColor` survives restart. Verified:

1. `Workspace.init(...)` accepts no `customColor`; the field is set on restore via `setCustomColor(snapshot.customColor)` at `Workspace.swift:256`.
2. `Workspace.snapshot()` (via `SessionWorkspaceSnapshot` build site) emits `customColor: customColor` into the JSON snapshot (`SessionPersistence.swift` builders).
3. `SessionPersistenceStore` writes `session-com.stage11.c11.json` every 8s (`defaultSnapshotFileURL`), which round-trips the field.

### 5.5 Proposal — gaining subtle prevalence (M2)

Today the workspace color hits exactly one view. M2 wires it into three more surfaces with conservative defaults so the color feels like ambient grounding, not decoration:

| Target surface | Default formula | Rationale |
|---|---|---|
| Pane dividers (horizontal + vertical) | `$workspaceColor.mix($background, 0.65)` — i.e. 35% toward workspace hue | Subtle but visible in peripheral vision. Holds together even with pale / extreme workspace colors because of the heavy mix. |
| Outer workspace frame | `$workspaceColor` at full opacity, 1.5pt border wrapping the content area | The frame is the explicit logical representation of the workspace; this is the one place the color is allowed to be assertive. |
| Sidebar active-tab tint overlay (`.solidFill`) | `$workspaceColor.opacity(0.08)` layered over sidebar tint | Already close to today's `.solidFill` at reduced opacity. Lets `.solidFill` become the default render mode without overwhelming the sidebar. |
| Top-tab-bar active-indicator (optional, theme-author choice) | `$workspaceColor` | Already a 2pt bar; opt-in accent. |

All four are **default formulas in the built-in Stage 11 theme**. Themes (including a "Minimal" theme that zeroes out dividers and the sidebar tint overlay, leaving just the frame) can change them per-surface. Defaults are deliberately on the quiet side; "High-contrast workspace" built-in theme exists for operators who want the loud version.

### 5.6 CLI / socket surface for workspace color

No first-class command today. `cmux` exposes workspace color **read-only** via the v2 API (`TerminalController.swift:3592`). M4 adds:

```
c11 workspace-color set --workspace <ref> <hex>
c11 workspace-color clear --workspace <ref>
c11 workspace-color get --workspace <ref>
c11 workspace-color list-palette
```

Backed by a new socket method `workspace.set_custom_color`. The CLI is additive — context menu stays the canonical user surface.

---

## 6. `C11muxTheme` schema design

### 6.1 File format decision — TOML

Evaluated concretely against the alternatives:

| Format | Pros | Cons | Verdict |
|---|---|---|---|
| **TOML** | Human-writable, comments supported, obvious types, no indentation hazards, `[table]` maps onto nested schema cleanly, `toml` Swift package widely available. Matches Ghostty's own config ergonomics (operators already recognise it). | Slightly more verbose than JSON for deeply nested structures. | **Adopted.** |
| JSON | Ubiquitous, stdlib support, one obvious parser. | No comments, trailing-comma hostile, theme authors have to remember JSON quoting rules, strings-with-hex-colors get noisy. | Rejected — theme files are authored by humans first, parsed second; comments matter. |
| YAML | Comments, less punctuation. | Indentation-sensitive (easy to break), implicit typing surprises (`#FF0000` would YAML-parse weirdly), no stdlib parser in Swift — requires a yams-style dependency. | Rejected — indentation + implicit-type foot-guns outweigh gains over TOML. |

The file extension is `.toml`. Both built-ins and user themes carry it.

**Realistic parser effort** (per Trident review, all three adversarial reviewers): the ~200-line framing in §12 #7 covers the happy-path grammar only. A production parser with error recovery, Unicode, BOM handling, line/column tracking for diagnostics, and the foot-gun cases in §6.4 (hex-string vs `#` comment, unquoted strings, duplicate keys, deep nesting, empty tables) realistically runs **400–600 lines** and should be budgeted at **2–3 engineer-days**, not treated as incidental. The §12 lock on a hand-written subset parser (zero deps) remains — this is a framing correction, not a reopen.

### 6.2 Directory layout

- **Built-ins**: bundled in `Resources/c11-themes/<name>.toml`. Read-only. Shipped with the app.
- **User themes**: `~/Library/Application Support/c11/themes/<name>.toml`. Writable; file watcher picks up changes. User names that collide with built-ins shadow them, with a single OSLog warning on load.
- **Active theme selection**: two `@AppStorage` keys per §12 #12 — `@AppStorage("theme.active.light")` and `@AppStorage("theme.active.dark")` each hold a theme `<name>`; empty/missing means the built-in default (`stage11`). The resolver picks the slot matching `ThemeContext.colorScheme`. Operators who want one theme across both modes set both keys identically (the Settings picker offers a one-click "apply to both" action per §9.1). Per §12 #14, both keys are stored in `UserDefaults(suiteName: Bundle.main.bundleIdentifier)` so production, DEV, tagged builds, and STAGING each maintain independent selections; the shared themes directory is the only cross-instance surface.
- **Per-workspace override**: Deferred past v1 per §12 #6. Schema is forward-compatible for M5+ — `Workspace` may gain `themeOverride: String?` with a `SessionWorkspaceSnapshot` version bump.

**Theme identity** (per Trident review):

- `[identity].name` is the **machine-stable identifier**. Lowercase, kebab-case, must match `^[a-z0-9][a-z0-9\-]{0,62}$`. Used in the `@AppStorage("theme.active.{light,dark}")` pair (§12 #12), CLI arguments, socket messages, tests.
- `[identity].display_name` is the operator-facing label. Any unicode string; not a stable identifier.
- **Case-insensitive filename matching** for user themes: `Stage11.toml` and `stage11.toml` in the same directory are a duplicate collision → load-time error, fall back to default theme, OSLog warning with both paths.
- **User-theme shadowing**: when a user theme's `[identity].name` matches a built-in, user wins. Scripts that need deterministic behavior should reference built-ins by their bundle path via a `--builtin` flag (M4).

### 6.3 Schema (TOML, annotated)

```toml
# Built-in default theme, shipped at Resources/c11-themes/stage11.toml.
# Theme files are TOML. Comments supported. Keys are hierarchical tables.

[identity]
name         = "Stage 11"                 # stable, kebab-case preferred
display_name = "Stage 11"                 # shown in pickers (optional)
author       = "Stage 11 Agentics"
version      = "0.01.001"                 # Stage 11 versioning (X.XX.XXX)
schema       = 1                          # bump only on breaking schema changes

# Raw color palette. Values here are always resolved hex strings — never
# expressions — because other sections can $-reference them.
[palette]
void          = "#0A0C0F"                 # primary background
surface       = "#121519"                 # elevated surfaces (title bars)
gold          = "#C4A561"                 # brand accent
fog           = "#2A2F36"                 # separators / chrome borders
text          = "#E9EAEB"                 # primary foreground
textDim       = "#8A8F96"                 # secondary foreground

# Variables referenceable by chrome sections as `$name`.
# Variables can reference palette entries, other variables, or magic tokens
# ($workspaceColor, $ghosttyBackground).
[variables]
background          = "$palette.void"
surface             = "$palette.surface"
foreground          = "$palette.text"
foregroundSecondary = "$palette.textDim"
accent              = "$palette.gold"
separator           = "$palette.fog"
# Magic: resolved at render time from Workspace.customColor, brightened in dark mode
# via WorkspaceTabColorSettings.brightenedForDarkAppearance.
workspaceColor      = "$workspaceColor"
# Magic: resolved from GhosttyApp.shared.defaultBackgroundColor
ghosttyBackground   = "$ghosttyBackground"

# ---- Chrome sections ----
# Each leaf is a "ThemedValue": either a plain hex string, a variable
# reference ($name), or a variable reference with a chain of modifiers.

[chrome.windowFrame]
color            = "$workspaceColor"
thicknessPt      = 1.5
inactiveOpacity  = 0.25                 # §12 #3 locks the default; themable knob
unfocusedOpacity = 0.6                  # window-unfocus dimming per macOS HIG (v2 addition)
# Optional per-edge overrides; if absent, `color`/`thicknessPt` applies to all
# four edges. When present the color wraps the content area only (sidebar
# excluded). See §7 for render path.

[chrome.sidebar]
tintOverlay         = "$workspaceColor.opacity(0.08)"      # layered over below
tintBase            = "$background.opacity(0.18)"
tintBaseOpacity     = 0.18
activeTabFill       = "$workspaceColor"                    # .solidFill mode
activeTabFillFallback = "$surface"                         # no workspaceColor
activeTabRail       = "$workspaceColor"                    # .leftRail mode
activeTabRailFallback = "$accent"
activeTabRailOpacity  = 0.95
inactiveTabCustomOpacity = 0.7
inactiveTabMultiSelectOpacity = 0.35
badgeFill           = "$accent"
borderLeading       = "$separator"                         # sidebar↔content

[chrome.dividers]
color        = "$workspaceColor.mix($background, 0.65)"    # 35% toward workspace
thicknessPt  = 1.0
# Reserved for M5 (v2 adds these to the schema with warn-and-ignore in v1):
# insetLeadingPt  = 0
# insetTrailingPt = 0
# opacity         = 1.0

[chrome.titleBar]
background       = "$surface"
backgroundOpacity = 0.85
foreground       = "$foreground"
foregroundSecondary = "$foregroundSecondary"
borderBottom     = "$separator"

[chrome.tabBar]
background       = "$ghosttyBackground"                    # preserve current behaviour
activeFill       = "$ghosttyBackground.lighten(0.04)"
divider          = "$separator"
activeIndicator  = "$workspaceColor"                       # 2pt bottom indicator

[chrome.browserChrome]
background      = "$ghosttyBackground"
omnibarFill     = "$surface.mix($background, 0.15)"

[chrome.markdownChrome]
background      = "$background"

# ---- Optional top-level meta ----
[behavior]
# Whether switching workspaces animates theme-variable crossfades. Default false.
animateWorkspaceCrossfade = false
```

### 6.4 Value grammar

Every leaf under `[chrome.*]` is a `ThemedValue`, parseable as one of:

1. **Hex literal**: `"#RRGGBB"` or `"#RRGGBBAA"`.
2. **Variable reference**: `"$name"`. Resolves via the `[variables]` table (and recursively into `[palette]` or magic tokens).
3. **Modifier chain**: `"$name.mod1(args).mod2(args)…"`. Modifiers:

| Modifier | Arg type | Effect |
|---|---|---|
| `.opacity(N)` | `0.0–1.0` | Multiplies alpha by `N`. |
| `.mix(value, N)` | target `ThemedValue`, `0.0–1.0` | Linear RGB interpolation; `N=0` → self, `N=1` → target. |
| `.darken(N)` | `0.0–1.0` | HSB brightness multiplied by `(1 - N)`. |
| `.lighten(N)` | `0.0–1.0` | HSB brightness moved toward 1.0 by `N` of headroom. |
| `.saturate(N)` | `0.0–1.0` | HSB saturation moved toward 1.0 by `N` of headroom. |
| `.desaturate(N)` | `0.0–1.0` | HSB saturation multiplied by `(1 - N)`. |

All resolution happens at render time against `NSColor` in `sRGB` color space. Rules:

- `$workspaceColor` resolves using `WorkspaceTabColorSettings.displayNSColor(hex:colorScheme:forceBright:)` so dark-mode brightening is reused exactly as today — no re-implementation.
- `$ghosttyBackground` resolves from `GhosttyApp.shared.defaultBackgroundColor` at each call (live-updates via the existing `ghosttyDefaultBackgroundDidChange` notification). The generation counter from this notification feeds `ThemeContext.ghosttyBackgroundGeneration` so the resolver cache invalidates correctly.
- Numeric leaves (thicknesses, opacities) are floats; all other leaves are `ThemedValue`.

### 6.4.a Runtime contract (added v2)

Locked in v2 per Trident review. All three reviewers independently flagged underspecified semantics here; this subsection is the canonical table. Deviations from any clause are bugs.

1. **Reserved magic variables**: `$workspaceColor`, `$ghosttyBackground` are reserved identifiers. Writing `workspaceColor = "#FF0000"` in `[variables]` is a **load-time error** (fall back to default theme, OSLog warning with theme name + key path). Themes may not override magic tokens with static hexes.
2. **Variable reference grammar**: dot-paths (`$palette.void`) vs modifier chains (`$name.opacity(0.5)`) are disambiguated at parse time: an identifier segment that begins with a lowercase letter and has no parenthesized args is a dot-path component; an identifier followed by `(...)` is a modifier. Mixed chains (`$palette.void.opacity(0.5)`) resolve left-to-right: first the palette lookup, then each modifier.
3. **Evaluation order**: modifier chains evaluate **strictly left-to-right**. `$x.opacity(0.5).mix($y, 0.3)` is `mix(opacity($x, 0.5), $y, 0.3)` — not commutative with `$x.mix($y, 0.3).opacity(0.5)`. One round-trip test fixture per built-in theme locks this.
4. **Cycle detection**: variable-reference cycles (`$a → $b → $a`) are detected at **parse time** during `[variables]` topological-sort; cycles produce a load-time error (fall back to default theme, OSLog warning listing the cycle path). No cycle detection at render time.
5. **Invalid-value policy**:
   - Out-of-range modifier arg (`opacity(1.5)`, `mix($y, -0.2)`): **clamp to valid range** `[0.0, 1.0]`, emit OSLog warning once per theme load per key.
   - Invalid hex (`#GGG`, `#FF`, `#AABBCCDD00`): **load-time error**, fall back to default theme's value for that key, OSLog warning.
   - Unknown modifier (`.unknown(0.5)`): **load-time error**, same treatment.
   - Negative thickness (`thicknessPt = -2`): **clamp to 0**, OSLog warning. `thicknessPt > 8` clamps to 8 (UX guard — thicker dividers become oppressive).
6. **Disable-signal semantics**: to disable a theme role (e.g., turn off the sidebar tint overlay), use explicit `enabled = false` or `null`, not `$background.opacity(0.0)`. The loader accepts either:
   ```toml
   [chrome.sidebar]
   tintOverlay = { enabled = false }           # preferred
   tintOverlay = null                           # also accepted
   ```
   Setting `opacity(0.0)` is still valid and produces a transparent render; the structured form is preferred for diagnostics (`c11 themes dump` marks disabled keys explicitly).
7. **Color space**: all resolution is in `sRGB` space. Native P3 inputs (NSColor from system pickers, Ghostty background) are converted to `sRGB` on ingress; cross-space `.mix()` is undefined and produces a load-time error. Reviewer-flagged gap: the `WorkspaceTabColorSettings.displayNSColor` helper is audited for color-space conformance in M1.
8. **Cache key**: the resolved-color memoization key is the full `ThemeContext` hash (§3), not a subset. Any `ThemeContext` field added in a future milestone automatically becomes part of the cache key with no code change at consumers.
9. **Schema `version` mismatch**: see §6.5.

### 6.5 Extensibility — how new surfaces get added without breaking old themes

The schema is **additive-only** within a `schema = 1` major version:

- Missing chrome sections / keys fall back to the built-in default theme's values. A theme authored today continues to load when c11 ships a new chrome surface next year — the new surface just uses the default theme's value until the theme author opts in.
- The loader emits a single OSLog warning per missing key per theme load (deduped), never a fatal error.
- `schema = 2` is reserved for breaking changes (e.g. removing a key, changing a modifier's semantics). When we bump, we ship a one-time converter.

A *separate* extensibility axis: when a surface needs a brand-new variable name (not a new chrome key), add it to the reference loader's `[variables]` synthesizer — not to user themes. Themes can reference anything in `[variables]`, but the canonical set is owned by c11.

**Unknown-key / unknown-modifier policy** (locked v2):

- **Unknown chrome keys** (theme declares `chrome.futureSurface.foo`): **warn-and-ignore** via OSLog. Forward-compatibility for themes authored on newer cmux versions.
- **Unknown modifier names** (`$x.unknown(0.5)`): **load-time error** (see §6.4.a #5). Unknown modifiers are typos, not forward-compatibility.
- **Schema version mismatch**: a theme with `schema = 2` loaded by a v1 cmux **fails closed** — falls back to the built-in default theme, OSLog warning. A theme with `schema = 1` loaded by a v2 cmux runs through the one-time converter (v2's responsibility).
- **Inheritance diagnostics**: if a user theme omits sections to inherit defaults, `c11 themes dump --json` surfaces this via a `"inherited_from": "stage11"` annotation per key that fell back. Aids debugging user themes without adding runtime cost.

**Reserved keys for M5+** (v2 reserves these now; parser warns-and-ignores in v1):

- `[when.*]` tables — for conditional expressions (`when.workspaceHasColor`, `when.focus`). **Not reserved**: `when.appearance` — per §12 #12, light/dark handling is an operator preference (two `@AppStorage` slots) rather than an in-theme conditional block.
- `[identity].inherits = "<parent-name>"` — **per §12 #16**, reserved for M5+ explicit theme inheritance. v1 warns-and-ignores on load; a theme that sets this key loads normally, the key has no runtime effect. M5+ may add loader-level inheritance graph walk with cycle detection and an operator-facing forking flow in a separate feature decision.
- `[when.workspaceState.environment]`, `[when.workspaceState.risk]`, `[when.workspaceState.mode]`, `[when.workspaceState.tag.<key>]` — **per §12 #10**, categorical workspace-state conditional blocks. v1 reserves and warns-and-ignores; v1.x point release implements. Example:
  ```toml
  [when.workspaceState.risk.high.chrome.windowFrame]
  color       = "#C4526A"          # override frame color when risk=high
  thicknessPt = 2.5
  ```
- `chrome.windowFrame.style` — reserved for `solid | dashed | gradient` variants.
- `chrome.dividers.insetLeadingPt`, `chrome.dividers.insetTrailingPt`, `chrome.dividers.opacity` (per §4.4 deferred M5).
- `behavior.animateWorkspaceCrossfade` (reserved for §9.4/M5 opt-in; v1 parses, ignores, and confirms via `c11 themes dump` that the key is present-but-inactive).

Rationale: reserving keys now means M5 (and the §12 #10 v1.x state-channel rollout) don't require schema bumps — the additive-only-within-schema=1 guarantee holds.

### 6.6 Built-in themes (M3 ships two)

Per §12 #15, v1 ships a small, intentional set of built-ins. Variety lives in user-authored themes in the shared themes dir.

1. **`stage11.toml` — Stage 11 (default).** Void-dominant, gold accent, subtle workspace frame, muted workspace-tinted dividers (35% mix). Brand anchor; the theme new users first meet. Reviewed against `company/brand/visual-aesthetic.md`.
2. **`phosphor.toml` — Phosphor.** Subtle matrix/CRT-phosphor aesthetic; deliberate divergence from the Stage 11 palette to validate theme-switching and demonstrate that the engine handles aesthetically-different themes. Self-contained — declares its own `[palette]` and `[variables]`; does NOT inherit from `stage11.toml`. Named for the Stage 11 Phosphor voice (`stage11/phosphor/PHOSPHOR_SOUL.md`), the light-bearer / mutation-vector entity — the lineage is voice-level even as the visual identity diverges.

Example snippets at the end of §6, Appendix A.

---

## 7. Divider + workspace frame primitives

### 7.1 Bonsplit — divider thickness knob

Current state: `splitView.dividerStyle = .thin` at `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift:125`. `TabBarMetrics.dividerThickness = 1` exists but isn't used as an override. `NSSplitView.dividerThickness` is a computed property — on a subclass (e.g. the existing `ThemedSplitView`) we can override `var dividerThickness: CGFloat { get }`.

Change (M2; bonsplit submodule). **v2 note**: landing `dividerThicknessPt` on `ChromeColors` (a colors-only struct) plants a future rename as a breaking change. v2 adopts a sibling `DividerStyle` struct on `Appearance` — clean naming, clean expansion path for M5 (`insetLeading`, `insetTrailing`, `opacity`, `style`).

1. Add a new sibling struct to `Appearance`:

   ```swift
   // vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift
   public struct Appearance: Sendable {
       public struct ChromeColors: Sendable {
           public var backgroundHex: String?
           public var borderHex: String?

           public init(
               backgroundHex: String? = nil,
               borderHex: String? = nil
           ) { … }
       }

       public struct DividerStyle: Sendable {
           /// Optional override for pane divider thickness in points.
           /// When nil, Bonsplit uses NSSplitView's .thin default (~1pt).
           public var thicknessPt: CGFloat?

           /// Reserved for M5+: insets, opacity, style (solid/dashed).
           public init(thicknessPt: CGFloat? = nil) { … }
       }

       public var chromeColors: ChromeColors
       public var dividerStyle: DividerStyle   // NEW
   }
   ```

2. In `ThemedSplitView`:

   ```swift
   override var dividerThickness: CGFloat {
       overrideThickness ?? super.dividerThickness
   }
   var overrideThickness: CGFloat?
   ```

3. `SplitContainerView.makeNSView(...)` reads `appearance.dividerStyle.thicknessPt` and assigns it to the subclass' override field; the update path in `updateNSView` does the same.

4. Retains the `.thin` dividerStyle as the structural hint (keeps macOS's standard hit-test region reasonable) while letting visible thickness be customized.

**Submodule policy** (`CLAUDE.md` "Submodule safety"): the bonsplit change ships first on `Stage-11-Agentics/bonsplit`'s `main`, then the parent-repo submodule pointer bump lands in a separate commit.

### 7.2 Bonsplit — wire `borderHex` from c11

Already supported end-to-end in bonsplit; the c11 side just hasn't been connected. In `Sources/Workspace.swift:5113-5118`, extend `bonsplitAppearance(...)` to accept theme-resolved divider color and thickness:

```swift
private static func bonsplitAppearance(
    from backgroundColor: NSColor,
    backgroundOpacity: Double,
    theme: C11muxTheme,
    context: ThemeContext           // NEW: full context, includes workspaceColor
) -> BonsplitConfiguration.Appearance {
    let dividerColor = theme.resolve(.dividers_color, context: context)
    let dividerThickness = theme.resolve(.dividers_thickness, context: context) ?? 1.0
    return BonsplitConfiguration.Appearance(
        splitButtonTooltips: Self.currentSplitButtonTooltips(),
        enableAnimations: false,
        chromeColors: .init(
            backgroundHex: Self.bonsplitChromeHex(...),
            borderHex: dividerColor.hexString(includeAlpha: true)
        ),
        dividerStyle: .init(thicknessPt: dividerThickness)
    )
}
```

`applyGhosttyChrome(...)` (`Workspace.swift:5130-5154`) extends its no-op guard to compare divider color, divider thickness, and `customColor` alongside background hex, and updates `chromeColors.borderHex` + `dividerStyle.thicknessPt` when any of them change.

**Workspace-color propagation wiring** (v2 addition per Trident adversarial review): the current `TabManager.setTabColor → Workspace.setCustomColor` write path does not signal bonsplit. Without explicit wiring, theme-based divider/frame colors would go stale when the operator changes the workspace color. Fix:

1. `Workspace.setCustomColor(_ hex: String?)` publishes a `customColorDidChange` signal (Combine `PassthroughSubject<String?, Never>`).
2. `WorkspaceContentView` subscribes and calls `applyGhosttyChrome(...)` (which already runs the no-op guard, so this is safe under rapid changes).
3. `ThemeManager` also subscribes to invalidate per-workspace cache entries for `$workspaceColor`-derived roles.

Both subscriptions live behind the existing no-op guard; `applyGhosttyChrome` is not on any typing-latency-sensitive path (it runs on workspace mount and on explicit color change only).

### 7.3 Outer workspace frame — where it inserts

The content area a workspace owns is the SwiftUI subtree returned by `WorkspaceContentView.body` at `Sources/WorkspaceContentView.swift:39-166`. `WorkspaceContentView` is mounted once per workspace inside a ZStack in `ContentView.terminalContent` (`Sources/ContentView.swift:2108-2122`), *already* to the right of the sidebar. That mount point is exactly what the frame should wrap — no splitting "sidebar vs content" logic needed because the ZStack is already content-area-only.

**Insertion approach (SwiftUI overlay, adopted)**:

```swift
// Sources/WorkspaceContentView.swift
var body: some View {
    // … existing bonsplitView composition …

    Group {
        if isMinimalMode {
            bonsplitView.ignoresSafeArea(.container, edges: .top)
        } else {
            bonsplitView
        }
    }
    .overlay(
        WorkspaceFrame(
            workspace: workspace,
            theme: themeManager.active,
            isWorkspaceActive: isWorkspaceInputActive
        )
        .allowsHitTesting(false)
    )
}
```

`WorkspaceFrame` is a new `View` that draws a `RoundedRectangle` stroke at `theme.chrome.windowFrame.thicknessPt`, coloured from `theme.chrome.windowFrame.color` resolved against `workspace.customColor`. Only the active workspace draws at full opacity; background workspaces drop to `windowFrame.inactiveOpacity` (default 0.25, §12 #3 — now a themable knob via §6.3 schema).

**v2 addition — `WorkspaceFrameState` enum**: the frame is a structural primitive, not decorative. Per Trident evolutionary review (unanimous) and §12 #9 operator lock, the API ships with a `state` parameter from day one even though v1 only implements `.idle`. The non-idle cases carry **source attribution** so individual surfaces (panes) can signal into the frame, letting the frame render directional expression (e.g., pulse originates near the signaling surface):

```swift
// Sources/Theme/WorkspaceFrame.swift (M1 stub, M2 fills .idle rendering)
public enum WorkspaceFrameState: Sendable, Equatable {
    case idle                                              // v1 — themed stroke
    case dropTarget(source: SurfaceId? = nil)              // reserved M5 — drag-drop highlight
    case notifying(Urgency, source: SurfaceId? = nil)      // reserved M5 — ambient state pulse
    case mirroring(peer: WindowId? = nil)                  // reserved M5 — cross-window echo
}

struct WorkspaceFrame: View {
    let workspace: Workspace
    let theme: C11muxTheme
    let isWorkspaceActive: Bool
    let isWindowFocused: Bool
    var state: WorkspaceFrameState = .idle
    // …
}
```

M1 ships the stub (signature + `.idle` case matching current behaviour); M2 fills `.idle` rendering. M5+ bolts on the remaining cases — including the attribution-aware rendering paths — without breaking callers.

**Animation contract** (v2.1 per §12 #9): all state transitions are **Animatable**. The SwiftUI overlay uses implicit animation (`.animation(.default, value: state)` + equivalent for `color`, `thicknessPt`, `opacity`) so M5+ subtle motion — pulse curves, directional glow, breathing idle states, drop-zone brightening — lands as a rendering change inside `WorkspaceFrame` without re-plumbing the primitive. v1 uses `.animation(nil, value: state)` for the decorative baseline (no motion yet); M5 flips the animation knob on per-case. No non-animatable transitions are baked into the enum shape or the view signature.

**Geometry & platform-fit notes** (v2, per Trident adversarial review):

- **Rounded window corners**: macOS 14+ windows have ~10pt rounded corners. `Rectangle().strokeBorder` produces sharp corners that clip visibly at the bottom. Use `RoundedRectangle(cornerRadius: NSApp.mainWindow?.contentView?.layer?.cornerRadius ?? 10)` matched to the hosting window. Implementation reads the window's corner radius at mount and re-reads on window-style changes.
- **Window-unfocus dimming**: when the hosting window loses focus, macOS HIG dims chrome. `WorkspaceFrame` reads the `ThemeContext.isWindowFocused` field and scales to `windowFrame.unfocusedOpacity` (default 0.6) when unfocused. Prevents the frame from looking hyper-saturated on inactive windows.
- **Minimal presentation mode**: `WorkspaceContentView.isMinimalMode` already applies `.ignoresSafeArea(.container, edges: .top)` to `bonsplitView`. The frame's overlay inherits this — which means the frame extends under the absent titlebar area. v1 decision: **the frame persists in minimal mode** (it's the only chrome indicator of workspace identity when the titlebar is hidden). Full-screen mode is tested explicitly in M2.
- **Portal-hosted terminal z-ordering**: terminals use AppKit portal hosting (`WindowTerminalHostView`) that can sit above SwiftUI during split/workspace churn. The frame's `.allowsHitTesting(false)` + SwiftUI layer ordering was verified in M2 on tagged builds; explicit audit line in M2 PR.
- **Color-space conformance**: `NSColor` values entering the resolver are converted to `sRGB` on ingress. Cross-space `.mix()` is a load-time error (§6.4.a #7). Workspace custom-color values come from `WorkspaceTabColorSettings.displayNSColor`, which M1 audits for `sRGB` conformance.

**Why SwiftUI `.overlay` instead of a CALayer border**:

| Option | Pros | Cons |
|---|---|---|
| SwiftUI `.overlay` with `Rectangle().stroke(...)` | Respects SwiftUI layout, animates naturally, `allowsHitTesting(false)` keeps it event-transparent, no AppKit plumbing. | A hairline on Retina can antialias slightly differently than a 1pt CALayer border; for a subtle frame this is acceptable and actually reads well. |
| CALayer border on the hosting NSView | Pixel-perfect 1pt rendering. | Requires a `NSViewRepresentable` host, breaks the `.ignoresSafeArea` / `.frame` layout flow, doesn't respect SwiftUI animations without extra glue. |
| NSBox / AppKit `NSView.wantsLayer` border | Native. | Still requires a hosting representable and fights SwiftUI's layout engine. |

Adopted: SwiftUI overlay. Thickness rendered in points via `.strokeBorder(lineWidth:)`, which renders on the inside of the rect — avoids bleeding into adjacent views.

**Behavior under motion**:

- **Split animations** (pane open/close): the frame wraps the entire content area, not individual panes, so bonsplit's internal animation is unaffected. Frame doesn't flicker.
- **Window resize**: SwiftUI-driven; the overlay resizes with its container.
- **Full-screen**: the overlay disappears cleanly when `isMinimalMode` applies `.ignoresSafeArea(.container, edges: .top)` — verified behaviour because the overlay attaches to the `Group`, inheriting the same bounds.
- **Workspace switch** (ZStack-swap in `ContentView.terminalContent`): each workspace has its own frame at its own color. No crossfade needed in v1 — M5 evaluates.

### 7.4 Cross-fade on workspace switch

Opinion: **do not animate in v1**. Today the ZStack opacity-transitions workspaces instantly (`opacity(presentation.renderOpacity)` at `ContentView.swift:2123`). The frame inherits that. Animating the frame separately would:

- Risk flashing the wrong color briefly during handoff.
- Add coupling to `retiringWorkspaceId` state.
- Cost complexity for dubious UX gain.

If operators feedback asks, M5 adds `behavior.animateWorkspaceCrossfade = true` as a theme-level opt-in.

---

## 8. Migration story

The theme engine replaces no live setting in v1. Every existing `@AppStorage` key below stays in force — the theme engine provides **defaults** that those keys override. The staged deprecations happen after ≥1 release of measured usage.

| Existing setting | v1 behavior | Deferred deprecation |
|---|---|---|
| `sidebarTintHexLight` / `sidebarTintHexDark` / `sidebarTintHex` / `sidebarTintOpacity` (`Sources/ContentView.swift:13527-13528`) | Override theme's `chrome.sidebar.tintBase` / `tintBaseOpacity`. If either light/dark override is set, it continues to win. | Planned: remove @AppStorage keys and move user values into a "User overrides" theme file on first launch after M4 ships. Not in M1-M4. |
| `sidebarActiveTabIndicatorStyleRaw` (`Sources/TabManager.swift:171-186`) | Orthogonal — governs `.leftRail` vs `.solidFill` structure, not colors. Theme provides colors for whichever mode is active. | **No deprecation planned.** The indicator mode is a structural choice, not a theme choice; stays as a first-class setting. |
| `AppearanceMode` (light/dark/system — `Sources/c11App.swift:3534-3583`) | Orthogonal. Themes read `colorScheme` when resolving `$workspaceColor` (brightening) and should otherwise not assume a scheme. | **No deprecation planned.** Light/dark is OS-level; themes are additive to it. |
| `BrowserThemeSettings` (`Sources/Panels/BrowserPanel.swift:166-196`) | Orthogonal — governs web-content `prefers-color-scheme`, not chrome. | **No deprecation planned.** Content rendering ≠ chrome. |
| `WorkspaceTabColorSettings` (`Sources/TabManager.swift:245-443`) | Stays entirely — the palette, custom colors, and `Workspace.customColor` all feed `$workspaceColor`. | **No deprecation planned.** The theme engine consumes this; it does not replace it. |
| `c11 terminal-theme` CLI / `Resources/ghostty/themes/` | Untouched — these govern Ghostty terminal colors, not c11 chrome. | **No deprecation planned.** Separate ownership (Ghostty) from new engine. |

### 8.1 Default theme selection for existing installs

Automatic and silent: on first launch after M1, `theme.active = "stage11"` (the built-in default). M1 is a visual no-op — the default theme is calibrated to produce the same on-screen output as today. Existing installs see no change until M2 ships the frame + divider wiring.

**Rollback surfaces** (clarified v2 per Trident adversarial review — rollback controls were previously split across an env var, an AppStorage key, and a proposed runtime-toggled env var, which is inconsistent):

| Surface | Scope | When to use |
|---|---|---|
| `CMUX_DISABLE_THEME_ENGINE=1` (env var) | **Launch-time only** — forces pre-M1 code paths from process start. | Operator-level rollback safety net; debug reproducer. |
| `@AppStorage("theme.engine.disabledRuntime", default: false)` | **Runtime toggle** — flips via Debug menu; applies live. | Developer A/B during implementation; not shown in release builds. |
| `@AppStorage("theme.workspaceFrame.enabled", default: true)` | **Runtime, scoped to frame only** — turns off the §7.3 overlay without disabling the engine. | M2 rollback lever if the frame regresses but rest of theming is fine. |

The launch-time env var and runtime AppStorage are **independent**: env var wins when set. Removing the env var falls back to the runtime AppStorage value.

**Removal schedule**: `CMUX_DISABLE_THEME_ENGINE` and `theme.engine.disabledRuntime` are removed in the release **two milestones after M2 ships cleanly** (expected window: after M4 lands, assuming no theme-engine bugs reach stable-channel). "Cleanly" = zero open P0/P1 theme bugs, three consecutive release nightlies with no theme-related crash reports.

### 8.1.a Precedence matrix (v2 — per Trident adversarial review)

When a surface role has values from multiple sources, resolution follows a fixed precedence. Highest wins.

| Source | Example | Precedence |
|---|---|---|
| Launch-time env var rollback | `CMUX_DISABLE_THEME_ENGINE=1` | **Highest** — disables the engine entirely, legacy paths only. |
| Runtime engine toggle | `theme.engine.disabledRuntime = true` | Same as env var when env is unset. |
| Legacy `@AppStorage` override (per §8 table) | `sidebarTintHexLight`, `sidebarTintHexDark`, etc. | Wins for the specific role the key controls, **only** if the operator has explicitly set it. Detection: key present in `UserDefaults` (not just defaulted). |
| Active theme's chrome value | `chrome.sidebar.tintBase = "$background"` | Default when no legacy override is set. |
| Theme variable reference | `$background`, `$workspaceColor`, `$ghosttyBackground` | Resolved via the `[variables]` table of the active theme. |
| Runtime magic token | `$workspaceColor → Workspace.customColor` | Resolved per-call from runtime context; cache-keyed on `ThemeContext`. |
| Built-in default theme fallback | `stage11.toml` | Floor — used when active theme omits a key (§6.5). |

**Rationale**: the "Additive, not migratory" principle (§2 #8) requires that existing `@AppStorage` keys set by the operator keep working. A key **not** explicitly set by the operator (i.e. still defaulted) falls through to the theme value — this is what makes v1 a visual no-op for fresh installs while preserving behaviour for operators who customized.

### 8.2 Per-workspace color stays unchanged

`Workspace.customColor` is already durable (§5.4). Nothing about the theme engine changes its write path, persistence, or read API. The engine **consumes** it via the `$workspaceColor` variable.

---

## 9. Discoverability + UX

### 9.1 Settings pane (M4)

New "Appearance" section above "Workspace Colors" in `Sources/c11App.swift` settings:

- **Two theme pickers** (per §12 #12): "Theme (Light appearance)" and "Theme (Dark appearance)". Each is a segmented control or menu listing built-ins + user themes alphabetically; built-ins tagged with a small "Built-in" badge. Selections write to `@AppStorage("theme.active.light")` and `@AppStorage("theme.active.dark")` respectively.
- **"Apply to both" convenience action**: a small link/button next to the Light picker that copies the Light selection to the Dark slot (and vice versa). Saves a click for the common case of one theme across both modes. Default install: both slots set to `stage11`.
- Live preview pane: a small c11-shaped diagram (sidebar stub, workspace frame, divider, title bar) rendered with the selected theme's resolved values against a representative workspace color. Updates in ≤100ms on selection change (resolution is cheap; re-render is SwiftUI cheap).
- "Open Themes Folder" button → `NSWorkspace.shared.open(themesDirURL)` to reveal user themes dir in Finder, creating it on first click if absent.
- "Reload themes" button → manual retrigger of the M3 file watcher.

Leaves the existing "Workspace Colors" section intact (palette + custom colors + indicator style picker).

### 9.2 Context menu — per-workspace theme override

**Out of scope for v1.** Per-workspace `themeOverride` adds coordination surface (what happens when the global theme changes? when the override theme is deleted?) without a clear user ask. Theme designers would likely want per-environment themes (prod vs dev) rather than per-workspace, and that discussion is orthogonal.

Reserved: the `Workspace` model can gain `themeOverride: String?` in M5 if asked; the schema already supports it trivially.

### 9.3 Socket / CLI surface (M4)

```
c11 themes list                         # built-in + user, one per line, built-ins first            [read]
c11 themes get [--slot light|dark]      # print active c11 chrome theme name; optional slot per §12 #12 [read]
c11 themes set <name> [--slot light|dark|both] # switch a slot (or both); operator-only per §12 #13 [write]
c11 themes clear                        # revert slots to built-in default; operator-only           [write]
c11 themes reload                       # force-rescan user themes dir                              [read]
c11 themes path                         # print the absolute path of the user themes dir            [read]
c11 themes dump --json                  # dump the resolved c11 chrome theme as JSON for debugging  [read]
c11 themes validate <path>              # validate a c11 chrome theme file                          [read]
c11 themes diff <a> <b>                 # compare two c11 chrome themes                             [read]
c11 workspace-color set --workspace <ref> <hex> # see §5.6                                          [write]
c11 workspace-color clear --workspace <ref>                                                        [write]
c11 workspace-color get --workspace <ref>                                                          [read]
```

**Socket access policy** (per §12 #13): the `set` and `clear` verbs on `c11 themes` are operator-only — the CLI exposes them on the local operator's path, but the socket surface does NOT expose them to agent connections. Agents that need to signal workspace mode use `c11 set-workspace-metadata state.<key> <value>` (§12 #10); the active theme renders that state via `[when.workspaceState.*]` blocks. Read verbs (`list`, `get`, `dump`, `path`, `reload`) are safe for agent use.

**CLI namespace** (superseded 2026-04-22): the 2026-04-18 decision below kept the short `themes` verb for Ghostty terminal themes. Current c11 product language reverses that collision:

> `c11 themes` — c11 chrome themes (sidebar, title bars, dividers, browser chrome, markdown chrome, workspace frame).
> `c11 terminal-theme` — Ghostty terminal themes (terminal cells, cursor, prompt colors).

Legacy compatibility aliases remain implementation details; new docs and help should use `c11 themes ...`. Chrome theme authoring helpers such as `inherit` or `fork` remain deferred and are not part of this canonical namespace cleanup.

### 9.4 Debug menu entries

Per the `skills/cmux-debug-windows` conventions, add to the Debug menu:

- "Debug: Dump Active Theme" → opens a new markdown surface with the resolved theme as JSON.
- "Debug: Toggle Theme Engine" → flips `@AppStorage("theme.engine.disabledRuntime")` (not the env var — see §8.1 rationale).
- "Debug: Show Theme Folder" → `NSWorkspace.shared.open(themesDirURL)`.
- "Debug: Rotate Through Themes" → cycles active theme across all loaded themes (for quick visual comparison).
- "Debug: Show Resolution Trace" → per-role trace of how a color was resolved (which variable chain, which fallbacks fired).

All debug entries are `#if DEBUG`-only; no release impact.

### 9.5 Localization

All new user-facing strings use `String(localized: "key.name", defaultValue: "English text")` per CLAUDE.md policy. Keys land in `Resources/Localizable.xcstrings` with English + Japanese translations:

- `settings.section.appearance`
- `settings.appearance.theme`
- `settings.appearance.theme.builtin`
- `settings.appearance.theme.openFolder`
- `settings.appearance.theme.reload`
- `settings.appearance.preview.title`
- `debug.theme.dumpActive`, `debug.theme.toggleEngine`, `debug.theme.showFolder`, `debug.theme.rotate`

---

## 10. Phased rollout

Each milestone is independently mergeable, independently useful, and ships as one PR. Milestones are sized so each is one focused review, not a mega-PR.

### M1 — Foundation (invisible plumbing)

**v2 split** (per Trident standard + adversarial reviews): M1 was previously a single PR touching 8 systems simultaneously while asserting pixel-identity; that was too much review surface for too high a correctness bar. v2 splits into M1a (engine + parser + default theme, no call-site refactor) and M1b (surface-by-surface adoption behind a flag with per-surface visual diff).

#### M1a — Engine, parser, default theme (no call-site refactor)

**Deliverable**: `C11muxTheme` struct, TOML subset parser, built-in default theme bundled, `ThemeManager` singleton, `ThemeRoleRegistry`, `ResolvedThemeSnapshot`. Zero call-site changes — no existing chrome paths touched. The engine loads but nothing reads from it except tests.

**New files**:

- `Sources/Theme/C11muxTheme.swift` — the `Codable` struct (identity, palette, variables, chrome sections).
- `Sources/Theme/ThemedValueAST.swift` — **parse-time AST** (per Trident evolutionary review). Input: raw string. Output: typed AST node (`.hex(UInt32)`, `.variableRef(path)`, `.modifier(op, args)`, `.structured(disabled | opacity | …)`).
- `Sources/Theme/ThemedValueEvaluator.swift` — **resolve-time evaluator**. Takes an AST node + `ThemeContext`, returns `NSColor`. Split enforces "parse once, evaluate many."
- `Sources/Theme/TomlSubsetParser.swift` — hand-written subset parser (§6.1, §12 #7). Budget: **400–600 lines**.
- `Sources/Theme/ThemeContext.swift` — context struct (§3).
- `Sources/Theme/ThemeRoleRegistry.swift` — single source of truth for every role, its default value, owning surface, and fallback (§3).
- `Sources/Theme/ThemeManager.swift` — singleton `@MainActor` class; exposes `active: C11muxTheme`, `resolve<T>(_ role: ThemeRole, context: ThemeContext) -> T?`, per-section publishers, `version: UInt64`.
- `Resources/c11-themes/stage11.toml` — built-in default.
- OSLog subsystem: `com.stage11.c11`, categories: `theme.engine`, `theme.loader`, `theme.resolver`.
- `c11Tests/C11muxThemeLoaderTests.swift`, `c11Tests/ThemedValueResolutionTests.swift`, `c11Tests/TomlSubsetParserFuzzTests.swift`, `c11Tests/ThemeResolverBenchmarks.swift`.

**Tests (M1a, all automated, CI-visible)**:

1. Round-trip: load `stage11.toml`, encode as JSON, diff against a golden. Catches schema drift.
2. Resolution: a set of fixtures — `$foreground`, `$workspaceColor.opacity(0.08)`, `$background.mix($accent, 0.5)` — each producing a specific `NSColor` deterministically (sRGB, 8-bit-per-channel).
3. **Fuzz corpus** (v2 addition, per Trident): `c11Tests/TomlSubsetParserFuzzTests.swift` exercises BOM, CRLF/LF, trailing whitespace, unquoted hex (`#RRGGBB` as comment foot-gun), comments-before-tables, empty tables, deeply-nested tables, duplicate keys, string-vs-number confusion. Corpus lives at `c11Tests/Fixtures/toml-fuzz/`.
4. **Perf regression test** (v2 addition): 10,000 resolutions of the default theme's hottest roles against representative contexts; assert p95 <10ms total and per-lookup <1µs amortized. Gates the M1a merge.
5. **Resolved-snapshot artifact** (v2 addition): CI job emits `stage11-snapshot.json` (resolved `ThemeManager` output for default context); PRs diff against the committed golden. Catches semantics drift before visual regressions are visible.
6. **Cycle/invalid-value tests**: a theme with `$a → $b → $a` fails at parse time with the expected error; `opacity(1.5)` clamps to `1.0` + warning; `#GGG` is a load-time error; `unknown(0.5)` is a load-time error.

**Rollback (M1a)**: trivially none — the engine is unreferenced. The PR adds ~2000 lines in isolation.

#### M1b — Surface-by-surface adoption (behind a flag, per-surface visual diff)

**Deliverable**: chrome surfaces refactored to **read from the manager**; the default theme produces identical on-screen output. Each surface migration is feature-flagged and lands as its own screenshot-diff-gated commit inside the M1b PR (or as independent PRs if bandwidth allows).

**Surfaces migrated (in order, each with visual-diff gate)**:

1. `SurfaceTitleBarView` — lowest-risk; not on typing-latency path.
2. `Sources/Panels/BrowserPanelView.swift` — browser chrome background / omnibar.
3. `Sources/Panels/MarkdownPanelView.swift` — panel background.
4. `Sources/Workspace.swift:5084-5154` — `bonsplitAppearance` takes `ThemeContext`; resolves `chromeColors.backgroundHex` through the manager (default resolves `$ghosttyBackground` to today's value).
5. `Sources/ContentView.swift` — `TabItemView` reads `sidebar.activeTabFill` / `sidebar.activeTabRail` through the manager via **precomputed `let` parameters** (preserves `Equatable` contract at `ContentView.swift:10608`). No `@EnvironmentObject` inside `TabItemView`.
6. `Sources/ContentView.swift` — `customTitlebar` (titlebar background + bottom separator): explicitly in scope per §4.2. `titleBar.background` defaults to `$ghosttyBackground`; `titleBar.borderBottom` defaults to `$separator`.
7. `Sources/WorkspaceContentView.swift` — injects `ThemeManager.shared` + `ThemeContext` into the environment for M2 child views.

**M1b acceptance criteria (v2 — concrete, per Trident standard Q14)**:

- **24-dimensional sidebar snapshot test**: cross-product of {light, dark} × {`.solidFill`, `.leftRail`} × {active, inactive, multi-selected} × {has-custom-color, no-custom-color} — 24 snapshot fixtures committed under `c11Tests/Snapshots/sidebar-m1b/`, zero pixel drift from pre-M1 baseline. Captured on both a Retina and non-Retina target.
- **Titlebar snapshot test**: light/dark × {Ghostty-default-background, custom-workspace-background} — 4 fixtures.
- **Browser-chrome snapshot test**: light/dark × 3 system appearances — 6 fixtures.
- **Per-surface flag**: `@AppStorage("theme.m1b.\(surface).migrated", default: false)` — enables per-surface rollback if a specific migration introduces drift.

**Risks (M1):**

- *Resolution performance.* Theme lookups happen per-render, per-surface. Mitigation: memoize the resolved `NSColor` in `ThemeManager` keyed on `ThemeContext` hash; invalidate on theme change, on `ghosttyDefaultBackgroundDidChange`, and on `Workspace.customColor` mutation. Performance budget: ≤1µs per lookup on the hot path (sidebar tab render during workspace switch). Gate: M1a perf regression test.
- *SwiftUI render graph.* Turning hardcoded colors into observed values risks over-invalidation. Mitigation: `ThemeManager` exposes per-section publishers (`sidebarPublisher`, `titleBarPublisher`, `dividerPublisher`, `framePublisher`); global `version: UInt64` is used only for full-reload events. Views subscribe to the narrowest publisher for their role.
- *`TabItemView` Equatable contract.* M1b must preserve `ContentView.swift:10607-10608` invariants — no new `@EnvironmentObject`/`@ObservedObject` inside the view; theme reads as pre-computed `let` parameters. PR audit line required.
- *Parser quality & scope.* See §6.1 — realistic scope is 400–600 lines, budgeted 2–3 engineer-days. Fuzz corpus (M1a test 3) catches regression.

**Rollback (M1b)**: `CMUX_DISABLE_THEME_ENGINE=1` (launch-time) restores pre-M1 inline color paths. `theme.engine.disabledRuntime = true` toggles live via Debug menu. Per-surface `theme.m1b.<surface>.migrated = false` rolls back one surface at a time. Pre-M1 code paths stay dead-but-present behind the flag through M4, then are removed per §8.1 schedule.

### M2 — Workspace color prevalence + frame + dividers

**v2 split** (per Trident adversarial review): M2 was previously one PR touching a bonsplit submodule bump, bonsplit API extension, chromeColors wiring, a new frame primitive, sidebar tint overlay, and `applyGhosttyChrome` refactor — blocked by any single stall and with incoherent partial-ship rollback. v2 splits into three sequential PRs, each independently shippable.

#### M2a — Bonsplit `DividerStyle` (submodule-only)

**Deliverable**: `vendor/bonsplit` ships the `DividerStyle` struct (§7.1) and the `ThemedSplitView.dividerThickness` override. Parent repo is NOT bumped in this PR.

**Modified files**:

- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift` — add `DividerStyle` sibling struct on `Appearance`.
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift` — read `appearance.dividerStyle.thicknessPt`.
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/ThemedSplitView.swift` (if private class confirmed) — add `override var dividerThickness: CGFloat { overrideThickness ?? super.dividerThickness }`.
- `vendor/bonsplit` tests: `BonsplitDividerThicknessTests` — construct `Appearance` with `dividerStyle.thicknessPt: 3`, mount, assert `NSSplitView.dividerThickness == 3`.

**CLAUDE.md submodule safety** (v2 — explicit checklist):

1. Branch off bonsplit `main`, commit, push to `Stage-11-Agentics/bonsplit`.
2. Verify: `cd vendor/bonsplit && git merge-base --is-ancestor HEAD origin/main` — must succeed.
3. CI gate: bonsplit's own tests must pass before M2b opens.

**Rollback**: none needed — additive to bonsplit, no c11 callers yet.

#### M2b — Parent repo: wire divider color + thickness through bonsplit

**Deliverable**: `Workspace.bonsplitAppearance` and `applyGhosttyChrome` thread theme-resolved divider color/thickness through `ChromeColors.borderHex` + `DividerStyle.thicknessPt`. Dividers pick up the workspace color via the default theme's `$workspaceColor.mix($background, 0.65)` formula. The outer frame and sidebar overlay are NOT yet wired.

**Modified files**:

- Parent-repo submodule pointer bump to the M2a commit (separate commit per CLAUDE.md).
- `Sources/Workspace.swift:5106-5154` — `bonsplitAppearance` takes `ThemeContext`; `applyGhosttyChrome` no-op guard extends to `borderHex` + `dividerStyle.thicknessPt` + `customColor`.
- `Sources/WorkspaceContentView.swift` — subscribe to `Workspace.customColorDidChange` to re-apply bonsplit chrome when workspace color changes (§7.2).

**Tests**:

- `c11Tests/WorkspaceDividerColorPropagationTests.swift` — change `Workspace.customColor`, assert `applyGhosttyChrome` fires and `NSSplitView.dividerColor` reflects the new resolved value.
- XCUITest: set a workspace custom color, assert dividers change colour live (no restart).

**Rollback**: `CMUX_DISABLE_THEME_ENGINE=1` restores pre-M2b (dividers derived from background hex).

#### M2c — Outer workspace frame + sidebar tint overlay

**Deliverable**: `WorkspaceFrame` renders as an overlay on `WorkspaceContentView`; sidebar tint overlay gains the theme's `chrome.sidebar.tintOverlay` layered atop the existing tint. Full workspace-color prevalence story is shipped.

**New files**:

- `Sources/Theme/WorkspaceFrame.swift` — SwiftUI view that draws the outer frame overlay (stub shipped in M1 per §7.3; M2c fills `.idle` rendering).
- `Sources/Theme/ThemeManager+WorkspaceColor.swift` — live resolution of `$workspaceColor` via `WorkspaceTabColorSettings.displayNSColor`.

**Modified files**:

- `Sources/WorkspaceContentView.swift:39-166` — `.overlay(WorkspaceFrame(...))` on the top-level `Group`.
- `Sources/ContentView.swift` — sidebar tint overlay gains the theme's `chrome.sidebar.tintOverlay` layered atop the existing tint.

**Tests**:

- `c11Tests/WorkspaceFrameRenderTests.swift` — mounts `WorkspaceFrame` with mock workspace+theme, asserts stroke color + thickness + `allowsHitTesting(false)`.
- **Inactive-workspace frame opacity test** (v2 addition, per Trident standard review): mount two workspaces with different colors, switch active, assert the inactive frame renders at `windowFrame.inactiveOpacity` (default 0.25).
- **Unfocused window frame opacity test**: simulate `NSWindow.didResignKey`, assert frame scales to `windowFrame.unfocusedOpacity`.
- **Divider-thickness no-op guard test** (v2 addition): force `applyGhosttyChrome` to re-run without any theme change; assert `dividerStyle.thicknessPt` is unchanged (not reverted).
- **Rounded-corner geometry test**: mount in a rounded-corner host window; assert frame uses `RoundedRectangle` matched to the window's corner radius.

**Risks (M2c)**:

- *Typing-latency paths.* `WorkspaceFrame` attaches above `bonsplitView`, not to any terminal view. Stroke resolved once per theme/workspace-color change, memoized. Audit line in PR.
- *Workspace crossfade flicker.* ZStack swap during workspace switch could briefly show both frames at intermediate opacities — two workspace colors may clash. Mitigation: frame opacity gated on `presentation.renderOpacity` (same gate as workspace content); M2c ships an XCUITest that captures the crossfade and asserts no visible flash.
- *Portal-hosted terminal z-ordering.* Terminals use AppKit portal hosting that can sit above SwiftUI. M2c PR audit: verify frame renders correctly during split animations and workspace switches on a tagged build.
- *Minimal mode + frame.* Frame persists in minimal mode (§7.3). XCUITest covers the minimal-mode case.

**Rollback (M2c)**: `@AppStorage("theme.workspaceFrame.enabled", default: true)` kill switch per §8.1. Sidebar overlay defers to pre-M2c via `theme.engine.disabledRuntime = true`.

**Partial-ship protocol**: if M2b ships but M2c lags (e.g. frame geometry bug), dividers are live and frame is off — no rollback needed. If M2a ships but M2b lags, bonsplit exposes the new API but c11 doesn't consume it — also safe.

### M3 — User themes + hot reload

**Deliverable**: Users drop `.toml` files in `~/Library/Application Support/c11/themes/` and they load. Two built-ins ship per §12 #15: Stage 11 (default) and Phosphor. Editing a theme file triggers hot reload within ≤1s. `c11 themes validate` is available for offline debugging (pulled forward from M4 per Trident evolutionary review).

**New files**:

- `Sources/Theme/ThemeDirectoryWatcher.swift` — `DispatchSource.makeFileSystemObjectSource` watcher on the user themes dir (falls back to polling every 2s if FSEvents unavailable). Debounces to 250ms. Handles editor-save patterns (vim `.swp`, VSCode atomic rename).
- `Sources/Theme/ThemeCanonicalizer.swift` — canonical formatter (sorted keys, consistent whitespace). Reserved for future theme authoring workflows and optionally on file-watcher-detected changes.
- `Resources/c11-themes/phosphor.toml`
- `Resources/c11-themes/README.md` — bundled into the user themes dir on first-run creation; explains TOML subset, reserved variables, examples.
- CLI: `c11 themes validate <path-or-name>` — runs the loader in error-collecting mode; prints warnings + errors; exit 0 on clean, 1 on warnings, 2 on errors. Pulled forward from M4.

**Modified files**:

- `Sources/Theme/ThemeManager.swift` — enumerates built-ins + user themes; handles name shadowing (user wins); **atomic swap**: parses candidate fully before replacing active `ResolvedThemeSnapshot`; on parse failure, retains last-known-good and emits a sticky OSLog warning.
- `Sources/c11App.swift` — creates the user themes dir + README on first launch if absent.

**Hot-reload contract** (v2 — per Trident):

1. FSEvents fires → debounce 250ms.
2. Candidate file read → parsed → validated → `ResolvedThemeSnapshot` computed on a background queue.
3. Swap is main-actor-bound and atomic: the published snapshot reference is replaced in one assignment, triggering per-section publishers.
4. On parse failure: last-known-good snapshot is retained; OSLog warning with file path + first error surfaces; the user's Settings picker shows a "⚠ theme file invalid — using <fallback>" indicator (M4) so the state is not silent.
5. Editor save patterns (vim `.tmp` + rename; VSCode atomic replace; `:wa` multi-file saves): the debounce + candidate-parse flow handles these — incomplete intermediate files fail to parse and trigger last-known-good retention; final valid state is picked up on the next FSEvent.

**Tests**:

- `c11Tests/ThemeDirectoryWatcherTests.swift` — write a theme file, wait for change publisher, assert new theme loads. Use a temp dir via a new `ThemeManager.pathsOverride` seam.
- `c11Tests/ThemeShadowingTests.swift` — built-in named "stage11", user file named "stage11.toml", assert user wins, assert revert on user file delete, **assert revert on user file deleted while active**.
- `c11Tests/ThemeMalformedLoadTests.swift` — malformed TOML → OSLog warning, doesn't crash, **doesn't swap active theme** (last-known-good retention).
- `c11Tests/ThemeAtomicSwapTests.swift` (v2) — simulate vim-style temp-file-then-rename; assert no intermediate-invalid state is ever published.
- `c11Tests/ThemeCanonicalizerTests.swift` — round-trip: arbitrary valid theme → canonicalize → parse → semantically equivalent.
- **Additive-schema fallback test** (v2): user theme omits `[chrome.titleBar]`; load; assert title bar values come from `stage11.toml` fallback + diagnostic annotation.
- `tests_v2/test_theme_validate_cli.py` — `c11 themes validate` on good/warning/error fixtures, assert exit codes.

**Risks**:

- *FSEvents latency / unreliability.* Polling fallback mitigates; polling is cheap on ≤10 files.
- *User theme that references missing variables.* Additive fallback (§6.5) → missing keys use default-theme values with warning. Never crashes.
- *Theme file deleted while active.* Last-known-good retention handles this; on next reload (or restart), falls back to the default theme.
- *Themes directory edge cases* (permissions, exists-as-file, symlink to unreadable target): `ThemeManager` treats these as "no user themes available" + OSLog warning; built-ins still load.

**Rollback**: Built-ins continue to load regardless of user-theme state; deleting a broken user theme file restores prior behavior.

### M4 — Settings UI + CLI

**Deliverable**: Theme picker with live preview in Settings. Full `c11 themes` and `c11 workspace-color` CLI surface. `c11 themes diff` is available for operator diagnostics; explicit authoring helpers such as `inherit` or `fork` remain deferred.

**v2 scope clarification** (per Trident standard review): `CLI/c11.swift` is a large single file and `Sources/c11App.swift` handles all Settings surfaces inline. M4 does **not** introduce a `CLI/commands/` or `Sources/Settings/` directory restructure — new code lands inline in the existing files. If the inline-code-size becomes an issue post-M4, a separate refactor ticket handles the reorganization.

**New files** (minimal — most additions are inline):

- `Sources/Theme/AppearanceThemeSection.swift` — Settings picker + preview canvas (inline SwiftUI view; called from existing Settings layout in `c11App.swift`).
- `Sources/Theme/ThemePreviewCanvas.swift` — miniature c11 diagram for Settings.
- `Sources/Theme/ThemeSocketMethods.swift` — socket method handlers for `theme.*` and `workspace.set_custom_color`.

**Modified files**:

- `CLI/c11.swift` — canonical `themes` subcommand family (inline): `list`, `get`, `set <name>`, `clear`, `reload`, `path`, `dump --json`, `validate`, `diff <a> <b>`. `workspace-color` family: `set --workspace <ref> <hex>`, `clear`, `get`, `list-palette`.
- `Sources/c11App.swift:~4806` — insert new "Appearance" section above "Workspace Colors" (inline in existing settings scene).
- `Sources/ContentView.swift` — context-menu "Workspace Color" submenu gets a tooltip so operators learn about themes organically.
- Socket API doc `docs/socket-api-reference.md` — document new methods.

**`c11 themes dump --json` schema** (v2 locked):

```json
{
  "theme": {
    "identity": { "name": "stage11", "display_name": "Stage 11", "version": "0.01.001", "schema": 1 },
    "source_path": "/path/to/theme.toml | <bundled>",
    "context": { "workspaceColor": "#C0392B", "colorScheme": "dark", "ghosttyBackgroundGeneration": 42 },
    "roles": {
      "chrome.windowFrame.color": {
        "expression": "$workspaceColor",
        "resolved": "#C0392B",
        "inherited_from": null
      },
      "chrome.sidebar.tintBase": {
        "expression": "$background",
        "resolved": "#0A0C0F",
        "inherited_from": "stage11"
      }
    },
    "warnings": [
      { "key": "chrome.tabBar.activeFill", "message": "opacity clamped from 1.5 to 1.0" }
    ]
  }
}
```

**Workspace reference grammar** (v2, for `c11 workspace-color --workspace <ref>`):

- `<index>` — 1-based workspace index in the sidebar.
- `<uuid>` — workspace UUID.
- `@current` — active workspace.
- `@focused` — currently-focused workspace (usually same as `@current`, may differ during handoff).

**Tests**:

- `tests_v2/test_theme_cli.py` — full CRUD over CLI: list / get / set / clear / reload / dump / validate / diff.
- `tests_v2/test_workspace_color_cli.py` — set workspace color, assert readable via `workspace.list`, assert visible in snapshot file; exercise all workspace-ref forms.
- `c11Tests/AppearanceSettingsTests.swift` — picker change flips `ThemeManager.active`.
- `c11Tests/ThemeDumpJsonSchemaTests.swift` (v2) — `c11 themes dump --json` output conforms to the locked schema; `inherited_from` annotations match expected fallback behaviour.

**Risks**:

- *Socket focus policy.* `c11 themes set` must not steal focus (CLAUDE.md socket focus policy). The handler runs off-main; only theme application (a no-allocation update of observed state) touches main. Audit explicit in PR.

**Rollback**: The CLI is purely additive. The Settings section can be gated behind `@AppStorage("settings.appearance.themeSectionEnabled", default: true)` if needed.

### M5 — Advanced (stretch)

Re-justify after M4 lands. Candidates:

- **Theme crossfade on workspace switch** (`behavior.animateWorkspaceCrossfade = true`).
- **Per-workspace theme override** (`Workspace.themeOverride: String?`, context menu entry).
- **Community theme format** — versioned spec document + theme-sharing conventions (theme file as single gist, one-click import).
- **Light-theme variant handling** — today themes are mode-agnostic via `colorScheme`-aware resolution; a formal `[light]` / `[dark]` variant pair would let theme authors ship two resolved palettes per theme file.
- **Icon theming** — explicitly out of scope for v1 but would slot in here.

Each lands as its own PR, each re-justifies before work starts. None block M1-M4 landing cleanly.

---

## 11. Non-goals (explicit)

- **Ghostty terminal theme modification.** Terminal cells, cursor, prompt rendering, scrollback — entirely Ghostty-owned. `Resources/ghostty/themes/` and the `c11 terminal-theme` CLI are separate concerns.
- **Terminal cell / cursor / prompt / scrollback theming.**
- **macOS window chrome** — traffic lights, system titlebar buttons, window drop shadow. System-owned.
- **Browser *content* theming** — `BrowserThemeSettings` controls `prefers-color-scheme` on the rendered web content and stays orthogonal.
- **Markdown *content* rendering** — typography, syntax highlighting, list bullets, etc. Chrome-only.
- **Syntax highlighting** (for terminal ANSI or markdown code blocks).
- **Icon theming** — no app icon, menu item icon, or SF Symbol swapping in v1.
- **Settings window theming** — the window that *shows* theme controls is itself not themed.
- **Menu bar extra theming** — system-owned.
- **Cross-platform themes** — c11 is macOS-only; themes assume NSColor semantics.
- **Dynamic theming from external sources** (e.g. macOS accent color, desktop wallpaper sampling) — nice-to-have, not v1.
- **Theme marketplace / remote fetch** — users copy files by hand in v1.

---

## 12. Open questions — resolved 2026-04-18

All seven open questions were locked with Atin on 2026-04-18 before the Trident plan review kicked off. The plan has been updated to reflect these decisions; this section records them as provenance.

1. **Built-in default theme identity — LOCKED: Stage 11 brand.** The shipped default matches `company/brand/visual-aesthetic.md`: void-dominant (`#0A0C0F`), gold accent (`#C4A561`). See Appendix A.1. *Rationale*: tight brand coherence across the stack; operators fork from an opinionated baseline.

2. **Workspace frame default thickness — LOCKED: 1.5pt.** Readable on Retina without feeling thick next to `.thin` dividers. See §7.3.

3. **Workspace frame opacity for inactive workspaces — LOCKED: 0.25.** Preserves visual continuity during workspace switches. See §7.3 ("Behavior under motion").

4. **Workspace-colored tab-bar active indicator in default theme — LOCKED: `$workspaceColor`.** The default Stage 11 theme uses workspace color on the 2pt bottom indicator. See Appendix A.1 (`[chrome.tabBar].activeIndicator`). *Rationale*: reinforces workspace identity on a second chrome surface; subtle because the indicator is only 2pt.

5. **CLI namespace — SUPERSEDED 2026-04-22.** The original lock kept `cmux themes` for Ghostty terminal themes and put c11 chrome themes under `cmux ui themes ...`. Current c11 product language is `c11 themes` for c11 chrome themes and `c11 terminal-theme` for Ghostty terminal themes. See §9.3.

6. **Per-workspace theme override — LOCKED: deferred past v1.** v1 ships a single global theme. Per-workspace `customColor` already exists and gives per-workspace identity; a per-workspace theme *file* override (workspace A loads `stage11.toml`, workspace B loads `minimal.toml`) is deferred to M5 if operators ask. Schema stays forward-compatible. See §9.2.

7. **TOML parser — LOCKED: hand-written subset parser.** ~200 lines; covers strings, numbers, booleans, nested tables. No arrays-of-tables, no inline arrays, no datetime. Zero third-party deps. See §6.1.

8. **Audience — LOCKED: public, outward-facing utility.** cmux is a public tool; theming is a brand-expression surface that spreads the Stage 11 vibe outward. *Rationale*: polish bar is held to public-product standard across error UX, docs, CLI ergonomics, and localization. Concretely: TOML parse errors include file path, line, column, and expected-token context; CLI help is complete and self-explanatory; every user-facing string is localized; the built-in `stage11.toml` doubles as a brand showcase (reviewed against `company/brand/visual-aesthetic.md` per §13.6). The default theme being opinionated Stage-11 brand does NOT imply the surrounding UX is internal-only — the theme is how external users first meet Stage 11's aesthetic. *(Resolves §14 #1, raised by Adversarial Claude Q52 and Evolutionary Q7.)*

9. **Workspace frame — LOCKED: structural primitive, per-surface addressable, animation-ready.** M2c ships the decorative baseline only (themed stroke, workspace color, thickness/opacity per §7.3). The `WorkspaceFrameState` enum carries **source attribution** (`SurfaceId?` on `dropTarget` / `notifying`; `WindowId?` on `mirroring`) so individual surfaces can signal into the frame and the frame can render directional expression (e.g., agent-in-pane-X pulse originates near pane X). All frame state transitions are **Animatable** — the SwiftUI overlay uses implicit animation on `state`, `color`, `thicknessPt`, and `opacity` so future M5+ work can layer subtle motion (sophisticated pulse curves, directional glow, breathing idle states) without re-architecting the primitive. *Rationale*: the frame is a free canvas already being rendered and themed; treating it as structural keeps the door open for agent-state signaling, drop-zone affordance, mode indicators (see §12 #10/#11 when resolved), and cross-window mirroring — all at near-zero extra cost in v1. The enum already exists per §7.3 (v2 evolutionary-unanimous add); this lock specifies that source attribution and animation-readiness are non-negotiable shape commitments. §7.3 carries the refined enum shape and animation contract. *(Resolves §14 #2, raised by Evolutionary unanimous + Claude Q2.)*

10. **`$workspaceColor` scope — LOCKED: pure color token + sibling `workspaceState` channel on `ThemeContext`.** `$workspaceColor` stays a pure color token — resolves to per-workspace `NSColor` exclusively, no categorical overloading. Workspace state (environment, risk, mode, arbitrary tags) flows through a **separate** `workspaceState: WorkspaceState?` field on `ThemeContext`, reserved in v1 and implemented in a v1.x point release. v1 reserves schema keys `[when.workspaceState.environment]`, `[when.workspaceState.risk]`, `[when.workspaceState.mode]`, `[when.workspaceState.tag.<key>]` with warn-and-ignore per §6.5; v1.x lights them up. Population path: `c11 set-workspace-metadata state.<key> <value>` → `WorkspaceState` → `ThemeContext` — zero new theming syntax; reuses the existing metadata machinery. *Rationale*: `$workspaceColor` has semantically clean `NSColor`-only behavior today; overloading it with categorical semantics contaminates a surgical token and forces every modifier (`.mix`, `.opacity`) to branch on non-color cases. State tags are categorical, not chromatic — they want conditional blocks, not string interpolation. Separation also lowers the auth surface on Q7 (agents change *state*, not *theme*) and gives Q2's structural frame (`§12 #9`) a clean signal source. §3 (`ThemeContext`) and §6.5 (reserved keys) carry the body updates. *(Resolves §14 #3, raised by Evolutionary unanimous + Codex Q3 + Gemini Q2.)*

11. **Process ceremony — LOCKED: no formal gates; normal operator workflow applies.** Stage 11 is a single-operator project driven by Atin in-session; CMUX-9 is not a multi-week staffed initiative. The Trident review's "gate" language (tagged-build gate §13.9; brand-review sign-off gate §13.6) is **softened to recommended local-verify practice**, not blocking ceremony. Concretely: local tagged builds (`./scripts/reload.sh --tag theme-<milestone>`) remain the standard pre-merge verification because CI is red, but "gate" / "sign-off" / "artifact" framing is removed — it's just how the operator works. Brand review is the operator confirming the palette before M1a merges as part of normal implementation, not a separate ceremony requiring a screenshot-diff artifact or a deputy protocol. *Rationale*: gate ceremony borrowed from enterprise project templates doesn't match a solo-operator fast-moving project; the review reflexively added process overhead where the honest answer is "operator is in the loop continuously." Removing the ceremony does not remove the underlying practice — local-verify still happens, brand coherence still matters — it just stops pretending they're formal checkpoints. *(Resolves §14 #4 and §14 #5, raised by Adversarial Claude Q47, Q51; Evolutionary Q4.)*

12. **Light/dark mode — LOCKED: themes are mode-agnostic; appearance binding is an operator preference.** Theme files ship a single palette. Light/dark handling lives **one level up** in operator preferences: Settings exposes two slots — **"Theme (Light appearance)"** and **"Theme (Dark appearance)"** — each bound to any installed theme. Default ships both slots set to `stage11` (void-dominant; appears dark in both modes until the operator wires a light-oriented theme). Operators who want a single theme across both modes set both slots identically (trivial "apply one theme to both" flow). Operators who want mode-specific chrome pick e.g. `minimal` for Light and `stage11` for Dark. `ThemeContext.colorScheme` drives *which slot is selected*, not per-key resolution inside a theme. **`[when.appearance]` is NOT a reserved schema key** (removed from §6.5). *Rationale*: themes are brand expressions, not multi-mode configs. Forcing `stage11` to ship a light-palette block would either dilute its void-dominant identity or produce a half-hearted invert. Separating "which theme applies when" from "what the theme looks like" lets Stage 11 stay opinionated, lets third-party themes stay single-palette (easier authoring), and gives operators a clean composition surface. Parallels how Ghostty, VS Code, and iTerm2 handle appearance-linked theming. Storage: `@AppStorage("theme.active.light")` + `@AppStorage("theme.active.dark")`; the existing `@AppStorage("theme.active")` from v1 drafts is retired in favor of the pair (clean break, no migration burden — nothing has shipped). §3, §6.5, and §9.1 (Settings picker) carry the body updates. *(Resolves §14 #6, raised by Evolutionary Claude Q10 + Adversarial Claude Q22.)*

13. **Agent socket access — LOCKED: agents signal workspace state, not themes.** Theme selection is **operator-only**. The socket API exposes *read-only* theme methods (`c11 themes list` / `get` / `dump`) but no `set` / `clear` / `cycle` write methods to agent socket clients — theme writes are available only to operators invoking the CLI themselves (which already runs as the operator, not through an agent's socket connection). Agents express "this workspace is in mode X" via the **existing metadata API**: `c11 set-workspace-metadata state.<key> <value>` (§12 #10 already locks the `state.` prefix as the canonical channel). The active theme decides how to render that state via `[when.workspaceState.*]` conditional blocks. v1 keeps the metadata write path **open** — any socket consumer may set `state.*` keys; no per-client permission enforcement. The state namespace is small, the operator can clear at will, and there's no real auth infrastructure to build. Revisit only if a misuse pattern appears. *Rationale*: clean authorization boundary — agents signal, operator decides visual response. Socket focus policy from CLAUDE.md needs no new treatment because metadata writes are already non-focus-stealing. Chrome-as-notification-channel without chrome-control: agents inform the UI, but the theme author owns the visual vocabulary. Also: an agent on a shared DEV/STAGING build (Q8) can't accidentally clobber the operator's theme preference — the worst it can do is leave a stale state tag. *(Resolves §14 #7, raised by Adversarial Claude Q36 + Evolutionary Q16.)*

14. **Concurrent-instance state — LOCKED: per-bundle-ID `@AppStorage`, shared themes directory.** Theme *selection* is isolated per build; theme *library* is shared. Concretely: all `@AppStorage` keys in the theming system (`theme.active.light`, `theme.active.dark`, `theme.engine.disabledRuntime`) route through `UserDefaults(suiteName: Bundle.main.bundleIdentifier)` (or equivalent prefix scheme). Production `c11`, `c11 DEV`, `c11 DEV <tag>`, and `c11 STAGING` each hold their own selection — an operator iterating on theme code in a tagged build cannot accidentally flip their daily-driver's theme. The user themes dir stays at the shared location `~/Library/Application Support/c11/themes/` — themes authored once are visible to every build, and the file watcher runs independently per instance. *Rationale*: matches the existing c11 isolation model for tagged builds (sockets, bundle IDs, derived data already isolate; `@AppStorage` was the missing piece). Shared library matches operator expectations and how Ghostty / Terminal.app / iTerm2 handle user assets. Cost: ~5 lines of plumbing at `@AppStorage` call sites. §6.2 (directory + selection) and §13 (instance-isolation note) carry the body updates. *(Resolves §14 #8, raised by Adversarial Claude Q35.)*

15. **Built-in theme set — LOCKED: two built-ins ship; `stage11` + `phosphor`.** v1 ships an intentionally small built-in set: `stage11.toml` (brand default) and `phosphor.toml` (subtle matrix/CRT-phosphor aesthetic). `high-contrast-workspace.toml` and `minimal.toml` are dropped from v1 scope; their Appendix A entries are removed. The second built-in exists to **validate theme-switching end-to-end** AND to **demonstrate the engine's aesthetic range** — proving the schema and loader handle themes that are deliberately divergent from the Stage 11 palette, not just Stage 11 brand expressions. Variety beyond the two built-ins lives in **user-authored themes** in the shared themes dir, not in additional built-ins. `phosphor.toml` is **self-contained** — declares its own `[palette]` and `[variables]`; does NOT inherit from `stage11.toml` via loader fallback. The name nods to the Stage 11 Phosphor voice (`stage11/phosphor/PHOSPHOR_SOUL.md`) and to CRT-phosphor terminal nostalgia; lineage is voice-level even as the visual identity diverges. *Rationale*: small built-in set keeps brand curation tight while proving the engine supports broader aesthetic expression; operator/agent-authored themes are where variety happens, which is what the whole engine is for. Shipping three nearly-similar Stage-11-palette-inheriting themes would understate what the engine does; shipping one showcase-divergent second theme is stronger signal. Hex palette in Appendix A.2 is indicative and subject to iteration before M3 ships; the locked part is the schema shape, role assignments, and the name. §6.6 (built-ins), §A.2 (palette), and Appendix B (file list) carry the body updates. *(Resolves §14 #9, raised by Evolutionary Codex §2.8 Q9.)*

16. **Explicit theme inheritance — LOCKED: deferred to M5+; schema key reserved now.** v1 does **not** ship an `inherits = "<parent-name>"` field as a functioning feature, and v1/M4 does **not** expose an `inherit` or `fork` CLI verb under the canonical `c11 themes` namespace. The schema key `[identity].inherits` is **reserved** in v1 with warn-and-ignore semantics (per §6.5) — forward-compatible authoring is allowed but has no runtime effect. The implicit additive-fallback-through-`stage11` mechanism from §6.5 continues to be the only inheritance surface in v1, and is itself opt-in per built-in (phosphor opts out; user themes opt in by omitting keys). M5+ may implement loader-level inheritance graph walk with parse-time cycle detection, chain-aware `inherited_from` annotation in `c11 themes dump --json`, and a separately decided operator-facing forking flow if demand surfaces. *Rationale*: explicit inheritance is a real authoring win but ships a resolver-layer complexity (cycle detection, chain diagnostics, deprecation semantics for built-in parents) that's not yet proven necessary. v1 users can start from `c11 themes dump --json` output and edit by hand, which matches how Ghostty / VS Code user themes work. Keeping v1 simple preserves the hand-written subset parser's scope (§12 #7) and avoids locking in CLI semantics before we've seen the user pattern. §6.5 (reserved keys) carries the body update. *(Resolves §14 #10, raised by Evolutionary Claude.)*

---

## 13. Risks + pitfalls

### 13.1 Typing-latency-sensitive paths

CLAUDE.md flags three paths as typing-latency-sensitive; any theme change must prove it doesn't touch them on hot paths.

| Path | Risk | Mitigation |
|---|---|---|
| `WindowTerminalHostView.hitTest()` (`Sources/TerminalWindowPortal.swift`) | Called on every event including keyboard. Any work outside the `isPointerEvent` guard blocks input. | `WorkspaceFrame` attaches above the terminal view stack; `hitTest` never reaches it due to `.allowsHitTesting(false)`. No new work on this path. Explicit PR audit line. |
| `TabItemView` (`Sources/ContentView.swift`) | Uses `Equatable` + `.equatable()` to skip body re-evaluation during typing. New env/binding properties would break the `==` comparison. | Theme reads are through **pre-computed `let` parameters** passed into `TabItemView`, not via `@EnvironmentObject`/`@ObservedObject` inside the view. The M1 refactor carefully preserves `.equatable()`. Explicit PR audit line. |
| `TerminalSurface.forceRefresh()` (`Sources/GhosttyTerminalView.swift`) | Called on every keystroke. | Not touched by any milestone. The theme engine lives outside terminal surfaces. |

### 13.2 Submodule safety (bonsplit)

M2 modifies `vendor/bonsplit`. Per CLAUDE.md "Submodule safety":

1. Commit the bonsplit change on a branch of `Stage-11-Agentics/bonsplit`.
2. Push the commit to bonsplit's remote `main`.
3. Verify: `cd vendor/bonsplit && git merge-base --is-ancestor HEAD origin/main` — must succeed.
4. Only then bump the parent-repo submodule pointer in a separate commit.

Any divergence — detached HEAD, un-pushed commit, wrong branch — must be caught in the PR checklist.

### 13.3 Localizable strings

Every new user-facing string uses `String(localized: "key.name", defaultValue: "English text")`. Keys are added to `Resources/Localizable.xcstrings` with English + Japanese translations. No bare string literals in `Text()`, `Button()`, or alert titles. Explicit audit per PR.

### 13.4 Build / test policy

- Per CLAUDE.md, never run `xcodebuild test` locally — even `cmux-unit` launches host app instances. Defer all test runs to CI (`gh workflow run test-e2e.yml`).
- Per memory `feedback_cmux_never_run_xcodebuild_test.md`, use `build` action only when verifying compilation locally.
- `tests_v2/` Python socket tests must run against a tagged build's socket (`/tmp/c11-debug-<tag>.sock`), not an untagged `c11 DEV.app`.

### 13.5 Perf budget

- `ThemeManager.color(for:, workspaceColor:)` hot path: ≤1µs per call (memoized).
- `WorkspaceFrame` re-render: triggered only on theme change or workspace `customColor` change — not on keystrokes or typing.
- Bonsplit divider config churn: guarded by the existing no-op check in `applyGhosttyChrome` (`Workspace.swift:5136`), extended to cover `borderHex` + `dividerThicknessPt`.

### 13.6 Brand / aesthetic drift

`company/brand/visual-aesthetic.md` governs Stage 11 visual identity. The default theme must be explicitly reviewed against it before M1 ships. A mismatch here is hard to unwind after user installs pick up the bundled default.

**v2 additions**:

- **Cross-link `stage11.toml` ↔ `company/brand/visual-aesthetic.md`**: TOML is the runtime source of truth; the markdown is the rationale and lineage doc. Both files reference each other at their heads so drift between them is visible.
- **Contrast-budget validation** (warning-only): at theme load, `ThemeManager` computes perceived contrast ratios for key role pairs (foreground/background, divider/background, frame/background, tabBar.activeIndicator/tabBar.background). Ratios below WCAG AA thresholds emit OSLog warnings; never blocks load. Keeps custom themes debuggable and flags inadvertent low-contrast states without imposing policy.
- **Default-palette brand coherence**: §12 #1 locks the default theme as Stage 11 brand. The operator confirms the palette against `company/brand/visual-aesthetic.md` before M1a merges — this is normal implementation judgment, not a formal gate or sign-off ceremony (per §12 #11). Post-M1 palette tweaks stay schema-compatible (values inside `[palette]`) and use the same operator-judgment baseline.

### 13.7 Schema lock-in

Once users start authoring themes, breaking changes to the schema become expensive. The additive-only guarantee within `schema = 1` is load-bearing. Reviewer should explicitly evaluate each proposed schema change during review for breaking-ness.

### 13.8 User theme supply-chain concerns

`.toml` files are inert (no code execution). A malicious theme can at worst produce unreadable UI — not a security concern, but a usability one. Themes never load from remote URLs in v1.

### 13.9 CI red-build baseline

Per memory `project_c11mux_ci_build_runner_red.md`, the c11 CI build job is red on every main commit (macos-15-xlarge Larger Runner unavailable — billing). Ignore the red build check and use `gh pr merge --admin` to bypass, per established practice.

**Local-verify practice** (per §12 #11 — softened from the Trident review's "v2 milestone gate" framing): because CI is red, each theming milestone is verified via a local tagged build before merge. This is standard operator workflow, not a formal gate or merge-blocker:

```bash
./scripts/reload.sh --tag theme-<milestone>     # e.g. theme-m1a
```

The tagged build launches, `c11 themes dump --json` is sanity-checked (M1a+), and per-milestone acceptance tests (M1b snapshot diff; M2c crossfade XCUITest) run locally. Merge uses `gh pr merge --admin` per established practice.

### 13.10 Forward-only Lattice

Per memory `project_cmux_lattice_forward_only.md`, the CMUX-9 ticket tracks this plan and its implementation. It is **not** retrospectively decomposed into phase tickets for work-already-done. Each milestone PR references CMUX-9 and optionally a new child ticket per milestone when work starts.

### 13.11 Trident-review findings considered and rejected

Recorded per the review classification contract. Each entry is a finding the Trident pack surfaced that conflicts with a §12 locked decision or a load-bearing design principle; the underlying risk (when valid) is addressed via other amendments, but the proposed remediation is out of bounds.

1. **"Add an M0 spec-lock milestone before M1"** (Codex standard + adversarial). Rejected as a separate milestone — the underlying concern (runtime contract under-specification) is valid and is folded into §3, §6.4.a, §6.5, §7.3, §8.1.a as an in-plan runtime-contract amendment. Adding an M0 milestone adds governance overhead without producing code; appendix-in-plan is lighter-weight.
2. **"Force-migrate legacy `@AppStorage` overrides into a `user-overrides.toml` in M3"** (Gemini adversarial). Rejected — direct drift on §2 #8 ("Additive, not migratory") and the deferred-deprecation story in §8. The split-brain debugging concern is valid and is addressed via the precedence matrix (§8.1.a).
3. **"Replace the string-modifier grammar with structured TOML inline tables"** (Gemini adversarial). Rejected — would require the hand-written subset parser to accept inline arrays / arrays-of-tables, directly drifting on §12 #7. The ambiguity/cycle risks are addressed via grammar formalization (§6.4.a) and the fuzz corpus (M1a test 3).
4. **"Remove `behavior.animateWorkspaceCrossfade` from v1 schema until M5 implements it"** (Codex adversarial). Rejected — the key is explicitly reserved for M5 opt-in (§6.5) and v1 parses-and-ignores. Removing it now would force a schema change in M5, breaking the additive-only promise.
5. **"Swap M3 and M4 (ship socket/CLI before the file watcher)"** (Gemini evolutionary). Rejected — hot-reload is the authoring feedback loop that the evolutionary flywheel itself depends on. Shipping CLI first trades operator experience for automation readiness; not worth the reorder.
6. **"Adopt an external TOML parser (LebJe/toml, etc.)"** (implicit in Gemini adversarial + Claude parser-scope concern). Rejected — direct drift on §12 #7 (hand-written subset parser, zero deps). The effort-framing correction (400–600 lines, not 200) is folded into §6.1.
7. **"Drop the additive-fallback-through-stage11.toml"** (Codex adversarial, "hidden inheritance from mutable baseline"). Rejected — the fallback is the additive extensibility mechanism. The mutable-baseline risk is mitigated by (a) the default palette being locked pre-M1, (b) the schema=1 additive-only guarantee, and (c) the `inherited_from` annotation in `c11 themes dump --json`.
8. **"Flip the env-var polarity: `CMUX_THEME_ENGINE_ENABLED=1` instead of `CMUX_DISABLE_THEME_ENGINE=1`"** (Claude adversarial, cosmetic). Rejected — current form preserves "env unset → engine enabled" (the expected default). The matching `theme.engine.disabledRuntime` AppStorage key follows the same polarity for consistency.
9. **"Generalize resolver to `resolve<T>` in M1 — escalate decision to operator"**. **Accepted as generic `resolve<T>`** (§3); not rejected. Recorded here only because the original classification considered escalating; folded per the evolutionary unanimous recommendation.

---

## 14. Open questions post-Trident

Questions where the Trident review surfaced genuine operator judgment calls. Each item has a reviewer attribution and is 1:1 actionable. These do NOT reopen §12.

1. ~~**Audience declaration**~~ — **RESOLVED 2026-04-19 → see §12 #8.** Public, outward-facing utility; theming doubles as brand-expression surface.
2. ~~**Workspace frame: decorative or structural primitive?**~~ — **RESOLVED 2026-04-19 → see §12 #9.** Structural primitive, per-surface addressable state, animation-ready rendering; M2c ships the decorative baseline, M5+ hooks `WorkspaceFrameState` cases with source attribution and subtle motion.
3. ~~**`$workspaceColor` scope: pure color token, or broader workspace-state channel?**~~ — **RESOLVED 2026-04-19 → see §12 #10.** Pure color token; sibling `workspaceState` channel on `ThemeContext` (reserved in v1, implemented in v1.x); `[when.workspaceState.*]` conditional blocks drive state-based chrome expression.
4. ~~**Single-operator fallback**~~ — **RESOLVED 2026-04-19 → see §12 #11.** Not a real constraint; solo-operator in-session project, no multi-week gate-fallback protocol needed.
5. ~~**Brand-review sign-off mechanism**~~ — **RESOLVED 2026-04-19 → see §12 #11.** No gate or sign-off ceremony; operator confirms palette coherence as part of normal implementation judgment.
6. ~~**Light-mode identity**~~ — **RESOLVED 2026-04-19 → see §12 #12.** Themes are mode-agnostic; operators bind themes to system appearance via two Settings slots (`theme.active.light`, `theme.active.dark`). Default: both = `stage11`. No per-theme `[when.appearance]` block.
7. ~~**Agent-mediated theme changes via socket**~~ — **RESOLVED 2026-04-19 → see §12 #13.** No; agents signal workspace state via `c11 set-workspace-metadata state.*`, and the active theme renders that state via `[when.workspaceState.*]` blocks. Theme selection stays operator-only.
8. ~~**Concurrent-instance state**~~ — **RESOLVED 2026-04-19 → see §12 #14.** Per-bundle-ID `@AppStorage` isolation (each build holds its own selection); shared user themes directory (library is shared across all builds).
9. ~~**Built-in theme family cohesion**~~ — **RESOLVED 2026-04-19 → see §12 #15.** Two built-ins ship (`stage11` + `phosphor`); scope reduced from three. `phosphor` is intentionally divergent, self-contained, and validates theme-switching end-to-end. Variety beyond the built-in set lives in user-authored themes.
10. ~~**Future explicit theme inheritance schema**~~ — **RESOLVED 2026-04-19 → see §12 #16.** Deferred to M5+; `[identity].inherits` key reserved with warn-and-ignore in v1; any operator-facing CLI helper remains a separate feature decision.

---

## Appendix A — Built-in theme examples

### A.1 `stage11.toml` (default, ships in M3)

```toml
[identity]
name         = "stage11"
display_name = "Stage 11"
author       = "Stage 11 Agentics"
version      = "0.01.001"
schema       = 1

[palette]
void    = "#0A0C0F"
surface = "#121519"
gold    = "#C4A561"
fog     = "#2A2F36"
text    = "#E9EAEB"
textDim = "#8A8F96"

[variables]
background          = "$palette.void"
surface             = "$palette.surface"
foreground          = "$palette.text"
foregroundSecondary = "$palette.textDim"
accent              = "$palette.gold"
separator           = "$palette.fog"
workspaceColor      = "$workspaceColor"
ghosttyBackground   = "$ghosttyBackground"

[chrome.windowFrame]
color            = "$workspaceColor"
thicknessPt      = 1.5
inactiveOpacity  = 0.25
unfocusedOpacity = 0.6

[chrome.sidebar]
tintOverlay           = "$workspaceColor.opacity(0.08)"
tintBase              = "$background"
tintBaseOpacity       = 0.18
activeTabFill         = "$workspaceColor"
activeTabFillFallback = "$surface"
activeTabRail         = "$workspaceColor"
activeTabRailFallback = "$accent"
activeTabRailOpacity  = 0.95
inactiveTabCustomOpacity       = 0.70
inactiveTabMultiSelectOpacity  = 0.35
badgeFill             = "$accent"
borderLeading         = "$separator"

[chrome.dividers]
color       = "$workspaceColor.mix($background, 0.65)"
thicknessPt = 1.0

[chrome.titleBar]
background          = "$surface"
backgroundOpacity   = 0.85
foreground          = "$foreground"
foregroundSecondary = "$foregroundSecondary"
borderBottom        = "$separator"

[chrome.tabBar]
background       = "$ghosttyBackground"
activeFill       = "$ghosttyBackground.lighten(0.04)"
divider          = "$separator"
activeIndicator  = "$workspaceColor"

[chrome.browserChrome]
background   = "$ghosttyBackground"
omnibarFill  = "$surface.mix($background, 0.15)"

[chrome.markdownChrome]
background = "$background"

[behavior]
animateWorkspaceCrossfade = false
```

### A.2 `phosphor.toml`

Subtle matrix/CRT-phosphor aesthetic — self-contained, declares its own `[palette]` and `[variables]`. Hex values are indicative and subject to brand-palette iteration before M3 ships; the schema shape and role assignments are the locked part.

```toml
[identity]
name         = "phosphor"
display_name = "Phosphor"
author       = "Stage 11 Agentics"
version      = "0.01.001"
schema       = 1

[palette]
void        = "#04080A"          # deeper than stage11; sinks the foreground
surface     = "#0A1014"
phosphor    = "#2EE85C"          # desaturated CRT-green; avoids the kitsch trap
phosphorDim = "#1A8F3A"
cyan        = "#5EC8D6"          # muted accent
fog         = "#1C2A22"          # divider base — green-tinted near-black
text        = "#B8F0C7"          # slightly phosphor-tinted neutral
textDim     = "#5C7E66"

[variables]
background          = "$palette.void"
surface             = "$palette.surface"
foreground          = "$palette.text"
foregroundSecondary = "$palette.textDim"
accent              = "$palette.phosphor"
separator           = "$palette.fog"
workspaceColor      = "$workspaceColor"
ghosttyBackground   = "$ghosttyBackground"

[chrome.windowFrame]
color            = "$workspaceColor"                # workspace color escape-hatch
thicknessPt      = 1.0
inactiveOpacity  = 0.30
unfocusedOpacity = 0.55

[chrome.sidebar]
tintOverlay           = "$palette.phosphor.opacity(0.04)"    # barely-there phosphor wash
tintBase              = "$background"
tintBaseOpacity       = 0.22
activeTabFill         = "$palette.surface"
activeTabRail         = "$accent"
activeTabRailOpacity  = 0.85
inactiveTabCustomOpacity      = 0.65
inactiveTabMultiSelectOpacity = 0.30
badgeFill             = "$accent"
borderLeading         = "$separator"

[chrome.dividers]
color       = "$palette.phosphorDim.mix($background, 0.75)"   # almost-glowing hairline
thicknessPt = 1.0

[chrome.titleBar]
background          = "$surface"
backgroundOpacity   = 0.90
foreground          = "$foreground"
foregroundSecondary = "$foregroundSecondary"
borderBottom        = "$separator"

[chrome.tabBar]
background      = "$ghosttyBackground"
activeFill      = "$ghosttyBackground.lighten(0.02)"
divider         = "$separator"
activeIndicator = "$accent"

[chrome.browserChrome]
background  = "$ghosttyBackground"
omnibarFill = "$surface.mix($background, 0.20)"

[chrome.markdownChrome]
background = "$background"

[behavior]
animateWorkspaceCrossfade = false
# M5+ (per §12 #9 animation-ready frame): subtle phosphor breathing/flicker
# lives here as additional `[behavior.*]` keys when M5 ships.
```

---

## Appendix B — File & directory summary

### New files (across M1-M4, v2)

| Path | Milestone | Purpose |
|---|---|---|
| `Sources/Theme/C11muxTheme.swift` | M1a | Codable theme struct |
| `Sources/Theme/ThemedValueAST.swift` | M1a | Parse-time AST for value grammar |
| `Sources/Theme/ThemedValueEvaluator.swift` | M1a | Resolve-time evaluator |
| `Sources/Theme/TomlSubsetParser.swift` | M1a | Hand-written TOML subset parser |
| `Sources/Theme/ThemeContext.swift` | M1a | Context struct for resolver |
| `Sources/Theme/ThemeRoleRegistry.swift` | M1a | Single source of truth for all roles |
| `Sources/Theme/ThemeManager.swift` | M1a | Singleton manager + per-section publishers |
| `Sources/Theme/WorkspaceFrame.swift` | M1 (stub) / M2c (rendering) | Outer frame + `WorkspaceFrameState` enum |
| `Sources/Theme/ThemeManager+WorkspaceColor.swift` | M2c | `$workspaceColor` resolution |
| `Sources/Theme/ThemeDirectoryWatcher.swift` | M3 | User-theme file watcher (atomic swap) |
| `Sources/Theme/ThemeCanonicalizer.swift` | M3 | Canonical formatter |
| `Sources/Theme/AppearanceThemeSection.swift` | M4 | Settings picker (inline SwiftUI, not new directory) |
| `Sources/Theme/ThemePreviewCanvas.swift` | M4 | Settings preview |
| `Sources/Theme/ThemeSocketMethods.swift` | M4 | Socket handlers |
| `Resources/c11-themes/stage11.toml` | M1a | Default built-in (brand) |
| `Resources/c11-themes/phosphor.toml` | M3 | Built-in (Phosphor — matrix/CRT-phosphor aesthetic, §12 #15) |
| `Resources/c11-themes/README.md` | M3 | First-run doc bundled into user themes dir |

### Modified files (across M1-M4, v2)

| Path | Milestones | Notes |
|---|---|---|
| `Sources/Workspace.swift` | M1b, M2b | `bonsplitAppearance` takes `ThemeContext`; `applyGhosttyChrome` threads divider color+thickness + `customColor` no-op guard; `setCustomColor` publishes `customColorDidChange` |
| `Sources/WorkspaceContentView.swift` | M1b, M2b, M2c | `.overlay(WorkspaceFrame(...))`; subscribe to `customColorDidChange` |
| `Sources/ContentView.swift` | M1b, M2c, M4 | `TabItemView` theme reads via pre-computed `let`; `customTitlebar` background + border; sidebar tint overlay; context-menu tooltip |
| `Sources/SurfaceTitleBarView.swift` | M1b | Background / border / foreground through theme |
| `Sources/Panels/BrowserPanelView.swift` | M1b | Chrome background / omnibar through theme |
| `Sources/Panels/MarkdownPanelView.swift` | M1b | Panel background through theme |
| `Sources/c11App.swift` | M3, M4 | Create themes dir + README; insert Appearance settings section inline |
| `CLI/c11.swift` | M3, M4 | Inline `themes` + `workspace-color` subcommands (no CLI restructure) |
| `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift` | M2a | `DividerStyle` sibling struct (not on `ChromeColors`) |
| `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift` | M2a | Override `dividerThickness`; read `dividerStyle.thicknessPt` |
| `docs/socket-api-reference.md` | M4 | Document new `theme.*` and `workspace.set_custom_color` methods |
| `Resources/Localizable.xcstrings` | M3, M4 | New localization keys |

Ship M1a. Ship M1b. Ship M2a/M2b/M2c. Measure. Then M3, M4. Re-justify M5.
