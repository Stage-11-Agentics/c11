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
