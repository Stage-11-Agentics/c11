# C11-18: Ghostty surface duplicated/overdraws above pane bounds during portal sync

## Symptoms
A Ghostty terminal surface is occasionally drawn TWICE — once at its proper pane location and once shifted upward, with the duplicate's top edge extending above the workspace title bar / out of the workspace's visible area. The duplicate is not interactive (the user only interacts with the lower copy). Caught visually 2026-04-26 in tagged build `c11 DEV pane-close-overlay` after a sequence of split + close + reset operations on the only-pane reset path.

Two screenshots attached in the originating chat — one showing the workspace with the spurious copy bleeding above the chrome, one showing the same state with the menubar visible.

## Reproducibility
- Rare. Operator has seen "a few other versions of this" historically; was able to catch it this time but does not have steady repro steps.
- Suspicion: portal sync race during rapid pane structural changes (split → close → reset → terminal-respawn). The new pane-close overlay flow probably exercises this race more frequently than the old NSAlert path because the reset action both closes every tab AND immediately spawns a new terminal in the same pane within one frame.

## Where to look (priors)
1. `WindowTerminalPortal` (`Sources/TerminalWindowPortal.swift`) — the host that reparents `GhosttySurfaceScrollView` instances into the central window-level layer. Suspect candidates:
   - `entriesByHostedId` / `hostedByAnchorId` may end up holding two entries for the same panel during a rapid detach/reattach if the portal sync runs before the old anchor is fully torn down.
   - `synchronizeAllHostedViews(excluding:)` and `synchronizeHostFrameToReference()` may compute a stale frame for one entry while the new one is mid-install.
   - `transientRecoveryRetriesRemaining` retry budget could re-mount a previously-detached scroll view at a stale frame.
2. `attachPaneInteraction` / portal mounting interactions in `GhosttyTerminalView.swift` — when the new terminal spawns via `newTerminalSurface(inPane:)` immediately after `forceCloseTabIds.insert(...)` + `closeTab`, the old scroll view may not have been removed from the portal entry map by the time the new one registers.
3. SwiftUI `.transaction { tx in tx.disablesAnimations = true }` in `PaneContainerView.contentArea` — animations are disabled for tab moves but not necessarily for 'all tabs replaced in one frame.' A residual animation transaction could leave the old view rendered for one extra frame at a moved-up frame.

## Suggested investigation paths
1. Add a portal-state-dump log on every close + spawn (entry count, anchor identifiers, frames) and reproduce by scripting rapid reset-pane cycles via the c11 socket.
2. Try inserting a one-frame yield (`DispatchQueue.main.async`) between the bulk tab close and the `newTerminalSurface` call in the only-pane branch of `splitTabBar(_:didRequestClosePane:)` — if the race disappears, the real fix is making the portal idempotent under same-frame churn, not adding an artificial yield.
3. Audit `WindowTerminalPortal.detachEntry` (or equivalent) — confirm the entry map is purged synchronously, not lazily on the next sync pass.
4. Inspect `transientRecoveryEnabled` paths — disable temporarily to see if the duplicate goes away.

## Severity rationale
- Visual only (no data loss, no crash).
- Pre-existing per operator's account; the new pane-reset flow likely makes it more reachable.
- Distracting and erodes trust; not blocking.

## Out of scope
This is NOT caused by the pane-close overlay PR (#81). The portal-layering / multi-mount issue predates that work. The reset flow may make repro easier — useful signal for the investigation but not a fix target for that PR.
