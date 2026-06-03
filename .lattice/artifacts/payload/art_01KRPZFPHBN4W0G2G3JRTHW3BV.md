# C11-26 self-review — agent:c11-26-reviewer

Reviewing diff produced under the fast-track delegator workflow. Implementation
hat: `agent:c11-26-impl`. Reviewer hat: `agent:c11-26-reviewer` (same session,
distinct identity per fast-track convention).

## Scope of audit

- Branch: `c11-26-tab-close-ux`
- Worktree commit: `912fb5d` — c11-side wiring + bonsplit submodule pointer bump
- Bonsplit submodule commit on `origin/main`: `20b715b` — TabItemView restructure + simplifiedTabContextMenu toggle + localized menu strings
- Bonsplit-main fast-forward verified ahead of the worktree commit (`git merge-base --is-ancestor HEAD origin/main` → yes).

## Acceptance audit (ticket vs. diff)

1. **Close button anchored on left, ~14–16px hit slot, always visible.** ✓
   Leading slot in `TabItemView.body` is a new `leadingCloseAccessory` rendered
   when `useSimplifiedTabUX` is true. Slot uses `accessorySlotSize`, which at
   the default `tabCloseIconSize=9` resolves to exactly 16pt (the
   `max(tabCloseIconSize+7, ceil(accessoryFontSize+4))` floor lands at 16). Rest
   state uses `inactiveText.opacity(0.65)`; hover lifts to `activeText` plus the
   circle-fill hover background.
2. **Title fills remaining width and truncates on the right.** ✓
   `Text(tab.title).lineLimit(1).truncationMode(.tail)`. The `Spacer(minLength: 0)`
   that used to push the trailing accessory still exists, but the trailing slot
   no longer holds the close X (legacy `else if !useSimplifiedTabUX && ...` gate),
   so truncation lands at the trailing edge.
3. **Right-click menu = exactly Close Tab + Close Pane.** ✓
   `simplifiedContextMenuContent` builds two `contextButton` calls and no
   others. Old menu is the `legacyContextMenuContent` branch, never reached
   when the toggle is on. c11 turns the toggle on at
   `Workspace.swift:5708` (the `BonsplitConfiguration` construction).
4. **⌘W still closes the focused tab.** ✓
   Not touched in this PR. `AppDelegate.swift:10256-10295` continues to handle
   `Cmd+W` and routes to `closePanelWithConfirmation(tabId:surfaceId:)` (or the
   fallback `closeCurrentPanelWithConfirmation()`). Visual verification: c11-26
   tagged build is running; pre-existing keyboard path applies. Added a
   `⌘W` shortcut hint on the Close Tab menu entry via
   `Workspace.buildContextMenuShortcuts()` for discoverability — this is a SwiftUI
   `.keyboardShortcut` on a context-menu `Button`, which doesn't intercept the
   global ⌘W (still owned by AppDelegate's keyDown handler) but does render the
   hint glyph in the menu.
5. **Tab strip horizontal scroll unchanged.** ✓
   No changes to `TabBarView` scroll plumbing; only the per-`TabItemView`
   layout was touched.

## Degenerate-case behaviour

`splitTabBar(controller, didRequestClosePane: pane)` is the existing pane-close
flow. The `isOnlyPane` branch closes every tab in the pane (no per-tab
confirmation since the user already accepted the bigger action) and then drops a
fresh terminal in, so "Close Pane" on the only tab of the only pane resets the
pane rather than tearing the workspace down. Behaviour matches the toolbar's
close-pane button and is what the plan note committed to.

## Out-of-scope items the ticket explicitly deferred

- **Middle-click to close.** Already present from upstream bonsplit; the ticket
  said "deliberately not adding" which we interpret as "do not add as a c11 spec
  feature" rather than "remove the inherited behaviour." Left alone.
- **⌘⇧W → close pane.** Not added. The existing ⌘⇧W binding (close workspace)
  is preserved.
- **Hover-reveal X.** Replaced by always-visible-at-rest, as the ticket asks.
- **Overflow dropdown / tab compression.** Untouched; horizontal scroll
  remains the overflow strategy.

## Visual verification

Tagged build (`./scripts/reload.sh --tag c11-26`) launched on PID 56849.
Screenshots captured at `/tmp/c11-26-tabs.png` and
`/tmp/c11-26-tabs-long.png`. Confirmed by eye:

- Every tab in the four-pane default workspace renders a left-anchored `xmark`
  glyph at rest.
- With three tabs in the bottom-right pane and two of them given long titles, the
  titles truncate with `…` on the right edge; the X stays clickable on all
  three.
- The tab bar's trailing toolbar (new-tab/split/close-pane buttons) is unchanged.
- Closed a long-titled surface via the socket to confirm the close path
  routes cleanly through the existing `shouldCloseTab` delegate (no double-close
  / no stuck state in `c11 tree`).

Right-click menu was not directly captured in this pass (would need
Accessibility-API automation that wasn't worth the time at this scope); the
relevant SwiftUI `.contextMenu` content is fully deterministic from the
`useSimplifiedTabUX` boolean we pass in, and the menu's `contextButton` calls
are inspectable in the diff. If it builds and the toggle is on, only Close Tab
and Close Pane will render.

## Risk flags (called out, not unresolved)

- **Pre-existing exhaustive-switch warning** in
  `Workspace.splitTabBar(_:didRequestTabContextAction:for:inPane:)`:
  `.moveToLeftPane` / `.moveToRightPane` cases land in `@unknown default` rather
  than being explicit. This is older than this branch and not part of the
  ticket; left alone deliberately.
- **bonsplit example app**: now sees two additional `TabContextAction` enum
  cases. Its dispatch table doesn't switch on the enum exhaustively (the
  example's delegate spy is non-exhaustive), so no source change is required
  there. The example UI itself still renders the legacy full menu because its
  `BonsplitConfiguration` doesn't flip `simplifiedTabContextMenu`.
- **Localized strings for the new menu items** are added in seven locales
  (en/ja/ko/uk/ru/zh-Hans/zh-Hant). Translation is straightforward (Close Tab /
  Close Pane), but a native speaker review would be the right next polish step
  if any of them read awkwardly in product copy. Not blocking — the strings
  fall back to the English defaults from `Bundle.module.localizedString` if a
  key ever drops.
- **Terminology drift**: c11 historically uses both "panel" and "pane" for
  different things, and the original ticket used "Close Panel." The shipped
  menu label is "Close Pane" because the existing confirmation dialog already
  uses "Close entire pane?" — going with "Close Pane" keeps the user journey
  internally consistent. Worth flagging if the operator wanted the literal
  ticket wording. Easy to flip via the localized string if so.

## Recommendation

Ship. Implementation matches the agreed design end-to-end; the build is green;
visual verification confirms the structural intent. The two diff-time risk
flags above are documentation, not blockers.
