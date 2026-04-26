# C11-19: Pane X button still unresponsive on some panes after click-passthrough fix

## Summary
After PR #81's `.overlay → .background` fix in `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift`, the per-pane and per-tab × buttons respond on most panes again — but in dense / deeply-split workspaces a subset of panes still swallow the click.

## Reproducibility
- Operator confirmed (2026-04-26, tagged build `c11 DEV pane-close-overlay`): "It worked on a lot of them, but now some of them don't quite work." No exact pattern yet — manifests in workspaces with many splits and several stacked panes (cf. screenshot in the originating chat showing a 3-column layout with a vertical stack on the right).
- The "good" panes show the confirmation overlay correctly. The "bad" panes never fire `splitTabBar(_:didRequestClosePane:)` at all (consistent with the earlier diagnosis that clicks aren't reaching the X button).

## Why this is residual, not a new break
Before PR #81 there was no `paneOverlayBuilder` env value at all, so this code path never existed. The `.overlay` → `.background` switch fixed the systemic case. The remaining failures are likely pane-specific layout quirks that interact with the SwiftUI `.background` hosting (e.g. NSViewRepresentable in a `.background` slot inside a deeply nested NSSplitView arranged subview).

## Where to look
1. `vendor/bonsplit/Sources/Bonsplit/Internal/Views/PaneContainerView.swift` — the `.background { paneOverlayBuilder(pane.id) }` block. Confirm `.allowsHitTesting(false)` is honoured on every pane (try logging hit-test rejections from the AnchorView).
2. `Sources/Panels/PaneInteractionOverlayHostView.swift` — `AnchorView.hitTest` returns `nil`. Verify it's actually being asked (add a counter, click on a "bad" pane's X, see if `hitTest` was even invoked).
3. `Sources/Panels/PaneCloseOverlayController.swift` — verify `synchronize()` is NOT mounting an idle host on the bad panes (idle hosts have `isHidden=true` and pass through, but if a stale entry persists with `isHidden=false` and a wrong frame, it could capture clicks). Add an assert: when `runtime.active.isEmpty`, `hosts` should be empty too.
4. The `WindowTerminalPortal` host also lives at the themeFrame level. If a pane's portal entry is positioned over the tab bar area (related to the pre-existing C11-18 overdraw bug), it could intercept tab-bar clicks even without our overlay being involved. Worth ruling out by temporarily disabling the pane-close runtime entirely and checking whether the bad panes' X buttons start working again.

## Investigation suggestions
1. **Bisect by feature**: temporarily set `paneCloseInteractionRuntime` to a no-op runtime (drop the env-builder injection in `WorkspaceContentView`). If the bad panes' Xs work again, the issue is in our overlay path. If they still don't, the issue is upstream of our changes (likely portal-related, see C11-18).
2. **Click-event diagnostics**: instrument `AnchorView.hitTest` and `PaneInteractionOverlayHost.hitTest` with NSLog to record which view absorbed the click on a bad pane. The result will name the offending view directly.
3. **Audit other `.background`-hosted NSViewRepresentables in PaneContainerView's subtree**: `PaneDropInteractionContainer` adds a couple of `.overlay { Color.clear ... }` layers for drop-zone routing that gate on `isTabDragActive`. Confirm those gates are correctly false in the failing case.
4. **Frame-tracking lifecycle**: the AnchorView pushes its window-coord frame on `setFrameOrigin/Size/viewDidMoveToWindow/viewDidEndLiveResize`. If a pane's anchor never moves to a window (transient layout state, e.g. during pane reparenting), the controller's anchor cache could hold a stale frame. Not directly tied to clicks, but worth verifying.

## Severity rationale
- **High** because the X is a primary affordance the operator reaches for; partial unresponsiveness erodes trust faster than total unresponsiveness.
- Workaround: focus the offending pane and use the keyboard/menu close path (if exposed), or move tabs to another pane and let it auto-close.

## Linked work
- PR #81 — Pane-close confirmation overlay (where the regression originated and was partially fixed). Operator chose to merge with this known residual rather than block.
- C11-18 — Ghostty surface duplicated/overdraws above pane bounds during portal sync. Possibly related (portal layer can shadow tab-bar regions in deep splits).
