# C11-8: Fix custom workspace color chrome refresh and frame coverage

## Problem

Custom workspace colors currently bleed into the neutral workspace sidebar background, render an incomplete workspace outline, and do not update all interior chrome when the custom color changes live.

Observed from dogfood screenshots on 2026-04-21:

1. Setting a workspace custom color tints the sidebar/list rail background. The sidebar is neutral window chrome and should not inherit the workspace color. The workspace color should apply to the selected workspace tab/card plus the workspace-owned frame/outline.
2. The light workspace outline is inconsistent. It is visible around some of the app/workspace area but disappears around terminal/split interiors, and the browser scrollbar/right edge creates a visible gap where the outline appears to stop.
3. Changing the custom color from green to yellow updates the outer frame but not the inner workspace chrome/dividers/tab strip. All workspace-colored chrome should refresh atomically from the selected workspace color.

## Expected behavior

- Sidebar rail/background remains neutral regardless of the selected workspace custom color.
- Selected workspace tab/card may use the custom workspace color as the workspace identity marker.
- The active workspace outline/frame is continuous around the whole workspace content area, including terminal, browser, markdown, tab strip, split divider, and scrollbar-edge cases.
- Live custom color changes propagate to every workspace-colored chrome surface without relaunch, workspace switch, or manual refresh.

## Likely related work

- Related to CMUX-32 workspace color prevalence/theme M2 work. This ticket is a focused bug/regression pass based on current dogfood screenshots, not a full theme-engine expansion.

## Constraints

- Preserve typing-latency-sensitive paths from AGENTS.md.
- Do not tint Ghostty-owned terminal cells or browser page content.
- Avoid source-text/grep tests; prefer runtime behavior or artifact-level checks where practical.
- Do not run local E2E/UI tests; use a tagged build and visual validation if implementing locally.

## Exploration Findings

### 1. Sidebar tint is intentional in current code, but now wrong for product intent

`Sources/ContentView.swift` defines `SidebarBackdrop`, which subscribes to the selected workspace custom color and resolves `chrome.sidebar.tintOverlay` against it. The Stage 11 theme and registry default both set that role to `$workspaceColor.opacity(0.08)`.

Relevant paths:

- `Sources/ContentView.swift` - `SidebarBackdrop`
- `Sources/Theme/ThemeRoleRegistry.swift` - `.sidebar_tintOverlay`
- `Sources/Theme/C11muxTheme.swift` and `Resources/c11-themes/stage11.toml`
- `c11Tests/Fixtures/golden/stage11-snapshot.json`
- `c11Tests/Fixtures/golden/stage11-resolved-snapshot.json`

This directly explains the subtle green/yellow wash behind the workspace list.

### 2. The tab active indicator theme role exists but is not wired

The theme schema has `chrome.tabBar.activeIndicator = "$workspaceColor"`, but Bonsplit still renders the selected tab's 2 pt indicator with `Color.accentColor` in `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`.

That makes the inner tab strip capable of staying at the app/accent color instead of tracking the live workspace color. This is probably one part of the "outside updates, inside does not" symptom.

Relevant paths:

- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift`
- `Sources/Workspace.swift` - `Workspace.applyGhosttyChrome(...)`
- `Sources/Theme/ThemeRoleRegistry.swift` - `.tabBar_activeIndicator`

Because Bonsplit is vendored from upstream, any generic active-indicator appearance seam should be flagged as an upstream candidate.

### 3. Dividers are theme-aware, but portal layering can still hide chrome

`Workspace.applyGhosttyChrome(...)` resolves divider color/thickness from `ThemeManager` and writes them to Bonsplit `chromeColors.borderHex` and `dividerStyle.thicknessPt`. `WorkspaceContentView` listens to `workspace.customColorDidChange`, invalidates theme caches, and calls `applyGhosttyChrome`.

However, terminal/browser content is portal-hosted AppKit content. There is a terminal-only `SplitDividerOverlayView` in `Sources/TerminalWindowPortal.swift` that redraws split dividers above portal-hosted terminal views, but no equivalent shared/browser overlay. The browser scrollbar/right edge gap in the screenshot is consistent with portal content sitting above SwiftUI/Bonsplit chrome.

Relevant paths:

- `Sources/WorkspaceContentView.swift`
- `Sources/Workspace.swift`
- `Sources/TerminalWindowPortal.swift`
- `Sources/BrowserWindowPortal.swift`
- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift`

### 4. Workspace frame overlay is SwiftUI-level and can be occluded

