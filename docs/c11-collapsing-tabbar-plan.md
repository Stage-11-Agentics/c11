# Collapsing tab dropdown (responsive tab bar)

## Problem

A pane's tab bar is one horizontal track shared by two things that compete for
the same pixels: the tabs (identity/navigation, needed constantly) and a
fixed-width action cluster of 8 buttons plus 2 separators (agent, terminal,
browser, markdown, split-right, split-down, new-tab, close-pane). The cluster is
roughly 240-300pt and never shrinks. In a 3-way split on a wide monitor each
pane is ~350-400pt, so the cluster eats nearly half the bar, the tabs collapse
to unreadable slivers ("Overwatch Daemon" → "Overwatch D"), and the tab becomes
a tiny, low-scent click target. There was no responsive behavior at all.

## Solution: a 3-tier responsive tab bar

As a pane narrows, the strip degrades in two independent steps. The tab list
folds away first; the controls fold away second.

| Tier | Trigger | Bar shows | Dropdown holds |
|------|---------|-----------|----------------|
| **Full** | all tabs + controls fit | every tab inline + full controls cluster (today's layout) | — |
| **Medium** | tabs don't all fit, but active title + controls do | active tab title + controls cluster inline + a prominent `N ⌄` disclosure | the tab list only |
| **Narrow** | not even title + controls fit | active tab title + `N ⌄` disclosure only | controls row (first), then the tab list |

The collapse order as a pane shrinks: `all-tabs-inline → tab-list-into-dropdown
(controls stay) → controls-also-into-dropdown`. Widening reverses it.

### Key behaviors

- **The whole header is the dropdown's hit target.** In Medium and Narrow, the
  active title, the empty run, and the `N ⌄` pill are one large tap region that
  toggles the dropdown. It is a high-traffic touch point, so the target is big.
- **Prominent disclosure.** This is a new interaction paradigm, so the `N ⌄`
  control is a filled, outlined pill carrying the tab count and a heavy chevron,
  with an activity dot when a background tab has unread/dirty state.
- **Full title legibility in the dropdown.** Each tab is a full-width row, no
  truncation in the common case, with a leading selection/activity marker and a
  per-row close. Rows are equal height for a square, chunky rhythm.
- **Drag is preserved.** Each dropdown tab row is a drag source (reorder within
  the pane or transfer to another pane), and the collapsed header is a drop
  target (a tab dragged from another pane appends here).
- **Hysteresis.** Tier boundaries use a directional dead-band: degrade promptly
  when space runs out, re-expand only past a slack margin, so dragging a divider
  near a boundary does not strobe between tiers.
- **Keyboard switching is unaffected** (Cmd+1-9, Ctrl+Tab) in every tier, which
  softens the extra click that the dropdown adds when narrow.

## Where it lives

Entirely inside the c11-forked bonsplit `TabBarView`
(`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`). The action
cluster is already a c11 addition to the fork, so no upstream-merge cost. No c11
`Sources/` changes. The only new strings are SF Symbols plus bonsplit-style
plain accessibility labels, so no `Localizable.xcstrings` churn.

The mode decision is geometry-driven (an outer `GeometryReader` width plus
measured/estimated chrome and title widths) and runs on width/tab-set changes,
never on the keystroke path.

## Validation

Built tagged (`reload.sh --tag tabdrop`) and exercised through all three tiers
by resizing the window and splitting panes, confirming: Full shows all tabs +
controls; Medium shows title + controls + `N ⌄`; Narrow shows title + `N ⌄`
only; the Narrow dropdown renders the controls row then the equal-height tab
rows with the selected row marked; single short-title panes stay Full until the
controls genuinely no longer fit.

## Status & how to resume (handoff)

**Branch / worktree / PR.** Work lives on `feat/collapsing-tab-dropdown` in the
worktree `code/c11-worktrees/collapsing-tab-dropdown`, off `origin/main`. Open
as **PR #266** (`Stage-11-Agentics/c11`). The `vendor/bonsplit` submodule
changes are on bonsplit's own `feat/collapsing-tab-dropdown` branch (pushed);
the parent pointer references the latest bonsplit commit on that branch — NOT
bonsplit `main`. Everything is committed and pushed; nothing uncommitted.

**Done and review-ready:**
- 3-tier responsive tab bar (Full → Medium → Narrow) with directional hysteresis.
- Whole collapsed header is one bordered, hover-brightening chip (title + count +
  chevron); the entire header is the tap target; the dropdown anchors under it.
- Dropdown: controls row (Narrow) / tab-list-only (Medium); equal-height rows;
  each row is a drag source; collapsed header is a drop target.
- Full-width gold focus accent line in collapsed mode.
- Tighter collapse so the controls stay inline in a narrower pane (decision floor
  68pt; short titles only — long titles collapse on real width).
- Tool-button tooltips fixed: `SplitToolbarButton` uses native `.help`, and
  bonsplit's `safeHelp` now delegates to `.help` (was an occluded-view no-op).

**Open / needs a human with a real mouse (automation could not confirm these):**
1. **Click + tooltip verification.** Synthetic cursor moves drive SwiftUI's
   hover highlight but NOT macOS's tooltip timer, and the tagged window kept
   relocating across displays, so coordinate-based click tests were unreliable.
   The tap is the structure proven earlier (fix3d capture opened the dropdown
   from a title click); the tooltips use the same `.help` path the rest of c11
   uses. Confirm by hand on the tagged build: click a collapsed header's title
   opens the dropdown; hover a tool button shows its tooltip (normal bar AND
   dropdown).
2. **Submodule branch → main.** On merge, fold bonsplit's
   `feat/collapsing-tab-dropdown` into bonsplit `main` and (if the SHA changes)
   re-point `vendor/bonsplit` before/with the c11 merge.

**Tagged build for testing:** `./scripts/reload.sh --tag tabdrop` then launch.
The debug bundle's launch "Resume previous session?" prompt is disabled via
`defaults write com.stage11.c11.debug c11.launch.resumePolicy never`. Cleanup:
`pkill -f "c11 DEV tabdrop.app/Contents/MacOS/c11"`.

**To resume work:** `cd code/c11-worktrees/collapsing-tab-dropdown`; edits go in
`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift` (the whole
feature is there — no c11 `Sources/` changes). Fast loop: `cd vendor/bonsplit &&
swift build` to compile-check bonsplit, then `./scripts/reload.sh --tag tabdrop`
for the app. Submodule discipline: commit + push bonsplit's branch BEFORE
committing the parent pointer.
