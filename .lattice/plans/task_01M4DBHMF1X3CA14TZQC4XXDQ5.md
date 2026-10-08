# C11-360 reader chrome implementation plan

## Architecture and boundaries

- Native SwiftUI owns the toolbar row: outline toggle and pressed/label state, file and heading breadcrumb, progress readout and gold hairline, fixed right cluster, and find/source/scale/theme/typeface/external actions. The toolbar remains available before renderer readiness and after renderer failure.
- `Resources/markdown-viewer/` renders the outline in the page. R1 already owns the effective-width threshold, dock gutter, scrollspy, scale, theme/typeface tokens, and `State.outline.tree`. The page uses those values directly for blur, typography, task counts, filtering, click-to-jump, and the 120 ms dock/overlay crossfade. Native sends `setSettings({outlineOpen})` from the persisted R2 setting. Page Escape sends the fixed `outlineDismiss` event; native persists `false` through the same model setter. No second heading-tree renderer or per-frame outline bridge is added.
- Find stays in the native bar. Native Cmd-F opens it and focuses its field only through the focused Markdown panel's normal action path. `MarkdownWKWebView.allowsPanelFocus` remains the gate for WebKit focus; outline input gets focus from the operator clicking it, never from a background update.
- The renderer's native readout/find/outline models stay sliced. Outline publishes only revision/open/docked/choice; the page keeps its tree and current row. Model setters reuse R2 persistence and synchronization. Open externally resolves and opens only the current Markdown file's registered default app.

## Files and cut line

- Native: `Sources/Panels/MarkdownPanelView.swift`, `MarkdownPanel.swift`, `MarkdownWebRenderer.swift`, `WorkspaceManager.swift`, `AppDelegate.swift`.
- Page and contract: `Resources/markdown-viewer/index.html`, `viewer.css`, `viewer.js`, `BRIDGE.md`, `README.md`, `scripts/markdown-viewer/test.mjs`.
- Copy and operator workflow: `Resources/Localizable.xcstrings`, `skills/c11-markdown/SKILL.md`.
- No persistence schema, tenant configuration, other panel chrome, renderer API beyond the one documented Escape event, or release behavior changes.

## Acceptance to proof

- Docked versus overlay: harness computes the R1 threshold from active CSS metrics, asserts overlay just below and docked at/above it, and verifies the dock gutter remains reserved while closed.
- Filter/tree/task counts: harness checks matching rows, ancestor context, empty results, task totals, and active scrollspy row.
- Click-to-jump and Escape: harness clicks a filtered outline row, checks the page scroller reaches the heading and outline stays open, then presses Escape and checks the page closes and posts `outlineDismiss`.
- Anchor stability: at docked and overlay widths, capture a real text-row viewport position and assert open and close preserve it. Existing settings-anchor coverage continues across narrow/medium/wide and scale/theme/typeface/source changes.
- Native chrome and shortcuts: parse/build, then Atlas tagged app and sandbox proof at ~560 px and wide; exercise toolbar/menu and keyboard theme/typeface/size/source/find/outline paths, fixed right controls, accessible pressed label, restored explicit choice, and external-app tooltip/action.
- Localization: all new visible/accessibility/page strings have English plus ja, uk, ko, zh-Hans, zh-Hant and ru entries; validate catalog JSON and placeholder parity.

## Runtime and persistence notes

Page scroll state and dock geometry remain page-owned; no native scroll restore is added for ordinary settings changes. R2 persists the explicit outline choice per panel/last-used state. The page reports only a user Escape dismissal so native can save `false`. Scrollspy changes update only the compact outline snapshot and toolbar readout; the native side does not parse the full outline tree. No typing hot path, blocking call, or app-level polling is introduced.

## Reset 2026-10-08 by agent:codex-md-r3
