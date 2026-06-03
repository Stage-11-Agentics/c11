# C11-26: Tab close UX: anchor X on left, add right-click Close Tab / Close Panel

Make closing a tab trivial regardless of tab strip scroll position, title length, or how many vertical splits crowd the pane.

## Problem

The current close affordance is an X anchored at the right edge of each tab. Two failure modes compound:

1. **Hit-target collision at the pane boundary.** When the X sits flush against a pane separator (especially with vertical splits crowding the strip), it 'fades out behind the tab bar menu items' — clicks land on the separator/adjacent pane's toolbar instead of the X. Visible, but unclickable.
2. **Scroll-dependent close.** Long titles push the X past the visible clip boundary. Reaching it requires horizontal scroll, which mouse-wheel-only users (single vertical axis) cannot perform.

Repro: open enough tabs with long titles in a pane that's vertically split against another pane. Try to close a tab whose X visually sits at the pane boundary. Click does nothing.

## Design (agreed)

- **Close button:** anchor a small precise X on the **left** edge of each tab (~14–16px hit target). The rest of the tab remains the switch-to hit region. X visible at rest, not hover-only. This matches the native macOS Cocoa tab convention (Finder, Terminal.app, Notes) and structurally sidesteps the right-edge hit-collision bug — the left side of a tab has no adjacent controls.
- **Title:** fills the remaining width and truncates with '…' on the right when needed. The X is never the thing that gets clipped.
- **Right-click context menu** — intentionally minimal, two items:
  - Close Tab
  - Close Panel
  No 'Close Others' or 'Close to the Right'. Two clear concepts is better user education than four.
- **Keyboard:** ⌘W closes the focused tab. Verify it's already wired; add if not.
- **Tab strip overflow:** keep horizontal scroll as-is. With the left-anchored X, scroll is only ever for *finding* a tab, never for *closing* one.

## Explicitly deferred / out of scope

- Middle-click to close (deliberately not adding; revisit if users ask)
- ⌘⇧W to close panel via keyboard (deliberately deferred)
- Hover-reveal X (rejected — discoverability cost)
- Overflow dropdown / tab compression (rejected — current scroll is fine once close is decoupled from layout)

## Implementation notes / decisions to make at build time

- **'Close Panel' degenerate case:** when the panel contains the only tab of the only pane, what does 'Close Panel' do? Close the window? Refuse? Collapse to neighbor? Worth a 30-second decision when implementing.
- **Verify ⌘W:** check existing keyboard map before adding; this likely exists already and just needs documentation if so.
- **X hit zone tuning:** target ~14–16px. The goal is 'has to be aimed for' so users clicking 'on' a tab to switch don't accidentally close it.

## Context

Captured from a dialogue with @atin on 2026-05-15. Triggered by a real instance where the X next to 'Percepta Builds a…' in a vertically-split pane was visible but unclickable.
