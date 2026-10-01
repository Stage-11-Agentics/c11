# Tab bar round five: worker brief

Worktree `/Users/atin/Projects/Stage11/code/c11/c11-worktrees/tab-bar-round-five`, branch `tab-bar-round-five`, stacked on `tab-sheet-grid` (c11 #462 + bonsplit #6, reviewed, not merged yet). Run `git submodule update --init --recursive`, then branch bonsplit `tab-bar-round-five` from `6328254`. Open new PRs based on `tab-sheet-grid` in both repos. Parent: Cairn at `surface:159` / `workspace:14`. Report at each phase change, on blockers, and at the end. Do not merge.

**Binding design:** `design/tab-bar-qol/prototype-v5.html`. Copy it into this worktree from `../tab-sheet-grid/design/tab-bar-qol/` if it isn't here yet. Serve it and drive it: the area-width slider, the count cell, and hovering rows and tabs. Atin's words: tabs should stay visible more often; the sheet was too big in a small window and a touch too black; the black count button was too prominent; the list and the horizontal tabs need a clear relationship; the motion should be very fast, cognitively and on the CPU.

## Phase 1: tabs, drawer, relationship, palette (one PR pair)

1. **Tabs stay visible longer.**
   - When tabs overflow, the strip scrolls horizontally instead of folding into the solid block.
   - It collapses to the block only when fewer than about 150pt remain for tabs after the count cell and controls. That replaces today's medium tier; keep the narrow tier's behaviour.
   - Keep the selected tab scrolled into view. Show edge fades when more tabs exist off either side.
   - Scroll input:
     - Trackpad horizontal scroll over the strip scrolls it, as it already did.
     - A vertical wheel or two-finger vertical scroll over the strip also scrolls it sideways. Atin remapped horizontal swipes, so this path matters.
     - While a tab is dragged near either end of the strip, the strip auto-scrolls. The ghost slot keeps working throughout, with no strip jumps (reuse the round-one guard against scrolling mid-drag, which only lets drag-driven scroll through).
   - The count cell stays on every bar.
2. **The drawer belongs to its area.**
   - The sheet is exactly the area's width: flush under the bar, left and right edges aligned with the area, never overhanging a neighbour.
   - An area narrower than 320pt still gets a 320pt sheet, anchored left and clamped to the screen.
   - Columns drop by width tier, fixed within each tier:
     - ≥820: everything.
     - 600–819: the first clock only.
     - 440–599: the agent tag moves to line 2 as `Harness · model ·` before the subtitle, and the clocks go.
     - <440: Tab N (56pt), mark, title and status.
   - A resize across a tier boundary while the sheet is open relays the sheet immediately.
3. **Linked hover.**
   - Hovering a row lights its tab in the strip: a lighter background plus a 2pt white underline, as in the prototype. If that tab is scrolled out of view, scroll it into view without animation jank.
   - Hovering a tab while the sheet is open lights its row.
   - In a collapsed bar, hovering the active row lights the block.
4. **Shared vocabulary.** Horizontal tabs show their number in the same monospace as the sheet's `Tab N`, gold on the selected tab. This replaces the `N: ` title prefix when "Show Surface IDs in Tab Titles" is on. Keep that setting as the switch; if it's off, show no number.
5. **Fast unveil.**
   - On open, each visible tab's rendering moves from its strip frame into its row frame, and the rows fade in. Close reverses it.
   - About 140ms, transforms and opacity only: layer-backed snapshots or CA animations, no per-frame SwiftUI layout.
   - Respect Reduce Motion (skip it entirely).
   - A tab not currently in the strip unveils from the count cell.
   - It must never delay input: a click on a row mid-animation still works.
6. **Palette steps back.**
   - The count cell uses the bar colour family (prototype `#2f3138`, dim text, hover lifts), gold only while open.
   - The collapsed block is `#34363e` (hover `#3c3e47`).
   - Sheet tokens: bg `#1d1e23`, hover `#282a31`, active `#25272d`, head/foot `#191a1e`, separators `#2c2e34`, border `#4a4c55`.
   - Derive the light-theme equivalents the same way round three did.

## Phase 2: the rail (same PRs, after phase 1 is validated)

A setting, **Tab layout: Tabs (default) | Rail**, stored where c11 keeps comparable settings, exposed in Settings, and changeable by an agent in one command (document it in `skills/c11/SKILL.md`). In Rail mode:

- The count cell toggles a vertical tab list docked on the area's left edge, inside the area. It pushes the content over rather than overlaying it.
- Width: about 38% of the area, clamped to 200–300pt.
- While the rail shows, the bar shows `Tab N · title` of the selected tab plus the count cell (gold) and the controls. The horizontal strip is hidden, because the rail replaces it.
- Rows: mark, title, and status with its duration on line 2, `Tab N` at the right; the selected row has the gold rule. Rows scroll vertically. Drag and drop works: reorder inside the rail, and drag out to other areas' strips or rails.
- **Animate the reveal inside the area** (about 160ms, transforms only), so it's obvious the list is the area's tabs turned sideways. Respect Reduce Motion.
- Remember rail open/closed per area across relaunch.

## Rules (unchanged from round three)

- Localize every new string in all 7 locales in the same commit.
- Builds go through the lock and run incrementally. Run targeted tests only. Another builder (`tab-agent-signals`) shares the lock.
- **No synthesized drags, no app activation, no focus stealing.** Use your debug socket seam and `screencapture -l`. Add debug seams where needed, `#if DEBUG` like `debug.tab_sheet.open`: for example, set the strip scroll offset, set hover, set area width. Atin does drag checks by hand from your numbered script.
- Screenshots in both themes: a small window (560pt area) with the strip scrolled and fades showing; the drawer at 340/560/820/1120 widths; linked hover in both directions; the rail open in a small and a large area. Include a short frame sequence of the unveil if you can capture one cheaply.
- Commit and PR attribution as before.
