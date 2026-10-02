# C11-249 plan

## Approach
- In Sources/TabRailTipCenter.swift, keep the Undo explanation scoped to the front area that Try Rail actually opens. Track the previewed Slot and close only that pane's rail in performUndo before returning Tab Layout to Tabs. Update the existing undoBody call-site default and English catalog entry; C11-291 owns refreshed non-English translations.
- Route a count-cell tap in the active teaching offer through performShowList, so the same tab sheet opens and the offer returns with the existing after-list copy. Keep ordinary count-cell behavior unchanged outside that offer.
- In vendor/bonsplit at pinned commit c17c6f41, identify the reporting bar's anchor and clear it on disappearance only if that same reader still owns the controller's anchor. Keep the live anchor when a replaced bar disappears later.

## Acceptance and behavioral proof
All four defects are the post-merge C11-245 review findings from PR #474, reproduced in the cited current-main seams.
1. Undo copy: after overflow in a split workspace, Try Rail and confirm the copy describes the one area whose list opened. Verify the wording on the tagged UI.
2. Count-cell tap: with the tip visible, click its number; the area sheet opens. Close the sheet and confirm the same offer returns with the after-list explanation, without a new 30-day suppression. This exercises the existing count-cell action and offer lifecycle.
3. Undo persistence: Try Rail, Undo, then choose Rail later in Settings. The previously previewed area remains closed. This covers railOpenPaneIds, which Workspace session autosave persists.
4. Anchor replacement: cause a bar replacement while the tip is visible (switch Tabs/Rail and resize the area); capture before/after UI and confirm the popover follows the live count cell without a stale or empty anchor.

Run these scenarios on one Atlas tagged Debug build, tag c11-249, using the c11 computer-use sandbox. Elements and copy must not jump. No source-grep test is planned; these are observed UI lifecycle defects and require real pointer/layout behavior.

## Boundaries and risks
- Hot-path/threading impact: only the count-cell UI callback and TabRailTipCenter's main-actor state; no terminal input, focus routing, sidebar body, or socket telemetry changes.
- Persistence: clear the previewed pane's existing rail-open bit on Undo before mode restoration; no schema or migration change.
- Localization: existing key tabRailTip.undoBody only; change English at the localized call site and en catalog. Keep other locale entries for C11-291.
- Cut line: do not open rails in every area, change offer/dismissal timing, or alter general Tabs/Rail behavior.
- Decision: correct the Undo copy rather than opening every area's rail (recommended; smallest behavior change and matches performTryRail).
- Dependency: Bonsplit anchor fix must be committed and pushed to Stage-11's bonsplit main before updating the c11 submodule pointer. Push the ticket branch only at handoff.

## Reset 2026-10-02 by agent:luna-249
