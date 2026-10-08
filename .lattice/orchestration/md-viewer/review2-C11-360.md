# Review 2: C11-360 reader chrome, PR #623

Reviewer: agent:grok-md-review-360-g (Grok, cross-family). Read-only.
Head reviewed: `cc7ae2596302469000e2df519bfb89b4edb7e325` (asserted), diff `origin/main...HEAD`.

Review 1's B1–B4 and N1–N9 stand. This review does not repeat them. The native find bar's styling is left alone; the orchestrator has already ruled that find moves into the page.

**Verdict: FAIL.** One new blocking finding.

## What I ran

- Web harness, headless, no ports bound, no windows: `node scripts/markdown-viewer/test.mjs` passed **34/34**, with zero console errors and zero network requests. Playwright 1.56.1's pinned Chromium 1194 shell is missing on this machine, so the run used the installed 1223 headless shell via `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`. Evidence dir: `$TMPDIR/c11-md-358-evidence`.
- Mutation, scratch copy of `Resources/markdown-viewer` only, then deleted. Reserving the dock gutter only while the outline is open (`paddingLeft` gated on `S.docked && S.outlineOpen`) made the same harness fail at `scripts/markdown-viewer/test.mjs:173`: `docked outline open moved the text anchor horizontally 166 -> 300`. On the unmodified bundle, opening and closing the outline at 1400 px moves the read-column anchor by 0, 0.
- Headless geometry on the real bundle at 1400×900, light, serif, scale 1, outline explicitly open and docked, then source mode. Screenshot: `/tmp/md360-shots/source-docked.png`.
- Headless outline at scale 3, viewport 1600×700 (effective width 533, so overlay). Screenshot: `/tmp/md360-shots/scale3-outline.png`.
- Localization: 46 `markdown.reader.*` keys, ja / uk / ko / zh-Hans / zh-Hant / ru all present, format tokens match. The catalog parses as JSON.
- No Atlas build and no c11 launch. The new failure is in the page bundle, and the headless page shows it. Review 1 already holds the native toolbar evidence.

## Invariants

- **(a) The text never moves.** Holds for the cases the harness covers: theme, typeface, scale, outline open and close, source-toggle position, reload. The gutter mutation shows the reserved dock padding is what keeps the read column still. No new break.
- **(b) Controls never jump or clip.** No new toolbar break beyond Review 1 B2 and B3. At 300% the outline filter glyphs are cropped (N11). That matches the prototype's fixed 38 px header, and the text stays readable.
- **(c) Docking.** The read column sits clear of a docked outline. An explicit close at a docked width stays closed and does not move the column. Source mode breaks "the open outline covers nothing" (B5).
- **(d) Keyboard.** No new finding. I did not rebuild the app, so Review 1's route notes stand.
- **(e) Prototype fidelity.** The new miss is one the round-4 prototype shares. The design doc wins on it (B5). Review 1's B1 and B3 are unchanged.
- **(f) Localization.** No new catalog miss. The hardcoded filter placeholder remains Review 1 B4.

## Blocking

**B5. In source mode a docked outline covers the line numbers and the start of every line.**

- Where: `Resources/markdown-viewer/viewer.js:549` sets `paddingLeft` on `#layout` only. The source scroller is a sibling (`index.html:32`, shown by `viewer.css:306-308`). The outline is `position: absolute` over the whole surface (`viewer.css:35-37`). Source rows place the line number in the first `54px * scale` and the text immediately after (`viewer.css:275-277`).
- Measured at 1400×900, serif, scale 1, outline open and docked (`choice: true`, effective width 1400): the panel's right edge is 272. Line numbers occupy 0–54 and are fully under the panel (`elementFromPoint` hits `.ohead`). Source text starts at 54, and 218 px of it is under the panel (`elementFromPoint` on the first line hits `#outlineFilter`). The screenshot shows only the tail of each line ("line.") beside the frosted panel.
- Normal path: a wide pane docks and opens the outline by default. The source toggle then hides the start of every line, including the line number. Closing the outline reveals the text. The read column is padded and is not covered.
- The round-4 prototype pads only the read layout as well (`docs/design-prototypes/markdown-viewer/reader/index.html` around the dock block). The design doc wins where they disagree: "the column is laid out clear of the panel, so the open outline covers nothing" (`docs/markdown-viewer-design.md`, Outline). The harness checks that a source toggle keeps the same line and offset. It never checks whether the outline covers that line, which is why 34/34 stays green.
- Fix: give `#srcScroller` the same dock gutter as `#layout`, reserved whether or not the outline is open, so closing the outline does not shift source lines either.

## Non-blocking

- **N10. Typing in the outline filter drops the scrollspy mark.** `renderOutlineList` ends with `updateOutlineActive()` and no force (`viewer.js:398`). The early return when the slug is unchanged (`viewer.js:402-404`) skips `.on` and `.read` on the links just created. Before a filter, `section-12` was `l2 show on`. During the filter "Detail 12", `section-12` was `l2` and `detail-12` was `l3`. The current row stays in the list. The mark returns on the next heading change, which calls `updateOutlineActive(true)`. Fix: pass `true` at the end of `renderOutlineList`.
- **N11. At 300% the outline filter glyphs are cut at the top.** `.ohead` is a fixed 38 px and the input is 30 px tall with `font-size: calc(12px * var(--scale))` (`viewer.css:47-48`). At scale 3 that is 36 px type in a 30 px box. The screenshot shows the tops of "Detail 12" cut off. The round-4 prototype uses the same header metrics, and the letters stay readable, so this is not a doc-specified size deviation.
- **N12. An explicit outline choice is stored on the snapshot as `"auto"`.** The page publishes `choice` as a boolean (`viewer.js:721`; the probe saw `"choice": true`). Swift keeps it with `outline["choice"] as? String ?? "auto"` (`MarkdownWebRenderer.swift:397`). Nothing reads `MarkdownReaderOutlineSnapshot.choice` today. The toolbar uses `isOpen` (`MarkdownPanelView.swift:424`) and persistence uses the presentation flag. No visible loop. A later reader of the snapshot will treat an explicit open or close as auto.
- **N13. Clearing the find field can paint the previous query back for one bridge round-trip.** The field getter returns `readerFind.value?.query` whenever `panel.findQuery` is empty (`MarkdownPanelView.swift:353`). Deleting the last character stores an empty query, then the getter restores the stale bridge query until `setFindQuery` lands. I read this from the binding. I did not drive the native field.

## Not re-opened

Review 1 B1–B4, N1–N9, the native find bar's styling, and the 15–18 px dock-threshold note (N7).
