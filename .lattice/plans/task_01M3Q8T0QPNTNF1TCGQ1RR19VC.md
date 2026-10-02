# C11-240: c11: New Workspace picker: no scroll on click, double-click creates, pins row, search, denser recents

New Workspace sheet (Sources/CreateWorkspaceSheet.swift): make the recent-directory picker the fast path. Atin's words: "a really core part of the workflow... bump it up a notch."

DESIGN IS PENDING ATIN'S PROTOTYPE FEEDBACK. Do not start until this line is replaced by "Prototype approved".
Prototype (real recents, local only, never commit it to this public repo): /private/tmp/claude-501/-Users-atin-Projects-Stage11-code-overwatch/fd4968b2-46ae-44b9-bfb9-e30b29645592/scratchpad/prototype.html

Root causes found
1. Auto-center on click. selectRecent sets keyboardSelectedRecentIdx; recentsList's onChange then runs proxy.scrollTo(id, anchor: .center) on every change, clicks included.
2. Double-click is already wired (TapGesture count 2 + simultaneous count 1), but the first click recenters the list, so the second click lands on whatever row slid under the cursor. Fixing 1 is most of the fix for 2. Verify that a double-click creates the workspace for the row that was clicked, with the list scrolled to its middle.
3. The recents list caps at 50 (CreateWorkspaceRecents.maxCount) and is full today. save() keeps prefix(maxCount) of an unsorted list, so the cap can evict a pinned entry or a recent one instead of the oldest.

Spec (subject to prototype feedback)
- A click selects and fills the path field; it never scrolls. Keyboard ↑↓ scrolls only enough to keep the selection visible (no .center anchor; nil or nearest behavior).
- Double-click on a recent row or a pin chip creates the workspace immediately with the selected layout.
- Pins move out of the list into a horizontal row of chips above it (★ name, a ⌘1–⌘9 badge, × on hover in the badge's slot so the width holds, drag to reorder, empty state "Star a recent directory to pin it here"). Pinned dirs are not repeated in the list except in search results. Pin order is user order: persist it (e.g. a pinnedOrder field or a separate key). Migrate existing pins.
- ⌘1–⌘9 creates a workspace from pin N.
- A search field sits above the list beside the sort control. It has focus when the sheet opens, and typing anywhere outside a text field goes to it. The field shows "N of M". Matching: a subsequence within the directory name scores highest (prefix and word-boundary bonuses); elsewhere in the path only a contiguous substring counts. Results rank by score, and the sort control is disabled while a query is active. The top hit is auto-selected so ⏎ opens it. ↑↓ move the selection while focus stays in the search field. Esc clears a non-empty query; Esc on an empty query cancels the sheet as today. Matched characters are highlighted in gold. There is an explicit no-match state.
- Denser rows: one line, 28 pt: name (13 medium), parent path (11 mono, dim, truncated), relative time (fixed width, tabular), ×count (fixed width), and a pin star in a reserved slot so nothing shifts on hover. About 12 rows are visible where about 6 are today. The sheet grows to about 1030 pt, so on a short screen the list, not the sheet, must give up height.
- Evict the oldest unpinned entry at the cap and never a pinned one; raise maxCount (proposal: 200) now that search makes a long tail useful.
- Footer hint: "Click selects · double-click or ⏎ creates · ↑↓ move · ⌘1–⌘9 open a pin".

Acceptance
- Unit tests for the recents model: eviction never drops a pin, pin order persists and migrates, fuzzy ranking on a fixed fixture.
- Real-app validation through the c11-computer-use skill on a tagged Debug build: click a row mid-list (no scroll), double-click (creates that row's dir), ⌘N then type then ⏎, ⌘2, pin/unpin/reorder, the no-match state, a short window.
- Localized strings go through String(localized:) as today.