`WorkspaceFrame` is attached as a SwiftUI `.overlay` on `WorkspaceContentView`. Its own comment notes portal-hosted terminals stay above it in z-order. That is at odds with the desired "outline is consistent and around everything" result when terminal/browser portals cover the stroke.

Relevant paths:

- `Sources/Theme/WorkspaceFrame.swift`
- `Sources/WorkspaceContentView.swift`
- `Sources/TerminalWindowPortal.swift`
- `Sources/BrowserWindowPortal.swift`

## Implementation Plan

1. Make the workspace sidebar background neutral.

   Remove workspace-color participation from `SidebarBackdrop`. The simplest behaviorally correct fix is to stop passing selected workspace color into the sidebar backdrop and make `chrome.sidebar.tintOverlay` neutral/disabled by default. Keep selected workspace card/rail coloring in `SidebarView.themedSidebarTabColors(...)`.

   Update:

   - `Sources/ContentView.swift`
   - `Sources/Theme/ThemeRoleRegistry.swift`
   - `Sources/Theme/C11muxTheme.swift`
   - `Resources/c11-themes/stage11.toml`
   - theme golden fixtures/snapshots that currently expect `chrome.sidebar.tintOverlay` to resolve to `#C0392B14`

2. Wire tab active indicator color through Bonsplit appearance.

   Add an optional active-indicator hex to Bonsplit appearance, preferably as a narrow generic seam such as `Appearance.ChromeColors.activeIndicatorHex` or a small sibling tab-bar style value. Update `TabItemView.tabBackground` to use the configured color when present, falling back to `Color.accentColor`.

   In c11, resolve `.tabBar_activeIndicator` in `Workspace.applyGhosttyChrome(...)` using the same `ThemeContext(workspaceColor: customColor, ...)` path and include it in the no-op guard so live color edits propagate.

   Update tests in `vendor/bonsplit/Tests/BonsplitTests` for the generic seam and add/adjust c11 tests around appearance resolution if there is a pure seam available.

3. Audit divider refresh and force visible refresh only where needed.

   First verify whether current `@Observable` nested configuration mutation is enough to invalidate `BonsplitView`. If not, assign a whole new `appearance` value instead of mutating nested fields one by one, or add a dedicated Bonsplit appearance update method that performs an observed property write.

   Keep the no-op guard, but extend it to every workspace-color-driven chrome axis:

   - tab bar background
   - divider/border color
   - divider thickness
   - active tab indicator

4. Fix portal chrome coverage.

   Do not solve this by drawing inside Ghostty cells or browser page content. The likely durable fix is a window-level chrome overlay above all portal-hosted content, or a shared divider/frame overlay used by both terminal and browser portals.

   Candidate implementation direction:

   - Extract/reuse the terminal `SplitDividerOverlayView` logic into shared AppKit chrome overlay code.
   - Install it in both terminal and browser portal host layers, or in a single window-level overlay that sits above both.
   - Include workspace-frame stroke rendering in that same above-portal layer, or reserve a content inset so the SwiftUI `WorkspaceFrame` stroke is never under WKWebView/Ghostty portal frames.
   - Ensure the overlay remains `hitTest == nil` and does not enter typing-latency-sensitive paths.

5. Validate with a tagged build and visual dogfood.

   Per repo policy, do not run local E2E/UI tests. For implementation validation:

   - Add focused unit tests for pure theme/appearance resolution.
   - Run `xcodebuild -scheme c11-unit` only if needed and safe; prefer CI.
   - Build via `./scripts/reload.sh --tag c11-8-workspace-color` before visual validation.
   - Visually check green -> yellow custom color change with terminal, browser, markdown, and split panes open.

## Acceptance Criteria

- Sidebar rail/background stays neutral for green, red, yellow, and custom hex workspace colors.
- Selected workspace card/rail still reflects the workspace color.
- Surface tab active indicator tracks live workspace color.
- Dividers and tab bar chrome update on custom color change without workspace switch/relaunch.
- Workspace outline/frame is continuous at the visible content boundary, including browser scrollbar edges.
- Terminal typing, divider dragging, browser scrolling, and tab dragging are unaffected.

## Open Questions

- Should `chrome.sidebar.tintOverlay` remain in the theme schema as a static theme overlay, or should it be deprecated because the sidebar is explicitly neutral space?
- Should the above-portal frame be a replacement for `WorkspaceFrame`, or should `WorkspaceFrame` remain the SwiftUI fallback when no portal content is mounted?
- If the Bonsplit active-indicator seam is generic enough, send/offer it upstream to `manaflow-ai/cmux`/Bonsplit lineage rather than keeping a c11-only divergence.
