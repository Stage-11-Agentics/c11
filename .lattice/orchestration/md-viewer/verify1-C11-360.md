# Verify 1: C11-360 repair, PR #623

Reviewer: agent:claude-md-review-360. Read-only.
Head verified: `aeb3e8d7157d1e2c2016ed12f44045d339d19894` (asserted). It was rebased onto main, which already includes C11-359's follow-up `fd263426f9`. The repair commit is `aeb3e8d715`.

**Verdict: FAIL.** The repair introduced one regression, B6, and it blocks. The fix is a single line. Every Review 1 blocker (B1–B4), the find-in-page ruling, and N1, N2, N3, N4, N5 and N7 are fixed. Each has a test that goes red without its fix, with one exception: N10 is fixed but its harness case can't detect the bug (V2 below).

## Checks run at this head

- **Atlas tagged build** `rv-360` (invocation `02ae319a4c864308a3b8b1e697946bfa`): `compile=ok`.
- **Native logic tests on Atlas** (`c11LogicTests/MarkdownReaderInteractionTests` and `MarkdownPanelFontScaleTests`, invocation `4bcf0643352949e899d4c27d0613dbcc`): 11/11 passed, `** TEST SUCCEEDED **`. The new file is in the `c11LogicTests` target, as the brief asked.
- **Native mutation run** (`d2adf7ea4c754238ae45f64a7e022c24`): `** TEST FAILED **`, as intended. I made two changes in a scratch worktree, not the review checkout:
  - Hard-coding ⇧⌘O in `MarkdownReaderShortcutRouter` turned `testOutlineShortcutRoutesThroughCustomizedRegistryToPanelAndStubRenderer` red.
  - Dropping the `pageConsumedEscape` guard turned `testNativeEscapeFallbackRunsOnlyAfterPageLeavesEscapeUnhandled` red.
- **Web harness, headless**: 37/37 scenarios passed, with zero console errors and zero network requests.
- **Localization**: `jq empty` passes. All 37 Swift keys in the diff have ja, uk, ko, zh-Hans, zh-Hant and ru values, and the format tokens match.
- **UI evidence**: the owner's refreshed artifacts. My own resize sweep guest (`rv360b`) came up on a macOS Setup Assistant pane. Quitting that pane killed the guest's display session, so I deleted the guest and used the owner's tagged-build screenshots plus a direct SwiftUI layout measurement instead.

## Repair checks

| Item | Fix at this head | Red without the fix |
|---|---|---|
| B1 theme vs chrome contrast | The toolbar sets `.environment(\.colorScheme, palette…)`; both button styles draw in `palette.ink`. The owner's shots show Light reader in dark c11 and Dark reader in light c11, and every glyph is readable. | Visual only; the native colour path has no harness. The owner shot all six theme × appearance combinations. |
| B2 cluster below 430 px | The breadcrumb is present at every width, and the controls are pinned trailing. | Code. But it introduced B6. |
| B3 button styling | The new `MarkdownOmnibarButtonStyle` matches the browser's (8 pt continuous radius, hover 0.08, pressed 0.16). Open externally and the theme button are 22 pt with an 11 pt glyph. Find, source, − and + are 26 pt with a 13 pt glyph, matching the prototype's `.ib`. The outline toggle is 92/30 in full ink. The theme menu uses `.menuIndicator(.hidden)` (no chevron in the shots). | Visual |
| B4 filter placeholder | `renderOutlineList` sets `outlineFilter.placeholder`. | Removing it turned the harness red: "outline filter placeholder did not use its localized string". |
| Ruling: find in the page | The native find bar, its state and its `onExitCommand` are removed. The page has the popover (356 px, `--pop`), count, ↑ ↓ ×, gold ticks and debounce. ⌘F and the toolbar button reach `openFind` through `WorkspaceManager.startSearch` and `requestFind`. Eviction restores the open state through `findOpen`. | Dropping Esc-closes-find turned the harness red. Dropping input focus turned it red (TimeoutError). Repainting a stale query (N13) turned it red (TimeoutError). |
| N1 shortcut routing | The hard-coded ⌘F block is gone; ⌘F uses the existing Find menu route. ⇧⌘O is the registry action `toggleMarkdownOutline` (default ⇧⌘O), read through `KeyboardShortcutSettings.shortcut(for:)`. | The native mutation turned it red, as above. |
| N2 Escape ordering | Native no longer intercepts Escape in `keyDown`. The page handles diagram, then footnote, then find, then filter text, then outline, and posts `escapeUnhandled` only when it consumed nothing. | The harness goes red when filter-first is dropped. The native test goes red when the guard is dropped. |
| N3 breadcrumb at narrow widths | Below 600 px the breadcrumb shows only the heading, with tail truncation. The 560 px shot shows "welcome to c11". | Visual |
| N4 progress width | 128 pt reserved with tail truncation; there is no `minimumScaleFactor`. | Code |
| N5 native tests | Four stub-renderer tests: toggle persistence, Escape fallback, find focus policy, customized-registry routing. | Two of the four were proven red above. |
| N7 doc note | One line in `docs/markdown-viewer-design.md`. "System" now reads "c11 effective appearance" in the doc, BRIDGE.md and the skill, per the ruling. | n/a |
| Review 2 B5 (source gutter) | `srcScroller.style.paddingLeft = dockGutter`. | Removing it turned the harness red: "docked outline covered source line number". |

