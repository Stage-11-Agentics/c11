# C11-26 Implementation Plan — Tab Close UX

Author: `agent:c11-26-planner` (fast-track delegator, single session)
Date: 2026-05-15

## Goal

Deliver the agreed design in the ticket:

1. Anchor a small precise X (~14–16 px hit slot) on the **left** edge of each tab.
2. Always visible at rest, not hover-gated.
3. Title fills the remaining width and truncates on the right.
4. Right-click context menu has **exactly two items**: Close Tab, Close Pane.
5. ⌘W closes the focused tab (verify wiring; already present in c11).
6. Horizontal scroll behaviour on the tab strip is unchanged.

## Where the change lands

The tab strip we care about is rendered by **bonsplit** (`vendor/bonsplit/`), not by `Sources/ContentView.swift::TabItemView`. The latter is the workspace sidebar row; the bonsplit tab bar is the per-pane strip that exhibits the bug.

Files we will touch (worktree-relative paths):

- `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift`
  - Move the close button out of the trailing accessory; render it as a leading accessory ahead of the icon.
  - Always render the close X for closeable, non-pinned tabs (no hover gate). Inactive-text colour at rest, active on hover; same hover background circle as today.
  - Keep dirty / notification / pin / shortcut-hint in the trailing slot. Pin behaviour is unchanged on the right (it acts as a state indicator; pinned tabs still have no close X).
  - When `BonsplitConfiguration.simplifiedTabContextMenu` is true, render only Close Tab + Close Pane (with `closeTab` / `closePane` `TabContextAction` cases). Existing menu retained when the toggle is off — bonsplit example + future consumers stay intact (minimum-divergence-from-upstream principle from `c11/CLAUDE.md`).
- `vendor/bonsplit/Sources/Bonsplit/Public/Types/TabContextAction.swift`
  - Add `closeTab` and `closePane` cases. Sendable / CaseIterable already conform.
- `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitConfiguration.swift`
  - Add `simplifiedTabContextMenu: Bool = false` to `BonsplitConfiguration` (top-level behaviour, not `Appearance`; the change is behavioural).
- `Sources/Workspace.swift`
  - Handle the new `closeTab` / `closePane` cases in `splitTabBar(_:didRequestTabContextAction:for:inPane:)`. `closeTab` → existing per-surface close path. `closePane` → existing pane-close confirmation flow (`closeBonsplitPane(pane:reason:)` or equivalent, with the confirmation card).
  - Set `simplifiedTabContextMenu = true` in the c11-side `BonsplitConfiguration` construction.
- `vendor/bonsplit/Sources/Bonsplit/Resources/en.lproj/Localizable.strings`
  - Add `command.closeTab.title` = "Close Tab" and `command.closePane.title` = "Close Pane".
  - Other locales stay at their previous translations until the translator sub-agent runs (per project policy). bonsplit's existing fallback prints the English value if a key is missing in a locale, so this is safe.

`Resources/Localizable.xcstrings` (the c11 root catalog) is **not** touched — the menu strings live in bonsplit's own catalog because the view rendering them is in bonsplit.

## Specific layout decisions

- **Leading slot width:** 16 px (matches today's `accessorySlotSize` floor; the close icon at default `tabCloseIconSize=9` already centres in a 16 px slot).
- **Title truncation:** `Text(tab.title).lineLimit(1).truncationMode(.tail)` — keeps the existing "…" behaviour at the right edge. Title block becomes the flexible part of the HStack; `Spacer(minLength: 0)` is removed so the title can fill the row without pushing accessories to the right edge.
- **Pinned tabs:** no leading close X (consistent with today's "pinned = no close"). Pin indicator continues to render in the trailing slot as a state indicator. Leading slot collapses to zero so the icon stays where it would be on non-pinned tabs.
- **Inactive / unselected tabs:** the close X is rendered at rest for these too — this is the explicit user-facing change. At-rest colour follows `TabBarColors.inactiveText(for: appearance)` so it does not visually shout.
- **Tab content spacing:** the title-block uses the same `tabContentSpacing` as today; the leading close slot uses spacing 0 against the icon so it sits flush with the left edge of the tab.

## Degenerate-case decision — "Close Pane" on the only tab in the only pane

Use the **existing** workspace-level confirmation path, which already handles this case with the "Reset entire pane?" dialog: the pane is reset, a new fresh terminal replaces the only-tab. Rationale:

- The behaviour is already implemented, localised, and battle-tested.
- "Reset to fresh terminal" is the principle-of-least-surprise outcome: the user keeps the pane open (no window loss), the surface is replaced rather than blank.
- Closing the window on this case would be surprising (the right action would be ⌃⌘W → Close Window), and refusing to act on the menu item is worse UX than silently doing the reset.

No new code required for the degenerate case — it falls out of routing `closePane` into the existing `closeBonsplitPane`/`closeCurrentPanelWithConfirmation` flow used by the toolbar's pane-close button.

## ⌘W verification (no change expected)

⌘W is wired in `Sources/AppDelegate.swift` (`shortcut.cmdW` branch) and routes the event to either Ghostty (per-surface close path) or `tabManager?.closeCurrentPanelWithConfirmation()`. Both close the focused tab/surface inside the focused pane — the ticket's "close the focused tab" semantics. ⌘⇧W = close workspace and ⌃⌘W = close window are intentionally separate (CLAUDE.md note around `c11App.swift:457`). We verify visually during the build pass; no code change is planned here.

## Out of scope (per ticket)

Middle-click already exists upstream from bonsplit and is left alone (the ticket says "deliberately not adding", which we interpret as "do not add to the c11 spec," not "remove the inherited behaviour"). ⌘⇧W → close pane via keyboard, hover-reveal X, and overflow dropdown / tab compression are all deferred.

## Submodule discipline

- bonsplit commits land on the `Stage-11-Agentics/bonsplit` `main` branch (not the upstream `almonk/bonsplit`).
- We push the submodule branch before bumping the pointer in the c11 worktree, per `c11/CLAUDE.md` submodule-safety rule.
- The submodule pointer bump is its own commit on the feature branch.

## Validation plan

- `./scripts/reload.sh --tag c11-26` to build + launch a tagged variant (no untagged `c11 DEV.app`).
- Manual visual checks inside the tagged build:
  1. Open multiple tabs with long titles in a vertically-split workspace; confirm X is clickable on every tab regardless of scroll.
  2. Right-click a tab: see exactly Close Tab and Close Pane; click each; verify behaviour.
  3. Right-click the only tab in the only pane and pick Close Pane; confirm the reset-pane dialog appears.
  4. ⌘W with focus in a terminal pane: confirm the focused tab closes.
  5. Title still truncates with "…" on the right when long.
- Tests: no new unit tests (no observable behaviour outside the view layer to assert without an AppKit harness; `c11/CLAUDE.md`'s test-quality policy bars text-only fixtures). CI handles regressions.
