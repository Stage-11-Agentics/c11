# Owner brief: C11-360 (R3, reader chrome)

- Ticket **C11-360** (`lattice show C11-360`; parent C11-336). Actor `agent:codex-md-r3`. Panel title `R3 Reader Chrome`.
- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/md-r3-chrome`, branch `md-viewer/C11-360-reader-chrome`.
- Depends on C11-358 (web bundle + bridge) and C11-359 (native WKWebView panel + state model). Starts on GO after both merge.

## What you build
The ticket description: the toolbar row (outline toggle, file › heading-path breadcrumb, progress readout and gold hairline, the fixed-width right cluster of find, source, text size, theme+typeface menu, open externally), the outline panel behaviour (docked vs overlay by effective width, translucent, ~120 ms crossfade, scrollspy, subheadings, task counts, filter, ⇧⌘O, persisted explicit choice), find (⌘F) and the source toggle, all driving R1's engine through the bridge and R2's state model. The toolbar is native SwiftUI, matching the browser panel's address row and buttons (`openInExternalBrowserButton`, `browserThemeModeButton` in `Sources/Panels/BrowserPanelView.swift`). Whether the outline panel and find bar render natively or in the web view is your call: pick what reproduces the prototype most faithfully (backdrop blur, no layout jump) and say why in the plan. Reproduce the round-4 prototype's chrome pixel-faithfully at ~560 px and wide, in all three themes. Localize every string and do the six-locale pass.

## Proof
Atlas tagged build (`--tag md-360`), computer use: screenshots side by side with the prototype at ~560 px and wide, each theme and typeface, size by keyboard (⌘= ⌘− ⌘0) and toolbar, outline docked and overlay, ⇧⌘O, find with count and next/prev, source toggle keeping place, open externally (tooltip names the app).

## Review track
Normal: Review 1 Claude Opus, Review 2 Grok.