## Blocking

**B6. The B2 fix halves the breadcrumb's space at wide widths and leaves the progress readout floating mid-bar.**
- Where: `Sources/Panels/MarkdownPanelView.swift:381-382`, where `controls` now gets `.frame(maxWidth: .infinity, alignment: .trailing)`.
- Cause: the breadcrumb is also `maxWidth: .infinity`. SwiftUI splits the free space equally between the two flexible children, so the breadcrumb is capped at half of it. The rest becomes an empty gap between the progress readout and the cluster.
- I measured it with an `NSHostingView` probe (`verify1-C11-360-evidence/hstack-split-probe.swift`):

  | Toolbar width | With the controls frame | Without it |
  |---|---|---|
  | 1120 pt | breadcrumb 430, controls frame 430 | breadcrumb 645, controls 215 |
  | 800 pt | breadcrumb 270 | breadcrumb 325 |

- The owner's own Light-in-dark-chrome shot shows it (`verify1-C11-360-evidence/v2-wide-toolbar-repaired.png`): "0% · 3 min left" sits mid-bar, about 230 px left of the find glyph. At `cc7ae25` it sat against the cluster, as in the prototype (`.crumb{flex:1}`, `.prog` immediately before `.tools`).
- Effect: a long heading path (file › section › subsection) truncates while part of the toolbar sits empty. The breadcrumb is the reader's position cue, so this is a regression from a fix.
- Fix: delete line 382. The breadcrumb is now flexible at every width, so it alone keeps the cluster trailing, including below 430 px where the progress readout is hidden. The probe confirms the cluster stays at 215 pt and trailing without the frame.

## Non-blocking

- **V1. The source toggle's pressed state draws differently from its neighbours.** It keeps `MarkdownChromeButtonStyle` (5 pt radius, no hover) beside the omnibar-styled icons (8 pt radius, hover). The prototype's `.ib.on` uses the 8 pt radius.
- **V2. The N10 harness case can't catch its bug.** I put the unforced `updateOutlineActive()` back and the harness stayed green. The settings re-layout that lands during the fill forces the mark anyway. A standalone probe (scroll to Section 12, wait, then filter) does reproduce it: `on=section-12` with the fix, no mark without it. So the fix works, but the guard needs a settled wait before filtering.
- **V3. The owner's validation says they synced the installed skill copies earlier, from the branch.** Installed copies may hold pre-merge text. The Merge Captain should run `scripts/sync-installed-skills.sh c11-markdown` from merged main.
